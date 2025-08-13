defmodule DemoTest do
  use ExUnit.Case, async: false

  require Logger

  alias NetworkSim.Kruskal
  alias NetworkSim.Router
  alias NetworkSim.Dot

  setup do
    File.mkdir_p("tmp/demo")
  end

  defp show_custom_mst(nodes, links, test_name) do
    Dot.show_mst(nodes, links, "tmp/demo/#{test_name}")
  end

  @doc """
  A tiny demo network:
      a —— b —— c
      |         |
      └—— d ——──┘
  """
  test "ping_pong protocol test" do
    nodes = [
      {:a, NetworkSim.Protocol.PingPong, []},
      {:b, NetworkSim.Protocol.PingPong, []},
      {:c, NetworkSim.Protocol.PingPong, []},
      {:d, NetworkSim.Protocol.PingPong, []}
    ]

    links = [
      {:a, :b, %{weight: 1}},
      {:a, :d, %{weight: 4}},
      {:b, :c, %{weight: 2}},
      {:c, :d, %{weight: 3}}
    ]

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

    # test ping_pong protocol
    NetworkSim.send(:a, :b, {:ping, 1})
    NetworkSim.send(:a, :b, {:ping, 2})
    NetworkSim.send(:d, :a, {:ping, 3})
    NetworkSim.send(:c, :d, {:ping, 4})

    # wait to see if pong is in inbox
    Process.sleep(5)
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:pong, 1}})
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:pong, 2}})
    assert Enum.member?(NetworkSim.inbox(:d), {:a, {:pong, 3}})
    assert Enum.member?(NetworkSim.inbox(:c), {:d, {:pong, 4}})

    # disable a link and verify both sides see the change
    Router.disable_link(:b, :c)

    assert {:error, :link_disabled} == NetworkSim.send(:b, :c, {:ping, 5})
    assert {:error, :link_disabled} == NetworkSim.send(:c, :b, {:ping, 5})

    # enable it back
    Router.enable_link(:b, :c)

    assert :ok == NetworkSim.send(:c, :b, {:ping, 6})

    Process.sleep(5)
    assert Enum.member?(NetworkSim.inbox(:c), {:b, {:pong, 6}})

    assert {:error, :not_neighbors} == NetworkSim.send(:a, :c, {:ping, 7})

    test_name = "graph_1"
    new_nodes = Enum.map(nodes, &elem(&1, 0))
    show_custom_mst(new_nodes, links, test_name)

    NetworkSim.stop_network()
  end

  test "echo protocol test" do
    nodes = [
      {:a, NetworkSim.Protocol.Echo, []},
      {:b, NetworkSim.Protocol.Echo, []}
    ]

    links = [
      {:a, :b}
    ]

    NetworkSim.start_network(nodes, links)

    NetworkSim.send(:a, :b, {:echo, "Hello, World!"})

    Process.sleep(10)
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:reply, "HELLO, WORLD!"}})

    NetworkSim.stop_network()
  end

  test "event_listener protocol test" do
    nodes = [
      {:a, NetworkSim.Protocol.EventListener, []},
      {:b, NetworkSim.Protocol.EventListener, []},
      {:c, NetworkSim.Protocol.EventListener, []}
    ]

    links = [
      {:a, :b},
      {:a, :c},
      {:b, :c}
    ]

    NetworkSim.start_network(nodes, links)

    NetworkSim.disable_link(:a, :b)

    Process.sleep(10)

    assert Enum.any?(NetworkSim.inbox(:a), fn
             {_, {:router_link_down, :b, _}} -> true
             _ -> false
           end)

    assert Enum.any?(NetworkSim.inbox(:b), fn
             {_, {:router_link_down, :a, _}} -> true
             _ -> false
           end)

    assert Enum.empty?(NetworkSim.inbox(:c))

    NetworkSim.disable_link(:a, :b)
    NetworkSim.enable_link(:a, :b)

    Process.sleep(10)
    NetworkSim.stop_network()
  end

  # test "dynamic MST protocol" do
  #   nodes = [:a, :b, :c, :d]

  #   links = [
  #     {:a, :b, %{weight: 1}},
  #     {:a, :d, %{weight: 4}},
  #     {:b, :c, %{weight: 2}},
  #     {:c, :d, %{weight: 3}}
  #   ]

  #   NetworkSim.start_network(nodes, links)
  #   mst = Kruskal.rooted_forest(Kruskal.kruskal(nodes, links).edges)
  # end
end
