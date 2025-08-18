defmodule ProtocolTest do
  use ExUnit.Case, async: true

  require Logger
  alias NetworkSim.TestHelper
  alias NetworkSim.Protocol

  setup do
    File.mkdir_p("tmp/dmst")
  end

  test "multiple recovery" do
    nodes = [
      {:root, Protocol.DynamicMST, %{parent: nil, children: [:lca_e_prime]}},
      {:lca_e_prime, Protocol.DynamicMST, %{parent: :root, children: [:v_prime]}},
      {:lca_e, Protocol.DynamicMST, %{parent: :lca_e_prime, children: [:u]}},
      {:x, Protocol.DynamicMST, %{parent: :lca_e, children: [:v, :u_prime]}},
      {:u, Protocol.DynamicMST, %{parent: :lca_e, children: []}},
      {:v, Protocol.DynamicMST, %{parent: :x, children: []}},
      {:u_prime, Protocol.DynamicMST, %{parent: :x, children: []}},
      {:v_prime, Protocol.DynamicMST, %{parent: :lca_e_prime, children: []}}
    ]

    links = [
      {:root, :lca_e_prime, %{weight: 3}},
      {:lca_e_prime, :v_prime, %{weight: 4}},
      {:lca_e_prime, :lca_e, %{weight: 5}},
      {:lca_e, :x, %{weight: 6}},
      {:lca_e, :u, %{weight: 7}},
      {:x, :v, %{weight: 8}},
      {:x, :u_prime, %{weight: 9}}
    ]

    test_name = "mult_rec_in"
    TestHelper.start(nodes, links, test_name)

    # Simulate a dual recovery scenario
    NetworkSim.enable_link(:u_prime, :v_prime, %{weight: 1})
    # NetworkSim.enable_link(:u, :v, %{weight: 2})

    Process.sleep(5)
    tree = NetworkSim.get_tree()

    Logger.info("Tree: #{inspect(tree, pretty: true)}")

    TestHelper.stop(test_name)
  end

  # test "boh" do
  #   nodes = [
  #     {:a, Protocol.DynamicMST, %{parent: :e, children: [:b, :c]}},
  #     {:b, Protocol.DynamicMST, %{parent: :a, children: []}},
  #     {:c, Protocol.DynamicMST, %{parent: :a, children: []}},
  #     {:e, Protocol.DynamicMST, %{parent: nil, children: [:a]}}
  #   ]

  #   links = [
  #     {:a, :b, %{weight: 2}},
  #     {:a, :c, %{weight: 3}},
  #     {:e, :a, %{weight: 4}}
  #   ]

  #   # links = [
  #   #   {:a, :b, %{weight: 2}},
  #   #   {:a, :c, %{weight: 3}},
  #   #   {:b, :c, %{weight: 1}}
  #   # ]

  #   NetworkSim.start_network(nodes, links)

  #   NetworkSim.enable_link(:b, :c, %{weight: 1})
  #   NetworkSim.disable_link(:a, :b)

  #   Process.sleep(5)
  #   tree = NetworkSim.get_tree()

  #   Logger.info("Tree after enabling links: #{inspect(tree, pretty: true)}")

  #   TestHelper.show_custom_tree(
  #     NetworkSim.Router.nodes(),
  #     NetworkSim.Router.links(),
  #     tree,
  #     "single_internal_recovery"
  #   )

  #   NetworkSim.stop_network()
  # end

  test "simple internal link recovery" do
    nodes = [
      {:a, Protocol.DynamicMST, %{parent: nil, children: [:b]}},
      {:b, Protocol.DynamicMST, %{parent: :a, children: [:c, :e]}},
      {:c, Protocol.DynamicMST, %{parent: :b, children: []}},
      {:d, Protocol.DynamicMST, %{parent: :e, children: []}},
      {:e, Protocol.DynamicMST, %{parent: :b, children: [:d]}}
    ]

    links = [
      {:a, :b, %{weight: 1}},
      {:b, :c, %{weight: 100}},
      {:b, :e, %{weight: 3}},
      {:d, :e, %{weight: 7}}
    ]

    test_name = "single_rec_in"
    TestHelper.start(nodes, links, test_name)

    NetworkSim.enable_link(:c, :d, %{weight: 4})

    Process.sleep(5)
    TestHelper.stop(test_name)
  end

  # test "dynamic MST" do
  #   nodes = [
  #     {:a, Protocol.DynamicMST, %{parent: nil, children: [:b, :c]}},
  #     {:b, Protocol.DynamicMST, %{parent: :a, children: []}},
  #     {:c, Protocol.DynamicMST, %{parent: :a, children: [:d, :e]}},
  #     {:d, Protocol.DynamicMST, %{parent: :c, children: []}},
  #     {:e, Protocol.DynamicMST, %{parent: :c, children: []}}
  #   ]

  #   links = [
  #     {:a, :b, %{weight: 8}},
  #     {:a, :c, %{weight: 1}},
  #     {:c, :d, %{weight: 2}},
  #     {:c, :e, %{weight: 3}},
  #     {:a, :d, %{weight: 5}},
  #     {:a, :e, %{weight: 6}}
  #   ]

  #   test_name = "dynamic_mst_start"
  #   nodes_ids = Enum.map(nodes, &elem(&1, 0))
  #   show_custom_mst(nodes_ids, links, test_name)

  #   NetworkSim.start_network(nodes, links)

  #   # NetworkSim.disable_link(:a, :c)
  #   NetworkSim.disable_link(:a, :d)
  #   # NetworkSim.disable_link(:a, :e)
  #   # NetworkSim.disable_link(:a, :b)
  #   NetworkSim.enable_link(:a, :d)
  #   # NetworkSim.enable_link(:a, :e)

  #   Process.sleep(100)

  #   tree = NetworkSim.get_tree()

  #   Logger.info("Tree after disabling links: #{inspect(tree, pretty: true)}")

  #   test_name = "dynamic_mst_end"

  #   show_custom_mst(
  #     nodes_ids,
  #     (links --
  #        [{:a, :c, %{weight: 1}}, {:a, :d, %{weight: 5}}, {:a, :b, %{weight: 8}}]) ++
  #       [{:a, :c, %{weight: 1}}],
  #     test_name
  #   )

  #   # Enum.each(nodes_ids, fn n ->
  #   #   IO.puts("#{inspect(NetworkSim.get_raw_state(n), pretty: true)}")
  #   # end)

  #   NetworkSim.stop_network()
  # end
end
