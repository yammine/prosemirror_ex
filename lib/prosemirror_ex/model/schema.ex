defmodule ProsemirrorEx.Model.Schema do
  @moduledoc """
  A document schema. Holds node and mark type objects for the nodes
  and marks that may occur in conforming documents, and provides
  functionality for creating and deserializing such documents.

  Ported from ProseMirror's schema.ts.
  """

  alias ProsemirrorEx.Model.ContentMatch
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.MarkType
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.NodeType

  @type t :: %__MODULE__{
          spec: map(),
          nodes: %{String.t() => NodeType.t()},
          marks: %{String.t() => MarkType.t()},
          top_node_type: NodeType.t() | nil,
          linebreak_replacement: NodeType.t() | nil,
          cached: map()
        }

  # `cached` is preserved as `%{}` for struct parity with JS ProseMirror Schema.
  defstruct [:spec, :nodes, :marks, :top_node_type, :linebreak_replacement, :cached]

  @doc """
  Construct a schema from a schema specification map.

  The spec should have:
  - "nodes" => list of `{name, node_spec}` tuples
  - "marks" => (optional) list of `{name, mark_spec}` tuples
  - "topNode" => (optional) name of the top node type, defaults to `"doc"`
  """
  @spec new(map()) :: t()
  def new(spec) when is_map(spec) do
    nodes_list = (Map.get(spec, "nodes") || []) |> dedup_specs()
    marks_list = (Map.get(spec, "marks") || []) |> dedup_specs()
    top_node_name = Map.get(spec, "topNode") || "doc"

    schema = %__MODULE__{
      spec: spec,
      nodes: %{},
      marks: %{},
      top_node_type: nil,
      linebreak_replacement: nil,
      cached: %{}
    }

    # Step 1: Compile NodeTypes
    nodes = compile_node_types(nodes_list)

    unless Map.has_key?(nodes, top_node_name) do
      raise "Schema is missing its top node type ('#{top_node_name}')"
    end

    unless Map.has_key?(nodes, "text") do
      raise "Every schema needs a 'text' type"
    end

    text_type = nodes["text"]

    if text_type.attrs != %{} do
      raise "The text node type should not have attributes"
    end

    # Step 2: Compile MarkTypes
    marks = compile_mark_types(marks_list)

    # Step 3: Check for node/mark name collisions
    Enum.each(nodes, fn {name, _} ->
      if Map.has_key?(marks, name) do
        raise "#{name} can not be both a node and a mark"
      end
    end)

    # Step 4: Compile content expressions (passing node_order explicitly)
    # and resolve inline_content, mark_set, and linebreak_replacement.
    node_order = Enum.map(nodes_list, fn {name, _} -> name end)

    {nodes, lbr_name, content_expr_by_node} =
      Enum.reduce(nodes_list, {nodes, nil, %{}}, fn {name, node_spec}, {ns, lbr, expr_acc} ->
        type = ns[name]
        content_expr = Map.get(node_spec, "content") || ""

        {content_match, expr_acc} =
          case Map.get(expr_acc, content_expr) do
            nil ->
              cm = ContentMatch.parse(content_expr, ns, node_order)
              {cm, Map.put(expr_acc, content_expr, cm)}

            cm ->
              {cm, expr_acc}
          end

        inline_content = ContentMatch.inline_content(content_match)
        is_leaf = content_match == ContentMatch.empty()
        is_textblock = type.is_block && inline_content
        is_atom_val = is_leaf || Map.get(node_spec, "atom", false) == true

        mark_set =
          case Map.get(node_spec, "marks") do
            "_" ->
              nil

            nil ->
              if !inline_content, do: [], else: nil

            "" ->
              []

            mark_expr when is_binary(mark_expr) ->
              mark_names = String.split(mark_expr, " ", trim: true)
              if mark_names == [], do: [], else: do_gather_marks(marks, mark_names)
          end

        lbr =
          if Map.get(node_spec, "linebreakReplacement", false) do
            if lbr != nil, do: raise("Multiple linebreak nodes defined")

            if !type.is_inline || !is_leaf,
              do: raise("Linebreak replacement nodes must be inline leaf nodes")

            name
          else
            lbr
          end

        updated_type = %{
          type
          | content_match: content_match,
            inline_content: inline_content,
            is_leaf: is_leaf,
            is_textblock: is_textblock,
            is_atom: is_atom_val,
            mark_set: mark_set,
            mark_set_names: mark_set && MapSet.new(mark_set, & &1.name)
        }

        {Map.put(ns, name, updated_type), lbr, expr_acc}
      end)

    # Step 5: Resolve mark exclusions
    marks =
      Enum.reduce(marks_list, marks, fn {name, mark_spec}, ms ->
        type = ms[name]

        {excluded, excluded_names} =
          case Map.get(mark_spec, "excludes") do
            nil ->
              {[type], MapSet.new([type.name])}

            "" ->
              {[], MapSet.new()}

            "_" ->
              all_marks = Map.values(ms)
              {all_marks, MapSet.new(all_marks, & &1.name)}

            excl when is_binary(excl) ->
              names = String.split(excl, " ", trim: true)

              if names == [] do
                {[], MapSet.new()}
              else
                gathered = do_gather_marks(ms, names)
                {gathered, MapSet.new(gathered, & &1.name)}
              end
          end

        Map.put(ms, name, %{type | excluded: excluded, excluded_names: excluded_names})
      end)

    # Step 6: Finalize MarkTypes, NodeTypes, ContentMatches, and back-references.
    # First attach finalized marks to nodes and update ContentMatch DFAs & wrap caches.
    nodes =
      Map.new(nodes, fn {name, type} ->
        updated_mark_set =
          case type.mark_set do
            nil -> nil
            list when is_list(list) -> Enum.map(list, fn mt -> Map.get(marks, mt.name, mt) end)
          end

        {name, %{type | mark_set: updated_mark_set}}
      end)

    # Pass 1: Update DFA edge NodeTypes so every edge has content_match & mark_set
    updated_cms =
      Map.new(content_expr_by_node, fn {expr, cm} ->
        {expr, ContentMatch.update_node_types(cm, nodes)}
      end)

    nodes =
      Enum.reduce(nodes_list, nodes, fn {name, node_spec}, ns ->
        expr = Map.get(node_spec, "content") || ""
        cm = Map.fetch!(updated_cms, expr)
        Map.update!(ns, name, fn type -> %{type | content_match: cm} end)
      end)

    # Pass 2: Precompute wrapping tables once all node types have updated content_match
    wrapped_cms =
      Map.new(updated_cms, fn {expr, cm} ->
        {expr, ContentMatch.precompute_wrappings(cm)}
      end)

    nodes =
      Enum.reduce(nodes_list, nodes, fn {name, node_spec}, ns ->
        expr = Map.get(node_spec, "content") || ""
        cm = Map.fetch!(wrapped_cms, expr)
        Map.update!(ns, name, fn type -> %{type | content_match: cm} end)
      end)

    # Build shallow_schema (no nested nodes/marks maps) to terminate back-reference
    # depth so Schema structs stay small and fast to copy across processes, while
    # preserving 2-hop access (e.g. doc.type.schema.nodes[x].schema.linebreak_replacement).
    shallow_schema = %{
      schema
      | nodes: %{},
        marks: %{},
        top_node_type: nil,
        linebreak_replacement: lbr_name && nodes[lbr_name]
    }

    # First link pass: attach shallow_schema so nodes inside snapshot_schema have non-nil schema
    {nodes_l1, marks_l1, cms_l1} =
      link_schema_refs(nodes, marks, nodes_list, wrapped_cms, shallow_schema)

    snapshot_schema = %{
      schema
      | nodes: nodes_l1,
        marks: marks_l1,
        top_node_type: nodes_l1[top_node_name],
        linebreak_replacement: lbr_name && nodes_l1[lbr_name]
    }

    # Second link pass: attach snapshot_schema to top-level nodes/marks and edge refs
    {nodes_l2, marks_l2, _cms_l2} =
      link_schema_refs(nodes_l1, marks_l1, nodes_list, cms_l1, snapshot_schema)

    %{
      snapshot_schema
      | nodes: nodes_l2,
        marks: marks_l2,
        top_node_type: nodes_l2[top_node_name],
        linebreak_replacement: lbr_name && nodes_l2[lbr_name]
    }
  end

  defp link_schema_refs(nodes, marks, nodes_list, cms_by_expr, target_schema) do
    marks =
      Map.new(marks, fn {name, type} ->
        {name, %{type | schema: target_schema}}
      end)

    marks =
      Map.new(marks, fn {name, type} ->
        updated_excluded = Enum.map(type.excluded, fn ex -> Map.get(marks, ex.name, ex) end)
        updated_type = %{type | excluded: updated_excluded}

        updated_type =
          if updated_type.instance do
            %{updated_type | instance: %{updated_type.instance | type: updated_type}}
          else
            updated_type
          end

        {name, updated_type}
      end)

    nodes =
      Map.new(nodes, fn {name, type} ->
        updated_mark_set =
          case type.mark_set do
            nil -> nil
            list when is_list(list) -> Enum.map(list, fn mt -> Map.get(marks, mt.name, mt) end)
          end

        {name, %{type | mark_set: updated_mark_set, schema: target_schema}}
      end)

    updated_cms =
      Map.new(cms_by_expr, fn {expr, cm} ->
        {expr, ContentMatch.update_node_types(cm, nodes)}
      end)

    nodes =
      Enum.reduce(nodes_list, nodes, fn {name, node_spec}, ns ->
        expr = Map.get(node_spec, "content") || ""
        cm = Map.fetch!(updated_cms, expr)
        Map.update!(ns, name, fn type -> %{type | content_match: cm} end)
      end)

    {nodes, marks, updated_cms}
  end

  @doc "Create a node in this schema."
  @spec node(
          t(),
          String.t() | NodeType.t(),
          map() | nil,
          Fragment.t() | PmNode.t() | [PmNode.t()] | nil,
          [Mark.t()] | Mark.t() | nil
        ) :: PmNode.t()
  def node(schema, type, attrs \\ nil, content \\ nil, marks \\ nil)

  def node(schema, type, attrs, content, marks) when is_binary(type) do
    node_type = node_type(schema, type)
    NodeType.create_checked(node_type, attrs, content, marks)
  end

  def node(_schema, %NodeType{} = type, attrs, content, marks) do
    NodeType.create_checked(type, attrs, content, marks)
  end

  @doc "Create a text node in the schema. Empty text nodes are not allowed."
  @spec text(t(), String.t(), [Mark.t()] | Mark.t() | nil) :: PmNode.t()
  def text(schema, text, marks \\ nil) when is_binary(text) do
    if text == "" do
      raise "Empty text nodes are not allowed"
    end

    type = schema.nodes["text"]

    %PmNode{
      type: type,
      attrs: type.default_attrs || %{},
      text: text,
      marks: Mark.set_from(marks),
      content: Fragment.empty()
    }
  end

  @doc "Create a mark with the given type and attributes."
  @spec mark(t(), String.t() | MarkType.t(), map() | nil) :: Mark.t()
  def mark(schema, type, attrs \\ nil)

  def mark(schema, type, attrs) when is_binary(type) do
    mark_type = schema.marks[type]

    unless mark_type do
      raise "Unknown mark type: #{type}"
    end

    MarkType.create(mark_type, attrs)
  end

  def mark(_schema, %MarkType{} = type, attrs) do
    MarkType.create(type, attrs)
  end

  @doc "Look up a node type by name."
  @spec node_type(t(), String.t()) :: NodeType.t()
  def node_type(schema, name) do
    case Map.get(schema.nodes, name) do
      nil -> raise "Unknown node type: #{name}"
      type -> type
    end
  end

  @doc "Deserialize a node from its JSON representation."
  @spec node_from_json(t(), map()) :: PmNode.t()
  def node_from_json(schema, json) do
    PmNode.from_json(schema, json)
  end

  @doc "Deserialize a mark from its JSON representation."
  @spec mark_from_json(t(), map()) :: Mark.t()
  def mark_from_json(schema, json) do
    Mark.from_json(schema, json)
  end

  # ── Private / Shared Internal Helpers ────────────────────────────

  defp dedup_specs(list) do
    list
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reverse()
  end

  defp compile_node_types(nodes_list) do
    Enum.reduce(nodes_list, %{}, fn {name, spec}, acc ->
      attrs = init_attrs(name, Map.get(spec, "attrs"))
      default_attrs = compute_default_attrs(attrs)

      groups =
        case Map.get(spec, "group") do
          g when is_binary(g) and g != "" -> String.split(g, " ", trim: true)
          _ -> []
        end

      is_block = !(spec["inline"] == true || name == "text")

      type = %NodeType{
        name: name,
        schema: nil,
        spec: spec,
        groups: groups,
        attrs: attrs,
        default_attrs: default_attrs,
        has_required_attrs: has_required?(attrs),
        is_block: is_block,
        is_text: name == "text",
        is_inline: !is_block,
        content_match: nil,
        inline_content: false,
        is_textblock: false,
        is_leaf: false,
        is_atom: false,
        mark_set: nil,
        mark_set_names: nil
      }

      Map.put(acc, name, type)
    end)
  end

  defp compile_mark_types(marks_list) do
    marks_list
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{name, spec}, rank}, acc ->
      attrs = init_attrs(name, Map.get(spec, "attrs"))
      default_attrs = compute_default_attrs(attrs)

      type = %MarkType{
        name: name,
        rank: rank,
        schema: nil,
        spec: spec,
        attrs: attrs,
        excluded: nil,
        excluded_names: nil,
        instance: nil
      }

      type =
        if default_attrs do
          instance = %Mark{type: type, attrs: default_attrs}
          %{type | instance: instance}
        else
          type
        end

      Map.put(acc, name, type)
    end)
  end

  @doc false
  @spec init_attrs(String.t(), map() | nil) :: map()
  def init_attrs(_type_name, nil), do: %{}

  def init_attrs(_type_name, attrs_spec) when is_map(attrs_spec) do
    Enum.reduce(attrs_spec, %{}, fn {attr_name, attr_spec}, acc ->
      has_default = Map.has_key?(attr_spec, "default")

      attr = %{
        has_default: has_default,
        default: Map.get(attr_spec, "default"),
        validate: Map.get(attr_spec, "validate")
      }

      Map.put(acc, attr_name, attr)
    end)
  end

  @doc false
  @spec compute_default_attrs(map()) :: map() | nil
  def compute_default_attrs(attrs) when map_size(attrs) == 0, do: %{}

  def compute_default_attrs(attrs) do
    Enum.reduce_while(attrs, %{}, fn {name, attr}, acc ->
      if attr.has_default do
        {:cont, Map.put(acc, name, attr.default)}
      else
        {:halt, nil}
      end
    end)
  end

  @doc false
  @spec compute_attrs(map(), map() | nil) :: map()
  def compute_attrs(attrs_spec, value) do
    Enum.reduce(attrs_spec, %{}, fn {name, attr}, acc ->
      given =
        if value && Map.has_key?(value, name) do
          Map.get(value, name)
        else
          if attr.has_default do
            attr.default
          else
            raise "No value supplied for attribute #{name}"
          end
        end

      Map.put(acc, name, given)
    end)
  end

  @doc false
  @spec check_attrs_map(map(), term(), String.t()) :: :ok
  def check_attrs_map(attrs_spec, raw_attrs, label) do
    cond do
      raw_attrs == nil ->
        :ok

      is_map(raw_attrs) and not is_struct(raw_attrs) ->
        Enum.each(raw_attrs, fn {name, _val} ->
          unless Map.has_key?(attrs_spec, name) do
            raise "Unsupported attribute #{name} for #{label}"
          end
        end)

        :ok

      true ->
        raise "Invalid attributes for #{label}"
    end
  end

  @doc false
  @spec validate_attrs(map(), map() | nil, String.t()) :: :ok
  def validate_attrs(attrs_spec, values, kind) do
    values =
      case values do
        nil -> %{}
        m when is_map(m) and not is_struct(m) -> m
        _ -> raise "Invalid attributes for #{kind}"
      end

    Enum.each(values, fn {name, _val} ->
      unless Map.has_key?(attrs_spec, name) do
        raise "Unsupported attribute #{name} for #{kind}"
      end
    end)

    Enum.each(attrs_spec, fn {attr_name, attr} ->
      validate = Map.get(attr, :validate)

      cond do
        is_function(validate, 1) ->
          validate.(Map.get(values, attr_name))

        is_binary(validate) ->
          validate_type_expr!(validate, attr_name, Map.get(values, attr_name))

        true ->
          :ok
      end
    end)
  end

  defp validate_type_expr!(expr, attr_name, value) do
    allowed =
      expr
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    actual = js_type_name(value)

    unless actual in allowed do
      raise "Expected value of type #{expr} for attribute #{attr_name}, got #{actual}"
    end
  end

  defp js_type_name(nil), do: "null"
  defp js_type_name(v) when is_binary(v), do: "string"
  defp js_type_name(v) when is_number(v), do: "number"
  defp js_type_name(v) when is_boolean(v), do: "boolean"
  defp js_type_name(v) when is_map(v), do: "object"
  defp js_type_name(v) when is_list(v), do: "array"
  defp js_type_name(_v), do: "unknown"

  defp has_required?(attrs) do
    Enum.any?(attrs, fn {_name, attr} -> !attr.has_default end)
  end

  defp do_gather_marks(marks_map, mark_names) do
    Enum.flat_map(mark_names, fn name ->
      case Map.get(marks_map, name) do
        nil ->
          found =
            marks_map
            |> Map.values()
            |> Enum.filter(fn mt ->
              name == "_" ||
                (is_binary(mt.spec["group"]) and mt.spec["group"] != "" and
                   name in String.split(mt.spec["group"], " ", trim: true))
            end)

          if found == [] do
            raise "Unknown mark type: '#{name}'"
          end

          found

        mark ->
          [mark]
      end
    end)
  end
end
