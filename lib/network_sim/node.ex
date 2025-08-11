defmodule NetworkSim.Node do
  @moduledoc """
  A node in the simulated network.

  Each node:
    * is a `GenServer`
    * registers in `Registry` under `{:node, id}`
    * keeps a simple inbox of received messages for inspection
  """

  use GenServer
  require Logger

  @typedoc """
  User-defined node identifier (string, integer, etc.)
  """
  @type node_id :: term()

  @typedoc """
  Internal state
  """
  @type state :: %{
          id: node_id(),
          inbox: [{node_id(), any()}]
        }

  ## Public API

  @doc """
  Start a node under the DynamicSupervisor and register it
  """
  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  @doc """
  Return the node's current inbox
  """
  def inbox(id), do: GenServer.call(via(id), :inbox)

  @doc """
  Clear the node's inbox (for demo/testing)
  """
  def clear_inbox(id), do: GenServer.call(via(id), :clear_inbox)

  @doc false
  def via(id), do: {:via, Registry, {NetworkSim.Registry, {:node, id}}}

  ## GenServer callbacks

  @impl true
  def init(id) do
    Logger.metadata(node_id: inspect(id))
    Logger.info("Node started", module: __MODULE__)
    {:ok, %{id: id, inbox: []}}
  end

  @impl true
  def handle_call(:inbox, _from, state) do
    {:reply, Enum.reverse(state.inbox), state}
  end

  @impl true
  def handle_call(:clear_inbox, _from, state) do
    {:reply, :ok, %{state | inbox: []}}
  end

  @impl true
  def handle_cast({:deliver, from, payload}, %{id: _id, inbox: inbox} = state) do
    Logger.debug("Received from=#{inspect(from)} payload=#{inspect(payload)}",
      module: __MODULE__
    )

    {:noreply, %{state | inbox: [{from, payload} | inbox]}}
  end
end
