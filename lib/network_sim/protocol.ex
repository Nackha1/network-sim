defmodule NetworkSim.Protocol do
  @moduledoc """
  # NetworkSim.Protocol

  Behaviour for **node-local protocols**. The simulator (via `NetworkSim.Node`)
  calls these callbacks but does not interpret messages or internal state.

  Implementers provide **pure protocol logic** that reacts to incoming messages
  and optionally replies immediately. The behaviour is intentionally small:

  - `c:init/2` — initialize and return the **protocol state** for this node
  - `c:handle_message/3` — handle one delivered message and optionally reply

  ## Implementing this behaviour

  - Declare `@behaviour NetworkSim.Protocol` in your module and define both callbacks.
  - Mark each implemented callback with `@impl true` for compiler checks and clearer intent. :contentReference[oaicite:0]{index=0}

  ## Message delivery model

  - The simulator delivers `payload` from a neighbor `from` to your node by
    calling `c:handle_message/3`.
  - You may:
    - return `{:noreply, new_proto_state}` to do nothing else, or
    - return `{:reply, reply_payload, new_proto_state}` to immediately reply to `from`.

  ## Examples

      defmodule DemoProtocol do
        @behaviour NetworkSim.Protocol

        @impl true
        def init(node_id, _opts) do
          %{id: node_id, seen: 0}
        end

        @impl true
        def handle_message(from, {:ping, n}, state) do
          {:reply, {:pong, n}, %{state | seen: state.seen + 1}}
        end

        def handle_message(_from, _payload, state) do
          {:noreply, state}
        end
      end
  """

  # ================
  #  Types
  # ================

  @typedoc """
  User-defined node identifier (atom, integer, string, tuple, etc.).
  """
  @type node_id :: term()

  @typedoc """
  Opaque protocol state maintained by the implementer.
  """
  @type proto_state :: any()

  @typedoc """
  Result returned by `c:handle_message/3`.
  """
  @type on_message :: {:noreply, proto_state()} | {:reply, term(), proto_state()}

  # ================
  #  Callbacks
  # ================

  @doc """
  Initialize the protocol state for a given node.

  ## Parameters
  - `node_id` — identifier for this node (opaque to the protocol)
  - `opts` — implementer-defined options (passed when the node starts)

  ## Returns
  - `proto_state` — any term; fed back to subsequent `c:handle_message/3` calls

  ### Notes
  Define callbacks using `@callback`, which is the idiomatic way to declare
  behaviour contracts in modern Elixir
  """
  @callback init(node_id :: node_id(), opts :: term()) :: proto_state()

  @doc """
  Handle a delivered message.

  The simulator calls this when a neighbor `from` sends `payload` to this node.

  ## Parameters
  - `from` — sender’s node id
  - `payload` — arbitrary term delivered from the neighbor
  - `proto_state` — the current protocol state for this node

  ## Returns
  - `{:noreply, new_state}` to take no further action, or
  - `{:reply, reply_payload, new_state}` to immediately reply to `from`.

  ### Tips
  - Keep state updates and side-effects explicit; the simulator only transports
    messages and relays your chosen reply.
  - Use typespecs in your implementation modules; callbacks are defined with
    `@callback` just like `@spec`.
  """
  @callback handle_message(from :: node_id(), payload :: term(), proto_state :: proto_state()) ::
              on_message()
end
