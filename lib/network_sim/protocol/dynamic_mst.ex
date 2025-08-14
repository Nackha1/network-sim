defmodule NetworkSim.Protocol.DynamicMST do
  @moduledoc """
  Dynamic MST (failure-only) protocol, implementing the appendix steps **(1)–(7)** of
  Cheng–Cimet–Kumar’88 — i.e., **link-failure response only**: fragment re-identification
  and minimum-outgoing-edge (moe) discovery/propagation. Recovery is intentionally
  omitted here and will be added in a subsequent step.

  ## Message names and node finite states

    * Messages: `:FAILURE`, `:REIDEN`, `:REIDEN_ACK`, `:FINDMOE`, `:FINDMOE_ACK`,
      `:CHANGE_ROOT`, `:TEST`, `:ACCEPT`, `:REJECT`
    * Node f-states: `:sleep | :reiden | :find | :found`

  The Router sends control notifications:
    * `{:router_link_down, neighbor, %{edge: {a,b}, attrs: %{weight: w}}}`
      (we treat `(a,b)` as undirected, and use `w` for fragment-id)

  ### References (paper appendix)
  Clauses (1)–(7): failure notification, FAILURE propagation, REIDEN broadcast/echo,
  FINDMOE broadcast/echo with TEST/ACCEPT/REJECT, CHANGE-ROOT and CONNECT emission.
  """

  @behaviour NetworkSim.Protocol
  require Logger
  alias NetworkSim.Router

  @type node_id :: term()
  @type edge :: {node_id(), node_id()}
  @type edge_key :: edge()
  @type weight :: number()
  @type fragment_id :: {weight(), node_id()}
  @type moe :: :none | {:edge, {edge_key(), weight()}}

  @typedoc "Local protocol state"
  @type t :: %{
          id: node_id(),

          # Tree structure (directed: parent=nil only at root)
          parent: node_id() | nil,
          children: MapSet.t(node_id()),

          # Fragment identity and failure-fsm state
          fragment_id: fragment_id() | nil,
          f_state: :sleep | :reiden | :find | :found,

          # Non-tree neighbors (computed from Router.neighbors - tree endpoints)
          non_tree: MapSet.t(node_id()),

          # REIDEN broadcast-echo bookkeeping
          reiden_acks_expected: non_neg_integer(),

          # FINDMOE broadcast-echo bookkeeping
          find_acks_expected: non_neg_integer(),
          child_reports: %{optional(node_id()) => {:none | {:edge, edge_key(), weight()}}},
          local_moe: moe(),

          # TEST tracking
          test_pending: MapSet.t(node_id()),
          test_results: [{node_id(), weight()}],

          # CHANGE_ROOT forwarding bookkeeping (which child reported the chosen moe)
          reporter_for_moe: node_id() | nil
        }

  @impl true
  @doc """
  Initialize node with the initial MST orientation:

      NetworkSim.Node.start_link(:a, protocol: {DynamicMST, %{parent: p, children: [..]}})

  The initial MST is a **directed rooted tree** as required by the protocol. All nodes
  begin in `:sleep`.
  """
  @spec init(node_id(), %{parent: node_id() | nil, children: [node_id()]}) :: t()
  def init(id, %{parent: parent, children: children0}) do
    children = MapSet.new(children0)

    # non-tree = neighbors - (parent ∪ children)
    neighbors = Router.neighbors(id)
    non_tree = neighbors |> MapSet.delete(parent) |> MapSet.difference(children)

    Logger.debug(
      "Node #{id} initialized with non-tree neighbors: #{inspect(non_tree)}, from neighbors=#{inspect(neighbors)} and children=#{inspect(children)}"
    )

    %{
      id: id,
      parent: parent,
      children: children,
      fragment_id: nil,
      f_state: :sleep,
      non_tree: non_tree,
      reiden_acks_expected: 0,
      find_acks_expected: 0,
      child_reports: %{},
      local_moe: :none,
      test_pending: MapSet.new(),
      test_results: [],
      reporter_for_moe: nil
    }
  end

  @impl true
  @doc """
  Message handler. We only implement **failure** side (appendix (1)–(7)).

  The `from` is either a neighbor node id, or `:router` for control notifications.
  """
  @spec handle_message(from :: term(), payload :: term(), st :: t()) ::
          {:noreply, t()} | {:reply, term(), t()}
  def handle_message(
        :router,
        {:router_link_down, neighbor, %{edge: {a, b}, attrs: %{weight: w}}},
        st
      ) do
    # Detect which side of the tree this node is on for the failed tree edge.
    # If it's a *non-tree* link, just forget it locally (paper 4.1 first paragraph).
    cond do
      # Child endpoint lost its parent ⇒ becomes root and *enters REIDEN* (appendix (1))
      st.parent == neighbor ->
        fid = {w, st.id}

        st
        |> become_root_and_set_fragment(fid)
        |> enter_reiden_broadcast()

      # Parent endpoint lost a child ⇒ propagate FAILURE upward with new fid (appendix (1))
      MapSet.member?(st.children, neighbor) ->
        fid = {w, st.id}
        handle_failure_upward(fid, st)

      # Non-tree failed: drop from non_tree set (paper 4.1 opening line)
      MapSet.member?(st.non_tree, neighbor) ->
        {:noreply, %{st | non_tree: MapSet.delete(st.non_tree, neighbor)}}

      true ->
        {:noreply, st}
    end
  end

  # (2) Response to FAILURE<fid>
  def handle_message(from, {:dmst, :FAILURE, fid}, st) do
    cond do
      # If I'm the root, adopt fid and start REIDEN broadcast (appendix (2))
      st.parent == nil ->
        st
        |> set_fragment(fid)
        |> enter_reiden_broadcast()

      # Otherwise forward FAILURE upward (appendix (2))
      true ->
        _ = safe_send(st.id, st.parent, {:dmst, :FAILURE, fid})
        {:noreply, st}
    end
  end

  # (3) Response to REIDEN<fid> (broadcast down); reply with REIDEN_ACK at leaves
  def handle_message(from, {:dmst, :REIDEN, fid}, st) do
    st1 =
      st
      |> set_fragment(fid)
      |> set_state(:reiden)

    # forward to all children except the sender (tree is directed; sender should be parent)
    childs = st1.children

    cond do
      MapSet.size(childs) == 0 ->
        # I'm a leaf: send REIDEN_ACK to parent (appendix (3))
        _ = safe_send(st1.id, st1.parent, {:dmst, :REIDEN_ACK, fid})
        {:noreply, st1}

      true ->
        Enum.each(childs, fn c -> safe_send(st1.id, c, {:dmst, :REIDEN, fid}) end)
        {:noreply, st1}
    end
  end

  # (4) Response to REIDEN-ACK<fid>; root launches FINDMOE when all acks received
  def handle_message(from, {:dmst, :REIDEN_ACK, fid}, st) do
    # Accept only if ids match (appendix (4))
    if st.fragment_id == fid do
      st1 = dec_reiden_ack(st)

      if st1.reiden_acks_expected == 0 do
        if st1.parent == nil do
          # I'm the leader/root; start FINDMOE broadcast (appendix (4))
          st2 = st1 |> set_state(:find)
          Enum.each(st2.children, fn c -> safe_send(st2.id, c, {:dmst, :FINDMOE, fid}) end)
          # Root also "participates" locally: issue TESTs on its non-tree links
          st3 = issue_tests(st2)
          {:noreply, st3}
        else
          # Forward REIDEN_ACK to parent
          _ = safe_send(st1.id, st1.parent, {:dmst, :REIDEN_ACK, fid})
          {:noreply, st1}
        end
      else
        {:noreply, st1}
      end
    else
      {:noreply, st}
    end
  end

  # (5) Response to FINDMOE<fid>: issue TEST to all non-tree links; echo up with local moe
  def handle_message(from, {:dmst, :FINDMOE, fid}, st) do
    if st.fragment_id == fid do
      st1 =
        st
        |> set_state(:find)
        |> issue_tests()
        # Forse funziona
        |> maybe_finish_tests_and_report(fid)

      # if MapSet.size(st1.children) == 0 do
      #   # Leaf: send local moe immediately (appendix (5))
      #   _ = safe_send(st1.id, st1.parent, {:dmst, :FINDMOE_ACK, fid, st1.local_moe})
      #   {:noreply, st1 |> set_state(:found)}
      # else
      #   # Forward FINDMOE to children
      #   Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:dmst, :FINDMOE, fid}) end)
      #   {:noreply, st1}
      # end

      # If I *do* have children, I wait for their FINDMOE acks; initialize expected count.
      set_find_acks_expected(st1, MapSet.size(st1.children))
      # Forward FINDMOE to children
      Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:dmst, :FINDMOE, fid}) end)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  # (test) Receiving TEST<fid> over a non-tree link — ACCEPT if fragment differs, else REJECT
  def handle_message(from, {:dmst, :TEST, fid}, st) do
    resp =
      if st.fragment_id == fid do
        {:dmst, :REJECT, fid}
      else
        {:dmst, :ACCEPT, fid}
      end

    _ = safe_send(st.id, from, resp)
    {:noreply, st}
  end

  # (test reply) ACCEPT — record weight(from) as candidate; REJECT — ignore
  def handle_message(from, {:dmst, :ACCEPT, fid}, st) do
    if st.fragment_id == fid do
      w = edge_weight(st.id, from)

      st1 =
        st
        |> add_test_result({from, w})
        |> maybe_finish_tests_and_report(fid)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:dmst, :REJECT, fid}, st) do
    if st.fragment_id == fid do
      st1 =
        st
        |> add_test_result({from, nil})
        |> maybe_finish_tests_and_report(fid)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  # (6) Response to FINDMOE-ACK<fid, moe> from a child; root chooses global moe and sends CHANGE-ROOT
  def handle_message(from, {:dmst, :FINDMOE_ACK, fid, child_moe}, st) do
    if st.fragment_id == fid do
      st1 =
        st
        |> store_child_report(from, child_moe)
        |> dec_find_ack()

      # When a non-root has all child-acks: send my moe upward
      cond do
        st1.parent != nil and st1.find_acks_expected == 0 ->
          # My local moe competes with children’s; pick best
          chosen = best_moe([st1.local_moe | Map.values(st1.child_reports)])
          _ = safe_send(st1.id, st1.parent, {:dmst, :FINDMOE_ACK, fid, chosen})
          {:noreply, st1 |> set_state(:found)}

        st1.parent == nil and st1.find_acks_expected == 0 ->
          # Root: pick global moe and issue CHANGE-ROOT along reporter path (appendix (6))
          chosen = best_moe([st1.local_moe | Map.values(st1.child_reports)])

          case chosen do
            :none ->
              # No outgoing edge: either whole net or disconnected component (paper 4.1 end). We just go sleep.
              {:noreply, st1 |> set_state(:sleep)}

            {:edge, {u, v}, _w} ->
              reporter = reporter_child_for(chosen, st1)
              st2 = %{st1 | reporter_for_moe: reporter}

              if reporter do
                _ = safe_send(st2.id, reporter, {:dmst, :CHANGE_ROOT, fid, chosen})
                {:noreply, st2}
              else
                # moe is incident to root ⇒ proceed directly (appendix (7) will send CONNECT)
                _ = send_connect_for(chosen, st2)
                {:noreply, st2}
              end
          end

        true ->
          {:noreply, st1}
      end
    else
      {:noreply, st}
    end
  end

  # (7) Response to CHANGE-ROOT<fid, moe>
  def handle_message(from, {:dmst, :CHANGE_ROOT, fid, {:edge, {u, v} = e, _w}}, st) do
    # Orient root-change down toward the endpoint; if incident, emit CONNECT (appendix (7))
    if st.fragment_id == fid do
      if st.id == u or st.id == v do
        # I'm incident to moe — send CONNECT over moe
        _ = send_connect_for({:edge, e, _w = edge_weight(u, v)}, st)
        {:noreply, st}
      else
        # Forward to the child that reported this moe in my subtree
        # weight not used to match child
        reporter = reporter_child_for({:edge, e, 0}, st)

        if reporter do
          _ =
            safe_send(
              st.id,
              reporter,
              {:dmst, :CHANGE_ROOT, fid, {:edge, e, edge_weight(elem(e, 0), elem(e, 1))}}
            )
        end

        {:noreply, st}
      end
    else
      {:noreply, st}
    end
  end

  # Optional: we *emit* CONNECT here as required by (7); the *merge mechanics* (tree re-orientation,
  # merging fragments, restarting the next round) are intentionally not implemented in this step-set.
  def handle_message(_from, {:dmst, :CONNECT, _fid}, st) do
    # No-op in steps (1)-(7). Future steps will merge trees here.
    {:noreply, st}
  end

  ## ——— Helpers ———

  @doc """
  Enter `:reiden` at the **root** and broadcast `REIDEN<fragment_id>` to all children;
  set up expected REIDEN_ACK count (appendix (2), (3), (4)).”
  """
  @spec enter_reiden_broadcast(t()) :: {:noreply, t()}
  def enter_reiden_broadcast(%{fragment_id: nil} = st),
    # should not happen; guard
    do: {:noreply, st}

  def enter_reiden_broadcast(st) do
    st1 =
      st
      |> set_state(:reiden)
      |> set_reiden_acks_expected(MapSet.size(st.children))

    Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:dmst, :REIDEN, st1.fragment_id}) end)
    {:noreply, st1}
  end

  defp become_root_and_set_fragment(st, fid) do
    %{st | parent: nil, fragment_id: fid}
  end

  defp set_fragment(st, fid), do: %{st | fragment_id: fid}

  defp set_state(st, s), do: %{st | f_state: s}

  defp set_reiden_acks_expected(st, n), do: %{st | reiden_acks_expected: n}

  defp dec_reiden_ack(%{reiden_acks_expected: n} = st),
    do: %{st | reiden_acks_expected: max(n - 1, 0)}

  defp set_find_acks_expected(st, n), do: %{st | find_acks_expected: n}
  defp dec_find_ack(%{find_acks_expected: n} = st), do: %{st | find_acks_expected: max(n - 1, 0)}

  defp store_child_report(st, child, moe),
    do: %{st | child_reports: Map.put(st.child_reports, child, moe)}

  defp handle_failure_upward(fid, st) do
    # Appendix (1): if f-state == :found, hold; if in :reiden or :find, forward.
    # To keep this minimal/lock-free at this step, we forward unless :found.
    case st.f_state do
      :found ->
        # Keep it simple: buffer is skipped in this iteration. One can add a queue here.
        _ = safe_send(st.id, st.parent, {:dmst, :FAILURE, fid})
        {:noreply, st}

      _ ->
        _ = safe_send(st.id, st.parent, {:dmst, :FAILURE, fid})
        {:noreply, st}
    end
  end

  ## TEST phase

  defp issue_tests(%{non_tree: nts} = st) do
    fid = st.fragment_id
    Enum.each(nts, fn n -> safe_send(st.id, n, {:dmst, :TEST, fid}) end)
    %{st | test_pending: nts, test_results: [], local_moe: :none}
  end

  defp add_test_result(st, {n, nil}) do
    %{
      st
      | test_pending: MapSet.delete(st.test_pending, n)
    }
  end

  defp add_test_result(st, {n, w}) do
    %{
      st
      | test_results: [{n, w} | st.test_results],
        test_pending: MapSet.delete(st.test_pending, n)
    }
  end

  defp maybe_finish_tests_and_report(%{test_pending: pend} = st, fid) do
    if MapSet.size(pend) == 0 do
      # compute local moe
      moe =
        case st.test_results do
          [] ->
            :none

          results ->
            {n, w} = Enum.min_by(results, fn {_n, w} -> w end)
            {:edge, undirected(st.id, n), w}
        end

      st1 = %{st | local_moe: moe, test_results: []}

      # If I have no children, I’m a leaf: send up now.
      if MapSet.size(st1.children) == 0 do
        _ = safe_send(st1.id, st1.parent, {:dmst, :FINDMOE_ACK, fid, st1.local_moe})
      end

      st1
    else
      st
    end
  end

  defp best_moe(list) do
    list
    |> Enum.reject(&(&1 == :none))
    |> case do
      [] -> :none
      xs -> Enum.min_by(xs, fn {:edge, _e, w} -> w end)
    end
  end

  defp reporter_child_for(:none, _st), do: nil

  defp reporter_child_for({:edge, {u, v}, _w}, st) do
    # Pick the child whose reported moe equals this edge (by endpoints).
    Enum.find(st.children, fn c ->
      case Map.get(st.child_reports, c) do
        {:edge, {x, y}, _} -> MapSet.new([x, y]) == MapSet.new([u, v])
        _ -> false
      end
    end)
  end

  defp send_connect_for({:edge, {u, v}, _w}, st) do
    # Emit CONNECT over the moe (appendix (7)). Merge mechanics come in later steps.
    other = if st.id == u, do: v, else: if(st.id == v, do: u, else: nil)

    if other do
      safe_send(st.id, other, {:dmst, :CONNECT, st.fragment_id})
    else
      # If called at root not incident to moe, this will be forwarded down first.
      :ok
    end
  end

  defp undirected(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  defp edge_weight(a, b) do
    case Router.edge_attr(a, b) do
      %{:weight => w} -> w
      %{"weight" => w} -> w
      _ -> :infinity
    end
  end

  defp safe_send(_from, nil, _msg), do: :ok

  defp safe_send(from, to, msg) do
    case NetworkSim.send(from, to, msg) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end
end
