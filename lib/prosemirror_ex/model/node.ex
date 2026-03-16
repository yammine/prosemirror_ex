defmodule ProsemirrorEx.Model.Node do
  @moduledoc """
  Represents a ProseMirror document node. It holds a type,
  optional attributes, a content Fragment, marks, and (for text nodes) text.
  """

  alias ProsemirrorEx.Model.{Fragment, Mark, CompareDeep}

  defstruct [:type, :attrs, :content, :marks, :text]

  # ── Size ──────────────────────────────────────────────────────────────

  @doc "The size of this node as counted by the indexing scheme. For text nodes this is the text length, for leaf nodes it is 1, and for non-leaf nodes it is the content size + 2 (for the open and close tokens)."
  def node_size(%__MODULE__{text: text}) when is_binary(text), do: String.length(text)
  def node_size(%__MODULE__{type: %{is_leaf: true}}), do: 1
  def node_size(%__MODULE__{content: nil}), do: 2
  def node_size(%__MODULE__{content: %Fragment{size: size}}), do: 2 + size

  # ── Property accessors (delegate to type) ─────────────────────────────

  @doc "True when this is a text node."
  def is_text(%__MODULE__{text: text}), do: is_binary(text)

  @doc "True when this is a block node."
  def is_block(%__MODULE__{type: %{is_block: val}}), do: val

  @doc "True when this is a textblock node (a block that contains inline content)."
  def is_textblock(%__MODULE__{type: type}) do
    Map.get(type, :is_block, false) and
      (Map.get(type, :inline_content, false) or Map.get(type, :is_textblock, false))
  end

  @doc "True when this is an inline node."
  def is_inline(%__MODULE__{type: %{is_inline: val}}), do: val

  @doc "True when this is a leaf node."
  def is_leaf(%__MODULE__{type: %{is_leaf: val}}), do: val

  @doc "True when this is an atom node (a leaf node that is treated as a single unit)."
  def is_atom_node(%__MODULE__{type: type}), do: Map.get(type, :is_atom, type.is_leaf)

  @doc "True when this node allows inline content."
  def inline_content(%__MODULE__{type: type}), do: Map.get(type, :inline_content, false)

  @doc "The number of children that this node has."
  def child_count(%__MODULE__{content: content}),
    do: Fragment.child_count(content || Fragment.empty())

  @doc "The list of children of this node."
  def children(%__MODULE__{content: content}), do: (content || Fragment.empty()).content

  # ── Child access ─────────────────────────────────────────────────────

  @doc "Get the child node at the given index. Raises on out-of-range."
  def child(%__MODULE__{content: content}, index), do: Fragment.child(content, index)

  @doc "Get the child node at the given index, or nil if out of range."
  def maybe_child(%__MODULE__{content: content}, index), do: Fragment.maybe_child(content, index)

  @doc "Get the first child of this node, or nil."
  def first_child(%__MODULE__{content: content}), do: Fragment.first_child(content)

  @doc "Get the last child of this node, or nil."
  def last_child(%__MODULE__{content: content}), do: Fragment.last_child(content)

  # ── Markup comparison ────────────────────────────────────────────────

  @doc "Test whether the markup (type, attributes, marks) of this node is the same as that of another."
  def same_markup(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_type(a.type, b.type) and
      CompareDeep.compare(a.attrs || %{}, b.attrs || %{}) and
      Mark.same_set(a.marks || [], b.marks || [])
  end

  # Compare types by name (works with both full NodeType structs and plain maps)
  defp same_type(%{name: name_a}, %{name: name_b}), do: name_a == name_b
  defp same_type(a, b), do: a == b

  @doc "Test whether this node is the same as another node (structurally equal)."
  def eq(%__MODULE__{text: text_a} = a, %__MODULE__{} = b) when is_binary(text_a) do
    same_markup(a, b) and text_a == b.text
  end

  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_markup(a, b) and
      Fragment.eq(a.content || Fragment.empty(), b.content || Fragment.empty())
  end

  @doc "Test whether this node has the given type, attributes, and marks."
  def has_markup(%__MODULE__{} = node, type, attrs \\ nil, marks \\ nil) do
    same_type(node.type, type) and
      CompareDeep.compare(
        node.attrs || %{},
        attrs || Map.get(type, :default_attrs) || %{}
      ) and
      Mark.same_set(node.marks || [], marks || [])
  end

  # ── mark/2 ───────────────────────────────────────────────────────────

  @doc "Create a copy of this node with a different set of marks."
  def mark(%__MODULE__{} = node, marks) do
    if Mark.same_set(node.marks || [], marks), do: node, else: %{node | marks: marks}
  end

  # ── Copy, cut, with_text ─────────────────────────────────────────────

  @doc "Create a copy of this node with the given content."
  def copy(%__MODULE__{} = node, content) do
    if content == node.content, do: node, else: %{node | content: content}
  end

  @doc "Cut the text or content of this node between the given positions."
  def cut(node, from, to \\ nil)

  def cut(%__MODULE__{text: text} = node, from, to) when is_binary(text) do
    to = to || String.length(text)

    if from == 0 and to == String.length(text) do
      node
    else
      %{node | text: String.slice(text, from, to - from)}
    end
  end

  def cut(%__MODULE__{content: content} = node, from, to) do
    to = to || content.size

    if from == 0 and to == content.size do
      node
    else
      %{node | content: Fragment.cut(content, from, to)}
    end
  end

  @doc "Create a text node with the same type, attributes, and marks but different text."
  def with_text(%__MODULE__{} = node, text) do
    if text == node.text, do: node, else: %{node | text: text}
  end

  # ── Iteration ────────────────────────────────────────────────────────

  @doc "Call `f` for each child node, passing (node, offset, index)."
  def for_each(%__MODULE__{content: content}, f) do
    Fragment.for_each(content, f)
  end

  @doc """
  Invoke a callback for all descendant nodes between the given positions
  (relative to the start of this node's content). Passes the node, its
  absolute position, its parent node, and its index into the parent's
  child list.

  When the callback returns `false`, descending into that node is skipped.
  """
  def nodes_between(%__MODULE__{} = node, from, to, f, start_pos \\ 0) do
    Fragment.nodes_between(node.content, from, to, f, start_pos, node)
  end

  @doc "Call the given function for all descendant nodes."
  def descendants(%__MODULE__{} = node, f) do
    nodes_between(node, 0, (node.content || Fragment.empty()).size, f)
  end

  # ── Text content ─────────────────────────────────────────────────────

  @doc "Get the text content of this node."
  def text_content(%__MODULE__{text: text}) when is_binary(text), do: text

  def text_content(%__MODULE__{type: type} = node) do
    if type.is_leaf and is_function(Map.get(type.spec, :leafText)) do
      type.spec[:leafText].(node)
    else
      text_between(node, 0, (node.content || Fragment.empty()).size, "")
    end
  end

  @doc "Get the text between `from` and `to` positions within this node."
  def text_between(node, from, to, block_sep \\ "", leaf_text \\ nil)

  def text_between(%__MODULE__{text: text}, from, to, _block_sep, _leaf_text)
      when is_binary(text) do
    String.slice(text, from, to - from)
  end

  def text_between(%__MODULE__{content: content}, from, to, block_sep, leaf_text) do
    Fragment.text_between(content, from, to, block_sep, leaf_text)
  end

  # ── node_at ──────────────────────────────────────────────────────────

  @doc "Find the node at the given position."
  def node_at(%__MODULE__{} = node, pos) do
    do_node_at(node, pos)
  end

  defp do_node_at(node, pos) do
    content = node.content || Fragment.empty()

    try do
      {index, offset} = Fragment.find_index(content, pos)

      case Fragment.maybe_child(content, index) do
        nil ->
          nil

        child ->
          if offset == pos or is_text(child) do
            child
          else
            do_node_at(child, pos - offset - 1)
          end
      end
    rescue
      ProsemirrorEx.Model.RangeError -> nil
    end
  end

  # ── child_after / child_before ────────────────────────────────────────

  @doc "Find the child node after the given position. Returns {node, index, offset}."
  def child_after(%__MODULE__{content: content}, pos) do
    {index, offset} = Fragment.find_index(content, pos)
    {Fragment.maybe_child(content, index), index, offset}
  end

  @doc "Find the child node before the given position. Returns {node, index, offset}."
  def child_before(%__MODULE__{}, 0), do: {nil, 0, 0}

  def child_before(%__MODULE__{content: content}, pos) do
    {index, offset} = Fragment.find_index(content, pos)

    if offset < pos do
      {Fragment.child(content, index), index, offset}
    else
      child = Fragment.child(content, index - 1)
      {child, index - 1, offset - node_size(child)}
    end
  end

  # ── range_has_mark ───────────────────────────────────────────────────

  @doc "Test whether the given range contains a mark of the given type."
  def range_has_mark(%__MODULE__{} = node, from, to, mark_or_type) do
    if to <= from do
      false
    else
      found = :atomics.new(1, signed: false)

      nodes_between(node, from, to, fn child, _pos, _parent, _index ->
        if mark_in_set?(mark_or_type, child.marks || []) do
          :atomics.put(found, 1, 1)
          false
        else
          true
        end
      end)

      :atomics.get(found, 1) == 1
    end
  end

  defp mark_in_set?(%Mark{} = mark, marks), do: Mark.is_in_set(mark, marks)

  defp mark_in_set?(%{name: _} = type, marks),
    do: Enum.any?(marks, fn m -> m.type.name == type.name end)

  # ── debug_string ─────────────────────────────────────────────────────

  @doc "A human-readable debug representation of this node (equivalent to JS toString)."
  def debug_string(%__MODULE__{type: type, text: text} = node) when is_binary(text) do
    base =
      if is_function(type.spec[:toDebugString]) do
        type.spec[:toDebugString].(node)
      else
        inspect_text(text)
      end

    wrap_marks(node.marks || [], base)
  end

  def debug_string(%__MODULE__{type: type, content: content} = node) do
    base =
      if is_function(Map.get(type.spec || %{}, :toDebugString)) do
        type.spec[:toDebugString].(node)
      else
        name = type.name
        content_frag = content || Fragment.empty()

        if content_frag.size > 0 do
          name <> "(" <> Fragment.to_string_inner(content_frag) <> ")"
        else
          name
        end
      end

    wrap_marks(node.marks || [], base)
  end

  defp inspect_text(text), do: "\"" <> escape_string(text) <> "\""

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp wrap_marks([], str), do: str

  defp wrap_marks(marks, str) do
    marks
    |> Enum.reverse()
    |> Enum.reduce(str, fn mark, acc ->
      mark.type.name <> "(" <> acc <> ")"
    end)
  end

  # ── Serialize ────────────────────────────────────────────────────────

  @doc "Serialize this node to JSON."
  def to_json(%__MODULE__{} = node) do
    result = %{"type" => node.type.name}

    result =
      if node.attrs != nil and node.attrs != %{} do
        Map.put(result, "attrs", node.attrs)
      else
        result
      end

    result =
      if is_binary(node.text) do
        Map.put(result, "text", node.text)
      else
        case Fragment.to_json(node.content || Fragment.empty()) do
          nil -> result
          content_json -> Map.put(result, "content", content_json)
        end
      end

    result =
      if node.marks != nil and node.marks != [] do
        Map.put(result, "marks", Enum.map(node.marks, &Mark.to_json/1))
      else
        result
      end

    result
  end

  # ── Stubs for later tasks ────────────────────────────────────────────

  @doc "Resolve the given position in this document. Stub - requires ResolvedPos."
  def resolve(_node, _pos), do: raise("not yet implemented: resolve/2 requires ResolvedPos")

  @doc "Extract a slice of the document between the given positions. Stub - requires Slice."
  def slice(_node, _from, _to, _include_parents \\ false),
    do: raise("not yet implemented: slice requires Slice")

  @doc "Replace a range of the document. Stub - requires Replace algorithm."
  def replace(_node, _from, _to, _slice),
    do: raise("not yet implemented: replace requires Replace algorithm")

  @doc "Check that this node's content is valid for its type. Stub - requires Schema."
  def check(_node), do: raise("not yet implemented: check requires Schema")

  @doc "Test whether a given mark or mark type is present in this document in the given range."
  def can_replace(_node, _from, _to, _type, _marks \\ nil),
    do: raise("not yet implemented: can_replace requires ContentMatch")

  @doc "Test whether replacing the range from–to with a node of the given type would leave the node's content valid."
  def can_replace_with(_node, _from, _to, _type, _marks \\ nil),
    do: raise("not yet implemented: can_replace_with requires ContentMatch")

  @doc "Test whether the given node's content can be appended to this node."
  def can_append(_node, _other),
    do: raise("not yet implemented: can_append requires ContentMatch")

  @doc "Return a content match at the given index. Stub - requires ContentMatch."
  def content_match_at(_node, _index),
    do: raise("not yet implemented: content_match_at requires ContentMatch")

  @doc "Deserialize a node from its JSON representation. Stub - requires Schema."
  def from_json(_schema, _json),
    do: raise("not yet implemented: from_json requires Schema")
end
