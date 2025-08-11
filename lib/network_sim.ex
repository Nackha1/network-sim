defmodule NetworkSim do
  @moduledoc """
  Public API for the network simulator (undirected/bidirectional links).

  This module provides convenience wrappers to load a graph either as:
    * a map accepted by `Router.load_graph/1`, or
    * **two lists** of `nodes` and `links` via `start_network/2`.
  """

  alias NetworkSim.Router

  @typedoc """
  User-defined node identifier (string, integer, atom, etc.).
  """

  @type node_id :: term()

  @typedoc """
  An undirected link; may carry an attribute term in 3rd position.
  """
  @type link :: {node_id(), node_id()} | {node_id(), node_id(), term()}

  @typedoc """
  Adjacency as a *list-based* map: each node maps to a (deduplicated) list
  of neighbor node ids. Order is not significant.
  """
  @type list_adjacency :: %{required(node_id()) => [node_id()]}

  # ================
  #  Graph loading
  # ================

  @doc """
  Load a graph specification: `%{id => [neighbors...]}`.

  The graph is made **undirected** automatically by the router; any missing reverse
  edges are added, and disabled-link state is cleared.
  """
  @spec load_graph(%{optional(node_id()) => [node_id()]}) :: :ok
  def load_graph(graph_spec), do: Router.load_graph(graph_spec)

  @doc """
  Start the network given `nodes` and undirected `links`.

  Each link may optionally carry attributes in a third element:

    * `{:a, :b}`                 → no attributes
    * `{:a, :b, %{weight: 10}}` → attributes (protocol-specific)

  Attributes are stored by the router keyed on the undirected edge `{min,max}`.
  The simulator itself remains agnostic.

  ## Examples

      iex> nodes = [:a, :b, :c]
      iex> links = [{:a, :b, %{weight: 1}}, {:b, :c, %{weight: 2}}]
      iex> NetworkSim.start_network(nodes, links)
      :ok
  """
  @spec start_network([node_id()], [link()]) :: :ok | {:error, term()}
  def start_network(nodes, links) do
    graph = graph_from_lists(nodes, links)
    attrs = edge_attrs_from_links(links)
    Router.load_graph(graph, attrs)
  end

  @doc """
  Stop the network by terminating all node processes and clearing topology.

  This:
    * terminates all children under `NetworkSim.NodeSupervisor`
    * resets the router to an empty graph
  """
  @spec stop_network() :: :ok
  def stop_network do
    # Terminate all node processes supervised dynamically
    for {_, pid, _, _} <- DynamicSupervisor.which_children(NetworkSim.NodeSupervisor) do
      # Ignore errors if a child already exited
      _ = DynamicSupervisor.terminate_child(NetworkSim.NodeSupervisor, pid)
    end

    # Clear router state (no nodes, no edges)
    :ok = Router.load_graph(%{})
    :ok
  end

  # =====================
  #  Topology inspection
  # =====================

  @doc """
  Return the neighbors of a node.
  """
  @spec neighbors(node_id()) :: MapSet.t(node_id())
  def neighbors(id), do: Router.neighbors(id)

  @doc """
  Enable an undirected link `{a, b}` (both directions).
  """
  @spec enable_link(node_id(), node_id()) :: :ok
  def enable_link(a, b), do: Router.enable_link(a, b)

  @doc """
  Disable an undirected link `{a, b}` (both directions).
  """
  @spec disable_link(node_id(), node_id()) :: :ok
  def disable_link(a, b), do: Router.disable_link(a, b)

  @doc """
  Check if `{a, b}` is currently enabled.
  """
  @spec link_enabled?(node_id(), node_id()) :: boolean()
  def link_enabled?(a, b), do: Router.link_enabled?(a, b)

  # ===============
  #  Messaging API
  # ===============

  @doc """
  Send a payload from `from` to `to` over an **enabled** undirected edge.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec send(node_id(), node_id(), any()) :: :ok | {:error, term()}
  def send(from, to, payload), do: Router.send(from, to, payload)

  # ==================
  #  Node conveniences
  # ==================

  @doc """
  Read a node's inbox (most recent at the end).
  """
  @spec inbox(node_id()) :: [{node_id(), any()}]
  def inbox(id), do: NetworkSim.Node.inbox(id)

  @doc """
  Clear a node's inbox.
  """
  @spec clear_inbox(node_id()) :: :ok
  def clear_inbox(id), do: NetworkSim.Node.clear_inbox(id)

  # =========
  #  Helpers
  # =========

  @doc """
  Build a **list-based** adjacency map from `nodes` and undirected `links`.

  The output is a map `%{node => [neighbors...]}` with these properties:

    * **Symmetric:** every `{:u, :v}` adds `v` to `u`'s list and `u` to `v`'s list.
    * **No self-loops:** any `{:u, :u}` is ignored.
    * **Deduplicated:** neighbor lists contain unique entries.
    * **Total:** all nodes appear as keys, even if isolated.
    * **Order-free:** list order is unspecified (do not rely on it).

  This function is intentionally “dumb & fast” at the boundary:
  it does not use `MapSet`s; the `Router` still normalizes and stores
  neighbors as sets internally.

  ## Examples

      iex> NetworkSim.graph_from_lists([:a, :b, :c], [{:a, :b}, {:b, :c}])
      %{
        a: [:b],
        b: [:a, :c],
        c: [:b]
      }

      iex> # isolated nodes still appear:
      ...> NetworkSim.graph_from_lists([:x, :y], [])
      %{x: [], y: []}
  """
  @spec graph_from_lists([node_id()], [link()]) :: list_adjacency()
  def graph_from_lists(nodes, links) do
    links = Enum.map(links, &normalize_link/1)

    # Include any endpoint that appears only in `links` but not in `nodes`.
    ids =
      nodes
      |> Enum.uniq()
      |> Kernel.++(Enum.flat_map(links, fn {u, v, _attr} -> [u, v] end))
      |> Enum.uniq()

    # Start with every node present and no neighbors.
    base = Map.new(ids, &{&1, []})

    # Accumulate undirected edges (skip self-loops).
    adj =
      Enum.reduce(links, base, fn
        {u, v, _attr}, acc when u == v ->
          acc

        {u, v, _attr}, acc ->
          acc
          |> Map.update!(u, fn ns -> [v | ns] end)
          |> Map.update!(v, fn ns -> [u | ns] end)
      end)

    # Deduplicate and drop accidental self-entries if any slipped in.
    for {id, ns} <- adj, into: %{} do
      {id, ns |> Enum.uniq() |> Enum.reject(&(&1 == id))}
    end
  end

  # Build the attribute map from the links list.
  # Keys are normalized undirected tuples `{min,max}`.
  @spec edge_attrs_from_links([link()]) :: %{optional({node_id(), node_id()}) => term()}
  defp edge_attrs_from_links(links) do
    links
    |> Enum.reduce(%{}, fn
      {u, v, attr}, acc when u != v ->
        k = if u <= v, do: {u, v}, else: {v, u}
        Map.put(acc, k, attr)

      _other, acc ->
        acc
    end)
  end

  defp normalize_link({u, v}), do: {u, v, %{}}
  defp normalize_link({u, v, attrs}) when is_map(attrs), do: {u, v, attrs}
end
