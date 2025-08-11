defmodule NetworkSim.Dot do
  @moduledoc """
  Export the network graph to Graphviz DOT.

  ## Examples

      iex> NetworkSim.Dot.to_dot([:a, :b, :c, :d], [{:a,:b},{:a,:d},{:b,:c},{:d,:c}])
      ...> |> String.contains?("graph")
      true

      iex> NetworkSim.Dot.to_dot([:a, :b], [{:a, :b, %{weight: 7}}])
      ...> |> String.contains?(~s("a" -- "b" [weight=7, label="7"];))
      true
  """

  @doc """
  Return a Graphviz DOT string for an *undirected* graph.

  `links` can be any of:
    * `[{u, v}]`
    * `[{u, v, attrs}]`
    * `[{ {u, v}, attrs }]`

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
  Write the DOT file to `path`. Optionally, if Graphviz is installed,
  set `png: true` to also render a PNG next to it.

  This function has the same inputs as before; it simply respects attributes
  embedded in `links` as described in `to_dot/2`.
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

  # Accept: {:u, :v} | {:u, :v, attrs} | {{:u, :v}, attrs}
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
    has_label? = Map.has_key?(attrs, :label) or Map.has_key?(attrs, "label")
    weight = Map.get(attrs, :weight) || Map.get(attrs, "weight")

    cond do
      has_label? or is_nil(weight) ->
        attrs

      true ->
        Map.put(attrs, :label, weight)
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
