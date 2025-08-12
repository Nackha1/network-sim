defmodule NetworkSim.Dot do
  @moduledoc """
  Export the network graph to Graphviz DOT.
  """

  require Logger

  alias NetworkSim.Kruskal

  @doc """
  Return a Graphviz DOT string for an *undirected* graph.

  `links` can be any of:
    * `[{u, v}]`
    * `[{u, v, attrs}]`

  where `attrs` is a map with string or atom keys.
  Known nicety: if `:label`/`"label"` is not provided but `:weight`/`"weight"` is,
  we auto-set `label` to the weight value.
  """
  @spec to_dot(
          [atom | String.t()],
          [{term, term}] | [{term, term, map()}] | [{{term, term}, map()}]
        ) :: String.t()
  def to_dot(nodes, links) do
    node_lines =
      nodes
      |> Enum.map(fn n -> ~s(  "#{n}";) end)
      |> Enum.join("\n")

    edge_lines =
      links
      |> Enum.map(&normalize_link/1)
      |> Enum.map(fn {u, v, attrs} ->
        ~s(  "#{u}" -- "#{v}"#{render_attrs(attrs)};)
      end)
      |> Enum.join("\n")

    """
    graph G {
    #{node_lines}
    #{edge_lines}
    }
    """
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

  def show_mst(nodes, links, file_name) do
    mst = Kruskal.kruskal(nodes, links)
    Logger.info("MST for #{file_name}: #{inspect(mst)}")

    style = %{color: "blue", fontcolor: "blue", style: "bold"}
    new_links = mark_mst_edges(links, mst, style)
    write_dot(nodes, new_links, "#{file_name}.dot", format: "svg", engine: "dot")
  end

  @doc """
  Write the DOT file to `path`.
  """
  @spec write_dot(
          [term],
          [{term, term}] | [{term, term, map()}] | [{{term, term}, map()}],
          Path.t(),
          keyword
        ) ::
          {:ok, Path.t()} | {:error, term}
  def write_dot(nodes, links, path, opts \\ []) do
    dot = to_dot(nodes, links)
    :ok = File.write!(path, dot)

    format = Keyword.get(opts, :format, nil)
    engine = Keyword.get(opts, :engine, "dot")

    if !is_nil(format) do
      png = Path.rootname(path) <> ".#{format}"
      {_, _} = System.cmd(engine, ["-T#{format}", path, "-o", png])
    end

    {:ok, path}
  rescue
    e -> {:error, e}
  end

  # --- helpers ---------------------------------------------------------------

  # Accept: {:u, :v} | {:u, :v, attrs}
  # Return: {u, v, attrs_map}
  defp normalize_link({u, v}), do: {u, v, %{}}
  defp normalize_link({u, v, attrs}) when is_map(attrs), do: {u, v, attrs}

  # Render attribute map as DOT attribute list, e.g.:
  # [weight=10, label="10"]
  # Auto-fill label from weight if label missing.
  defp render_attrs(attrs) when attrs in [%{}, nil], do: ""

  defp render_attrs(attrs) when is_map(attrs) do
    attrs =
      maybe_autofill_label(attrs)

    inside =
      attrs
      |> Enum.map(&kv/1)
      |> Enum.join(", ")

    if inside == "", do: "", else: " [#{inside}]"
  end

  defp maybe_autofill_label(attrs) do
    has_label? = Map.has_key?(attrs, :label)
    weight = Map.get(attrs, :weight)

    cond do
      has_label? or is_nil(weight) ->
        attrs

      true ->
        attrs |> Map.delete(:weight) |> Map.put(:label, weight)
    end
  end

  # Emit `key=value` with numbers bare; strings/others quoted.
  defp kv({k, v}) do
    key = to_string(k)

    value =
      case v do
        n when is_integer(n) or is_float(n) -> to_string(n)
        true -> "true"
        false -> "false"
        other -> ~s("#{escape(~s(#{other}))}")
      end

    "#{key}=#{value}"
  end

  defp escape(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
