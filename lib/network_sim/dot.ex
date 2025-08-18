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

  def show_mst(nodes, links, tree, file_name) do
    tree_links_style = %{color: "blue", fontcolor: "blue", style: "bold"}
    graph_attrs = %{rankdir: "BT"}

    write_directed_dot(nodes, links, tree, "#{file_name}.dot",
      format: "svg",
      engine: "dot",
      graph_attrs: graph_attrs,
      tree_style: tree_links_style
    )
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
    write_to_file(path, dot, opts)
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

  defp write_to_file(path, dot, opts) do
    :ok = File.write!(path, dot)

    format = Keyword.get(opts, :format, nil)
    engine = Keyword.get(opts, :engine, "dot")

    if format do
      out = Path.rootname(path) <> ".#{format}"
      {_, _} = System.cmd(engine, ["-T#{format}", path, "-o", out])
    end

    {:ok, path}
  rescue
    e -> {:error, e}
  end

  # --- ORIENTED/TREE RENDERING (additive) --------------------------------------
  @typedoc """
  Tree descriptor:

    * `tree` is a list of maps like:
      `%{id: node_id, parent: parent_id | nil, children: MapSet.t()}`

  Only the `parent` field is used to orient edges; `children` may be `MapSet.new/1`
  and is ignored here (but kept to match upstream data structures).
  """

  # @type tree_node :: %{id: term(), parent: term() | nil ,  optional(:children) => MapSet.t()}
  # @type tree :: [tree_node]

  @doc """
  Return a Graphviz DOT string for a *directed* graph where known tree edges
  are oriented **child → parent**.

  ## Parameters

    * `nodes` — list of node ids (atoms/strings)
    * `links` — `[ {u, v} | {u, v, attrs} | {{u, v}, attrs} ]`
    * `tree`  — list of `%{id: id, parent: parent | nil, children: MapSet.t()}`

  ## Options

    * `:non_tree` — how to render edges that are **not** parent/child in `tree`:
        * `:dirnone` (default) → keep edge, add `dir=none` (no arrowheads)
        * `:as_given`         → keep direction as given in `(u, v)`
        * `:omit`             → drop the edge entirely

    * `:graph_attrs` — map of DOT graph attributes (e.g., `%{rankdir: "LR"}`)

  The output uses `digraph` and `->`. If an edge has `:weight` but no `:label`,
  its `label` is auto-filled with the weight (same behavior as `to_dot/2`).
  """
  # @spec to_dot_tree(
  #         [atom | String.t()],
  #         [{term, term}] | [{term, term, map()}] | [{{term, term}, map()}],
  #         tree,
  #         keyword
  #       ) :: String.t()
  def to_dot_tree(nodes, links, tree, opts \\ []) do
    graph_attrs = Keyword.get(opts, :graph_attrs, %{})
    non_tree = Keyword.get(opts, :non_tree, :dirnone)
    tree_style = Keyword.get(opts, :tree_style, %{})
    non_tree_style = Keyword.get(opts, :non_tree_style, %{})

    parent_of = build_parent_index(tree)

    node_lines =
      nodes
      |> Enum.map(fn n -> ~s(  "#{n}";) end)
      |> Enum.join("\n")

    edge_lines =
      links
      |> Enum.map(&normalize_link/1)
      |> Enum.map(&orient_edge(&1, parent_of, non_tree, tree_style, non_tree_style))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {from, to, attrs} ->
        ~s(  "#{from}" -> "#{to}"#{render_attrs(attrs)};)
      end)
      |> Enum.join("\n")

    inside_graph_attrs =
      graph_attrs
      |> Enum.map(fn {k, v} -> ~s(  #{to_string(k)}=#{attr_value(v)};) end)
      |> Enum.join("\n")

    """
    digraph G {
    #{inside_graph_attrs}
    #{node_lines}
    #{edge_lines}
    }
    """
  end

  @doc """
  Write a *directed* DOT file (child → parent orientation) to `path`.

  Accepts the same `opts` as `to_dot_tree/4`, plus `:format` and `:engine`
  like `write_dot/4`.
  """
  # @spec write_directed_dot(
  #         [term],
  #         [{term, term}] | [{term, term, map()}] | [{{term, term}, map()}],
  #         tree,
  #         Path.t(),
  #         keyword
  #       ) :: {:ok, Path.t()} | {:error, term}
  def write_directed_dot(nodes, links, tree, path, opts \\ []) do
    dot = to_dot_tree(nodes, links, tree, opts)
    write_to_file(path, dot, opts)
  end

  # ── helpers (existing + new) ────────────────────────────────────────────────
  # Build child→parent index from the provided tree
  # @spec build_parent_index(tree) :: %{optional(term) => term}
  defp build_parent_index(tree) do
    Enum.reduce(tree, %{}, fn %{id: id, parent: p}, acc ->
      case p do
        nil -> acc
        _ -> Map.put(acc, id, p)
      end
    end)
  end

  # Orient an edge according to the child→parent relation when available.
  # Returns `{from, to, attrs}` or `nil` (if non-tree policy is :omit).
  # @spec orient_edge({term, term, map()}, map(), :dirnone | :as_given | :omit) ::
  #         {term, term, map()} | nil
  defp orient_edge({u, v, attrs}, parent_of, non_tree_policy, tree_style, non_tree_style) do
    attrs = attrs || %{}

    cond do
      # tree edge oriented child -> parent
      Map.get(parent_of, u) == v ->
        {u, v, Map.merge(attrs, tree_style)}

      Map.get(parent_of, v) == u ->
        {v, u, Map.merge(attrs, tree_style)}

      # non-tree edges, behavior controlled by policy
      non_tree_policy == :omit ->
        nil

      non_tree_policy == :as_given ->
        {u, v, Map.merge(attrs, non_tree_style)}

      true ->
        # default: keep edge, remove arrowheads, then apply non-tree style
        merged =
          attrs
          # see Graphviz `dir` attribute
          |> Map.put_new(:dir, "none")
          |> Map.merge(non_tree_style)

        {u, v, merged}
    end
  end

  defp attr_value(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp attr_value(true), do: "true"
  defp attr_value(false), do: "false"
  defp attr_value(other), do: ~s("#{escape(~s(#{other}))}")
end
