defmodule NetworkSim.Protocol.DynamicMST do
  @moduledoc """
  Dynamic MST protocol
  """

  @behaviour NetworkSim.Protocol

  require Logger
  alias NetworkSim.Router

  @type node_id :: term()
  @type edge :: {node_id(), node_id()}
  @type edge_key :: edge()
  @type weight :: number()
  # Can be adjusted to allow failure counter
  @type fragment_id :: {weight(), node_id()}
  @type moe :: :none | {:edge, {edge_key(), weight()}}
  # Can be adjusted for same weight links
  @type edge_id :: weight()

  @typedoc "Local protocol state"
  @type t :: %{
          id: node_id(),

          # Tree structure
          parent: node_id() | nil,
          children: MapSet.t(node_id()),
          neighbors: MapSet.t(node_id()),

          # Fragment identity and state
          fragment_id: fragment_id() | nil,
          f_state: :sleep | :reiden | :find | :found | :recover,
          find_moe_round: non_neg_integer(),

          # REIDEN broadcast-echo bookkeeping
          reiden_acks_expected: non_neg_integer(),

          # FINDMOE broadcast-echo bookkeeping
          find_acks_expected: non_neg_integer(),
          local_moe: moe(),

          # TEST tracking
          test_pending: MapSet.t(node_id()),

          # CHANGE_ROOT forwarding bookkeeping (which child reported the chosen moe)
          reporter_for_moe: node_id() | nil,

          # GHS-style merge handshake tracking
          connect_sent: MapSet.t(node_id()),
          connect_recv: MapSet.t(node_id()),

          # Recovery tracking
          recovery_in_recv: %{edge_id() => {non_neg_integer(), node_id(), weight()}},
          recovery_in_sent: MapSet.t(edge_id()),
          curr_privilege: edge_id() | nil
        }

  @impl true
  @doc """
  Initialize node with the initial MST orientation:

      NetworkSim.Node.start_link(:a, protocol: {DynamicMST, %{parent: p, children: [..]}})

  The initial MST is a **directed rooted tree** as required by the protocol. All nodes
  begin in `:sleep`.
  """
  @spec init(node_id(), %{parent: node_id() | nil, children: [node_id()]}) :: t()
  def init(id, %{parent: parent, children: children}) do
    %{
      id: id,
      parent: parent,
      children: MapSet.new(children),
      neighbors: Router.neighbors(id),
      fragment_id: nil,
      f_state: :sleep,
      find_moe_round: 0,
      reiden_acks_expected: 0,
      find_acks_expected: 0,
      local_moe: :none,
      test_pending: MapSet.new(),
      reporter_for_moe: nil,
      connect_sent: MapSet.new(),
      connect_recv: MapSet.new(),
      recovery_in_recv: Map.new(),
      recovery_in_sent: MapSet.new(),
      curr_privilege: nil
    }
  end

  # RECOVERY Section

  @impl true
  def handle_message(
        :router,
        {:router_link_up, neighbor, %{edge: {_a, _b}, attrs: %{weight: w}}},
        st
      ) do
    Logger.info("Router link up: #{inspect(neighbor)} with weight #{inspect(w)}")
    st = %{st | neighbors: MapSet.put(st.neighbors, neighbor)}
    safe_send(st.id, neighbor, {:ID_CHECK, st.fragment_id})
    {:noreply, st}
  end

  @impl true
  def handle_message(from, {:ID_CHECK, fid}, %{fragment_id: fid} = st) do
    st = st |> set_state(:recover)
    w_e = edge_weight(st.id, from)
    w_prime = Enum.max([w_e, w_e])

    st =
      st
      |> recv_new_recovery(from, w_e, w_prime)
      |> maybe_propagate_recovery(from, fid, w_e, w_prime)

    {:noreply, st}
  end

  @impl true
  def handle_message(_from, {:ID_CHECK, _fid}, st) do
    st = st |> set_state(:recover)

    send_parent(st, {:RECOVERY_OUT, st.fragment_id})

    {:noreply, st}
  end

  @impl true
  def handle_message(_from, {:RECOVERY_OUT, fid}, %{fragment_id: fid} = st) do
    st = st |> set_state(:recover)

    if is_root?(st) do
      # I'm the root: start new FINDMOE round
      st = start_new_findmoe_round(st)
      {:noreply, st}
    else
      send_parent(st, {:RECOVERY_OUT, fid})
      {:noreply, st}
    end
  end

  @impl true
  def handle_message(_from, {:RECOVERY_OUT, fid}, st) do
    Logger.warning("Discarding old :RECOVERY_OUT message, fid=#{inspect(fid)}")
    {:noreply, st}
  end

  @impl true
  def handle_message(from, {:RECOVERY_IN, fid, w_e, w}, %{fragment_id: fid} = st) do
    st = st |> set_state(:recover)
    w_prime = Enum.max([w, edge_weight(st.id, from)])

    st =
      st
      |> recv_new_recovery(from, w_e, w_prime)
      |> maybe_propagate_recovery(from, fid, w_e, w_prime)

    {:noreply, st}
  end

  @impl true
  def handle_message(_from, {:RECOVERY_IN, fid, _w_e, _w}, st) do
    Logger.warning("Discarding old :RECOVERY_IN message, fid=#{inspect(fid)}")
    {:noreply, st}
  end

  @impl true
  def handle_message(from, {:PRIVILEGE, fid, w_e}, %{fragment_id: fid} = st) do
    {count, sender, max_weight} = Map.get(st.recovery_in_recv, w_e)

    Logger.debug(
      "Handling PRIVILEGE message from=#{inspect(from)} fid=#{inspect(fid)} w_e=#{inspect(w_e)}, state=#{inspect(st, pretty: true)}"
    )

    cond do
      # No serialization is necessary, start running the replace process
      count == 2 ->
        # I am the lca of the two nodes
        st = %{st | curr_privilege: w_e}
        next = sender

        st =
          cond do
            next_cut?(st, next, max_weight) == true ->
              # Delete next, no matter what
              %{st | children: MapSet.delete(st.children, next)}

            true ->
              # Keep next as child, no matter what
              %{st | children: MapSet.put(st.children, next)}
          end

        # Update stage if needed
        next_stage = if next_cut?(st, next, max_weight), do: 1, else: 0

        safe_send(st.id, next, {:REPLACE, fid, w_e, max_weight, st.id, next_stage})

        st =
          if is_root?(st) do
            st = %{
              st
              | recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
                recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
            }

            pending_count = map_size(st.recovery_in_recv)

            # Check if another replace can start
            cond do
              pending_count == 0 ->
                # No more pending recovery messages, go to sleep
                %{st | curr_privilege: nil} |> set_state(:sleep)

              true ->
                {new_w_e, {_count, sender, _max_weight}} = st.recovery_in_recv |> Enum.at(0)
                next = next_in_cycle(st, sender, from)
                safe_send(st.id, next, {:PRIVILEGE, fid, new_w_e})
                %{st | curr_privilege: new_w_e}
            end
          else
            # Return privilege to root
            send_parent(st, {:PRIVILEGE, fid, w_e})

            st = %{
              st
              | curr_privilege: nil,
                recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
                recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
            }

            st =
              case st.recovery_in_recv |> Map.to_list() do
                [{new_w_e, {_count, sender, max_weight}} | _rest] ->
                  st |> propagate_recovery(sender, fid, new_w_e, max_weight)

                _ ->
                  st
              end

            st
          end

        {:noreply, st}

      count == 1 ->
        st =
          if is_root?(st) and from != st.id do
            st = %{
              st
              | recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
                recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
            }

            pending_count = map_size(st.recovery_in_recv)

            cond do
              pending_count == 0 ->
                # No more pending recovery messages, go to sleep
                %{st | curr_privilege: nil} |> set_state(:sleep)

              true ->
                {new_w_e, {_count, sender, _max_weight}} = st.recovery_in_recv |> Enum.at(0)
                next = next_in_cycle(st, sender, from)

                safe_send(st.id, next, {:PRIVILEGE, fid, new_w_e})
                %{st | curr_privilege: new_w_e}
            end
          else
            st =
              if st.curr_privilege == w_e do
                # Return privilege to root
                send_parent(st, {:PRIVILEGE, fid, w_e})

                st = %{
                  st
                  | curr_privilege: nil,
                    recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
                    recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
                }

                st =
                  case st.recovery_in_recv |> Map.to_list() do
                    [{new_w_e, {_count, sender, max_weight}} | _rest] ->
                      st |> propagate_recovery(sender, fid, new_w_e, max_weight)

                    _ ->
                      st
                  end

                st
              else
                st = %{st | curr_privilege: w_e}

                st =
                  cond do
                    MapSet.member?(st.recovery_in_sent, w_e) ->
                      st

                    true ->
                      st |> propagate_recovery(from, fid, w_e, max_weight)
                  end

                next = next_in_cycle(st, sender, from)
                safe_send(st.id, next, {:PRIVILEGE, fid, w_e})
                st
              end

            st
          end

        {:noreply, st}
    end
  end

  @impl true
  def handle_message(_from, {:PRIVILEGE, fid, w_e}, st) do
    Logger.warning("Discarding old :PRIVILEGE message, fid=#{inspect(fid)} w_e=#{inspect(w_e)}")
    {:noreply, st}
  end

  @impl true
  def handle_message(
        from,
        {:REPLACE, fid, w_e, _w, starter, stage},
        %{id: starter, fragment_id: fid} = st
      ) do
    st = st |> set_state(:sleep)

    st =
      if stage == 1,
        do: %{st | children: MapSet.delete(st.children, from)},
        else: st

    Logger.info("Replace cycle for #{inspect(w_e)} finished")

    {:noreply,
     %{
       st
       | recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
         recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
     }}
  end

  @impl true
  def handle_message(from, {:REPLACE, fid, w_e, w, starter, stage}, %{fragment_id: fid} = st) do
    st = st |> set_state(:sleep)

    {_count, sender, _max_weight} = Map.get(st.recovery_in_recv, w_e)

    st = %{
      st
      | recovery_in_recv: Map.delete(st.recovery_in_recv, w_e),
        recovery_in_sent: MapSet.delete(st.recovery_in_sent, w_e)
    }

    next = next_in_cycle(st, sender, from)
    # Going up, counter-stream in the tree
    going_up = next == st.parent

    cond do
      stage == 0 ->
        # Link with the previous part of the cycle, cut will happen later
        st =
          if going_up do
            %{st | parent: from, children: MapSet.delete(st.children, from)}
          else
            st
          end

        st =
          cond do
            next_cut?(st, next, w) == true ->
              # Delete next, no matter what
              %{st | children: MapSet.delete(st.children, next)}

            true ->
              # Keep next as child, no matter what
              %{st | children: MapSet.put(st.children, next)}
          end

        # update stage if needed
        next_stage = if next_cut?(st, next, w), do: 1, else: stage

        safe_send(st.id, next, {:REPLACE, fid, w_e, w, starter, next_stage})

        {:noreply, st}

      stage == 1 ->
        # Delete from, no matter what
        st = %{st | children: MapSet.delete(st.children, from)}

        st =
          if going_up do
            st
          else
            %{st | parent: next, children: MapSet.delete(st.children, next)}
          end

        # update to stage = 2
        safe_send(st.id, next, {:REPLACE, fid, w_e, w, starter, 2})
        {:noreply, st}

      true ->
        # Link with the next part of the cycle, cut has already happened
        st =
          if going_up do
            %{st | children: MapSet.put(st.children, from)}
          else
            %{st | parent: next, children: MapSet.delete(st.children, next)}
          end

        safe_send(st.id, next, {:REPLACE, fid, w_e, w, starter, stage})
        {:noreply, st}
    end
  end

  @impl true
  def handle_message(_from, {:REPLACE, fid, _w_e, _w, _starter}, st) do
    Logger.warning("Discarding old :REPLACE message, fid=#{inspect(fid)}")
    {:noreply, st}
  end

  # FAILURE Section

  @impl true
  @spec handle_message(from :: term(), payload :: term(), st :: t()) ::
          {:noreply, t()} | {:reply, term(), t()}
  def handle_message(
        :router,
        {:router_link_down, neighbor, %{edge: {_a, _b}, attrs: %{weight: w}}},
        st
      ) do
    st = %{st | neighbors: MapSet.delete(st.neighbors, neighbor)}

    cond do
      # Non-tree failed: no-op
      not is_tree_link?(st, neighbor) ->
        Logger.info("Non-tree link failed, no action required")
        {:noreply, st}

      # Child endpoint lost its parent, becomes root and enters REIDEN
      st.parent == neighbor ->
        fid = gen_fid(w, st.id)

        st1 = st |> become_root() |> reiden_handler(fid)
        {:noreply, st1}

      # Parent endpoint lost a child, propagate FAILURE upward with new fid
      true ->
        fid = gen_fid(w, st.id)
        st1 = st |> set_fragment(fid) |> remove_child(neighbor)
        safe_send(st1.id, st1.id, {:FAILURE, fid})

        {:noreply, st1}
    end
  end

  def handle_message(_from, {:FAILURE, fid}, st) do
    cond do
      # If I'm the root, adopt fid and start REIDEN broadcast
      st.parent == nil ->
        st1 = st |> set_fragment(fid)

        safe_send(st1.id, st1.id, {:REIDEN, fid})
        {:noreply, st1}

      # Otherwise forward FAILURE upward
      true ->
        send_parent(st, {:FAILURE, fid})
        {:noreply, st}
    end
  end

  def handle_message(_from, {:REIDEN, fid}, st) do
    {:noreply, reiden_handler(st, fid)}
  end

  def handle_message(_from, {:REIDEN_ACK, fid}, st) do
    # Accept only if ids match
    if st.fragment_id == fid do
      st1 = dec_reiden_ack(st)

      if st1.reiden_acks_expected == 0 do
        if st1.parent == nil do
          # I'm the leader/root; start FINDMOE broadcast
          st1 = start_new_findmoe_round(st1)
          {:noreply, st1}
        else
          # Forward REIDEN_ACK to parent
          send_parent(st1, {:REIDEN_ACK, fid})
          {:noreply, st1}
        end
      else
        {:noreply, st1}
      end
    else
      {:noreply, st}
    end
  end

  def handle_message(_from, {:FINDMOE, fid, round}, st) do
    if st.fragment_id == fid do
      st1 =
        %{st | find_moe_round: round}
        |> set_state(:find)
        |> set_find_acks_expected(MapSet.size(st.children))
        |> issue_tests()
        |> maybe_report_back()

      # Forward FINDMOE to children
      Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:FINDMOE, fid, round}) end)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:TEST, fid}, st) do
    resp =
      if st.fragment_id == fid do
        {:REJECT, fid}
      else
        {:ACCEPT, fid}
      end

    _ = safe_send(st.id, from, resp)
    {:noreply, st}
  end

  def handle_message(from, {:ACCEPT, fid}, st) do
    if st.fragment_id == fid do
      w = edge_weight(st.id, from)
      edge_key = {st.id, from}

      st1 =
        st
        |> update_local_moe({:edge, {edge_key, w}}, nil)
        |> remove_pending(from)
        |> maybe_report_back()

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:REJECT, fid}, st) do
    if st.fragment_id == fid do
      st1 =
        st
        |> update_local_moe(:none, nil)
        |> remove_pending(from)
        |> maybe_report_back()

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:FINDMOE_ACK, fid, round, child_moe}, st) do
    if st.fragment_id == fid do
      if round < st.find_moe_round do
        {:noreply, st}
      else
        if(from == st.id) do
          st1 = st |> react_to_moe(st.local_moe)
          {:noreply, st1}
        else
          st1 =
            st
            |> update_local_moe(child_moe, from)
            |> dec_find_ack()
            |> maybe_report_back()

          {:noreply, st1}
        end
      end
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:CHANGE_ROOT, fid, {:edge, {{u, v}, _w}} = moe}, st) do
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
        st2 = send_connect_for(moe, st1)
        {:noreply, st2}
      else
        # Forward to the child that reported this moe in my subtree
        safe_send(st1.id, new_parent, {:CHANGE_ROOT, fid, moe})

        {:noreply, st1}
      end
    else
      {:noreply, st}
    end
  end

  def handle_message(from, {:CONNECT, _fid}, st) do
    # We received CONNECT from `from`; record and check if we also sent to `from`
    st1 = mark_connect_recv(st, from)
    st2 = maybe_commit_merge(st1, from)
    {:noreply, st2}
  end

  def handle_message(_from, {:GOSLEEP, fid}, st) do
    if st.fragment_id == fid do
      st1 = st |> set_state(:sleep)

      Enum.each(st1.children, fn c -> safe_send(st1.id, c, {:GOSLEEP, fid}) end)

      {:noreply, st1}
    else
      {:noreply, st}
    end
  end

  ## Helpers

  defp gen_fid(weight, node_id), do: {weight, node_id}

  defp become_root(st), do: %{st | parent: nil}

  defp next_in_cycle(st, sender, from), do: if(sender == from, do: st.parent, else: sender)

  defp next_cut?(st, next, w), do: edge_weight(st.id, next) == w

  defp remove_child(st, child), do: %{st | children: MapSet.delete(st.children, child)}

  defp set_fragment(st, fid), do: %{st | fragment_id: fid}

  defp set_state(st, s), do: %{st | f_state: s}

  defp set_reiden_acks_expected(st, n), do: %{st | reiden_acks_expected: n}

  defp dec_reiden_ack(%{reiden_acks_expected: n} = st),
    do: %{st | reiden_acks_expected: max(n - 1, 0)}

  defp set_find_acks_expected(st, n), do: %{st | find_acks_expected: n}

  defp dec_find_ack(%{find_acks_expected: n} = st), do: %{st | find_acks_expected: max(n - 1, 0)}

  defp recv_new_recovery(st, from, w_e, w_prime) do
    if from == st.id do
      st
    else
      %{
        st
        | recovery_in_recv:
            Map.update(st.recovery_in_recv, w_e, {1, from, w_prime}, fn {count, sender, old_w} ->
              {count + 1, sender, Enum.max([old_w, w_prime])}
            end)
      }
    end
  end

  defp maybe_propagate_recovery(st, from, fid, w_e, w_prime) do
    if MapSet.size(st.recovery_in_sent) != 0 do
      st
    else
      propagate_recovery(st, from, fid, w_e, w_prime)
    end
  end

  defp propagate_recovery(st, from, fid, w_e, w_prime) do
    st =
      cond do
        not is_root?(st) ->
          send_parent(st, {:RECOVERY_IN, fid, w_e, w_prime})
          st

        is_root?(st) and is_nil(st.curr_privilege) ->
          safe_send(st.id, from, {:PRIVILEGE, fid, w_e})
          %{st | curr_privilege: w_e}

        true ->
          st
      end

    %{st | recovery_in_sent: MapSet.put(st.recovery_in_sent, w_e)}
  end

  defp reiden_handler(st, fid) do
    st1 =
      st
      |> reset_state(:reiden)
      |> set_fragment(fid)
      |> set_reiden_acks_expected(MapSet.size(st.children))

    if MapSet.size(st1.children) == 0 do
      if is_root?(st1) do
        # I'm the root: start FINDMOE
        st1 |> start_new_findmoe_round()
      else
        # I'm a leaf: send REIDEN_ACK to parent
        safe_send(st1.id, st1.id, {:REIDEN_ACK, fid})
        st1
      end
    else
      # Send to children
      Enum.each(st1.children, fn c ->
        safe_send(st1.id, c, {:REIDEN, fid})
      end)

      st1
    end
  end

  defp start_new_findmoe_round(st) do
    st = %{st | find_moe_round: st.find_moe_round + 1}
    safe_send(st.id, st.id, {:FINDMOE, st.fragment_id, st.find_moe_round})
    st
  end

  defp react_to_moe(st, moe) do
    case moe do
      # No outgoing edge: either whole net or disconnected component (paper 4.1 end). We just go sleep.
      :none ->
        safe_send(st.id, st.id, {:GOSLEEP, st.fragment_id})
        st

      chosen ->
        case st.reporter_for_moe do
          # moe is incident to root ⇒ proceed directly (appendix (7) will send CONNECT)
          nil ->
            send_connect_for(chosen, st)

          reporter ->
            safe_send(st.id, reporter, {:CHANGE_ROOT, st.fragment_id, chosen})

            %{
              st
              | parent: reporter,
                children: MapSet.delete(st.children, reporter),
                reporter_for_moe: nil
            }
        end
    end
  end

  ## TEST phase

  defp issue_tests(st) do
    fid = st.fragment_id
    out_neighs = st.neighbors |> MapSet.delete(st.parent) |> MapSet.difference(st.children)
    Enum.each(out_neighs, fn n -> safe_send(st.id, n, {:TEST, fid}) end)
    %{st | test_pending: out_neighs, local_moe: :none}
  end

  @spec remove_pending(t(), node_id()) :: t()
  defp remove_pending(st, n) do
    %{st | test_pending: MapSet.delete(st.test_pending, n)}
  end

  @spec update_local_moe(t(), moe(), node_id()) :: t()
  defp update_local_moe(st, edge, reporter) do
    if less_or_equal?(edge, st.local_moe) do
      %{st | local_moe: edge, reporter_for_moe: reporter}
    else
      st
    end
  end

  defp maybe_report_back(st) do
    if MapSet.size(st.test_pending) == 0 and st.find_acks_expected == 0 do
      send_parent(st, {:FINDMOE_ACK, st.fragment_id, st.find_moe_round, st.local_moe})

      st |> set_state(:found)
    else
      st
    end
  end

  # === CONNECT helpers (handshake-aware) ===

  # Send CONNECT if we are incident to the edge; mark as "sent"; try to commit if peer already sent.
  @spec send_connect_for(moe(), t()) :: t()
  defp send_connect_for({:edge, {{u, v}, _w}}, st) do
    other = if st.id == u, do: v, else: u

    safe_send(st.id, other, {:CONNECT, st.fragment_id})
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

  defp is_tree_link?(st, other), do: st.parent == other or MapSet.member?(st.children, other)

  defp is_root?(st), do: st.parent == nil

  defp undirected(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  defp edge_weight(a, b) do
    cond do
      a == b ->
        0

      true ->
        case Router.edge_attr(a, b) do
          %{:weight => w} ->
            w

          _ ->
            Logger.warning("Returned :infinity for edge {#{a}, #{b}}")
            :infinity
        end
    end
  end

  defp send_parent(%{parent: nil} = st, msg), do: safe_send(st.id, st.id, msg)

  defp send_parent(st, msg), do: safe_send(st.id, st.parent, msg)

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
        find_moe_round: 0,
        reiden_acks_expected: 0,
        find_acks_expected: 0,
        local_moe: :none,
        test_pending: MapSet.new(),
        reporter_for_moe: nil
    }
  end

  @spec compare(edge_key(), edge_key()) :: :lt | :eq | :gt
  def compare({a, b}, {c, d}) do
    e1 = undirected(a, b)
    e2 = undirected(c, d)

    cond do
      e1 < e2 -> :lt
      e1 > e2 -> :gt
      true -> :eq
    end
  end

  @spec compare(moe(), moe()) :: :lt | :eq | :gt
  def compare(:none, :none), do: :eq
  def compare(:none, {:edge, _}), do: :gt
  def compare({:edge, _}, :none), do: :lt

  def compare({:edge, {e1, w1}}, {:edge, {e2, w2}}) do
    cond do
      w1 < w2 ->
        :lt

      w1 > w2 ->
        :gt

      true ->
        compare(e1, e2)
    end
  end

  @spec less_or_equal?(moe(), moe()) :: boolean()
  def less_or_equal?(a, b) do
    case compare(a, b) do
      :lt -> true
      :eq -> true
      :gt -> false
    end
  end
end
