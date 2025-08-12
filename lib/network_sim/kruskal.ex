defmodule NetworkSim.Kruskal do
  @moduledoc """
  Minimum Spanning Tree using Kruskal's algorithm for an undirected graph.

  ## Graph shape

      nodes :: [node]
      links :: [{node, node, %{weight: number}}]

  An *edge* is `{u, v, %{weight: w}}`. The graph is undirected, so `{u, v, ...}`
  and `{v, u, ...}` are the same edge.

  ## Return shape

      %{
        edges: [{node, node, %{weight: number}}],
        weight: number
      }

  If the graph is disconnected, the result is a *minimum spanning forest*.
  """

  @type weight :: number()
  @type meta :: %{optional(atom()) => term()}
  @type edge :: {term(), term(), meta()}
  @type mst :: %{edges: [edge()], weight: weight()}

  @spec kruskal([node()], [edge()]) :: mst()
  def kruskal(nodes, links) when is_list(nodes) and is_list(links) do
    # 1) sort all edges by weight (ascending)
    #    (edges with missing weights are treated as +infinity)
    sorted =
      Enum.sort_by(links, fn {_u, _v, m} -> weight_of(m) end)

    # you can also remove duplicate undirected edges here if you had both {u,v} and {v,u}

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

  # -- Helpers ---------------------------------------------------------------

  @spec weight_of(meta()) :: weight()
  defp weight_of(m) do
    Map.get(m, :weight, :infinity)
  end

  # Disjoint-set: `ds` is {parents_map, ranks_map}

  @spec find(node(), {map(), map()}) :: {node(), {map(), map()}}
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

  @spec union(node(), node(), {map(), map()}) :: {map(), map()}
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
