defmodule NetworkSim.Protocol do
  @moduledoc """
  Behaviour for node-local protocols. The simulator calls these,
  but does not interpret messages or state.
  """

  @callback init(node_id :: term(), opts :: term()) :: any()

  @doc """
  Handle a delivered message from `from` to this node.

  Return:
    * `{:noreply, proto_state}` to do nothing else, or
    * `{:reply, reply_payload, proto_state}` to immediately reply to `from`.
  """
  @callback handle_message(from :: term(), payload :: term(), proto_state :: any()) ::
              {:noreply, any()} | {:reply, term(), any()}
end
