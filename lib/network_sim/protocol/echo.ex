defmodule NetworkSim.Protocol.Echo do
  @behaviour NetworkSim.Protocol
  require Logger

  @impl true
  def init(_id, _opts), do: %{}

  @impl true
  def handle_message(from, {:echo, str}, state) do
    Logger.debug("PROTOCOL: received echo from=#{inspect(from)} str=#{inspect(str)}")
    {:reply, {:reply, String.upcase(str)}, state}
  end

  @impl true
  def handle_message(_from, _other, state) do
    {:noreply, state}
  end
end
