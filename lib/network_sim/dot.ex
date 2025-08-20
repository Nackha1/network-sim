defmodule NetworkSim.Dot do
  @moduledoc """
  # NetworkSim.Dot

  Export utilities to produce **Graphviz DOT** representations of network graphs.

  This module focuses on two common views:

  - **Undirected** view (`graph` / `--`) via `to_dot/2`
  - **Directed tree-oriented** view (`digraph` / `->`) via `to_dot_tree/4`, where
    known tree edges are oriented **child → parent**, and non-tree edges are rendered
    according to a policy.

  ## Conventions

  - A **link** can be provided in multiple forms; inputs are normalized internally:
      * `{u, v}`                     → attributes default to `%{}`
      * `{u, v, attrs}`              → explicit attribute map
      * `{{u, v}, attrs}`            → convenience form (often used by algorithms)

  - If an edge has `:weight` but no `:label`, rendering **auto-fills** `label` from
    `weight` (and removes `:weight` from the final DOT attributes to avoid layout bias).
  """

  alias NetworkSim.Kruskal

  # ================
  #  Types
  # ================

  @typedoc "Node identifier (atom, string, integer, etc.)."
  @type node_id :: term()

  @typedoc "Edge attribute map (string or atom keys)."
  @type attrs :: %{optional(atom() | String.t()) => term()}

  @typedoc "Accepted link input forms (normalized internally to `{u, v, attrs}`)."
  @type link_in ::
          {node_id(), node_id()}
          | {node_id(), node_id(), attrs()}
          | {{node_id(), node_id()}, attrs()}

  @typedoc "Tree record used for directed rendering (only `:id` and `:parent` are required)."
  @type tree_item :: %{
          required(:id) => node_id(),
          required(:parent) => node_id() | nil,
          optional(:children) => Enumerable.t()
        }

  # ================
  #  Public API — DOT generation
  # ================

  @doc """
  Return a Graphviz **DOT** string for an **undirected** graph (`graph` / `--`).

  `links` can be any of:
    * `[{u, v}]`
    * `[{u, v, attrs}]`
    * `[{ {u, v}, attrs }]` (convenience form)

  Where `attrs` is a map with string or atom keys.

  **Nicety:** if `:label` is not provided but `:weight` is, the rendered `label`
  is auto-filled with the weight **and** the `weight` attribute is omitted.
  """
  @spec to_dot([atom() | String.t()], [link_in()]) :: String.t()
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
  Return a Graphviz **DOT** string for a **directed** graph (`digraph` / `->`)
  where known tree edges are oriented **child → parent**.

  ## Parameters

  - `nodes` — list of node ids (atoms/strings)
  - `links` — edge list in any accepted form (see `t:link_in/0`)
  - `tree`  — list of `%{id: id, parent: parent | nil, children: MapSet.t()}`

  ## Options

  - `:non_tree` — how to render edges **not** in the tree:
      * `:dirnone` (default) → keep edge, add `dir=none` (no arrowheads)
      * `:as_given`          → keep direction as given in `(u, v)`
      * `:omit`              → drop the edge entirely

  - `:graph_attrs`   — map of DOT graph attributes (e.g., `%{rankdir: "LR"}`)
  - `:tree_style`    — map of attributes to merge into **tree** edges
  - `:non_tree_style`— map of attributes to merge into **non-tree** edges

  **Nicety:** if an edge has `:weight` but no `:label`, the label is auto-filled
  (same behavior as `to_dot/2`).
  """
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
  Mark edges present in the given MST with a style.

  ## Parameters
  - `links` — list of `{u, v, attrs}` tuples
  - `mst`   — result map from your MST algorithm (`%{edges: [...], weight: total_weight}`)
  - `style` — attribute map to **merge** into each MST edge, e.g. `%{color: "blue", penwidth: 2}`

  ## Returns
  The updated list of `{u, v, attrs}` where MST edges include the provided style.
  """
  @spec mark_mst_edges(
          [{term(), term(), map()}],
          %{required(:edges) => [Kruskal.edge()], required(:weight) => number() | :infinity},
          map()
        ) ::
          [{term(), term(), map()}]
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

  @doc """
  Write an **undirected** DOT file to `path`.

  Accepts the same `links` forms as `to_dot/2`.

  ## Options
  - `:format` — when set (e.g. `"svg"`, `"png"`), also invokes Graphviz to render
    an output image next to the DOT file.
  - `:engine` — Graphviz layout engine (default: `"dot"`). Examples: `"neato"`, `"sfdp"`.

  Returns `{:ok, path}` on success or `{:error, reason}` on failure.
  """
  @spec write_dot([node_id()], [link_in()], Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_dot(nodes, links, path, opts \\ []) do
    dot = to_dot(nodes, links)
    write_to_file(path, dot, opts)
  end

  @doc """
  Write a **directed** DOT file (child → parent orientation) to `path`.

  Accepts the same options as `to_dot_tree/4`, plus `:format` and `:engine`
  with the same meaning as in `write_dot/4`.
  """
  @spec write_directed_dot([node_id()], [link_in()], [tree_item()], Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_directed_dot(nodes, links, tree, path, opts \\ []) do
    dot = to_dot_tree(nodes, links, tree, opts)
    write_to_file(path, dot, opts)
  end

  @doc """
  Convenience: write an **undirected** DOT and (optionally) render an image.

  Produces `<file_name>.dot` and, if `format: "svg"` (or similar) is provided,
  also `<file_name>.<format>` via Graphviz.
  """
  @spec show_graph([node_id()], [link_in()], String.t()) :: {:ok, Path.t()} | {:error, term()}
  def show_graph(nodes, links, file_name) do
    write_dot(nodes, links, "#{file_name}.dot", format: "svg", engine: "dot")
  end

  @doc """
  Convenience: compute an MST (Kruskal), **style** those edges, and write an
  **undirected** DOT (optionally rendering via Graphviz).

  The MST edges are emphasized by default with `%{color: "blue", fontcolor: "blue", style: "bold"}`.
  """
  @spec show_mst([node_id()], [Kruskal.edge()], String.t()) :: {:ok, Path.t()} | {:error, term()}
  def show_mst(nodes, links, file_name) do
    mst = Kruskal.kruskal(nodes, links)

    style = %{color: "blue", fontcolor: "blue", style: "bold"}
    new_links = mark_mst_edges(links, mst, style)
    write_dot(nodes, new_links, "#{file_name}.dot", format: "svg", engine: "dot")
  end

  @doc """
  Convenience: write a **directed** DOT using a provided **tree** for orientation.

  Uses `rankdir: "BT"` by default (roots at the top, children below), and styles
  tree edges in **blue** and **bold** unless overridden via options.
  """
  @spec show_mst([node_id()], [link_in()], [tree_item()], String.t()) ::
          {:ok, Path.t()} | {:error, term()}
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

  # ================
  #  Helpers
  # ================

  # Accept: {:u, :v} | {:u, :v, attrs}
  # Return: {u, v, attrs_map}
  @spec normalize_link(link_in()) :: {node_id(), node_id(), attrs()}
  defp normalize_link({u, v}), do: {u, v, %{}}
  defp normalize_link({u, v, attrs}) when is_map(attrs), do: {u, v, attrs}

  # Render attribute map as DOT attribute list, e.g.:
  # [weight=10, label="10"]
  # Auto-fill label from weight if label missing.
  @spec render_attrs(nil | attrs()) :: String.t()
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

  @spec maybe_autofill_label(attrs()) :: attrs()
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
  @spec kv({atom() | String.t(), term()}) :: String.t()
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

  @spec escape(String.t()) :: String.t()
  defp escape(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  @spec attr_value(term()) :: String.t()
  defp attr_value(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp attr_value(true), do: "true"
  defp attr_value(false), do: "false"
  defp attr_value(other), do: ~s("#{escape(~s(#{other}))}")

  @spec write_to_file(Path.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
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

  # Build child→parent index from the provided tree
  @spec build_parent_index([tree_item()]) :: %{optional(node_id()) => node_id()}
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
  @spec orient_edge(
          {node_id(), node_id(), attrs()},
          map(),
          :dirnone | :as_given | :omit,
          attrs(),
          attrs()
        ) ::
          {node_id(), node_id(), attrs()} | nil
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
end
