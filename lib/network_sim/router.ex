defmodule NetworkSim.Router do
  @moduledoc """
  # NetworkSim.Router

  Central authority for **topology**, **edge attributes**, and **enable/disable state**
  assuming all links are **undirected / bidirectional**.

  The Router is a single `GenServer` that owns:

  - an **undirected adjacency** `graph :: %{id => MapSet.neighbors}` (symmetric);
  - a `MapSet` of **disabled undirected edges** keyed canonically as `{min(a, b), max(a, b)}`;
  - an **edge attributes** table `%{{min, max} => map()}` with arbitrary per-edge metadata.

  ## Responsibilities

  - Load or replace the network graph and its edge attributes (`load_graph/2`).
  - Enable/disable undirected links (`enable_link/3`, `disable_link/2`).
  - Answer topology queries (`neighbors/1`, `nodes/0`, `links/0`, `edge_attr/2`,
    `link_enabled?/2`).
  - **Route** payloads between **neighboring** nodes when the undirected edge is **enabled**
    (`send/3`). Delivery is asynchronous to the receiver via `GenServer.cast/2`.

  ## Canonical undirected edge keys

  Any pair `{a, b}` is normalized to `e = {min(a, b), max(a, b)}` using `<=` so that
  an undirected edge has exactly **one** stable key across the system. See the private
  helper `undirected/2`.

  ### Notes

  - `load_graph/2` **replaces** the current topology and attributes and resets
    the disabled set to empty.
  - `neighbors/1` returns an empty `MapSet` for unknown nodes to keep callers simple.
  - Delivery is attempted only if `from` and `to` are neighbors and the link is enabled.
    On success the receiver gets `{:deliver, from, payload}` via `GenServer.cast/2`.
  """

  use GenServer
  require Logger

  # ================
  #  Types
  # ================

  @typedoc """
  Opaque user-defined node identifier (atom, integer, string, etc.).
  """
  @type node_id :: term()

  @typedoc """
  Undirected adjacency: for each node id, a symmetric set of neighbors.
  """
  @type graph :: %{optional(node_id()) => MapSet.t(node_id())}

  @typedoc """
  Canonical undirected edge key, ordered as `{min(a, b), max(a, b)}`.
  """
  @type edge_key :: {node_id(), node_id()}

  @typedoc """
  Per-edge attributes table: `%{{min, max} => map()}`.
  """
  @type edge_attrs :: %{optional(edge_key()) => map()}

  @typedoc """
  Router server state.
  """
  @type state :: %{
          graph: graph(),
          disabled: MapSet.t(edge_key()),
          attrs: edge_attrs()
        }

  # ================
  #  Public API
  # ================

  ## Public API

  @doc """
  Start the router process.

  Returns `{:ok, pid}` on success.

  The process is registered by module name (`name: __MODULE__`) for convenient calls.
  """
  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Replace the current graph and edge attributes.

  **Inputs must already be normalized**:

  - `graph`: `%{id => MapSet.neighbors}`
  - `attrs`: `%{{min, max} => map}`

  This call **clears** the disabled set.
  """
  @spec load_graph(graph(), edge_attrs()) :: :ok
  def load_graph(graph, attrs \\ %{}),
    do: GenServer.call(__MODULE__, {:load_graph, graph, attrs})

  @doc """
  (Reserved) Load or replace the current graph **and** set per-edge attributes
  from a _list-based_ adjacency.

  > **Status:** API placeholder for future convenience. The server currently
  > expects adjacency in normalized `MapSet` form and does **not** implement
  > this message. Prefer `load_graph/2` with normalized inputs.

  - `graph_spec`: `%{id => [neighbor_ids...]}` (list-based adjacency)
  - `attrs`: `%{{min, max} => map}`
  - `protocol`: a module tag passed by higher layers (unused here)
  """
  @spec load_graph(%{optional(node_id()) => [node_id()]}, edge_attrs(), module()) :: :ok
  def load_graph(graph_spec, attrs, protocol),
    do: GenServer.call(__MODULE__, {:load_graph, graph_spec, attrs, protocol})

  @doc """
  Get the current node IDs as a list (order not guaranteed).
  """
  @spec nodes() :: [node_id()]
  def nodes(), do: GenServer.call(__MODULE__, {:nodes})

  @doc """
  Get the current **enabled** undirected links as `[{u, v, attrs}]`.

  Only links **not** present in the `disabled` set are returned. Attributes are
  looked up from the `attrs` table.
  """
  @spec links() :: [edge_attrs()]
  def links(), do: GenServer.call(__MODULE__, {:links})

  @doc """
  Read attributes for an undirected edge `{a, b}`.

  Returns the stored map or `nil` if none are set.
  """
  @spec edge_attr(node_id(), node_id()) :: term() | nil
  def edge_attr(a, b), do: GenServer.call(__MODULE__, {:edge_attr, undirected(a, b)})

  @doc """
  Return the current neighbors for a node as a `MapSet`.

  If `node_id` is unknown in the current graph, returns an **empty** `MapSet`.
  """
  @spec neighbors(node_id()) :: MapSet.t(node_id())
  def neighbors(node_id), do: GenServer.call(__MODULE__, {:neighbors, node_id})

  @doc """
  Disable an **undirected** link between `a` and `b`. No effect if the edge does not exist.

  On first disable, both endpoints (if running) receive:

  - `{:deliver, :router, {:router_link_down, other, %{edge: {min, max}, attrs: map_or_nil}}}`
  """
  @spec disable_link(node_id(), node_id()) :: :ok
  def disable_link(a, b), do: GenServer.call(__MODULE__, {:disable, undirected(a, b)})

  @doc """
  Enable (or create and enable) an **undirected** link between `a` and `b`.

  - If the edge already exists, it is marked **enabled** and `attrs` (when non-empty)
    overwrite existing attributes.
  - If the edge did not yet exist in the adjacency, both directions are inserted and
    the edge becomes enabled.

  Both endpoints (if running) receive the event notification
  """
  @spec enable_link(node_id(), node_id(), map()) :: term()
  def enable_link(a, b, attrs),
    do: GenServer.call(__MODULE__, {:enable, undirected(a, b), attrs})

  @doc """
  Route a `payload` from `from` to `to` if:

  - `to` is a **neighbor** of `from`, and
  - the **undirected** link `{from, to}` is **enabled**.

  ## Returns

  - `:ok` on delivery (the receiver process gets `{:deliver, from, payload}` via `GenServer.cast/2`)
  - `{:error, :unknown_node | :not_neighbors | :link_disabled | :unknown_receiver_pid}` otherwise

  Special case: if `from == to`, delivery is attempted to `to` (useful for local testing).
  """
  @spec send(node_id(), node_id(), any()) :: :ok | {:error, term()}
  def send(from, to, payload), do: GenServer.call(__MODULE__, {:send, from, to, payload})

  @doc """
  Check if an **undirected** link `{a, b}` is currently **enabled**.
  """
  @spec link_enabled?(node_id(), node_id()) :: boolean()
  def link_enabled?(a, b), do: GenServer.call(__MODULE__, {:link_enabled?, undirected(a, b)})

  # ================
  #  GenServer callbacks
  # ================

  @impl true
  def init(_) do
    {:ok, %{graph: %{}, disabled: MapSet.new(), attrs: %{}}}
  end

  @impl true
  def handle_call({:load_graph, graph, attrs}, _from, _state) do
    Logger.info("Graph loaded with #{map_size(graph)} nodes")
    {:reply, :ok, %{graph: graph, disabled: MapSet.new(), attrs: attrs}}
  end

  @impl true
  def handle_call({:nodes}, _from, state) do
    {:reply, Map.keys(state.graph), state}
  end

  @impl true
  def handle_call({:links}, _from, state) do
    {:reply,
     state.attrs
     |> Enum.filter(fn {edge_key, _} -> not MapSet.member?(state.disabled, edge_key) end)
     |> Enum.map(fn {{u, v}, attrs} -> {u, v, attrs} end), state}
  end

  @impl true
  def handle_call({:edge_attr, e}, _from, %{attrs: attrs} = state) do
    {:reply, Map.get(attrs, e), state}
  end

  @impl true
  def handle_call({:neighbors, node_id}, _from, %{graph: g} = state) do
    {:reply, Map.get(g, node_id), state}
  end

  @impl true
  def handle_call({:disable, e}, _from, %{graph: g, disabled: dis, attrs: attrs} = state) do
    {a, b} = e

    # Only act if edge is in the topology
    if edge_exists?(g, a, b) do
      if MapSet.member?(dis, e) do
        # already disabled
        {:reply, {:warning, :link_already_disabled}, state}
      else
        dis2 = MapSet.put(dis, e)
        meta = %{edge: e, attrs: Map.get(attrs, e)}

        notify(a, {:router_link_down, b, meta})
        notify(b, {:router_link_down, a, meta})

        {:reply, :ok, %{state | disabled: dis2}}
      end
    else
      {:reply, {:error, :unknown_edge}, state}
    end
  end

  @impl true
  def handle_call(
        {:enable, {a, b} = e, attrs},
        _from,
        %{graph: g, disabled: dis, attrs: old_attrs} = state
      ) do
    dis2 = MapSet.delete(dis, e)

    g2 =
      g
      |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
      |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))

    attrs2 =
      if map_size(attrs) == 0 do
        old_attrs
      else
        Map.put(old_attrs, e, attrs)
      end

    meta = %{edge: e, attrs: Map.get(attrs2, e)}

    notify(a, {:router_link_up, b, meta})
    notify(b, {:router_link_up, a, meta})

    {:reply, :ok, %{state | graph: g2, disabled: dis2, attrs: attrs2}}

    # OLD VERSION
    # if edge_exists?(g, a, b) do
    #   if MapSet.member?(dis, e) do
    #     dis2 = MapSet.delete(dis, e)
    #     meta = %{edge: e, attrs: Map.get(attrs, e)}

    #     notify(a, {:router_link_up, b, meta})
    #     notify(b, {:router_link_up, a, meta})

    #     {:reply, :ok, %{state | disabled: dis2}}
    #   else
    #     # already enabled
    #     {:reply, {:warning, :link_already_enabled}, state}
    #   end
    # else
    #   {:reply, {:error, :unknown_edge}, state}
    # end
  end

  @impl true
  def handle_call({:link_enabled?, e}, _from, %{disabled: dis} = state) do
    {:reply, not MapSet.member?(dis, e), state}
  end

  @impl true
  def handle_call({:send, from, to, payload}, _from, %{graph: g, disabled: dis} = state) do
    cond do
      from == to ->
        deliver(from, to, payload, state)

      # {:reply, {:error, :same_node}, state}

      not Map.has_key?(g, from) or not Map.has_key?(g, to) ->
        {:reply, {:error, :unknown_node}, state}

      not MapSet.member?(Map.get(g, from), to) ->
        {:reply, {:error, :not_neighbors}, state}

      MapSet.member?(dis, undirected(from, to)) ->
        {:reply, {:error, :link_disabled}, state}

      true ->
        deliver(from, to, payload, state)
    end
  end

  # ================
  #  Helpers
  # ================

  # Normalize an arbitrary pair to an undirected edge key
  @spec undirected(node_id(), node_id()) :: edge_key()
  defp undirected(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  # Check if edge exists in the graph
  @spec edge_exists?(graph(), node_id(), node_id()) :: boolean()
  defp edge_exists?(g, a, b) do
    case Map.get(g, a) do
      nil -> false
      ns -> MapSet.member?(ns, b)
    end
  end

  # Deliver a control notification to a node `id` if it is running.
  defp notify(id, msg) do
    case Registry.lookup(NetworkSim.Registry, {:node, id}) do
      [{pid, _}] -> GenServer.cast(pid, {:deliver, :router, msg})
      [] -> :ok
    end
  end

  defp deliver(from, to, payload, state) do
    case Registry.lookup(NetworkSim.Registry, {:node, to}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:deliver, from, payload})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :unknown_receiver_pid}, state}
    end
  end
end
