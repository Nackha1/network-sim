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
  User-defined node identifier
  """
  @type node_id :: term()

  @typedoc """
  Internal state
  """
  @type state :: %{
          id: node_id(),
          inbox: [{node_id(), any()}],
          protocol_module: module(),
          protocol_state: any()
        }

  ## Public API

  @doc """
  Start a node, optionally specifying a protocol:

      NetworkSim.Node.start_link(:a, protocol: {MyProto, proto_opts})

  If omitted, uses the app-level default protocol (see below).
  """
  def start_link(id, opts \\ []) do
    GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
  end

  def state(id), do: GenServer.call(via(id), :state)

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
  def init({id, opts}) do
    Logger.metadata(node_id: inspect(id))

    {proto_mod, proto_opts} =
      case Keyword.get(opts, :protocol) do
        {mod, p_opts} when is_atom(mod) ->
          {mod, p_opts}

        nil ->
          {NetworkSim.Protocol.PingPong, %{}}
      end

    proto_state = proto_mod.init(id, proto_opts)

    Logger.info("Node started with {#{inspect(proto_mod)}, #{inspect(proto_opts)}}",
      module: __MODULE__
    )

    {:ok, %{id: id, inbox: [], proto_mod: proto_mod, proto_state: proto_state}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state.proto_state, state}
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
  def handle_cast(
        {:deliver, from, payload},
        %{id: id, inbox: inbox, proto_mod: pm, proto_state: ps} = state
      ) do
    case from do
      :router ->
        Logger.warning(
          "Received router event #{inspect(payload)}",
          module: __MODULE__
        )

      ^id ->
        Logger.debug(
          "Received self-message (#{inspect(payload)})",
          module: __MODULE__
        )

      _ ->
        Logger.info(
          "Received message from=#{inspect(from)} payload=#{inspect(payload)}",
          module: __MODULE__
        )
    end

    # Always record deliveries (handy for tests/inspection)
    new_state = %{state | inbox: [{from, payload} | inbox]}

    st =
      case pm.handle_message(from, payload, ps) do
        {:noreply, ps2} ->
          %{new_state | proto_state: ps2}

        {:reply, reply_payload, ps2} ->
          # Reply goes back through the router so topology rules still apply.
          _ = NetworkSim.send(id, from, reply_payload)
          %{new_state | proto_state: ps2}
      end

    # Logger.debug("State after handling latest message \n#{inspect(st, pretty: true)}")

    {:noreply, st}
  end
end
