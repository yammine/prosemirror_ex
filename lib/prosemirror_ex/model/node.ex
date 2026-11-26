defmodule ProsemirrorEx.Model.Node do
  @moduledoc """
  Represents a ProseMirror document node. It holds a type,
  optional attributes, a content Fragment, marks, and (for text nodes) text.
  """

  alias ProsemirrorEx.Model.{
    CompareDeep,
    ContentMatch,
    Fragment,
    Mark,
    MarkType,
    NodeType,
    Replace,
    ResolvedPos,
    Schema,
    Slice,
    Utf16
  }

  defstruct [:type, :attrs, :marks, :text, :text_size, content: %Fragment{content: [], size: 0}]

  @type t :: %__MODULE__{
          type: NodeType.t() | map(),
          attrs: map() | nil,
          content: Fragment.t() | nil,
          marks: [Mark.t()] | nil,
          text: String.t() | nil,
          text_size: non_neg_integer() | nil
        }

  # ── Size ──────────────────────────────────────────────────────────────

  @doc "The size of this node as counted by the indexing scheme. For text nodes this is the UTF-16 text length, for leaf nodes it is 1, and for non-leaf nodes it is the content size + 2 (for the open and close tokens)."
  @spec node_size(t()) :: non_neg_integer()
  def node_size(%__MODULE__{text: text, text_size: text_size})
      when is_binary(text) and is_integer(text_size),
      do: text_size

  def node_size(%__MODULE__{text: text}) when is_binary(text), do: Utf16.length(text)
  def node_size(%__MODULE__{type: %{is_leaf: true}}), do: 1
  def node_size(%__MODULE__{content: nil}), do: 2
  def node_size(%__MODULE__{content: %Fragment{size: size}}), do: 2 + size

  defp node_content(%__MODULE__{content: %Fragment{} = content}), do: content
  defp node_content(%__MODULE__{content: nil}), do: Fragment.empty()

  # ── Property accessors (delegate to type) ─────────────────────────────

  @doc "True when this is a text node."
  @spec is_text(t()) :: boolean()
  def is_text(%__MODULE__{text: text}), do: is_binary(text)

  @doc "True when this is a block node."
  @spec is_block(t()) :: boolean()
  def is_block(%__MODULE__{type: %{is_block: val}}), do: val

  @doc "True when this is a textblock node (a block that contains inline content)."
  @spec is_textblock(t()) :: boolean()
  def is_textblock(%__MODULE__{type: type}) do
    Map.get(type, :is_block, false) and
      (Map.get(type, :inline_content, false) or Map.get(type, :is_textblock, false))
  end

  @doc "True when this is an inline node."
  @spec is_inline(t()) :: boolean()
  def is_inline(%__MODULE__{type: %{is_inline: val}}), do: val

  @doc "True when this is a leaf node."
  @spec is_leaf(t()) :: boolean()
  def is_leaf(%__MODULE__{type: %{is_leaf: val}}), do: val

  @doc "True when this is an atom node (a leaf node that is treated as a single unit)."
  @spec is_atom_node(t()) :: boolean()
  def is_atom_node(%__MODULE__{type: type}), do: Map.get(type, :is_atom, type.is_leaf)

  @doc "True when this node allows inline content."
  @spec inline_content(t()) :: boolean()
  def inline_content(%__MODULE__{type: type}), do: Map.get(type, :inline_content, false)

  @doc "The number of children that this node has."
  @spec child_count(t()) :: non_neg_integer()
  def child_count(%__MODULE__{} = node), do: Fragment.child_count(node_content(node))

  @doc "The list of children of this node."
  @spec children(t()) :: [t()]
  def children(%__MODULE__{} = node), do: node_content(node).content

  # ── Child access ─────────────────────────────────────────────────────

  @doc "Get the child node at the given index. Raises on out-of-range."
  @spec child(t(), integer()) :: t()
  def child(%__MODULE__{} = node, index), do: Fragment.child(node_content(node), index)

  @doc "Get the child node at the given index, or nil if out of range."
  @spec maybe_child(t(), integer()) :: t() | nil
  def maybe_child(%__MODULE__{} = node, index),
    do: Fragment.maybe_child(node_content(node), index)

  @doc "Get the first child of this node, or nil."
  @spec first_child(t()) :: t() | nil
  def first_child(%__MODULE__{} = node), do: Fragment.first_child(node_content(node))

  @doc "Get the last child of this node, or nil."
  @spec last_child(t()) :: t() | nil
  def last_child(%__MODULE__{} = node), do: Fragment.last_child(node_content(node))

  # ── Markup comparison ────────────────────────────────────────────────

  @doc "Test whether the markup (type, attributes, marks) of this node is the same as that of another."
  @spec same_markup(t(), t()) :: boolean()
  def same_markup(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_type(a.type, b.type) and
      CompareDeep.compare(a.attrs || %{}, b.attrs || %{}) and
      Mark.same_set(a.marks || [], b.marks || [])
  end

  # Compare types by name (works with both full NodeType structs and plain maps)
  defp same_type(%{name: name_a}, %{name: name_b}), do: name_a == name_b
  defp same_type(a, b), do: a == b

  @doc "Test whether this node is the same as another node (structurally equal)."
  @spec eq(t(), t()) :: boolean()
  def eq(%__MODULE__{text: text_a} = a, %__MODULE__{} = b) when is_binary(text_a) do
    same_markup(a, b) and text_a == b.text
  end

  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_markup(a, b) and Fragment.eq(node_content(a), node_content(b))
  end

  @doc "Test whether this node has the given type, attributes, and marks."
  @spec has_markup(t(), NodeType.t() | map(), map() | nil, [Mark.t()] | nil) :: boolean()
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
  @spec mark(t(), [Mark.t()] | nil) :: t()
  def mark(%__MODULE__{} = node, marks) do
    marks = marks || []
    if Mark.same_set(node.marks || [], marks), do: node, else: %{node | marks: marks}
  end

  # ── Copy, cut, with_text ─────────────────────────────────────────────

  @doc "Create a copy of this node with the given content."
  @spec copy(t(), Fragment.t() | nil) :: t()
  def copy(%__MODULE__{} = node, content \\ nil) do
    content = content || Fragment.empty()
    cur = node_content(node)

    if content.size == cur.size and content == cur do
      node
    else
      %{node | content: content}
    end
  end

  @doc "Cut the text or content of this node between the given positions."
  @spec cut(t(), integer(), integer() | nil) :: t()
  def cut(node, from, to \\ nil)

  def cut(%__MODULE__{text: text} = node, from, to) when is_binary(text) do
    len = node_size(node)
    to = to || len

    if from == 0 and to == len do
      node
    else
      sliced = Utf16.slice(text, from, to)
      %{node | text: sliced, text_size: Utf16.length(sliced)}
    end
  end

  def cut(%__MODULE__{} = node, from, to) do
    content = node_content(node)
    to = to || content.size

    if from == 0 and to == content.size do
      node
    else
      %{node | content: Fragment.cut(content, from, to)}
    end
  end

  @doc "Create a text node with the same type, attributes, and marks but different text."
  @spec with_text(t(), String.t()) :: t()
  def with_text(%__MODULE__{} = node, text) when is_binary(text) do
    if text == node.text do
      node
    else
      %{node | text: text, text_size: Utf16.length(text)}
    end
  end

  @doc false
  @spec with_text_and_size(t(), String.t(), non_neg_integer()) :: t()
  def with_text_and_size(%__MODULE__{} = node, text, text_size) do
    %{node | text: text, text_size: text_size}
  end

  # ── Iteration ────────────────────────────────────────────────────────

  @doc "Call `f` for each child node, passing (node, offset, index)."
  @spec for_each(t(), (t(), non_neg_integer(), non_neg_integer() -> any())) :: :ok
  def for_each(%__MODULE__{} = node, f) do
    Fragment.for_each(node_content(node), f)
  end

  @doc """
  Invoke a callback for all descendant nodes between the given positions
  (relative to the start of this node's content). Passes the node, its
  absolute position, its parent node, and its index into the parent's
  child list.

  When the callback returns `false`, descending into that node is skipped.
  """
  @spec nodes_between(
          t(),
          integer(),
          integer(),
          (t(), non_neg_integer(), t() | nil, non_neg_integer() -> any()),
          non_neg_integer()
        ) :: :ok
  def nodes_between(%__MODULE__{} = node, from, to, f, start_pos \\ 0) do
    Fragment.nodes_between(node_content(node), from, to, f, start_pos, node)
  end

  @doc """
  Fold over all descendant nodes between `from` and `to`, threading an accumulator.

  `f` receives `(node, pos, parent, index, acc)` and returns `acc`, `{:skip, acc}`,
  or `{:halt, acc}`.
  """
  @spec fold_nodes_between(
          t(),
          integer(),
          integer(),
          (t(), non_neg_integer(), t() | nil, non_neg_integer(), acc ->
             acc | {:skip, acc} | {:halt, acc}),
          acc,
          non_neg_integer()
        ) :: acc
        when acc: var
  def fold_nodes_between(%__MODULE__{} = node, from, to, f, acc, start_pos \\ 0) do
    Fragment.fold_nodes_between(node_content(node), from, to, f, acc, start_pos, node)
  end

  @doc "Call the given function for all descendant nodes."
  @spec descendants(t(), (t(), non_neg_integer(), t() | nil, non_neg_integer() -> any())) :: :ok
  def descendants(%__MODULE__{} = node, f) do
    content = node_content(node)
    Fragment.nodes_between(content, 0, content.size, f, 0, node)
  end

  @doc """
  Fold over all descendant nodes, threading an accumulator.

  `f` receives `(node, pos, parent, index, acc)` and returns either:
  - `acc` — descend into children with updated accumulator
  - `{:skip, acc}` — skip children, continue with updated accumulator
  - `{:halt, acc}` — halt traversal immediately with final accumulator
  """
  @spec fold_descendants(
          t(),
          acc,
          (t(), non_neg_integer(), t() | nil, non_neg_integer(), acc ->
             acc | {:skip, acc} | {:halt, acc})
        ) :: acc
        when acc: var
  def fold_descendants(%__MODULE__{} = node, acc, f) do
    content = node_content(node)
    Fragment.fold_nodes_between(content, 0, content.size, f, acc, 0, node)
  end

  # ── Text content ─────────────────────────────────────────────────────

  @doc "Get the text content of this node."
  @spec text_content(t()) :: String.t()
  def text_content(%__MODULE__{text: text}) when is_binary(text), do: text

  def text_content(%__MODULE__{type: type} = node) do
    spec = Map.get(type, :spec) || %{}
    leaf_text = spec["leafText"] || spec[:leafText]

    if Map.get(type, :is_leaf, false) do
      cond do
        is_function(leaf_text, 1) ->
          leaf_text.(node)

        is_binary(leaf_text) ->
          leaf_text

        true ->
          content = node_content(node)
          Fragment.text_between(content, 0, content.size, "")
      end
    else
      content = node_content(node)
      Fragment.text_between(content, 0, content.size, "")
    end
  end

  @doc "Get the text between `from` and `to` positions within this node."
  @spec text_between(
          t(),
          integer(),
          integer(),
          String.t() | nil,
          String.t() | (t() -> String.t()) | nil
        ) :: String.t()
  def text_between(node, from, to, block_sep \\ "", leaf_text \\ nil)

  def text_between(%__MODULE__{text: text}, from, to, _block_sep, _leaf_text)
      when is_binary(text) do
    Utf16.slice(text, from, to)
  end

  def text_between(%__MODULE__{} = node, from, to, block_sep, leaf_text) do
    Fragment.text_between(node_content(node), from, to, block_sep, leaf_text)
  end

  # ── node_at ──────────────────────────────────────────────────────────

  @doc "Find the node at the given position."
  @spec node_at(t(), integer()) :: t() | nil
  def node_at(%__MODULE__{} = node, pos) do
    do_node_at(node, pos)
  end

  defp do_node_at(node, pos) do
    content = node_content(node)

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
  @spec child_after(t(), integer()) :: {t() | nil, non_neg_integer(), non_neg_integer()}
  def child_after(%__MODULE__{} = node, pos) do
    content = node_content(node)
    {index, offset} = Fragment.find_index(content, pos)
    {Fragment.maybe_child(content, index), index, offset}
  end

  @doc "Find the child node before the given position. Returns {node, index, offset}."
  @spec child_before(t(), integer()) :: {t() | nil, non_neg_integer(), non_neg_integer()}
  def child_before(%__MODULE__{}, 0), do: {nil, 0, 0}

  def child_before(%__MODULE__{} = node, pos) do
    Fragment.child_before(node_content(node), pos)
  end

  # ── range_has_mark ───────────────────────────────────────────────────

  @doc "Test whether the given range contains a mark of the given type."
  @spec range_has_mark(t(), integer(), integer(), Mark.t() | MarkType.t() | map()) :: boolean()
  def range_has_mark(%__MODULE__{} = node, from, to, mark_or_type) do
    if to <= from do
      false
    else
      do_range_has_mark(node_content(node).content, from, to, mark_or_type, 0)
    end
  end

  defp do_range_has_mark([], _from, _to, _mark_or_type, _pos), do: false
  defp do_range_has_mark(_children, _from, to, _mark_or_type, pos) when pos >= to, do: false

  defp do_range_has_mark([child | rest], from, to, mark_or_type, pos) do
    child_end = pos + node_size(child)

    if child_end > from do
      if mark_in_set?(mark_or_type, child.marks || []) do
        true
      else
        child_frag = child.content

        found_in_child =
          if child_frag != nil and child_frag.size > 0 do
            start = pos + 1

            do_range_has_mark(
              child_frag.content,
              max(0, from - start),
              min(child_frag.size, to - start),
              mark_or_type,
              0
            )
          else
            false
          end

        found_in_child or do_range_has_mark(rest, from, to, mark_or_type, child_end)
      end
    else
      do_range_has_mark(rest, from, to, mark_or_type, child_end)
    end
  end

  defp mark_in_set?(%Mark{} = mark, marks), do: Mark.is_in_set(mark, marks)
  defp mark_in_set?(%MarkType{} = type, marks), do: MarkType.is_in_set(type, marks) != nil

  defp mark_in_set?(%{name: name}, marks),
    do: Enum.any?(marks, fn m -> m.type.name == name end)

  # ── debug_string ─────────────────────────────────────────────────────

  @doc "A human-readable debug representation of this node (equivalent to JS toString)."
  @spec debug_string(t()) :: String.t()
  def debug_string(%__MODULE__{type: type, text: text} = node) when is_binary(text) do
    spec = Map.get(type, :spec) || %{}
    to_debug = spec["toDebugString"] || spec[:toDebugString]

    base =
      if is_function(to_debug, 1) do
        to_debug.(node)
      else
        inspect_text(text)
      end

    wrap_marks(node.marks || [], base)
  end

  def debug_string(%__MODULE__{type: type} = node) do
    spec = Map.get(type, :spec) || %{}
    to_debug = spec["toDebugString"] || spec[:toDebugString]

    base =
      if is_function(to_debug, 1) do
        to_debug.(node)
      else
        name = type.name
        content_frag = node_content(node)

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
    |> do_escape_string([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp do_escape_string(<<>>, acc), do: acc
  defp do_escape_string(<<"\\", rest::binary>>, acc), do: do_escape_string(rest, ["\\\\" | acc])
  defp do_escape_string(<<"\"", rest::binary>>, acc), do: do_escape_string(rest, ["\\\"" | acc])
  defp do_escape_string(<<"\b", rest::binary>>, acc), do: do_escape_string(rest, ["\\b" | acc])
  defp do_escape_string(<<"\f", rest::binary>>, acc), do: do_escape_string(rest, ["\\f" | acc])
  defp do_escape_string(<<"\n", rest::binary>>, acc), do: do_escape_string(rest, ["\\n" | acc])
  defp do_escape_string(<<"\r", rest::binary>>, acc), do: do_escape_string(rest, ["\\r" | acc])
  defp do_escape_string(<<"\t", rest::binary>>, acc), do: do_escape_string(rest, ["\\t" | acc])

  defp do_escape_string(<<c, rest::binary>>, acc) when c < 0x20 do
    hex = c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    do_escape_string(rest, ["\\u" <> hex | acc])
  end

  defp do_escape_string(<<c::utf8, rest::binary>>, acc) do
    do_escape_string(rest, [<<c::utf8>> | acc])
  end

  defp do_escape_string(<<byte, rest::binary>>, acc) do
    do_escape_string(rest, [<<byte>> | acc])
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
  @spec to_json(t()) :: map()
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
        case Fragment.to_json(node_content(node)) do
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

  # ── Position resolution, slicing, replacing ──────────────────────────

  @doc "Resolve the given position in this document, returning a ResolvedPos."
  @spec resolve(t(), integer()) :: ResolvedPos.t()
  def resolve(%__MODULE__{} = doc, pos) do
    ResolvedPos.resolve(doc, pos)
  end

  @doc "Extract a slice of the document between the given positions."
  @spec slice(t(), integer(), integer() | nil, boolean()) :: Slice.t()
  def slice(node, from, to \\ nil, include_parents \\ false)

  def slice(%__MODULE__{} = node, from, nil, include_parents) do
    slice(node, from, node_content(node).size, include_parents)
  end

  def slice(%__MODULE__{} = node, from, to, include_parents) do
    if from >= to do
      Slice.empty()
    else
      from_pos = ResolvedPos.resolve(node, from)
      to_pos = ResolvedPos.resolve(node, to)
      depth = if include_parents, do: 0, else: ResolvedPos.shared_depth(from_pos, to)
      start = ResolvedPos.start(from_pos, depth)
      node_at_depth = ResolvedPos.node(from_pos, depth)

      content =
        Fragment.cut(node_content(node_at_depth), from_pos.pos - start, to_pos.pos - start)

      Slice.new(content, from_pos.depth - depth, to_pos.depth - depth)
    end
  end

  @doc "Replace a range of the document with the given slice."
  @spec replace(t(), integer(), integer() | nil, Slice.t() | nil) :: t()
  def replace(%__MODULE__{} = node, from, to \\ nil, slice \\ nil) do
    to = to || from
    slice = slice || Slice.empty()
    from_pos = ResolvedPos.resolve(node, from)
    to_pos = ResolvedPos.resolve(node, to)
    Replace.replace(from_pos, to_pos, slice)
  end

  # ── check ──────────────────────────────────────────────────────────────

  @doc """
  Check that this node's content is valid for its type.

  Validates content against the content expression, checks that all
  attributes are valid, and recursively checks children. Raises on
  any validation error.
  """
  @spec check(t()) :: :ok
  def check(%__MODULE__{} = node) do
    if is_binary(node.text) and node.text == "" do
      raise "Empty text nodes are not allowed"
    end

    content = node_content(node)
    NodeType.check_content(node.type, content)
    NodeType.check_attrs(node.type, node.attrs || %{})

    copy =
      Enum.reduce(node.marks || [], Mark.none(), fn mark, acc ->
        MarkType.check_attrs(mark.type, mark.attrs || %{})
        Mark.add_to_set(mark, acc)
      end)

    if !Mark.same_set(copy, node.marks || []) do
      mark_names = Enum.map_join(node.marks || [], ", ", fn m -> m.type.name end)
      raise "Invalid collection of marks for node #{node.type.name}: [#{mark_names}]"
    end

    Fragment.for_each(content, fn child, _offset, _index ->
      check(child)
    end)
  end

  # ── content_match_at ───────────────────────────────────────────────────

  @doc """
  Return a content match state that represents the match after the
  first `index` children of this node.
  """
  @spec content_match_at(t(), non_neg_integer()) :: ContentMatch.t()
  def content_match_at(%__MODULE__{} = node, index) do
    match =
      ContentMatch.match_fragment(
        node.type.content_match,
        node_content(node),
        0,
        index
      )

    if !match do
      raise "Called contentMatchAt on a node with invalid content"
    end

    match
  end

  # ── can_replace ────────────────────────────────────────────────────────

  @doc """
  Test whether replacing the range `from..to` (child indices) in this
  node with the given `replacement` fragment would leave the node's
  content valid. `start` and `end_val` optionally restrict which part
  of the replacement is considered.
  """
  @spec can_replace(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          Fragment.t() | nil,
          non_neg_integer(),
          non_neg_integer() | nil
        ) :: boolean()
  def can_replace(node, from, to, replacement \\ nil, start \\ 0, end_val \\ nil)

  def can_replace(%__MODULE__{} = node, from, to, replacement, start, end_val) do
    replacement = replacement || Fragment.empty()
    end_val = end_val || Fragment.child_count(replacement)

    one = ContentMatch.match_fragment(content_match_at(node, from), replacement, start, end_val)
    two = one && ContentMatch.match_fragment(one, node_content(node), to)

    if !two || !two.valid_end do
      false
    else
      all_marks_allowed?(node.type, Enum.drop(replacement.content, start), end_val - start)
    end
  end

  defp all_marks_allowed?(_node_type, _children, remaining) when remaining <= 0, do: true
  defp all_marks_allowed?(_node_type, [], _remaining), do: true

  defp all_marks_allowed?(node_type, [child | rest], remaining) do
    NodeType.allows_marks(node_type, child.marks || []) and
      all_marks_allowed?(node_type, rest, remaining - 1)
  end

  # ── can_replace_with ───────────────────────────────────────────────────

  @doc """
  Test whether replacing the range `from..to` (child indices) with a
  node of the given `type` would leave the node's content valid.
  """
  @spec can_replace_with(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          NodeType.t(),
          [Mark.t()] | nil
        ) :: boolean()
  def can_replace_with(%__MODULE__{} = node, from, to, type, marks \\ nil) do
    if marks && !NodeType.allows_marks(node.type, marks) do
      false
    else
      start = ContentMatch.match_type(content_match_at(node, from), type)
      end_match = start && ContentMatch.match_fragment(start, node_content(node), to)

      if end_match do
        end_match.valid_end
      else
        false
      end
    end
  end

  # ── can_append ─────────────────────────────────────────────────────────

  @doc """
  Test whether the given node's content can be appended to this node.
  If that node's content is not empty, this is equivalent to checking
  whether the content can be inserted at the end.
  """
  @spec can_append(t(), t()) :: boolean()
  def can_append(%__MODULE__{} = node, %__MODULE__{} = other) do
    other_content = node_content(other)

    if other_content.size > 0 do
      count = child_count(node)
      can_replace(node, count, count, other_content)
    else
      NodeType.compatible_content(node.type, other.type)
    end
  end

  # ── from_json ──────────────────────────────────────────────────────────

  @doc """
  Deserialize a node from its JSON representation.

  Takes a schema and a JSON map. Validates structure, attributes, marks,
  and content expressions.
  """
  @spec from_json(term(), term()) :: t()
  def from_json(schema, json) do
    do_from_json(schema, json, true)
  end

  @doc false
  @spec from_json_for_slice(term(), term()) :: t()
  def from_json_for_slice(schema, json) do
    do_from_json(schema, json, false)
  end

  defp do_from_json(schema, json, validate_content?)
       when is_map(json) and not is_struct(json) do
    type_name = json["type"]

    unless is_binary(type_name) do
      raise "Invalid input for Node.fromJSON"
    end

    marks = parse_marks(schema, json)

    if type_name == "text" do
      parse_text_node(schema, json, marks)
    else
      parse_element_node(schema, type_name, json, marks, validate_content?)
    end
  end

  defp do_from_json(_schema, _json, _validate_content?) do
    raise "Invalid input for Node.fromJSON"
  end

  defp parse_marks(schema, json) do
    case Map.fetch(json, "marks") do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, mark_list} when is_list(mark_list) ->
        Enum.map(mark_list, &Mark.from_json(schema, &1))

      {:ok, _other} ->
        raise "Invalid mark data for Node.fromJSON"
    end
  end

  defp parse_text_node(schema, json, marks) do
    text = json["text"]

    unless is_binary(text) do
      raise "Invalid text node in JSON"
    end

    case Map.get(json, "attrs") do
      nil -> :ok
      attrs when is_map(attrs) and map_size(attrs) == 0 -> :ok
      _ -> raise "Unsupported attribute for text node"
    end

    if Map.get(json, "content") != nil do
      raise "Text node cannot have content"
    end

    node = Schema.text(schema, text, marks)
    %{node | text_size: Utf16.length(text)}
  end

  defp parse_element_node(schema, type_name, json, marks, validate_content?) do
    node_type = Schema.node_type(schema, type_name)
    raw_attrs = Map.get(json, "attrs")

    unless is_nil(raw_attrs) or (is_map(raw_attrs) and not is_struct(raw_attrs)) do
      raise "Invalid attrs for node #{type_name}"
    end

    if is_map(raw_attrs) do
      Enum.each(raw_attrs, fn {k, _v} ->
        unless is_binary(k) and Map.has_key?(node_type.attrs, k) do
          raise "Unsupported attribute #{inspect(k)} for node #{type_name}"
        end
      end)
    end

    content =
      if validate_content? do
        Fragment.from_json(schema, json["content"])
      else
        Fragment.from_json_for_slice(schema, json["content"])
      end

    node = NodeType.create(node_type, raw_attrs, content, marks)
    NodeType.check_attrs(node.type, node.attrs || %{})

    if validate_content? do
      NodeType.check_content(node.type, content)
    else
      # Even inside open slices, disallowed marks on children are always invalid
      Enum.each(content.content, fn child ->
        unless NodeType.allows_marks(node.type, child.marks || []) do
          raise "Invalid content for node #{node.type.name}: disallowed mark"
        end
      end)
    end

    node
  end
end
