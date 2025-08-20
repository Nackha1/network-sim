defmodule NetworkSim.Kruskal do
  @moduledoc """
  # NetworkSim.Kruskal

  Minimum Spanning Tree (MST) using **Kruskal’s algorithm** for an undirected graph.

  Kruskal’s algorithm sorts all edges by weight (ascending) and scans them,
  adding an edge iff it connects two **different** components. Components are
  tracked with a **Disjoint-Set / Union–Find** structure (with union by rank
  and path compression).

  ## Graph shape

      nodes :: [node_id]
      links :: [{node_id, node_id, %{weight: number}}]

  An edge is `{u, v, %{weight: w}}`. The graph is undirected, so `{u, v, ...}`
  and `{v, u, ...}` denote the same undirected edge.

  ## Return shape

      %{
        edges: [{node_id, node_id, %{weight: number}}],
        weight: number | :infinity
      }

  If the graph is **disconnected**, the result is a *minimum spanning forest*
  (one MST per connected component). If any chosen edge has a missing weight
  (treated as `:infinity`), the total `weight` is reported as `:infinity`.
  """

  # ================
  #  Types
  # ================
  @typedoc "Scalar weight for an edge."
  @type weight :: number()

  @typedoc "Arbitrary edge metadata; `:weight` is expected when present."
  @type meta :: %{optional(atom()) => term()}

  @typedoc "Undirected, attributed edge."
  @type edge :: {node_id(), node_id(), meta()}

  @typedoc "Node identifier (opaque)."
  @type node_id :: term()

  @typedoc "MST (or forest) result."
  @type mst :: %{edges: [edge()], weight: weight() | :infinity}

  @typedoc """
  Per-node tree info for a rooted forest: `parent` is `nil` at the root,
  `children` are ordered from oldest-to-newest discovery in BFS.
  """
  @type rooted_info :: %{optional(node_id()) => %{parent: node_id() | nil, children: [node_id()]}}

  # ================
  #  Public API
  # ================

  @doc """
  Compute a Minimum Spanning Tree (or forest) using Kruskal’s algorithm.

  - Edges are sorted ascending by `:weight`.
  - Edges **without** a `:weight` are treated as having weight **`:+∞`** (i.e. `:infinity`).
  - If the graph is disconnected, the result contains one tree per component.
  - The final `weight` is the sum of chosen edge weights, or `:infinity` if any
    chosen edge is missing a numeric weight.

  ## Parameters
  - `nodes` — list of node identifiers
  - `links` — list of edges `{u, v, %{weight: w}}` (additional metadata allowed)

  ## Returns
  - `%{edges: [edge], weight: number | :infinity}`
  """
  @spec kruskal([node_id()], [edge()]) :: mst()
  def kruskal(nodes, links) when is_list(nodes) and is_list(links) do
    # 1) sort all edges by weight (ascending)
    #    (edges with missing weights are treated as +infinity)
    sorted =
      Enum.sort_by(links, fn {_u, _v, m} -> weight_of(m) end)

    # 2) initialize disjoint-set (Union–Find) structures
    parents = Map.new(nodes, &{&1, &1})
    ranks = Map.new(nodes, &{&1, 0})

    # 3) scan edges, adding those that connect different components
    target_edges = max(length(nodes) - 1, 0)

    {chosen, {_parents, _ranks}} =
      Enum.reduce_while(sorted, {[], {parents, ranks}}, fn {u, v, _m} = e, {acc, ds} ->
        {ru, ds} = find(u, ds)
        {rv, ds} = find(v, ds)

        if ru != rv do
          ds = union(ru, rv, ds)
          acc = [e | acc]

          if length(acc) == target_edges do
            {:halt, {Enum.reverse(acc), ds}}
          else
            {:cont, {acc, ds}}
          end
        else
          {:cont, {acc, ds}}
        end
      end)

    %{
      edges: chosen,
      weight: Enum.reduce(chosen, 0, fn {_u, _v, m}, acc -> acc + weight_of(m) end)
    }
  end

  @doc """
  Produce a **randomly rooted** forest from MST edges.

  Only nodes that appear in `edges` are included. For each connected component, a
  root is chosen uniformly with `Enum.random/1`, and a BFS assigns `parent/children`.

  ## Parameters
  - `edges` — MST edges as returned by `kruskal/2`

  ## Returns
  - `%{node_id => %{parent: node_id | nil, children: [node_id]}}`
  """
  @spec rooted_forest([edge()]) :: rooted_info
  def rooted_forest(edges) do
    nodes_in_edges =
      edges
      |> Enum.flat_map(fn {u, v, _} -> [u, v] end)
      |> Enum.uniq()

    rooted_forest(edges, nodes_in_edges)
  end

  @doc """
  Produce a **randomly rooted** forest from MST edges, ensuring a given superset
  of `nodes` is included (isolated nodes become singleton trees with `parent: nil`).

  ## Parameters
  - `edges` — MST edges
  - `nodes` — nodes to include even if isolated

  ## Returns
  - `%{node_id => %{parent: node_id | nil, children: [node_id]}}`
  """
  @spec rooted_forest([edge()], [term()]) :: rooted_info
  def rooted_forest(edges, nodes) when is_list(edges) and is_list(nodes) do
    adj =
      edges
      |> Enum.reduce(%{}, fn {u, v, _}, acc ->
        acc
        |> Map.update(u, [v], &[v | &1])
        |> Map.update(v, [u], &[u | &1])
      end)
      # Ensure isolated nodes appear with empty adjacency
      |> then(fn m -> Enum.reduce(nodes, m, &Map.put_new(&2, &1, [])) end)

    # Find connected components (including singletons)
    {components, _visited} =
      Enum.reduce(Map.keys(adj), {[], MapSet.new()}, fn node, {comps, vis} ->
        if MapSet.member?(vis, node) do
          {comps, vis}
        else
          {comp, vis2} = collect_component(node, adj, vis)
          {[comp | comps], vis2}
        end
      end)

    # For each component, pick a random root and BFS to assign parent/children
    Enum.reduce(components, %{}, fn comp, acc ->
      root = Enum.random(comp)
      acc |> Map.merge(bfs_parent_children(root, adj))
    end)
  end

  # ================
  #  Helpers
  # ================

  defp collect_component(start, adj, visited) do
    queue = :queue.from_list([start])
    visited = MapSet.put(visited, start)
    comp = []

    do_collect(queue, adj, visited, comp)
  end

  defp do_collect(queue, adj, visited, comp) do
    case :queue.out(queue) do
      {{:value, u}, q} ->
        neighbors = Map.get(adj, u, [])

        {q, visited, comp} =
          Enum.reduce(neighbors, {q, visited, [u | comp]}, fn v, {q, vis, comp} ->
            if MapSet.member?(vis, v) do
              {q, vis, comp}
            else
              {:queue.in(v, q), MapSet.put(vis, v), comp}
            end
          end)

        do_collect(q, adj, visited, comp)

      {:empty, _} ->
        {comp, visited}
    end
  end

  defp bfs_parent_children(root, adj) do
    queue = :queue.from_list([root])
    parents = %{root => %{parent: nil, children: []}}
    visited = MapSet.new([root])

    do_bfs(queue, adj, parents, visited)
  end

  defp do_bfs(queue, adj, parents, visited) do
    case :queue.out(queue) do
      {{:value, u}, q} ->
        {q, parents, visited} =
          Enum.reduce(Map.get(adj, u, []), {q, parents, visited}, fn v, {q, parents, visited} ->
            if MapSet.member?(visited, v) do
              {q, parents, visited}
            else
              parents =
                parents
                |> Map.update!(u, fn m -> %{m | children: [v | m.children]} end)
                |> Map.put(v, %{parent: u, children: []})

              {:queue.in(v, q), parents, MapSet.put(visited, v)}
            end
          end)

        do_bfs(q, adj, parents, visited)

      {:empty, _} ->
        # normalize children order (optional)
        Enum.into(parents, %{}, fn {k, %{parent: p, children: ch}} ->
          {k, %{parent: p, children: Enum.reverse(ch)}}
        end)
    end
  end

  @spec weight_of(meta()) :: weight()
  defp weight_of(m) do
    Map.get(m, :weight, :infinity)
  end

  @spec find(term(), {map(), map()}) :: {term(), {map(), map()}}
  defp find(x, {parents, ranks}) do
    p = Map.fetch!(parents, x)

    if p == x do
      {x, {parents, ranks}}
    else
      {root, {parents, ranks}} = find(p, {parents, ranks})
      # path compression
      parents = Map.put(parents, x, root)
      {root, {parents, ranks}}
    end
  end

  @spec union(term(), term(), {map(), map()}) :: {map(), map()}
  defp union(ra, rb, {parents, ranks}) when ra == rb, do: {parents, ranks}

  defp union(ra, rb, {parents, ranks}) do
    ra_rank = Map.fetch!(ranks, ra)
    rb_rank = Map.fetch!(ranks, rb)

    cond do
      ra_rank < rb_rank ->
        {Map.put(parents, ra, rb), ranks}

      ra_rank > rb_rank ->
        {Map.put(parents, rb, ra), ranks}

      true ->
        parents = Map.put(parents, rb, ra)
        ranks = Map.put(ranks, ra, ra_rank + 1)
        {parents, ranks}
    end
  end
end
