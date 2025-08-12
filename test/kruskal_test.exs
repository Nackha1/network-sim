defmodule KruskalTest do
  use ExUnit.Case, async: true
  require Logger
  alias NetworkSim.Dot

  setup do
    File.mkdir_p!("tmp/kruskal")
    :ok
  end

  defp calculate_mst(nodes, links, test_name) do
    mst = NetworkSim.Kruskal.kruskal(nodes, links)
    Logger.info("MST for #{test_name}: #{inspect(mst)}")

    style = %{color: "blue", fontcolor: "blue", style: "bold"}
    new_links = mark_mst_edges(links, mst, style)
    Dot.write_dot(nodes, new_links, "tmp/kruskal/#{test_name}.dot", format: "svg", engine: "dot")
  end

  @doc """
  Marks edges present in the given MST with a style.

  ## Parameters
    * `links` - a list of `{u, v, attrs}` tuples.
    * `mst` - a map returned by your MST algorithm (`%{edges: [...], weight: total_weight}`).
    * `style` - a map of attributes to merge into the MST edges, e.g. `%{color: "blue", penwidth: 2}`.

  Returns the updated list of links with MST edges having the given style.
  """
  @spec mark_mst_edges([{term, term, map}], %{edges: list, weight: number}, map) :: [
          {term, term, map}
        ]
  def mark_mst_edges(links, %{edges: mst_edges}, style) when is_map(style) do
    mst_set =
      mst_edges
      |> Enum.map(fn {u, v, _attrs} -> MapSet.new([u, v]) end)
      |> MapSet.new()

    Enum.map(links, fn {u, v, attrs} ->
      if MapSet.member?(mst_set, MapSet.new([u, v])) do
        {u, v, Map.merge(attrs, style)}
      else
        {u, v, attrs}
      end
    end)
  end

  test "basic triangle" do
    nodes = [:a, :b, :c]

    links = [
      {:a, :b, %{weight: 1}},
      {:b, :c, %{weight: 2}},
      {:a, :c, %{weight: 3}}
    ]

    test_name = "triangle"
    calculate_mst(nodes, links, test_name)
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
    calculate_mst(nodes, links, test_name)
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
    calculate_mst(nodes, links, test_name)
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
    calculate_mst(nodes, links, test_name)
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
    calculate_mst(nodes, links, test_name)
  end
end
