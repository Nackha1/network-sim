defmodule NetworkSim.Protocol.DynamicMST do
  @moduledoc """
  Dynamic MST (failure-only) protocol, implementing the appendix steps **(1)–(7)** of
  Cheng–Cimet–Kumar’88 — i.e., **link-failure response only**: fragment re-identification
  and minimum-outgoing-edge (moe) discovery/propagation. Recovery is intentionally
  omitted here and will be added in a subsequent step.

  ## Message names and node finite states

    * Messages: `:FAILURE`, `:REIDEN`, `:REIDEN_ACK`, `:FINDMOE`, `:FINDMOE_ACK`,
      `:CHANGE_ROOT`, `:TEST`, `:ACCEPT`, `:REJECT`, `:GOSLEEP`
    * Node f-states: `:sleep | :reiden | :find | :found`

  The Router sends control notifications:
    * `{:router_link_down, neighbor, %{edge: {a,b}, attrs: %{weight: w}}}`
      (we treat `(a,b)` as undirected, and use `w` for fragment-id)
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
          neighbors: MapSet.t(node_id()),

          # Fragment identity and failure-fsm state
          fragment_id: fragment_id() | nil,
          f_state: :sleep | :reiden | :find | :found,

          # Non-tree neighbors (computed from Router.neighbors - tree endpoints)
          # non_tree: MapSet.t(node_id()),

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
          reporter_for_moe: node_id() | nil,

          # === NEW: GHS-style merge handshake tracking ===
          connect_sent: MapSet.t(node_id()),
          connect_recv: MapSet.t(node_id())
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

    neighbors = Router.neighbors(id)

    %{
      id: id,
      parent: parent,
      children: children,
      neighbors: neighbors,
      fragment_id: nil,
      f_state: :sleep,
      reiden_acks_expected: 0,
      find_acks_expected: 0,
      child_reports: %{},
      local_moe: :none,
      test_pending: MapSet.new(),
      test_results: [],
      reporter_for_moe: nil,
      connect_sent: MapSet.new(),
      connect_recv: MapSet.new()
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
    st = %{st | neighbors: MapSet.delete(st.neighbors, neighbor)}

    cond do
      # Non-tree failed: no-op
      not is_tree_link?(st, neighbor) ->
        Logger.info("Non-tree link failed, no action required")
        {:noreply, st}

      # Child endpoint lost its parent ⇒ becomes root and *enters REIDEN* (appendix (1))
      st.parent == neighbor ->
        fid = {w, st.id}

        st1 = st |> become_root() |> reiden_handler(fid)
        # safe_send(st1.id, st1.id, {:dmst, :REIDEN, fid})
        {:noreply, st1}

      # Parent endpoint lost a child ⇒ propagate FAILURE upward with new fid (appendix (1))
      true ->
        fid = {w, st.id}
        st1 = st |> set_fragment(fid) |> remove_child(neighbor)
        safe_send(st1.id, st1.id, {:dmst, :FAILURE, fid})

        {:noreply, st1}
    end
  end

  def reiden_handler(st, fid) do
    st1 =
      st
      |> reset_state(:reiden)
      |> set_fragment(fid)
      |> set_reiden_acks_expected(MapSet.size(st.children))

    if MapSet.size(st1.children) == 0 do
      if is_root?(st1) do
        # I'm the root: start FINDMOE
        safe_send(st1.id, st1.id, {:dmst, :FINDMOE, fid})
      else
        # I'm a leaf: send REIDEN_ACK to parent
        safe_send(st1.id, st1.id, {:dmst, :REIDEN_ACK, fid})
      end
    else
      # Send to children
      Enum.each(st1.children, fn c ->
        safe_send(st1.id, c, {:dmst, :REIDEN, fid})
      end)
    end

    st1
  end

  # (2) Response to FAILURE<fid>
  def handle_message(from, {:dmst, :FAILURE, fid}, st) do
    cond do
      # If I'm the root, adopt fid and start REIDEN broadcast (appendix (2))
      st.parent == nil ->
        st1 = st |> set_fragment(fid)

        safe_send(st1.id, st1.id, {:dmst, :REIDEN, fid})
        {:noreply, st1}

      # Otherwise forward FAILURE upward (appendix (2))
      true ->
        send_parent(st, {:dmst, :FAILURE, fid})
        {:noreply, st}
    end
  end

  # (3) Response to REIDEN<fid> (broadcast down); reply with REIDEN_ACK at leaves
  def handle_message(from, {:dmst, :REIDEN, fid}, st) do
    # st1 =
    #   st
    #   |> set_fragment(fid)
    #   |> set_state(:reiden)
    #   |> set_reiden_acks_expected(MapSet.size(st.children))

    # cond do
    #   MapSet.size(st1.children) == 0 ->
    #     # I'm a leaf: send REIDEN_ACK to parent (appendix (3))
    #     _ = safe_send(st1.id, from, {:dmst, :REIDEN_ACK, fid})
    #     {:noreply, st1}

    #   true ->
    #     Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:dmst, :REIDEN, fid}) end)
    #     {:noreply, st1}
    # end
    {:noreply, reiden_handler(st, fid)}
  end

  # (4) Response to REIDEN-ACK<fid>; root launches FINDMOE when all acks received
  def handle_message(from, {:dmst, :REIDEN_ACK, fid}, st) do
    # Accept only if ids match (appendix (4))
    if st.fragment_id == fid do
      st1 = dec_reiden_ack(st)

      if st1.reiden_acks_expected == 0 do
        if st1.parent == nil do
          # I'm the leader/root; start FINDMOE broadcast (appendix (4))
          safe_send(st1.id, st1.id, {:dmst, :FINDMOE, fid})
          {:noreply, st1}
        else
          # Forward REIDEN_ACK to parent
          send_parent(st1, {:dmst, :REIDEN_ACK, fid})
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
        |> set_find_acks_expected(MapSet.size(st.children))
        |> issue_tests()
        |> maybe_finish_tests_and_report(fid)

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

          reporter =
            case chosen do
              :none ->
                nil

              child ->
                # If we have a chosen moe, find the child that reported it
                reporter_child_for(child, st1)
            end

          st2 = %{st1 | reporter_for_moe: reporter}

          send_parent(st2, {:dmst, :FINDMOE_ACK, fid, chosen})
          # safe_send(st1.id, st1.parent, {:dmst, :FINDMOE_ACK, fid, chosen})

          {:noreply, st2 |> set_state(:found)}

        st1.parent == nil and st1.find_acks_expected == 0 and
            MapSet.size(st1.test_pending) == 0 ->
          # Root: pick global moe and issue CHANGE-ROOT along reporter path (appendix (6))
          chosen = best_moe([st1.local_moe | Map.values(st1.child_reports)])

          case chosen do
            :none ->
              # No outgoing edge: either whole net or disconnected component (paper 4.1 end). We just go sleep.
              safe_send(st1.id, st1.id, {:dmst, :GOSLEEP, fid})
              {:noreply, st1}

            {:edge, {u, v}, _w} ->
              reporter = reporter_child_for(chosen, st1)
              st2 = %{st1 | reporter_for_moe: reporter}

              if reporter do
                safe_send(st2.id, reporter, {:dmst, :CHANGE_ROOT, fid, chosen})

                {:noreply,
                 %{
                   st2
                   | parent: reporter,
                     children: MapSet.delete(st.children, reporter),
                     reporter_for_moe: nil
                 }}
              else
                # moe is incident to root ⇒ proceed directly (appendix (7) will send CONNECT)
                st3 = send_connect_for(chosen, st2)
                {:noreply, st3}
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
  def handle_message(from, {:dmst, :CHANGE_ROOT, fid, {:edge, {u, v} = e, w}}, st) do
    # Orient root-change down toward the endpoint; if incident, emit CONNECT (appendix (7))
    if st.fragment_id == fid do
      new_parent = st.reporter_for_moe

      st1 = %{
        st
        | parent: new_parent,
          children: MapSet.delete(MapSet.put(st.children, from), new_parent),
          reporter_for_moe: nil
      }

      if st1.id == u or st1.id == v do
        # I'm incident to moe — send CONNECT over moe
        st2 = send_connect_for({:edge, e, w}, st1)
        {:noreply, st2}
      else
        # Forward to the child that reported this moe in my subtree

        safe_send(st1.id, new_parent, {:dmst, :CHANGE_ROOT, fid, {:edge, e, w}})

        {:noreply, st1}
      end
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:dmst, :CONNECT, _fid}, st) do
    # TODO: Implement merging functionality
    # is_root = st.id > from

    # if is_root do
    #   st1 = %{
    #     st
    #     | children: MapSet.put(st.children, from)
    #   }

    #   # send_parent(st1, {:dmst, :REIDEN, st1.fragment_id})
    #   Logger.debug("Merging between #{st1.id} and #{from} completed")
    #   {:noreply, st1}
    # else
    #   # st1 = %{st | parent: from, non_tree: MapSet.delete(st.non_tree, from)}
    #   st1 = %{st | parent: from}
    #   {:noreply, st1}
    # end

    # We received CONNECT from `from`; record and check if we also sent to `from`
    st1 = mark_connect_recv(st, from)
    st2 = maybe_commit_merge(st1, from)
    {:noreply, st2}
  end

  def handle_message(_from, {:dmst, :GOSLEEP, fid}, st) do
    if st.fragment_id == fid do
      st1 = st |> set_state(:sleep)

      Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:dmst, :GOSLEEP, fid}) end)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  ## ——— Helpers ———

  defp become_root(st), do: %{st | parent: nil}

  defp remove_child(st, child), do: %{st | children: MapSet.delete(st.children, child)}

  defp set_fragment(st, fid), do: %{st | fragment_id: fid}

  defp set_state(st, s), do: %{st | f_state: s}

  defp set_reiden_acks_expected(st, n), do: %{st | reiden_acks_expected: n}

  defp dec_reiden_ack(%{reiden_acks_expected: n} = st),
    do: %{st | reiden_acks_expected: max(n - 1, 0)}

  defp set_find_acks_expected(st, n) do
    # Logger.debug("Setting find_acks_expected to #{n} for node #{st.id}")
    %{st | find_acks_expected: n}
  end

  defp dec_find_ack(%{find_acks_expected: n} = st) do
    # Logger.debug("Decrementing find_acks_expected from #{n} for node #{st.id}")
    %{st | find_acks_expected: max(n - 1, 0)}
  end

  defp store_child_report(st, child, moe),
    do: %{st | child_reports: Map.put(st.child_reports, child, moe)}

  ## TEST phase

  defp issue_tests(st) do
    fid = st.fragment_id
    out_neighs = st.neighbors |> MapSet.delete(st.parent) |> MapSet.difference(st.children)
    Enum.each(out_neighs, fn n -> safe_send(st.id, n, {:dmst, :TEST, fid}) end)
    %{st | test_pending: out_neighs, test_results: [], local_moe: :none}
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

      if st1.find_acks_expected == 0 do
        send_parent(st1, {:dmst, :FINDMOE_ACK, fid, st1.local_moe})

        # reset_state(st1, :found)
        st1 |> set_state(:found)
      else
        st1
      end
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

  # defp reporter_child_for(:none, _st), do: nil

  defp reporter_child_for({:edge, {u, v}, _w}, st) do
    # Pick the child whose reported moe equals this edge (by endpoints).
    Enum.find(st.children, fn c ->
      case Map.get(st.child_reports, c) do
        {:edge, {x, y}, _} -> MapSet.new([x, y]) == MapSet.new([u, v])
        _ -> false
      end
    end)
  end

  # defp send_connect_for({:edge, {u, v}, _w}, st) do
  #   # Emit CONNECT over the moe (appendix (7)).
  #   other = if st.id == u, do: v, else: u

  #   safe_send(st.id, other, {:dmst, :CONNECT, st.fragment_id})
  # end
  # === CONNECT helpers (handshake-aware) ===

  # Send CONNECT if we are incident to the edge; mark as "sent"; try to commit if peer already sent.
  defp send_connect_for({:edge, {u, v}, _w}, st) do
    other = if st.id == u, do: v, else: u

    safe_send(st.id, other, {:dmst, :CONNECT, st.fragment_id})
    st1 = mark_connect_sent(st, other)
    maybe_commit_merge(st1, other)
  end

  defp mark_connect_sent(st, n), do: %{st | connect_sent: MapSet.put(st.connect_sent, n)}
  defp mark_connect_recv(st, n), do: %{st | connect_recv: MapSet.put(st.connect_recv, n)}

  # Commit the merge only if we've both sent and received CONNECT on this neighbor.
  defp maybe_commit_merge(st, n) do
    if MapSet.member?(st.connect_sent, n) and MapSet.member?(st.connect_recv, n) do
      st
      |> commit_merge(n)
      |> clear_connect_flags(n)
    else
      st
    end
  end

  defp clear_connect_flags(st, n) do
    %{
      st
      | connect_sent: MapSet.delete(st.connect_sent, n),
        connect_recv: MapSet.delete(st.connect_recv, n)
    }
  end

  # Deterministic orientation: larger id becomes parent, smaller id becomes child.
  # This avoids cycles without levels.
  defp commit_merge(st, n) do
    cond do
      st.id > n ->
        # I am the parent; add neighbor as child
        %{st | children: MapSet.put(st.children, n)} |> become_root() |> reiden_handler(st.id)

      true ->
        # I am the child; set my parent to neighbor
        %{st | parent: n, children: MapSet.delete(st.children, n)}
    end
  end

  defp is_tree_link?(st, other) do
    st.parent == other or MapSet.member?(st.children, other)
  end

  defp is_root?(st), do: st.parent == nil

  defp undirected(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  defp edge_weight(a, b) do
    case Router.edge_attr(a, b) do
      %{:weight => w} -> w
      %{"weight" => w} -> w
      _ -> :infinity
    end
  end

  defp send_parent(st, msg) when st.parent == nil do
    safe_send(st.id, st.id, msg)
  end

  defp send_parent(st, msg) do
    safe_send(st.id, st.parent, msg)
  end

  # defp safe_send(_from, nil, _msg), do: :ok

  defp safe_send(from, to, msg) do
    case NetworkSim.send(from, to, msg) do
      :ok ->
        :ok

      {:error, e_msg} ->
        Logger.warning("Error when sending #{inspect(msg)} to #{inspect(to)}: #{inspect(e_msg)}")

        :ok
    end
  end

  defp reset_state(st, state) do
    %{
      st
      | f_state: state,
        reiden_acks_expected: 0,
        find_acks_expected: 0,
        child_reports: %{},
        local_moe: :none,
        test_pending: MapSet.new(),
        test_results: [],
        reporter_for_moe: nil
    }
  end
end
