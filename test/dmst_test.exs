defmodule ProtocolTest do
  use ExUnit.Case, async: true

  require Logger
  alias NetworkSim.Dot
  alias NetworkSim.Protocol

  setup do
    File.mkdir_p("tmp/dmst")
  end

  defp show_custom_mst(nodes, links, test_name) do
    Dot.show_mst(nodes, links, "tmp/dmst/#{test_name}")
  end

  test "dynamic MST" do
    nodes = [
      {:a, Protocol.DynamicMST, %{parent: nil, children: [:b, :c]}},
      {:b, Protocol.DynamicMST, %{parent: :a, children: []}},
      {:c, Protocol.DynamicMST, %{parent: :a, children: [:d, :e]}},
      {:d, Protocol.DynamicMST, %{parent: :c, children: []}},
      {:e, Protocol.DynamicMST, %{parent: :c, children: []}}
    ]

    links = [
      {:a, :b, %{weight: 8}},
      {:a, :c, %{weight: 1}},
      {:c, :d, %{weight: 2}},
      {:c, :e, %{weight: 3}},
      {:a, :d, %{weight: 5}},
      {:a, :e, %{weight: 6}}
    ]

    # nodes = [
    #   {:a, Protocol.DynamicMST, %{parent: nil, children: [:b]}},
    #   {:b, Protocol.DynamicMST, %{parent: :a, children: []}}
    # ]

    # links = [
    #   {:a, :b, %{weight: 3}}
    # ]

    test_name = "dynamic_mst_start"
    show_custom_mst(Enum.map(nodes, &elem(&1, 0)), links, test_name)

    NetworkSim.start_network(nodes, links)

    NetworkSim.disable_link(:a, :c)
    NetworkSim.disable_link(:a, :d)
    NetworkSim.disable_link(:a, :b)
    NetworkSim.enable_link(:a, :c)

    Process.sleep(100)

    tree = NetworkSim.get_tree()

    Logger.info("Tree after disabling links: #{inspect(tree, pretty: true)}")

    test_name = "dynamic_mst_end"

    show_custom_mst(
      Enum.map(nodes, &elem(&1, 0)),
      (links --
         [{:a, :c, %{weight: 1}}, {:a, :d, %{weight: 5}}, {:a, :b, %{weight: 8}}]) ++
        [{:a, :c, %{weight: 1}}],
      test_name
    )

    # Enum.each(new_nodes, fn n ->
    #   IO.puts("#{inspect(NetworkSim.get_raw_state(n), pretty: true)}")
    # end)

    NetworkSim.stop_network()
  end
end
