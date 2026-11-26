defmodule ProsemirrorEx.Model.Fragment do
  @moduledoc """
  A fragment represents a node's collection of child nodes.

  Like nodes, fragments are persistent data structures, and you should not
  mutate them or their content. Rather, you create new instances whenever
  needed. The API tries to make this easy.
  """

  alias ProsemirrorEx.Model.Diff
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.RangeError, as: PmRangeError
  alias ProsemirrorEx.Model.Utf16

  defstruct content: [], size: 0

  @type t :: %__MODULE__{
          content: [PmNode.t()],
          size: non_neg_integer()
        }

  @doc "Create a new fragment with the given content and size."
  @spec new([PmNode.t()], non_neg_integer()) :: t()
  def new(content, size) do
    %__MODULE__{content: content, size: size}
  end

  @doc "An empty fragment. Singleton."
  @spec empty() :: t()
  def empty do
    %__MODULE__{content: [], size: 0}
  end

  @doc "The number of child nodes in this fragment."
  @spec child_count(t()) :: non_neg_integer()
  def child_count(%__MODULE__{content: content}), do: length(content)

  @doc """
  Get the child node at the given index. Raise an error when the index is
  out of range.
  """
  @spec child(t(), integer()) :: PmNode.t()
  def child(%__MODULE__{content: content}, index) when is_integer(index) and index >= 0 do
    case Enum.fetch(content, index) do
      {:ok, node} ->
        node

      :error ->
        raise RuntimeError,
              "Index #{index} out of range for fragment with #{length(content)} children"
    end
  end

  def child(%__MODULE__{content: content}, index) do
    raise RuntimeError,
          "Index #{index} out of range for fragment with #{length(content)} children"
  end

  @doc "Get the child node at the given index, if it exists."
  @spec maybe_child(t(), integer()) :: PmNode.t() | nil
  def maybe_child(%__MODULE__{content: content}, index) when is_integer(index) and index >= 0 do
    Enum.at(content, index)
  end

  def maybe_child(%__MODULE__{}, _index), do: nil

  @doc "Get the first child of this fragment, or nil."
  @spec first_child(t()) :: PmNode.t() | nil
  def first_child(%__MODULE__{content: []}), do: nil
  def first_child(%__MODULE__{content: [first | _]}), do: first

  @doc "Get the last child of this fragment, or nil."
  @spec last_child(t()) :: PmNode.t() | nil
  def last_child(%__MODULE__{content: []}), do: nil
  def last_child(%__MODULE__{content: content}), do: List.last(content)

  @doc "Call the given function for each child node, passing the node, its offset, and its index."
  @spec for_each(t(), (PmNode.t(), non_neg_integer(), non_neg_integer() -> any())) :: :ok
  def for_each(%__MODULE__{content: content}, fun) when is_function(fun, 3) do
    do_for_each(content, fun, 0, 0)
  end

  defp do_for_each([], _fun, _offset, _index), do: :ok

  defp do_for_each([child | rest], fun, offset, index) do
    fun.(child, offset, index)
    do_for_each(rest, fun, offset + PmNode.node_size(child), index + 1)
  end

  @doc "Test whether this fragment is equal to another fragment."
  @spec eq(t(), t()) :: boolean()
  def eq(%__MODULE__{size: size_a}, %__MODULE__{size: size_b}) when size_a != size_b, do: false

  def eq(%__MODULE__{content: content_a}, %__MODULE__{content: content_b}),
    do: do_eq(content_a, content_b)

  defp do_eq([], []), do: true
  defp do_eq([a | rest_a], [b | rest_b]), do: PmNode.eq(a, b) and do_eq(rest_a, rest_b)
  defp do_eq(_, _), do: false

  @doc """
  Create a fragment from an array of nodes, joining adjacent text nodes
  with the same markup.
  """
  @spec from_array([PmNode.t()]) :: t()
  def from_array([]), do: empty()

  def from_array(array) when is_list(array) do
    {joined, size} = scan_no_merge(array, array, 0, 0, nil, 0)
    new(joined, size)
  end

  # Single-pass O(N) scan. Returns `orig` untouched if no adjacent text nodes
  # share markup, or switches once to reverse-accumulator mode on the first merge.
  defp scan_no_merge([], orig, size, _count, _prev, _prev_size), do: {orig, size}

  defp scan_no_merge([node | rest], orig, size, count, prev, prev_size) do
    node_size = PmNode.node_size(node)
    new_size = size + node_size

    if prev != nil and PmNode.is_text(node) and PmNode.same_markup(prev, node) do
      rev_prefix = rev_take(orig, count - 1, [])
      merged = PmNode.with_text_and_size(prev, prev.text <> node.text, prev_size + node_size)
      scan_merging(rest, [merged | rev_prefix], new_size)
    else
      scan_no_merge(rest, orig, new_size, count + 1, node, node_size)
    end
  end

  defp scan_merging([], rev_acc, size), do: {Enum.reverse(rev_acc), size}

  defp scan_merging([node | rest], [prev | tail] = rev_acc, size) do
    node_size = PmNode.node_size(node)
    new_size = size + node_size

    if PmNode.is_text(node) and PmNode.same_markup(prev, node) do
      merged_size = PmNode.node_size(prev) + node_size
      merged = PmNode.with_text_and_size(prev, prev.text <> node.text, merged_size)
      scan_merging(rest, [merged | tail], new_size)
    else
      scan_merging(rest, [node | rev_acc], new_size)
    end
  end

  defp rev_take(_list, 0, acc), do: acc
  defp rev_take([h | t], n, acc), do: rev_take(t, n - 1, [h | acc])

  @doc """
  Create a fragment from something that can be interpreted as a set of nodes.
  For nil, it returns the empty fragment. For a fragment, the fragment itself
  is returned. For a node or array of nodes, a fragment containing those
  nodes is returned.
  """
  @spec from(t() | PmNode.t() | [PmNode.t()] | nil) :: t()
  def from(nil), do: empty()
  def from(%__MODULE__{} = fragment), do: fragment

  def from(%PmNode{} = node) do
    new([node], PmNode.node_size(node))
  end

  def from(nodes) when is_list(nodes) do
    from_array(nodes)
  end

  @doc """
  Cut out the sub-fragment between the two given positions.

  Positions are document positions (not child indices). For text nodes,
  positions map to UTF-16 code-unit offsets. For non-text non-leaf nodes,
  positions are adjusted by -1 to account for the opening token.
  """
  @spec cut(t(), integer(), integer() | nil) :: t()
  def cut(%__MODULE__{} = frag, from, to \\ nil) do
    to = to || frag.size

    if from == 0 and to == frag.size do
      frag
    else
      if to > from do
        do_cut(frag.content, from, to, [], 0, 0)
      else
        empty()
      end
    end
  end

  defp do_cut([], _from, _to, result, size, _pos) do
    new(Enum.reverse(result), size)
  end

  defp do_cut([child | rest], from, to, result, size, pos) do
    child_size = PmNode.node_size(child)
    child_end = pos + child_size

    if child_end <= from do
      if child_end < to do
        do_cut(rest, from, to, result, size, child_end)
      else
        new(Enum.reverse(result), size)
      end
    else
      cut_child =
        if pos < from or child_end > to do
          if PmNode.is_text(child) do
            PmNode.cut(
              child,
              max(0, from - pos),
              min(child_size, to - pos)
            )
          else
            child_content_size = if child.content, do: child.content.size, else: 0

            PmNode.cut(
              child,
              max(0, from - pos - 1),
              min(child_content_size, to - pos - 1)
            )
          end
        else
          child
        end

      new_size = size + PmNode.node_size(cut_child)

      if child_end >= to do
        new(Enum.reverse([cut_child | result]), new_size)
      else
        do_cut(rest, from, to, [cut_child | result], new_size, child_end)
      end
    end
  end

  @doc "Cut by child index rather than position."
  @spec cut_by_index(t(), non_neg_integer(), non_neg_integer()) :: t()
  def cut_by_index(%__MODULE__{content: content}, from, to) do
    if from == to do
      empty()
    else
      sliced = Enum.slice(content, from, to - from)
      size = Enum.reduce(sliced, 0, fn node, acc -> acc + PmNode.node_size(node) end)
      new(sliced, size)
    end
  end

  @doc """
  Create a new fragment in which the node at the given index is replaced
  by the given node.
  """
  @spec replace_child(t(), non_neg_integer(), PmNode.t()) :: t()
  def replace_child(%__MODULE__{content: content, size: size}, index, node) do
    {new_content, old_size} = do_replace_child(content, index, node, [])
    new(new_content, size - old_size + PmNode.node_size(node))
  end

  defp do_replace_child([old | rest], 0, node, rev_prefix) do
    {:lists.reverse(rev_prefix, [node | rest]), PmNode.node_size(old)}
  end

  defp do_replace_child([head | rest], index, node, rev_prefix) do
    do_replace_child(rest, index - 1, node, [head | rev_prefix])
  end

  @doc "Add a node to the start of the fragment, joining it with the first child if possible."
  @spec add_to_start(t(), PmNode.t()) :: t()
  def add_to_start(%__MODULE__{} = frag, node) do
    append(from(node), frag)
  end

  @doc "Add a node to the end of the fragment, joining it with the last child if possible."
  @spec add_to_end(t(), PmNode.t()) :: t()
  def add_to_end(%__MODULE__{} = frag, node) do
    append(frag, from(node))
  end

  @doc """
  Concatenate two fragments, joining adjacent text nodes with the same
  markup if possible.
  """
  @spec append(t(), t()) :: t()
  def append(%__MODULE__{size: 0}, %__MODULE__{} = other), do: other
  def append(%__MODULE__{} = this, %__MODULE__{size: 0}), do: this

  def append(%__MODULE__{content: content_a, size: size_a}, %__MODULE__{
        content: [first | rest_b] = content_b,
        size: size_b
      }) do
    {rev_prefix, last} = split_last(content_a, [])

    if PmNode.is_text(last) and PmNode.same_markup(last, first) do
      merged_size = PmNode.node_size(last) + PmNode.node_size(first)
      merged = PmNode.with_text_and_size(last, last.text <> first.text, merged_size)
      new(:lists.reverse(rev_prefix, [merged | rest_b]), size_a + size_b)
    else
      new(content_a ++ content_b, size_a + size_b)
    end
  end

  defp split_last([last], rev_prefix), do: {rev_prefix, last}
  defp split_last([head | rest], rev_prefix), do: split_last(rest, [head | rev_prefix])

  @doc """
  Find the index and inner offset corresponding to a given document position.
  Returns `{index, offset}`.
  """
  @spec find_index(t(), integer()) :: {non_neg_integer(), non_neg_integer()}
  def find_index(%__MODULE__{}, 0), do: {0, 0}

  def find_index(%__MODULE__{content: content, size: size}, pos) when pos == size do
    {length(content), pos}
  end

  def find_index(%__MODULE__{size: size}, pos) when pos > size or pos < 0 do
    raise PmRangeError, "Position #{pos} outside of fragment (size #{size})"
  end

  def find_index(%__MODULE__{content: content}, pos) do
    do_find_index(content, pos, 0, 0)
  end

  defp do_find_index([child | rest], pos, index, cur_pos) do
    child_end = cur_pos + PmNode.node_size(child)

    cond do
      child_end == pos -> {index + 1, child_end}
      child_end > pos -> {index, cur_pos}
      true -> do_find_index(rest, pos, index + 1, child_end)
    end
  end

  @doc false
  @spec child_before(t(), integer()) :: {PmNode.t() | nil, non_neg_integer(), non_neg_integer()}
  def child_before(%__MODULE__{}, 0), do: {nil, 0, 0}

  def child_before(%__MODULE__{size: size}, pos) when pos < 0 or pos > size do
    raise PmRangeError, "Position #{pos} outside of fragment (size #{size})"
  end

  def child_before(%__MODULE__{content: content}, pos) do
    do_child_before(content, pos, 0, 0)
  end

  defp do_child_before([child | rest], pos, index, cur_pos) do
    child_end = cur_pos + PmNode.node_size(child)

    if pos <= child_end do
      {child, index, cur_pos}
    else
      do_child_before(rest, pos, index + 1, child_end)
    end
  end

  @doc """
  Serialize the content of this fragment to JSON. Returns nil if empty.
  """
  @spec to_json(t()) :: [map()] | nil
  def to_json(%__MODULE__{content: []}), do: nil

  def to_json(%__MODULE__{content: content}) do
    Enum.map(content, &PmNode.to_json/1)
  end

  @doc """
  Call `f` for every descendant node between the given positions.

  `f` receives `(node, start_pos, parent, index)`. When `f` returns `false`,
  descending into that node is skipped.
  """
  @spec nodes_between(
          t(),
          integer(),
          integer(),
          (PmNode.t(), non_neg_integer(), PmNode.t() | nil, non_neg_integer() -> any()),
          non_neg_integer(),
          PmNode.t() | nil
        ) :: :ok
  def nodes_between(%__MODULE__{content: content}, from, to, f, node_start \\ 0, parent \\ nil) do
    do_nodes_between(content, from, to, f, node_start, parent, 0, 0)
  end

  defp do_nodes_between([], _from, _to, _f, _node_start, _parent, _i, _pos), do: :ok

  defp do_nodes_between(_children, _from, to, _f, _node_start, _parent, _i, pos) when pos >= to,
    do: :ok

  defp do_nodes_between([child | rest], from, to, f, node_start, parent, i, pos) do
    child_end = pos + PmNode.node_size(child)

    if child_end > from do
      result = f.(child, node_start + pos, parent, i)

      if result != false and child.content != nil and child.content.size > 0 do
        start = pos + 1

        nodes_between(
          child.content,
          max(0, from - start),
          min(child.content.size, to - start),
          f,
          node_start + start,
          child
        )
      end
    end

    do_nodes_between(rest, from, to, f, node_start, parent, i + 1, child_end)
  end

  @doc """
  Like `nodes_between/6` but threads an accumulator through each callback.

  `f` receives `(node, start_pos, parent, index, acc)` and returns either:
  - `acc` — descend into children with updated accumulator
  - `{:skip, acc}` — skip children, continue with updated accumulator
  - `{:halt, acc}` — halt traversal immediately with final accumulator
  """
  @spec fold_nodes_between(
          t(),
          integer(),
          integer(),
          (PmNode.t(), non_neg_integer(), PmNode.t() | nil, non_neg_integer(), acc ->
             acc | {:skip, acc} | {:halt, acc}),
          acc,
          non_neg_integer(),
          PmNode.t() | nil
        ) :: acc
        when acc: var
  def fold_nodes_between(
        %__MODULE__{content: content},
        from,
        to,
        f,
        acc,
        node_start \\ 0,
        parent \\ nil
      ) do
    {_status, final_acc} =
      do_fold_nodes_between(content, from, to, f, acc, node_start, parent, 0, 0)

    final_acc
  end

  defp do_fold_nodes_between([], _from, _to, _f, acc, _node_start, _parent, _i, _pos),
    do: {:cont, acc}

  defp do_fold_nodes_between(_children, _from, to, _f, acc, _node_start, _parent, _i, pos)
       when pos >= to,
       do: {:cont, acc}

  defp do_fold_nodes_between([child | rest], from, to, f, acc, node_start, parent, i, pos) do
    child_end = pos + PmNode.node_size(child)

    if child_end > from do
      case f.(child, node_start + pos, parent, i, acc) do
        {:halt, halted_acc} ->
          {:halt, halted_acc}

        {:skip, next_acc} ->
          do_fold_nodes_between(rest, from, to, f, next_acc, node_start, parent, i + 1, child_end)

        next_acc ->
          if child.content != nil and child.content.size > 0 do
            start = pos + 1

            case do_fold_nodes_between(
                   child.content.content,
                   max(0, from - start),
                   min(child.content.size, to - start),
                   f,
                   next_acc,
                   node_start + start,
                   child,
                   0,
                   0
                 ) do
              {:halt, halted_acc} ->
                {:halt, halted_acc}

              {:cont, child_acc} ->
                do_fold_nodes_between(
                  rest,
                  from,
                  to,
                  f,
                  child_acc,
                  node_start,
                  parent,
                  i + 1,
                  child_end
                )
            end
          else
            do_fold_nodes_between(
              rest,
              from,
              to,
              f,
              next_acc,
              node_start,
              parent,
              i + 1,
              child_end
            )
          end
      end
    else
      do_fold_nodes_between(rest, from, to, f, acc, node_start, parent, i + 1, child_end)
    end
  end

  @doc """
  Extract the text between `from` and `to`. When `block_separator` is given,
  it will be inserted between textblocks. When `leaf_text` is given, it will
  be used to represent non-text leaf nodes (string or function).
  """
  @spec text_between(
          t(),
          integer(),
          integer(),
          String.t() | nil,
          String.t() | (PmNode.t() -> String.t()) | nil
        ) :: String.t()
  def text_between(%__MODULE__{} = frag, from, to, block_separator \\ "", leaf_text \\ nil) do
    if to <= from do
      ""
    else
      {chunks, _first?} =
        fold_nodes_between(
          frag,
          from,
          to,
          fn node, pos, _parent, _index, {acc, first?} ->
            node_text = extract_node_text(node, pos, from, to, leaf_text)

            is_block = Map.get(node.type, :is_block, false)
            is_leaf = Map.get(node.type, :is_leaf, false)

            is_textblock =
              is_block and
                (Map.get(node.type, :is_textblock, false) or
                   Map.get(node.type, :inline_content, false))

            {acc, first?} =
              if is_block and ((is_leaf and node_text != "") or is_textblock) and
                   block_separator != nil and block_separator != "" do
                if first? do
                  {acc, false}
                else
                  {[block_separator | acc], false}
                end
              else
                {acc, first?}
              end

            acc = if node_text != "", do: [node_text | acc], else: acc
            {acc, first?}
          end,
          {[], true}
        )

      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp extract_node_text(node, pos, from, to, leaf_text) do
    cond do
      PmNode.is_text(node) ->
        Utf16.slice(node.text, max(from, pos) - pos, to - pos)

      not Map.get(node.type, :is_leaf, false) ->
        ""

      is_function(leaf_text, 1) ->
        leaf_text.(node)

      is_binary(leaf_text) ->
        leaf_text

      true ->
        spec = Map.get(node.type, :spec) || %{}
        spec_leaf = spec["leafText"] || spec[:leafText]

        cond do
          is_function(spec_leaf, 1) -> spec_leaf.(node)
          is_binary(spec_leaf) -> spec_leaf
          true -> ""
        end
    end
  end

  @doc "Join child debug strings with \", \"."
  @spec to_string_inner(t()) :: String.t()
  def to_string_inner(%__MODULE__{content: content}) do
    Enum.map_join(content, ", ", &PmNode.debug_string/1)
  end

  @doc """
  Deserialize a fragment from its JSON representation.

  Takes a schema and either nil (returns empty fragment) or a list of node JSON maps.
  """
  @spec from_json(term(), [map()] | nil) :: t()
  def from_json(_schema, nil), do: empty()

  def from_json(schema, value) when is_list(value) do
    from_array(Enum.map(value, &PmNode.from_json(schema, &1)))
  end

  def from_json(_schema, _), do: raise("Invalid input for Fragment.fromJSON")

  @doc false
  @spec from_json_for_slice(term(), [map()] | nil) :: t()
  def from_json_for_slice(_schema, nil), do: empty()

  def from_json_for_slice(schema, value) when is_list(value) do
    from_array(Enum.map(value, &PmNode.from_json_for_slice(schema, &1)))
  end

  def from_json_for_slice(_schema, _),
    do: raise(ArgumentError, "Invalid input for Slice.fromJSON")

  @doc "Find the first position at which the content of two fragments diverges."
  @spec find_diff_start(t(), t(), integer()) :: non_neg_integer() | nil
  def find_diff_start(a, b, pos \\ 0), do: Diff.find_diff_start(a, b, pos)

  @doc "Find the first position from the end at which the content of two fragments diverges."
  @spec find_diff_end(t(), t(), integer() | nil, integer() | nil) ::
          %{a: integer(), b: integer()} | nil
  def find_diff_end(a, b, pos_a \\ nil, pos_b \\ nil), do: Diff.find_diff_end(a, b, pos_a, pos_b)
end
