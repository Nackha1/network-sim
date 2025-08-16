defmodule ProtocolTest do
  use ExUnit.Case, async: true

  require Logger

  alias NetworkSim.Kruskal
  alias NetworkSim.Router
  alias NetworkSim.Dot

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
      {:a, :b, %{weight: 1}},
      {:a, :c, %{weight: 1}},
      {:c, :d, %{weight: 1}},
      {:c, :e, %{weight: 1}},
      {:a, :d, %{weight: 5}},
      {:a, :e, %{weight: 6}}
    ]

    nodes = [
      {:a, Protocol.DynamicMST, %{parent: nil, children: [:b]}},
      {:b, Protocol.DynamicMST, %{parent: :a, children: []}}
    ]

    links = [
      {:a, :b, %{weight: 3}}
    ]

    test_name = "dynamic_mst"
    new_nodes = Enum.map(nodes, &elem(&1, 0))
    show_custom_mst(new_nodes, links, test_name)

    NetworkSim.start_network(nodes, links)

    NetworkSim.disable_link(:a, :b)

    Enum.each(new_nodes, fn n ->
      IO.puts("#{inspect(NetworkSim.get_raw_state(n), pretty: true)}")
    end)
  end
end
