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

  @type node_id :: term()
  @type graph :: %{optional(node_id()) => MapSet.t(node_id())}
  @type edge_key :: {node_id(), node_id()}
  @type edge_attrs :: %{optional(edge_key()) => map()}

  @type state :: %{
          graph: graph(),
          disabled: MapSet.t(edge_key()),
          attrs: edge_attrs()
        }

  ## Public API

  @doc """
  Start the router.
  """
  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Replace the current graph and edge attributes.

  Inputs must already be normalized:
    * `graph`: `%{id => MapSet.neighbors}`
    * `attrs`: `%{{min,max} => map}`
  """
  @spec load_graph(graph(), edge_attrs()) :: :ok
  def load_graph(graph, attrs \\ %{}),
    do: GenServer.call(__MODULE__, {:load_graph, graph, attrs})

  @doc """
    Load or replace the current graph **and** set per-edge attributes.
  """
  @spec load_graph(%{optional(node_id()) => [node_id()]}, edge_attrs(), module()) :: :ok
  def load_graph(graph_spec, attrs, protocol),
    do: GenServer.call(__MODULE__, {:load_graph, graph_spec, attrs, protocol})

  @doc """
  Get the current node IDs.
  """
  @spec nodes() :: [node_id()]
  def nodes(), do: GenServer.call(__MODULE__, {:nodes})

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
  @spec enable_link(node_id(), node_id(), map()) :: term()
  def enable_link(a, b, attrs),
    do: GenServer.call(__MODULE__, {:enable, undirected(a, b), attrs})

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

  ## Helpers

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
