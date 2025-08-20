defmodule NetworkSim.Node do
  @moduledoc """
  # NetworkSim.Node

  A **node process** in the simulated network.

  Each node:

  - runs as a `GenServer`;
  - registers itself in `Registry` under the key `{:node, id}`;
  - maintains a simple **inbox** of delivered messages for inspection and tests;
  - hosts a **protocol module** (implementing `NetworkSim.Protocol`) and its
    **protocol state**; only the protocol decides how to react to messages.

  ## Message flow

  1. Another node (or the router) triggers delivery: the Router calls
     `GenServer.cast(node_pid, {:deliver, from, payload})`.
  2. The node **records** the delivery in its inbox (for observability).
  3. The node delegates to the protocol via `c:NetworkSim.Protocol.handle_message/3`.
  4. If the protocol returns `{:reply, reply_payload, new_state}`, the node
     sends the reply back **through the router** using `NetworkSim.send/3`
     (so topology rules still apply).

  ### Default protocol

  If no protocol is given at start, the node uses `NetworkSim.Protocol.PingPong`
  with options `%{}`. You can supply a protocol with:

      NetworkSim.Node.start_link(:a, protocol: {MyProto, my_opts})
  """

  use GenServer
  require Logger

  # ================
  #  Types
  # ================

  @typedoc """
  User-defined node identifier (atom, integer, string, tuple, etc.).
  """
  @type node_id :: term()

  @typedoc """
  Internal process state held by the `GenServer`.

  - `:id` — node identifier
  - `:inbox` — list of `{from, payload}`; newest at the **head**, but
    `inbox/1` returns them **chronologically** (oldest → newest)
  - `:proto_mod` — protocol module implementing `NetworkSim.Protocol`
  - `:proto_state` — protocol’s private state (opaque)
  """
  @type state :: %{
          id: node_id(),
          inbox: [{node_id(), any()}],
          protocol_module: module(),
          protocol_state: any()
        }

  # ================
  #  Public API
  # ================

  @doc """
  Start a node process.

  Optionally specify a protocol with `protocol: {Module, opts}`. If omitted,
  the node starts with `NetworkSim.Protocol.PingPong` and `%{}` options.
  """
  @spec start_link(node_id(), keyword()) :: GenServer.on_start()
  def start_link(id, opts \\ []) do
    GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
  end

  @doc """
  Return the node’s **protocol state** (the inner state managed by the protocol).

  This is the value the protocol returned from `init/2` and evolved via
  `handle_message/3`.
  """
  @spec state(any()) :: any()
  def state(id), do: GenServer.call(via(id), :state)

  @doc """
  Return the node’s current inbox as a list of `{from, payload}`.

  The list is ordered **chronologically** (oldest first, newest last), which is
  handy for assertions in tests and for manual inspection.
  """
  @spec inbox(node_id()) :: [{node_id(), any()}]
  def inbox(id), do: GenServer.call(via(id), :inbox)

  @doc """
  Clear the node’s inbox.

  Useful in demos/tests to reset observation state.
  """
  @spec clear_inbox(node_id()) :: :ok
  def clear_inbox(id), do: GenServer.call(via(id), :clear_inbox)

  @doc false
  @spec via(node_id()) :: {:via, module(), {module(), term()}}
  def via(id), do: {:via, Registry, {NetworkSim.Registry, {:node, id}}}

  # ================
  #  GenServer callbacks
  # ================

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
