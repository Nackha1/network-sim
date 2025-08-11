defmodule NetworkSim.Application do
  @moduledoc """
  Application entrypoint. Starts:
    * `Registry` for node name lookup
    * `DynamicSupervisor` for node processes
    * `NetworkSim.Router` which owns the graph and link state
  """
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: NetworkSim.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: NetworkSim.NodeSupervisor},
      {NetworkSim.Router, []}
    ]

    opts = [strategy: :one_for_one, name: NetworkSim.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
