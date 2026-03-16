defmodule ProsemirrorEx.TestHelpers do
  @moduledoc """
  Test helpers for ProseMirror document building, ported from prosemirror-test-builder.

  Provides a standard test schema and builder functions that create nodes with
  position tags for testing. Tags track positions within documents, corresponding
  to `<a>`, `<b>`, etc. markers in string children.

  ## Usage

      import ProsemirrorEx.TestHelpers

      schema = test_schema()
      {node, tags} = doc([p(["hello<a>world"])])
      # tags["a"] => 6 (position of <a> marker in the document)
  """

  alias ProsemirrorEx.Model.{Schema, Node, Fragment, Mark, NodeType, MarkType}

  @doc "Returns the standard test schema matching JS prosemirror-test-builder."
  def test_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"horizontal_rule", %{"group" => "block"}},
        {"heading",
         %{
           "content" => "inline*",
           "group" => "block",
           "attrs" => %{"level" => %{"default" => 1}}
         }},
        {"code_block", %{"content" => "text*", "group" => "block", "code" => true}},
        {"text", %{"group" => "inline"}},
        {"image",
         %{
           "group" => "inline",
           "inline" => true,
           "attrs" => %{
             "src" => %{"default" => "img.png"},
             "alt" => %{"default" => nil},
             "title" => %{"default" => nil}
           }
         }},
        {"hard_break", %{"group" => "inline", "inline" => true}},
        {"ordered_list",
         %{
           "content" => "list_item+",
           "group" => "block",
           "attrs" => %{"order" => %{"default" => 1}}
         }},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"list_item", %{"content" => "paragraph block*"}}
      ],
      "marks" => [
        {"link",
         %{
           "attrs" => %{"href" => %{"default" => "foo"}, "title" => %{"default" => nil}},
           "inclusive" => false
         }},
        {"em", %{}},
        {"strong", %{}},
        {"code", %{}}
      ]
    })
  end

  # ── Node builders ─────────────────────────────────────────────────────

  @doc "Build a doc node. Returns `{node, tags}`."
  def doc(children), do: build_node("doc", %{}, children)

  @doc "Build a paragraph node. Returns `{node, tags}`."
  def p(children \\ []), do: build_node("paragraph", %{}, children)

  @doc "Build a blockquote node. Returns `{node, tags}`."
  def blockquote(children), do: build_node("blockquote", %{}, children)

  @doc "Build a heading node with level 1. Returns `{node, tags}`."
  def h1(children), do: build_node("heading", %{"level" => 1}, children)

  @doc "Build a heading node with level 2. Returns `{node, tags}`."
  def h2(children), do: build_node("heading", %{"level" => 2}, children)

  @doc "Build a heading node with level 3. Returns `{node, tags}`."
  def h3(children), do: build_node("heading", %{"level" => 3}, children)

  @doc "Build a code_block node. Returns `{node, tags}`."
  def pre(children \\ []), do: build_node("code_block", %{}, children)

  @doc "Build a bullet_list node. Returns `{node, tags}`."
  def ul(children), do: build_node("bullet_list", %{}, children)

  @doc "Build an ordered_list node. Returns `{node, tags}`."
  def ol(children), do: build_node("ordered_list", %{}, children)

  @doc "Build a list_item node. Returns `{node, tags}`."
  def li(children), do: build_node("list_item", %{}, children)

  # ── Leaf node builders ────────────────────────────────────────────────

  @doc "Build a horizontal_rule node. Returns `{node, tags}`."
  def hr, do: build_leaf("horizontal_rule", %{})

  @doc "Build a hard_break node. Returns `{node, tags}`."
  def br, do: build_leaf("hard_break", %{})

  @doc "Build an image node with default attrs. Returns `{node, tags}`."
  def img, do: build_leaf("image", %{"src" => "img.png"})

  @doc "Build an image node with custom attrs. Returns `{node, tags}`."
  def img(attrs) when is_map(attrs),
    do: build_leaf("image", Map.merge(%{"src" => "img.png"}, attrs))

  # ── Mark builders ─────────────────────────────────────────────────────

  @doc "Wrap children with an `em` mark. Returns `{flat_nodes, tags}`."
  def em(children), do: build_mark("em", %{}, children)

  @doc "Wrap children with a `strong` mark. Returns `{flat_nodes, tags}`."
  def strong(children), do: build_mark("strong", %{}, children)

  @doc "Wrap children with a `code` mark. Returns `{flat_nodes, tags}`."
  def code_mark(children), do: build_mark("code", %{}, children)

  @doc "Wrap children with a `link` mark using default attrs. Returns `{flat_nodes, tags}`."
  def a(children), do: build_mark("link", %{"href" => "foo"}, children)

  @doc "Wrap children with a `link` mark with custom attrs. Returns `{flat_nodes, tags}`."
  def a(attrs, children) when is_map(attrs),
    do: build_mark("link", Map.merge(%{"href" => "foo"}, attrs), children)

  # ── Equality helper ──────────────────────────────────────────────────

  @doc "Test structural equality of two nodes."
  def eq(a, b), do: Node.eq(a, b)

  # ── Tag access helpers ───────────────────────────────────────────────

  @doc "Get a tag position from a `{node, tags}` result."
  def tag({_node, tags}, name), do: Map.fetch!(tags, name)

  @doc "Get the node from a `{node, tags}` result."
  def node({node, _tags}), do: node

  # ── Internal builder implementation ──────────────────────────────────

  defp get_schema do
    case Process.get(:_pm_test_schema) do
      nil ->
        schema = test_schema()
        Process.put(:_pm_test_schema, schema)
        schema

      schema ->
        schema
    end
  end

  defp build_node(type_name, attrs, children) do
    schema = get_schema()
    node_type = Schema.node_type(schema, type_name)
    {nodes, tags} = flatten(schema, children)

    # For non-flat (non-text, non-leaf-inline) nodes, offset tags by 1 for the opening token
    tags =
      if !node_type.is_text and
           !(node_type.is_inline and node_type.is_leaf) do
        Map.new(tags, fn {k, v} -> {k, v + 1} end)
      else
        tags
      end

    computed_attrs = NodeType.compute_attrs(node_type, if(attrs == %{}, do: nil, else: attrs))
    content = Fragment.from(nodes)
    node = NodeType.create(node_type, computed_attrs, content, nil)
    {node, tags}
  end

  defp build_leaf(type_name, attrs) do
    schema = get_schema()
    node_type = Schema.node_type(schema, type_name)
    computed_attrs = NodeType.compute_attrs(node_type, if(attrs == %{}, do: nil, else: attrs))
    node = NodeType.create(node_type, computed_attrs, nil, nil)
    {node, %{}}
  end

  defp build_mark(mark_name, attrs, children) do
    schema = get_schema()
    mark_type = schema.marks[mark_name]
    mark = MarkType.create(mark_type, if(attrs == %{}, do: nil, else: attrs))
    {nodes, tags} = flatten(schema, children)

    # Add the mark to each node
    marked_nodes =
      Enum.map(nodes, fn node ->
        new_marks = Mark.add_to_set(mark, node.marks || [])
        %{node | marks: new_marks}
      end)

    # Return as a flat result (not a node, but a list of marked nodes + tags)
    # Mark builders return {flat_nodes, tags} which flatten will handle
    {:flat, marked_nodes, tags}
  end

  defp flatten(schema, children) when is_list(children) do
    Enum.reduce(children, {[], %{}, 0}, fn child, {nodes, tags, pos} ->
      case child do
        str when is_binary(str) ->
          {text, new_tags} = extract_tags(str, pos)

          if text != "" do
            text_node = Schema.text(schema, text)
            {nodes ++ [text_node], Map.merge(tags, new_tags), pos + String.length(text)}
          else
            {nodes, Map.merge(tags, new_tags), pos}
          end

        {:flat, flat_nodes, flat_tags} ->
          # Result from a mark builder
          offset_tags = Map.new(flat_tags, fn {k, v} -> {k, v + pos} end)

          child_size =
            Enum.reduce(flat_nodes, 0, fn n, acc -> acc + Node.node_size(n) end)

          {nodes ++ flat_nodes, Map.merge(tags, offset_tags), pos + child_size}

        {child_node, child_tags} when is_map(child_tags) ->
          # Result from a node builder (tuple of {node, tags})
          offset_tags = Map.new(child_tags, fn {k, v} -> {k, v + pos} end)

          {nodes ++ [child_node], Map.merge(tags, offset_tags), pos + Node.node_size(child_node)}
      end
    end)
    |> then(fn {nodes, tags, _pos} -> {nodes, tags} end)
  end

  defp flatten(_schema, []), do: {[], %{}}

  @tag_regex ~r/<(\w+)>/

  defp extract_tags(str, base_pos) do
    # Find all <tag> markers, strip them, and record positions
    do_extract_tags(str, base_pos, "", %{}, 0)
  end

  defp do_extract_tags(str, base_pos, text_acc, tags, offset) do
    case Regex.run(@tag_regex, str, return: :index) do
      nil ->
        {text_acc <> str, tags}

      [{match_start, match_len} | _] ->
        # Get the tag name
        [_, tag_name] = Regex.run(@tag_regex, str)

        # Text before the tag
        before = String.slice(str, 0, match_start)
        after_str = String.slice(str, (match_start + match_len)..-1//1)

        new_text = text_acc <> before
        # Position is base_pos + length of text accumulated so far
        tag_pos = base_pos + String.length(new_text)
        new_tags = Map.put(tags, tag_name, tag_pos)

        do_extract_tags(after_str, base_pos, new_text, new_tags, offset + match_len)
    end
  end
end
