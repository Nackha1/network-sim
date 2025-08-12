defmodule KruskalTest do
  use ExUnit.Case, async: true

  require Logger

  alias NetworkSim.Dot

  setup do
    File.mkdir_p("tmp/kruskal")
  end

  defp show_custom_mst(nodes, links, test_name) do
    Dot.show_mst(nodes, links, "tmp/kruskal/#{test_name}")
  end

  test "basic triangle" do
    nodes = [:a, :b, :c]

    links = [
      {:a, :b, %{weight: 1}},
      {:b, :c, %{weight: 2}},
      {:a, :c, %{weight: 3}}
    ]

    test_name = "triangle"
    show_custom_mst(nodes, links, test_name)
  end

  test "square with diagonals" do
    nodes = [:a, :b, :c, :d]

    links = [
      {:a, :b, %{weight: 1}},
      {:b, :c, %{weight: 1}},
      {:c, :d, %{weight: 1}},
      {:d, :a, %{weight: 1}},
      {:a, :c, %{weight: 2}},
      {:b, :d, %{weight: 2}}
    ]

    test_name = "square"
    show_custom_mst(nodes, links, test_name)
  end

  test "star topology" do
    nodes = [:center, :a, :b, :c, :d]

    links = [
      {:center, :a, %{weight: 1}},
      {:center, :b, %{weight: 2}},
      {:center, :c, %{weight: 3}},
      {:center, :d, %{weight: 4}},
      {:a, :b, %{weight: 10}},
      {:b, :c, %{weight: 10}},
      {:c, :d, %{weight: 10}}
    ]

    test_name = "star"
    show_custom_mst(nodes, links, test_name)
  end

  test "disconnected graph" do
    nodes = [:a, :b, :c, :d, :e, :f]

    links = [
      {:a, :b, %{weight: 1}},
      {:b, :c, %{weight: 2}},
      {:d, :e, %{weight: 1}},
      {:e, :f, %{weight: 2}}
    ]

    test_name = "disconnected"
    show_custom_mst(nodes, links, test_name)
  end

  test "dense graph" do
    nodes = [:a, :b, :c, :d, :e]

    links = [
      {:a, :b, %{weight: 2}},
      {:a, :c, %{weight: 3}},
      {:b, :c, %{weight: 1}},
      {:b, :d, %{weight: 4}},
      {:c, :d, %{weight: 5}},
      {:c, :e, %{weight: 6}},
      {:d, :e, %{weight: 7}}
    ]

    test_name = "dense"
    show_custom_mst(nodes, links, test_name)
  end
end
