defmodule DemoTest do
  use ExUnit.Case, async: true

  require Logger
  alias NetworkSim.Kruskal
  alias NetworkSim.Router

  @doc """
  A tiny demo network:
      a —— b —— c
      |         |
      └—— d ——──┘
  """
  test "sanity demo with bidirectional links and runtime (de)activation" do
    nodes = [:a, :b, :c, :d]

    links = [
      {:a, :b, %{weight: 1}},
      {:a, :d, %{weight: 4}},
      {:b, :c, %{weight: 2}},
      {:c, :d, %{weight: 3}}
    ]

    filename = "tmp/demo/graph_1.dot"
    :ok = File.mkdir_p!("tmp/demo")
    NetworkSim.Dot.write_dot(nodes, links, filename, format: "svg")

    # boot the network (expects your app exposes something like this)
    NetworkSim.start_network(nodes, links)

    # initial neighbor checks (Router.neighbors/1 should reflect both directions)
    assert MapSet.new(Router.neighbors(:a)) == MapSet.new([:b, :d])
    assert MapSet.new(Router.neighbors(:b)) == MapSet.new([:a, :c])
    assert MapSet.new(Router.neighbors(:c)) == MapSet.new([:b, :d])
    assert MapSet.new(Router.neighbors(:d)) == MapSet.new([:a, :c])

    # test link attributes
    assert NetworkSim.Router.edge_attr(:b, :a) == NetworkSim.Router.edge_attr(:a, :b)
    assert nil == NetworkSim.Router.edge_attr(:a, :c)

    NetworkSim.send(:a, :b, {:ping, make_ref()})
    NetworkSim.send(:a, :b, {:ping, make_ref()})
    NetworkSim.send(:d, :a, {:ping, make_ref()})
    NetworkSim.send(:c, :d, {:ping, make_ref()})

    # disable a link and verify both sides see the change
    assert :ok == Router.disable_link(:b, :c)

    assert {:error, :link_disabled} == NetworkSim.send(:b, :c, {:ping, make_ref()})

    # enable it back
    assert :ok == Router.enable_link(:b, :c)

    assert :ok == NetworkSim.send(:c, :b, {:ping, make_ref()})
    assert {:error, :not_neighbors} == NetworkSim.send(:a, :c, {:ping, make_ref()})

    Logger.info(inspect(Kruskal.kruskal(nodes, links)))
  end
end
