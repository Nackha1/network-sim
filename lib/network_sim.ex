defmodule NetworkSim do
  @moduledoc """
  Public API for the network simulator (undirected/bidirectional links).

  This module provides convenience wrappers to load a graph either as:
    * a map accepted by `Router.load_graph/1`, or
    * **two lists** of `nodes` and `links` via `start_network/2`.
  """

  require Logger
  alias NetworkSim.Router

  @typedoc """
  User-defined node identifier (string, integer, atom, etc.).
  """

  @type node_id :: term()

  @typedoc """
  An undirected link; may carry an attribute term in 3rd position.
  """
  @type link :: {node_id(), node_id()} | {node_id(), node_id(), map()}

  @typedoc "Per-node protocol spec"
  @type node_spec :: {node_id(), module(), keyword()}

  @typedoc """
  Adjacency as a *list-based* map: each node maps to a (deduplicated) list
  of neighbor node ids. Order is not significant.
  """
  @type list_adjacency :: %{required(node_id()) => [node_id()]}

  # ================
  #  Graph loading
  # ================

  @doc """
  Start the network.

  * `node_specs`: `[{id, ProtocolModule, opts}]`
  * `links`: `[{u, v}]` or `[{u, v, %{...attrs...}}]`

  This function:
    1) Ensures one `NetworkSim.Node` per `id`, started with `{ProtocolModule, opts}`
    2) Builds an **undirected** adjacency as `%{id => MapSet.neighbors}`
    3) Builds an edge-attributes map `%{{min,max} => attrs}`
    4) Calls `Router.load_graph/2` with the normalized data
  """
  @spec start_network([node_spec()], [link()]) :: :ok | {:error, term()}
  def start_network(node_specs, links) do
    # 1) normalized adjacency (MapSet-based)
    graph = graph_from_links(Enum.map(node_specs, &elem(&1, 0)), links)

    # 3) normalized edge attrs
    attrs = edge_attrs_from_links(links)

    # 3) tell the Router (already normalized; no normalization inside Router)
    Router.load_graph(graph, attrs)

    # 4) start nodes with their protocol
    Enum.each(node_specs, fn {id, proto_mod, proto_opts} ->
      _ = ensure_node(id, proto_mod, proto_opts)
    end)
  end

  @doc """
  Stop all node processes and clear the Router’s graph.
  """
  @spec stop_network() :: :ok
  def stop_network do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(NetworkSim.NodeSupervisor) do
      _ = DynamicSupervisor.terminate_child(NetworkSim.NodeSupervisor, pid)
    end

    Router.load_graph(%{}, %{})
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
  Check if `{a, b}` is currently enabled.
  """
  @spec link_enabled?(node_id(), node_id()) :: boolean()
  def link_enabled?(a, b), do: Router.link_enabled?(a, b)

  # =====================
  #  Topology modifications
  # =====================

  @doc """
  Enable an undirected link `{a, b}` (both directions).
  """
  # @spec enable_link(node_id(), node_id()) :: :ok
  def enable_link(a, b, attrs \\ %{}), do: Router.enable_link(a, b, attrs)

  @doc """
  Disable an undirected link `{a, b}` (both directions).
  """
  @spec disable_link(node_id(), node_id()) :: :ok
  def disable_link(a, b), do: Router.disable_link(a, b)

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

  @doc """
  Get a node's state.
  """
  @spec get_raw_state(node_id()) :: any()
  def get_raw_state(id) do
    case Registry.lookup(NetworkSim.Registry, {:node, id}) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> {:error, :node_not_found}
    end
  end

  @spec get_tree() :: [map()]
  def get_tree() do
    Router.nodes()
    |> Enum.map(fn node_id ->
      node_id
      |> NetworkSim.Node.state()
      |> Map.take([:id, :parent, :children])
    end)
  end

  # =========
  #  Helpers
  # =========

  # Ensure a node process exists with its protocol+opts. If already running,
  # ask it to update its protocol (no restart required).
  @spec ensure_node(node_id(), module(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp ensure_node(id, protocol_mod, protocol_opts) do
    case Registry.lookup(NetworkSim.Registry, {:node, id}) do
      [{pid, _}] ->
        send(pid, {:router_set_protocol, protocol_mod, protocol_opts})
        {:ok, pid}

      [] ->
        spec = %{
          id: {:node, id},
          start: {NetworkSim.Node, :start_link, [id, [protocol: {protocol_mod, protocol_opts}]]},
          restart: :transient,
          type: :worker
        }

        DynamicSupervisor.start_child(NetworkSim.NodeSupervisor, spec)
    end
  end

  # Build **undirected** adjacency as %{id => MapSet.neighbors}
  @spec graph_from_links([node_id()], [link()]) :: %{optional(node_id()) => MapSet.t(node_id())}
  defp graph_from_links(nodes, links) do
    ids =
      nodes
      |> Enum.uniq()
      |> Kernel.++(
        Enum.flat_map(links, fn
          {u, v} -> [u, v]
          {u, v, _} -> [u, v]
        end)
      )
      |> Enum.uniq()

    base = Map.new(ids, &{&1, MapSet.new()})

    Enum.reduce(links, base, fn
      {u, v}, acc when u != v ->
        acc
        |> Map.update!(u, &MapSet.put(&1, v))
        |> Map.update!(v, &MapSet.put(&1, u))

      {u, v, _attrs}, acc when u != v ->
        acc
        |> Map.update!(u, &MapSet.put(&1, v))
        |> Map.update!(v, &MapSet.put(&1, u))

      _self_loop, acc ->
        acc
    end)
  end

  # Edge attributes as %{{min,max} => attrs} (attrs default to %{})
  @spec edge_attrs_from_links([link()]) :: %{{node_id(), node_id()} => map()}
  defp edge_attrs_from_links(links) do
    Enum.reduce(links, %{}, fn
      {u, v, attrs}, acc when u != v and is_map(attrs) ->
        Map.put(acc, undirected(u, v), attrs)

      {u, v}, acc when u != v ->
        Map.put(acc, undirected(u, v), %{})

      _self, acc ->
        acc
    end)
  end

  @spec undirected(node_id(), node_id()) :: {node_id(), node_id()}
  defp undirected(a, b), do: if(a <= b, do: {a, b}, else: {b, a})
end
