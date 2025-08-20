defmodule NetworkSim.Protocol.PingPong do
  @behaviour NetworkSim.Protocol
  require Logger

  @impl true
  def init(_id, _opts), do: %{}

  @impl true
  def handle_message(from, {:ping, ref}, state) do
    Logger.debug("Received ping from=#{inspect(from)} ref=#{inspect(ref)}")
    {:reply, {:pong, ref}, state}
  end

  @impl true
  def handle_message(_from, _other, state) do
    {:noreply, state}
  end
end
