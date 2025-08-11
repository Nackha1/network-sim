defmodule NetworkSim.Router do
  @moduledoc """
  Central authority for topology and link enable/disable state **assuming
  all links are bidirectional**.

  Responsibilities:
    * own an **undirected** adjacency (symmetric neighbor sets)
    * keep a `MapSet` of disabled **undirected** edges (normalized `{a, b}`)
    * offer functions to enable/disable links
    * route messages between neighboring nodes when the undirected link is enabled
  """

  use GenServer
  require Logger

  @typedoc """
  User-defined node identifier (string, integer, atom, etc.).
  """
  @type node_id :: term()

  @typedoc """
  Symmetric adjacency: for every `{u, v}` edge, both `u` includes `v`
  **and** `v` includes `u`.
  """
  @type adjacency :: %{node_id() => MapSet.t(node_id())}

  @typedoc """
  Undirected edge key stored as `{min(u,v), max(u,v)}`.
  """
  @type uedge :: {node_id(), node_id()}

  @typedoc """
    Arbitrary edge attributes keyed by undirected edge.
  """
  @type edge_attrs :: %{optional(uedge()) => term()}

  @typedoc """
  Internal state.
  """
  @type state :: %{
          adjacency: adjacency(),
          disabled: MapSet.t(uedge()),
          attrs: edge_attrs()
        }

  ## Public API

  @doc """
  Start the router.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
    Load or replace the current graph (no attributes).
  """
  @spec load_graph(%{optional(node_id()) => [node_id()]}) :: :ok
  def load_graph(graph_spec), do: GenServer.call(__MODULE__, {:load_graph, graph_spec, %{}})

  @doc """
    Load or replace the current graph **and** set per-edge attributes.
  """
  @spec load_graph(%{optional(node_id()) => [node_id()]}, edge_attrs()) :: :ok
  def load_graph(graph_spec, attrs),
    do: GenServer.call(__MODULE__, {:load_graph, graph_spec, attrs})

  @doc """
    Read attributes for an undirected edge `{a,b}`.
    Returns `nil` if none are set.
  """
  @spec edge_attr(node_id(), node_id()) :: term() | nil
  def edge_attr(a, b), do: GenServer.call(__MODULE__, {:edge_attr, undirected(a, b)})

  @doc """
  Return the current neighbors for a node.
  """
  @spec neighbors(node_id()) :: MapSet.t(node_id())
  def neighbors(node_id), do: GenServer.call(__MODULE__, {:neighbors, node_id})

  @doc """
  Disable an **undirected** link between `a` and `b`. No effect if the edge does not exist.
  """
  @spec disable_link(node_id(), node_id()) :: :ok
  def disable_link(a, b), do: GenServer.call(__MODULE__, {:disable, undirected(a, b)})

  @doc """
  Enable an **undirected** link between `a` and `b`.
  """
  @spec enable_link(node_id(), node_id()) :: :ok
  def enable_link(a, b), do: GenServer.call(__MODULE__, {:enable, undirected(a, b)})

  @doc """
  Route a `payload` from `from` to `to` if:
    * `to` is a neighbor of `from`, and
    * the **undirected** link `{from, to}` is not disabled.

  Returns:
    * `:ok` on delivery (asynchronous `GenServer.cast/2` to `to`)
    * `{:error, reason}` otherwise
  """
  @spec send(node_id(), node_id(), any()) :: :ok | {:error, term()}
  def send(from, to, payload), do: GenServer.call(__MODULE__, {:send, from, to, payload})

  @doc """
  Check if an **undirected** link `{a, b}` is currently enabled.
  """
  @spec link_enabled?(node_id(), node_id()) :: boolean()
  def link_enabled?(a, b), do: GenServer.call(__MODULE__, {:link_enabled?, undirected(a, b)})

  ## GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %{adjacency: %{}, disabled: MapSet.new(), attrs: %{}}}
  end

  @impl true
  def handle_call({:load_graph, graph_spec, raw_attrs}, _from, _state) do
    {adj, nodes} = normalize_graph(graph_spec)

    Enum.each(nodes, &ensure_node/1)

    # Normalize attribute keys to undirected, and (optionally) drop attrs
    # that don’t correspond to an existing edge in `adj`.
    edge_keys = MapSet.new(all_edges(adj))

    attrs =
      raw_attrs
      |> Enum.map(fn
        {{a, b}, v} -> {undirected(a, b), v}
        other -> other
      end)
      |> Enum.filter(fn {k, _} -> MapSet.member?(edge_keys, k) end)
      |> Map.new()

    Logger.info("Graph loaded with #{map_size(adj)} nodes", module: __MODULE__)
    {:reply, :ok, %{adjacency: adj, disabled: MapSet.new(), attrs: attrs}}
  end

  def handle_call({:edge_attr, e}, _from, %{attrs: attrs} = state) do
    {:reply, Map.get(attrs, e), state}
  end

  def handle_call({:neighbors, node_id}, _from, %{adjacency: adj} = state) do
    {:reply, Map.get(adj, node_id, MapSet.new()), state}
  end

  def handle_call({:disable, {a, b}}, _from, %{adjacency: adj, disabled: dis} = state) do
    # Only disable if the edge exists in the graph
    dis2 =
      if MapSet.member?(Map.get(adj, a, MapSet.new()), b) do
        MapSet.put(dis, {a, b})
      else
        dis
      end

    {:reply, :ok, %{state | disabled: dis2}}
  end

  def handle_call({:enable, e}, _from, %{disabled: dis} = state) do
    {:reply, :ok, %{state | disabled: MapSet.delete(dis, e)}}
  end

  def handle_call({:link_enabled?, e}, _from, %{disabled: dis} = state) do
    {:reply, not MapSet.member?(dis, e), state}
  end

  def handle_call({:send, from, to, payload}, _from, %{adjacency: adj, disabled: dis} = state) do
    e = undirected(from, to)

    cond do
      not Map.has_key?(adj, from) ->
        {:reply, {:error, :unknown_sender}, state}

      not MapSet.member?(Map.get(adj, from, MapSet.new()), to) ->
        {:reply, {:error, :not_neighbors}, state}

      MapSet.member?(dis, e) ->
        {:reply, {:error, :link_disabled}, state}

      true ->
        case Registry.lookup(NetworkSim.Registry, {:node, to}) do
          [{pid, _}] ->
            GenServer.cast(pid, {:deliver, from, payload})
            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :unknown_receiver}, state}
        end
    end
  end

  ## Helpers

  # Normalize an arbitrary pair to an undirected edge key
  @spec undirected(node_id(), node_id()) :: uedge()
  defp undirected(a, b) do
    if a <= b, do: {a, b}, else: {b, a}
  end

  # Collect all undirected edges present in adjacency
  defp all_edges(adj) do
    adj
    |> Enum.flat_map(fn {u, vs} ->
      vs
      |> MapSet.to_list()
      # keep one direction (u < v)
      |> Enum.filter(&(&1 > u))
      |> Enum.map(&{u, &1})
    end)
  end

  # Make adjacency symmetric and collect all nodes
  defp normalize_graph(graph_spec) when is_map(graph_spec) do
    # First pass: coerce values to sets
    adj0 =
      graph_spec
      |> Enum.map(fn {id, neighs} -> {id, MapSet.new(List.wrap(neighs))} end)
      |> Map.new()

    # Second pass: symmetrize (for every u->v, add v->u)
    adj1 =
      Enum.reduce(adj0, adj0, fn {u, vs}, acc ->
        Enum.reduce(vs, acc, fn v, acc2 ->
          Map.update(acc2, v, MapSet.new([u]), &MapSet.put(&1, u))
        end)
      end)

    nodes =
      adj1
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(adj1 |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2))
      |> MapSet.to_list()

    {adj1, nodes}
  end

  defp ensure_node(id) do
    name = NetworkSim.Node.via(id)

    case GenServer.whereis(name) do
      nil ->
        spec = {NetworkSim.Node, id}

        case DynamicSupervisor.start_child(NetworkSim.NodeSupervisor, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> :ok
          other -> other
        end

      _pid ->
        :ok
    end
  end
end
