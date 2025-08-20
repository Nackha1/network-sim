@moduledoc false
defmodule RandomPropTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import StreamData

  alias NetworkSim.Router

  @moduledoc """
  Property-based checks for NetworkSim:

    • Start from a random, connected undirected graph.
    • Randomly (de)activate links and randomly send messages.
    • Invariants:
        - neighbors/1 is symmetric (undirected graph)
        - no self-neighbors
        - neighbors ⊆ nodes
        - send/3 returns :ok iff (to is neighbor of from) AND link_enabled?(from,to)
          (sending to self or non-neighbor or disabled link must return {:error, _})
  """

  #
  # Generators
  #

  # Distinct atom node names like :n1, :n2, ...
  defp gen_nodes() do
    sized(fn s ->
      # clamp to 3..min(12, s+3) for speed; increase for heavier runs
      max_n = max(3, min(12, s + 3))

      integer(3..max_n)
      |> bind(fn n ->
        nodes = for i <- 1..n, do: String.to_atom("n#{i}")
        constant(nodes)
      end)
    end)
  end

  # Connected undirected graph -> {nodes, links}
  # links is a MapSet of normalized edges {min,max}
  defp gen_connected_graph() do
    gen_nodes()
    |> bind(fn nodes ->
      base_edges = random_spanning_tree_edges(nodes)

      sized(fn s ->
        target_extra = min(length(nodes) * 2, s + 2)

        all_pairs = MapSet.new(all_undirected_pairs(nodes))
        non_tree = MapSet.difference(all_pairs, MapSet.new(base_edges))

        extra_edges =
          non_tree
          |> Enum.take_random(target_extra)

        links =
          base_edges
          |> Enum.concat(extra_edges)
          |> MapSet.new()

        constant({nodes, links})
      end)
    end)
  end

  # Random operation stream over the original edge set (flip/flop stress)
  defp gen_ops(nodes, links) do
    node_list = nodes
    edge_list = MapSet.to_list(links)

    sized(fn s ->
      op_count = max(20, min(200, s * 8))

      list_of(
        one_of([
          member_of(edge_list) |> map(fn {a, b} -> {:disable, {a, b}} end),
          member_of(edge_list) |> map(fn {a, b} -> {:enable, {a, b}} end),
          gen_random_send(node_list)
        ]),
        length: op_count
      )
    end)
  end

  defp gen_random_send(nodes) do
    bind(member_of(nodes), fn from ->
      bind(member_of(nodes), fn to ->
        constant({:send, from, to, :ping})
      end)
    end)
  end

  #
  # Helpers
  #

  defp all_undirected_pairs(nodes), do: for(a <- nodes, b <- nodes, a < b, do: {a, b})
  defp normalize_edge({a, b}) when a <= b, do: {a, b}
  defp normalize_edge({a, b}), do: {b, a}

  # simple random spanning tree by chaining a random permutation
  defp random_spanning_tree_edges(nodes) do
    nodes
    |> Enum.shuffle()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> normalize_edge({a, b}) end)
  end

  defp ensure_neighbors_symmetric!(nodes) do
    nset = MapSet.new(nodes)

    for n <- nodes do
      # ns :: MapSet.t()
      ns = Router.neighbors(n)

      # neighbors ⊆ nodes
      assert MapSet.subset?(ns, nset),
             "Node #{inspect(n)} has unknown neighbors: " <>
               inspect(MapSet.difference(ns, nset))

      # no self loops
      refute MapSet.member?(ns, n),
             "Node #{inspect(n)} has itself as neighbor"

      # symmetry: n ∈ N(m) <=> m ∈ N(n)
      Enum.each(ns, fn m ->
        m_ns = Router.neighbors(m)

        assert MapSet.member?(m_ns, n),
               "Neighbor symmetry violated: #{inspect(n)} <-> #{inspect(m)}"
      end)
    end
  end

  defp ref_payload(:ping), do: {:ping, make_ref()}
  defp ref_payload(other), do: other

  # Send must succeed iff to∈neighbors(from) AND link is enabled
  defp assert_send_according_to_topology(from, to, payload) do
    from_nbrs = Router.neighbors(from)

    cond do
      from == to ->
        assert {:error, _} = NetworkSim.send(from, to, ref_payload(payload))

      MapSet.member?(from_nbrs, to) and Router.link_enabled?(from, to) ->
        assert :ok == NetworkSim.send(from, to, ref_payload(payload))

      true ->
        assert {:error, _} = NetworkSim.send(from, to, ref_payload(payload))
    end
  end

  #
  # Property
  #

  setup do
    File.rm_rf!("tmp/random")
    :ok
  end

  property "random graphs stay consistent under random link failures/recoveries" do
    check all(
            {nodes, links} <- gen_connected_graph(),
            ops <- gen_ops(nodes, links),
            max_runs: 5
          ) do
      # Write DOT and PNG for debugging
      filename = "tmp/random/graph_#{System.unique_integer([:positive])}.dot"
      :ok = File.mkdir_p!("tmp/random")

      NetworkSim.Dot.write_dot(nodes, MapSet.to_list(links), filename,
        format: "svg",
        engine: "circo"
      )

      # Boot from lists (your wrapper converts to adjacency map)
      NetworkSim.start_network(nodes, MapSet.to_list(links))

      # initial invariants
      ensure_neighbors_symmetric!(nodes)

      # run randomized operations
      Enum.each(ops, fn
        {:disable, {a, b}} ->
          :ok = Router.disable_link(a, b)
          ensure_neighbors_symmetric!(nodes)

        {:enable, {a, b}} ->
          :ok = Router.enable_link(a, b)
          ensure_neighbors_symmetric!(nodes)

        {:send, from, to, payload} ->
          assert_send_according_to_topology(from, to, payload)
      end)

      ensure_neighbors_symmetric!(nodes)

      # clean shutdown to avoid cross-test interference
      NetworkSim.stop_network()
    end
  end
end
