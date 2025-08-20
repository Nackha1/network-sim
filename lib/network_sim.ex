defmodule NetworkSim do
  @moduledoc """
  # NetworkSim

  Public API for a small network simulator using **undirected / bidirectional links**.

  The simulator is designed to exercise distributed graph protocols (for example,
  GHS MST and resilient/dynamic MST variants) over a process-per-node model. In
  particular, this module focuses on:

  - **Graph loading**: Provide an undirected graph either as a map accepted by
    `NetworkSim.Router.load_graph/1`, or more commonly via
    two lists — `node_specs` and `links` — using `start_network/2`.
  - **Topology queries and edits**: Inspect neighbor sets, enable/disable links,
    and check whether a link is currently enabled.
  - **Messaging**: Send a payload over an **enabled** undirected edge between
    two nodes, delegating routing to the Router.
  - **Node conveniences**: Inspect and clear a node inbox, read node state, and
    extract a `{id, parent, children}` view useful for tree-shaped protocols.

  ## Lifecycle

  1. Call `start_network/2` with `node_specs` and `links`.
  2. Interact with the network (enable/disable links, send messages, read inbox).
  3. Call `stop_network/0` to stop all node processes and clear the graph.
  """

  require Logger
  alias NetworkSim.Router

  # ================
  #  Types
  # ================

  @typedoc """
  User-defined node identifier (string, integer, atom, tuple, etc.).

  Identifiers are treated opaquely and only compared for equality and ordering
  when canonicalizing undirected edges (see `undirected/2`).
  """
  @type node_id :: term()

  @typedoc """
  An **undirected** link; may carry an attribute map in the 3rd position.

  - `{u, v}` means “connect `u` and `v` with default attrs `%{}`”
  - `{u, v, attrs}` attaches user-defined metadata (e.g. weights, capacities)
  """
  @type link :: {node_id(), node_id()} | {node_id(), node_id(), map()}

  @typedoc """
  Per-node protocol spec: `{id, ProtocolModule, options}`.

  At startup, each node process is (re)configured with `{ProtocolModule, options}`.
  """
  @type node_spec :: {node_id(), module(), keyword()}

  @typedoc """
  Adjacency as a **list-based** map: each node maps to a (deduplicated) list
  of neighbor node ids. Order is not significant.
  """
  @type list_adjacency :: %{required(node_id()) => [node_id()]}

  # ================
  #  Graph loading
  # ================

  @doc """
  Start (or reconfigure) the network from a set of nodes and undirected links.

  ## Parameters

  - `node_specs` — a non-empty list like:
    `[{id :: t:node_id/0, protocol_module :: module(), options :: keyword()}]`
  - `links` — undirected edges:
    `[{u, v}]` or `[{u, v, %{...attrs...}}]` (self-loops are ignored)

  ## Behavior

  This function:

  1. Builds a **normalized undirected adjacency** `%{id => MapSet.neighbors}`.
  2. Builds a **canonical edge-attributes map** `%{{min, max} => attrs}` where
     `{min, max}` is the ordered pair of endpoints (see `undirected/2`).
  3. Calls `Router.load_graph/2` **once** with `(adjacency, attrs)` — Router
     is expected to be pure w.r.t. this normalization.
  4. Ensures one `NetworkSim.Node` per `id`, started (or updated) with
     `{ProtocolModule, options}`.

  The operation is additive with respect to missing nodes in `links`: if an id
  appears only in `node_specs`, it is still present in the adjacency with an
  empty neighbor set.

  ## Returns

  - `:ok` on success
  - `{:error, reason}` if any node process fails to start
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

  - Terminates all children under `NetworkSim.NodeSupervisor`.
  - Resets Router state by calling `Router.load_graph(%{}, %{})`.
  - Returns `:ok` even if the network is already stopped.
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
  Return the **current** neighbor set of `id` as a `MapSet`.

  The set reflects Router’s current enabled undirected links.
  """
  @spec neighbors(node_id()) :: MapSet.t(node_id())
  def neighbors(id), do: Router.neighbors(id)

  @doc """
  Check if the undirected link `{a, b}` is currently **enabled**.

  Returns `true` if traffic can flow between `a` and `b` in both directions,
  else `false`.
  """
  @spec link_enabled?(node_id(), node_id()) :: boolean()
  def link_enabled?(a, b), do: Router.link_enabled?(a, b)

  # =====================
  #  Topology modifications
  # =====================

  @doc """
  Enable or (re-)enable the undirected link `{a, b}` **both directions**.

  ## Parameters

  - `a`, `b` — node identifiers
  - `attrs` — attribute map for the edge (defaults to `%{}`)

  ## Returns

  - Typically `:ok` (delegated to `Router.enable_link/3`)

  ## Notes

  Supplying `attrs` overwrites any previous attributes stored for the
  canonical key `{min(a, b), max(a, b)}`.
  """
  # @spec enable_link(node_id(), node_id()) :: :ok
  def enable_link(a, b, attrs \\ %{}), do: Router.enable_link(a, b, attrs)

  @doc """
  Disable the undirected link `{a, b}` **both directions**.

  After disabling, `link_enabled?/2` returns `false`, and `neighbors/1`
  no longer includes the opposite endpoint for either node.
  """
  @spec disable_link(node_id(), node_id()) :: :ok
  def disable_link(a, b), do: Router.disable_link(a, b)

  # ===============
  #  Messaging API
  # ===============

  @doc """
  Send a payload from `from` to `to` over an **enabled** undirected edge.

  ## Parameters

  - `from` — sender id
  - `to` — immediate neighbor id (must be enabled)
  - `payload` — any term to deliver

  ## Returns

  - `:ok` on success
  - `{:error, reason}` if `{from, to}` is not enabled or delivery fails
  """
  @spec send(node_id(), node_id(), any()) :: :ok | {:error, term()}
  def send(from, to, payload), do: Router.send(from, to, payload)

  # ==================
  #  Node conveniences
  # ==================

  @doc """
  Read a node's inbox (most recent at the end).

  Returns a list of `{from, payload}` tuples as stored by `NetworkSim.Node`.
  """
  @spec inbox(node_id()) :: [{node_id(), any()}]
  def inbox(id), do: NetworkSim.Node.inbox(id)

  @doc """
  Clear a node's inbox.

  Removes all pending messages for the given node.
  """
  @spec clear_inbox(node_id()) :: :ok
  def clear_inbox(id), do: NetworkSim.Node.clear_inbox(id)

  @doc """
  Get a node's **raw** process state via `:sys.get_state/1`.

  ## Returns

  - Any term returned by the node process, or `{:error, :node_not_found}`.

  ## Warning

  This is a low-level escape hatch intended for debugging or test assertions.
  Prefer higher-level accessors where available.
  """
  @spec get_raw_state(node_id()) :: any()
  def get_raw_state(id) do
    case Registry.lookup(NetworkSim.Registry, {:node, id}) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> {:error, :node_not_found}
    end
  end

  @doc """
  Return a **tree-projection** of each node’s state for protocols that maintain
  a rooted tree (e.g., MST variants).

  Each element is a map with keys `:id`, `:parent`, `:children` extracted from
  `NetworkSim.Node.state/1`.
  """
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
