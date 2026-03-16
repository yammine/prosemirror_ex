defmodule ProsemirrorEx.Model.Schema do
  @moduledoc """
  A document schema. Holds node and mark type objects for the nodes
  and marks that may occur in conforming documents, and provides
  functionality for creating and deserializing such documents.

  Ported from ProseMirror's schema.ts.
  """

  alias ProsemirrorEx.Model.NodeType
  alias ProsemirrorEx.Model.MarkType
  alias ProsemirrorEx.Model.ContentMatch
  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.Node, as: PmNode

  defstruct [:spec, :nodes, :marks, :top_node_type, :linebreak_replacement, :cached]

  @doc """
  Construct a schema from a schema specification map.

  The spec should have:
  - "nodes" => list of {name, node_spec} tuples
  - "marks" => (optional) list of {name, mark_spec} tuples
  - "topNode" => (optional) name of the top node type, defaults to "doc"
  """
  def new(spec) do
    # Normalize the spec
    nodes_list = Map.get(spec, "nodes", [])
    marks_list = Map.get(spec, "marks", [])
    top_node_name = Map.get(spec, "topNode", "doc")

    # Create a partial schema struct that we'll fill in
    schema = %__MODULE__{
      spec: spec,
      nodes: %{},
      marks: %{},
      top_node_type: nil,
      linebreak_replacement: nil,
      cached: %{}
    }

    # Step 1: Compile NodeTypes
    nodes = compile_node_types(nodes_list, schema)

    # Validate
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
    marks = compile_mark_types(marks_list, schema)

    # Update schema with nodes and marks
    schema = %{schema | nodes: nodes, marks: marks}

    # Step 3: Check for node/mark name collisions
    Enum.each(nodes, fn {name, _} ->
      if Map.has_key?(marks, name) do
        raise "#{name} can not be both a node and a mark"
      end
    end)

    # Step 4: Compile content expressions and resolve inline_content
    content_expr_cache = %{}

    # Set node definition order for ContentMatch group resolution
    # This ensures groups are resolved in the same order as they're defined in the schema spec,
    # matching the JS OrderedMap behavior. Critical for recursive types like blockquote.
    node_order = Enum.map(nodes_list, fn {name, _} -> name end)
    Process.put(:_pm_content_match_node_order, node_order)

    {nodes, linebreak_replacement, _cache} =
      Enum.reduce(nodes_list, {nodes, nil, content_expr_cache}, fn {name, node_spec},
                                                                   {ns, lbr, cache} ->
        type = ns[name]
        content_expr = Map.get(node_spec, "content", "")
        mark_expr = Map.get(node_spec, "marks", :not_set)

        # Parse content expression (with caching)
        {content_match, cache} =
          case Map.get(cache, content_expr) do
            nil ->
              cm = ContentMatch.parse(content_expr, ns)
              {cm, Map.put(cache, content_expr, cm)}

            cm ->
              {cm, cache}
          end

        inline_content = ContentMatch.inline_content(content_match)

        is_leaf = content_match == ContentMatch.empty()
        is_textblock = type.is_block && inline_content
        is_atom_val = is_leaf || Map.get(node_spec, "atom", false) == true

        # Resolve mark set
        mark_set =
          cond do
            mark_expr == "_" ->
              nil

            is_binary(mark_expr) and mark_expr != :not_set ->
              if mark_expr == "" do
                []
              else
                gather_marks(schema, String.split(mark_expr, " "))
              end

            mark_expr == :not_set ->
              if !inline_content, do: [], else: nil
          end

        # Check linebreak replacement
        lbr =
          if Map.get(node_spec, "linebreakReplacement", false) do
            if lbr != nil, do: raise("Multiple linebreak nodes defined")

            if !type.is_inline || !is_leaf,
              do: raise("Linebreak replacement nodes must be inline leaf nodes")

            type
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
            mark_set: mark_set
        }

        {Map.put(ns, name, updated_type), lbr, cache}
      end)

    # Clean up process dictionary
    Process.delete(:_pm_content_match_node_order)

    # Step 4b: Update DFA edges to reference the updated node types (with content_match set)
    # This is needed because content expressions are parsed before all node types
    # have their content_match populated. The DFA edges store references to node types.
    Enum.each(nodes, fn {_name, type} ->
      if type.content_match != nil do
        ContentMatch.update_node_types(type.content_match, nodes)
      end
    end)

    # Step 5: Resolve mark exclusions
    marks =
      Enum.reduce(marks_list, marks, fn {name, mark_spec}, ms ->
        type = ms[name]
        excl = Map.get(mark_spec, "excludes", :not_set)

        excluded =
          cond do
            excl == :not_set -> [type]
            excl == "" -> []
            true -> gather_marks(schema, String.split(excl, " "))
          end

        updated_type = %{type | excluded: excluded}
        Map.put(ms, name, updated_type)
      end)

    # Update schema with final nodes, marks, and back-references
    schema = %{
      schema
      | nodes: nodes,
        marks: marks,
        top_node_type: nodes[top_node_name],
        linebreak_replacement: linebreak_replacement,
        cached: %{}
    }

    # Step 6: Update all node types and mark types with the final schema reference
    nodes =
      Enum.reduce(nodes, %{}, fn {name, type}, acc ->
        Map.put(acc, name, %{type | schema: schema})
      end)

    marks =
      Enum.reduce(marks, %{}, fn {name, type}, acc ->
        # Also update the instance's type to point to the new mark type with schema
        updated_type = %{type | schema: schema}

        updated_type =
          if updated_type.instance do
            %{updated_type | instance: %{updated_type.instance | type: updated_type}}
          else
            updated_type
          end

        Map.put(acc, name, updated_type)
      end)

    # Also update the excluded lists in marks to point to the updated mark types
    marks =
      Enum.reduce(marks, marks, fn {name, type}, acc ->
        updated_excluded =
          Enum.map(type.excluded, fn ex_type ->
            Map.get(acc, ex_type.name, ex_type)
          end)

        Map.put(acc, name, %{type | excluded: updated_excluded})
      end)

    # Update top_node_type
    top_node_type = nodes[top_node_name]

    # Final schema with everything pointing correctly
    schema = %{schema | nodes: nodes, marks: marks, top_node_type: top_node_type}

    # One more pass: update node type mark_sets to reference the final mark types
    nodes =
      Enum.reduce(nodes, %{}, fn {name, type}, acc ->
        updated_mark_set =
          case type.mark_set do
            nil ->
              nil

            list when is_list(list) ->
              Enum.map(list, fn mt -> Map.get(schema.marks, mt.name, mt) end)
          end

        Map.put(acc, name, %{type | mark_set: updated_mark_set, schema: schema})
      end)

    %{schema | nodes: nodes, top_node_type: nodes[top_node_name]}
  end

  @doc "Create a node in this schema."
  def node(schema, type, attrs \\ nil, content \\ nil, marks \\ nil)

  def node(schema, type, attrs, content, marks) when is_binary(type) do
    node_type = node_type(schema, type)
    NodeType.create_checked(node_type, attrs, content, marks)
  end

  def node(_schema, %NodeType{} = type, attrs, content, marks) do
    NodeType.create_checked(type, attrs, content, marks)
  end

  @doc "Create a text node in the schema. Empty text nodes are not allowed."
  def text(schema, text, marks \\ nil) do
    if text == "" do
      raise "Empty text nodes are not allowed"
    end

    type = schema.nodes["text"]

    %PmNode{
      type: type,
      attrs: type.default_attrs || %{},
      text: text,
      marks: Mark.set_from(marks),
      content: nil
    }
  end

  @doc "Create a mark with the given type and attributes."
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
  def node_type(schema, name) do
    case Map.get(schema.nodes, name) do
      nil -> raise "Unknown node type: #{name}"
      type -> type
    end
  end

  @doc "Deserialize a node from its JSON representation."
  def node_from_json(schema, json) do
    PmNode.from_json(schema, json)
  end

  @doc "Deserialize a mark from its JSON representation."
  def mark_from_json(schema, json) do
    Mark.from_json(schema, json)
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp compile_node_types(nodes_list, _schema) do
    Enum.reduce(nodes_list, %{}, fn {name, spec}, acc ->
      attrs = init_attrs(name, Map.get(spec, "attrs"))
      default_attrs = compute_default_attrs(attrs)
      groups = if spec["group"], do: String.split(spec["group"], " "), else: []
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
        # These are filled in later during content expression compilation
        content_match: nil,
        inline_content: false,
        is_textblock: false,
        is_leaf: false,
        is_atom: false,
        mark_set: nil
      }

      Map.put(acc, name, type)
    end)
  end

  defp compile_mark_types(marks_list, _schema) do
    marks_list
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{name, spec}, rank}, acc ->
      attrs = init_attrs(name, Map.get(spec, "attrs"))
      default_attrs = compute_default_attrs(attrs)

      instance =
        if default_attrs do
          type_stub = %MarkType{
            name: name,
            rank: rank,
            schema: nil,
            spec: spec,
            attrs: attrs,
            excluded: nil,
            instance: nil
          }

          %Mark{type: type_stub, attrs: default_attrs}
        else
          nil
        end

      type = %MarkType{
        name: name,
        rank: rank,
        schema: nil,
        spec: spec,
        attrs: attrs,
        excluded: nil,
        instance: instance
      }

      # Fix the instance's type reference
      type =
        if instance do
          %{type | instance: %{instance | type: type}}
        else
          type
        end

      Map.put(acc, name, type)
    end)
  end

  @doc false
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
  def compute_default_attrs(attrs) when map_size(attrs) == 0, do: %{}

  def compute_default_attrs(attrs) do
    result =
      Enum.reduce_while(attrs, %{}, fn {name, attr}, acc ->
        if attr.has_default do
          {:cont, Map.put(acc, name, attr.default)}
        else
          {:halt, nil}
        end
      end)

    result
  end

  @doc false
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

  defp has_required?(attrs) do
    Enum.any?(attrs, fn {_name, attr} -> !attr.has_default end)
  end

  defp gather_marks(%__MODULE__{} = schema, mark_names) do
    # schema.marks might not be populated yet during construction,
    # so we pass it through. During construction, this is called
    # after marks are compiled.
    do_gather_marks(schema.marks, mark_names)
  end

  defp do_gather_marks(marks_map, mark_names) do
    Enum.flat_map(mark_names, fn name ->
      case Map.get(marks_map, name) do
        nil ->
          # Try groups
          found =
            marks_map
            |> Map.values()
            |> Enum.filter(fn mt ->
              name == "_" ||
                (mt.spec["group"] && name in String.split(mt.spec["group"], " "))
            end)

          if found == [] do
            raise SyntaxError, description: "Unknown mark type: '#{name}'"
          end

          found

        mark ->
          [mark]
      end
    end)
  end
end
