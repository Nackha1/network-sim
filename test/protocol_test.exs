defmodule NetwrokSim.ProtocolTest do
  use ExUnit.Case, async: false

  require Logger

  alias NetworkSim.Kruskal
  alias NetworkSim.Router
  alias NetworkSim.Dot
  alias NetworkSim.Protocol

  setup do
    File.mkdir_p("tmp/protocol")
  end

  def show_custom_graph(nodes, links, test_name) do
    Dot.show_graph(nodes, links, "tmp/protocol/#{test_name}")
  end

  @doc """
  A tiny demo network:
      a —— b —— c
      |         |
      └—— d ——──┘
  """
  test "ping_pong protocol" do
    nodes = [
      {:a, Protocol.PingPong, []},
      {:b, Protocol.PingPong, []},
      {:c, Protocol.PingPong, []},
      {:d, Protocol.PingPong, []}
    ]

    links = [
      {:a, :b},
      {:a, :d},
      {:b, :c},
      {:c, :d}
    ]

    # Start the network
    NetworkSim.start_network(nodes, links)

    # Print the starting graph
    test_name = "00_ping_pong_start"
    show_custom_graph(Router.nodes(), Router.links(), test_name)

    # Initial neighbor checks (Router.neighbors/1 should reflect both directions)
    assert MapSet.new(Router.neighbors(:a)) == MapSet.new([:b, :d])
    assert MapSet.new(Router.neighbors(:b)) == MapSet.new([:a, :c])
    assert MapSet.new(Router.neighbors(:c)) == MapSet.new([:b, :d])
    assert MapSet.new(Router.neighbors(:d)) == MapSet.new([:a, :c])

    # Test link attributes
    assert Router.edge_attr(:b, :a) == Router.edge_attr(:a, :b)
    assert nil == Router.edge_attr(:a, :c)

    # Test ping_pong protocol
    NetworkSim.send(:a, :b, {:ping, 1})
    NetworkSim.send(:a, :b, {:ping, 2})
    NetworkSim.send(:d, :a, {:ping, 3})
    NetworkSim.send(:c, :d, {:ping, 4})

    # Wait to see if pong is in inbox
    Process.sleep(5)
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:pong, 1}})
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:pong, 2}})
    assert Enum.member?(NetworkSim.inbox(:d), {:a, {:pong, 3}})
    assert Enum.member?(NetworkSim.inbox(:c), {:d, {:pong, 4}})

    # Disable a link and verify both sides see the change
    NetworkSim.disable_link(:b, :c)

    assert {:error, :link_disabled} == NetworkSim.send(:b, :c, {:ping, 5})
    assert {:error, :link_disabled} == NetworkSim.send(:c, :b, {:ping, 5})

    # Enable it back
    NetworkSim.enable_link(:b, :c)

    assert :ok == NetworkSim.send(:c, :b, {:ping, 6})

    # Wait to see if pong is in inbox
    Process.sleep(5)
    assert Enum.member?(NetworkSim.inbox(:c), {:b, {:pong, 6}})

    assert {:error, :not_neighbors} == NetworkSim.send(:a, :c, {:ping, 7})

    # Print the ending graph
    test_name = "01_ping_pong_end"
    show_custom_graph(Router.nodes(), Router.links(), test_name)

    # Stop the network
    NetworkSim.stop_network()
  end

  test "echo protocol" do
    nodes = [
      {:a, Protocol.Echo, []},
      {:b, Protocol.Echo, []}
    ]

    links = [
      {:a, :b}
    ]

    NetworkSim.start_network(nodes, links)

    test_name = "01_echo_start"
    show_custom_graph(Router.nodes(), Router.links(), test_name)

    NetworkSim.send(:a, :b, {:echo, "Hello, World!"})

    Process.sleep(10)
    assert Enum.member?(NetworkSim.inbox(:a), {:b, {:reply, "HELLO, WORLD!"}})

    test_name = "01_echo_end"
    show_custom_graph(Router.nodes(), Router.links(), test_name)

    NetworkSim.stop_network()
  end

  test "event_listener protocol" do
    nodes = [
      {:a, Protocol.EventListener, []},
      {:b, Protocol.EventListener, []},
      {:c, Protocol.EventListener, []}
    ]

    links = [
      {:a, :b},
      {:a, :c},
      {:b, :c}
    ]

    NetworkSim.start_network(nodes, links)

    test_name = "02_event_listener_start"
    show_custom_graph(Router.nodes(), Router.links(), test_name)

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

    Process.sleep(5)
    test_name = "02_event_listener_end"
    show_custom_graph(Router.nodes(), Router.links(), test_name)
    NetworkSim.stop_network()
  end
end
