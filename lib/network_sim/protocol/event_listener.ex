defmodule NetworkSim.Protocol.EventListener do
  @behaviour NetworkSim.Protocol
  require Logger

  @impl true
  def init(_id, _opts), do: %{}

  @impl true
  def handle_message(from, {:router_link_down, neighbor, meta}, state) do
    Logger.debug(
      "PROTOCOL: received link_down event from=#{inspect(from)} neighbor=#{inspect(neighbor)} meta=#{inspect(meta)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_message(from, {:router_link_up, neighbor, meta}, state) do
    Logger.debug(
      "PROTOCOL: received link_up event from=#{inspect(from)} neighbor=#{inspect(neighbor)} meta=#{inspect(meta)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_message(_from, _other, state) do
    {:noreply, state}
  end
end
