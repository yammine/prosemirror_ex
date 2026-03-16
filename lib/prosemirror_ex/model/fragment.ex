defmodule ProsemirrorEx.Model.RangeError do
  @moduledoc "Error raised when a position is outside valid range."
  defexception [:message]
end

defmodule ProsemirrorEx.Model.Fragment do
  @moduledoc """
  A fragment represents a node's collection of child nodes.

  Like nodes, fragments are persistent data structures, and you should not
  mutate them or their content. Rather, you create new instances whenever
  needed. The API tries to make this easy.
  """

  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.RangeError, as: PmRangeError

  defstruct content: [], size: 0

  @type t :: %__MODULE__{
          content: [PmNode.t()],
          size: non_neg_integer()
        }

  @doc "Create a new fragment with the given content and size."
  def new(content, size) do
    %__MODULE__{content: content, size: size}
  end

  @doc "An empty fragment. Singleton."
  def empty do
    %__MODULE__{content: [], size: 0}
  end

  @doc "The number of child nodes in this fragment."
  def child_count(%__MODULE__{content: content}), do: length(content)

  @doc """
  Get the child node at the given index. Raise an error when the index is
  out of range.
  """
  def child(%__MODULE__{content: content}, index) do
    if index < 0 or index >= length(content) do
      raise RuntimeError,
            "Index #{index} out of range for fragment with #{length(content)} children"
    end

    Enum.at(content, index)
  end

  @doc "Get the child node at the given index, if it exists."
  def maybe_child(%__MODULE__{content: content}, index) do
    Enum.at(content, index)
  end

  @doc "Get the first child of this fragment, or nil."
  def first_child(%__MODULE__{content: []}), do: nil
  def first_child(%__MODULE__{content: [first | _]}), do: first

  @doc "Get the last child of this fragment, or nil."
  def last_child(%__MODULE__{content: []}), do: nil
  def last_child(%__MODULE__{content: content}), do: List.last(content)

  @doc "Call the given function for each child node, passing the node, its offset, and its index."
  def for_each(%__MODULE__{content: content}, fun) when is_function(fun, 3) do
    do_for_each(content, fun, 0, 0)
  end

  defp do_for_each([], _fun, _offset, _index), do: :ok

  defp do_for_each([child | rest], fun, offset, index) do
    fun.(child, offset, index)
    do_for_each(rest, fun, offset + PmNode.node_size(child), index + 1)
  end

  @doc "Test whether this fragment is equal to another fragment."
  def eq(%__MODULE__{content: content_a}, %__MODULE__{content: content_b}) do
    length(content_a) == length(content_b) and
      Enum.zip(content_a, content_b)
      |> Enum.all?(fn {a, b} -> PmNode.eq(a, b) end)
  end

  @doc """
  Create a fragment from an array of nodes, joining adjacent text nodes
  with the same markup.
  """
  def from_array([]), do: empty()

  def from_array(array) when is_list(array) do
    {joined, size} = do_from_array(array)
    new(joined, size)
  end

  # Faithfully ports the JS fromArray static method.
  # `joined` is nil until we first need to merge text nodes; then it becomes a list.
  defp do_from_array(array) do
    {result, size, _} =
      array
      |> Enum.with_index()
      |> Enum.reduce({nil, 0, nil}, fn {node, i}, {joined, size, _prev} ->
        node_size = PmNode.node_size(node)
        new_size = size + node_size

        prev_node = if i > 0, do: Enum.at(array, i - 1)

        if i > 0 and PmNode.is_text(node) and PmNode.same_markup(prev_node, node) do
          # Need to join with previous
          joined_list =
            case joined do
              nil ->
                # First time: materialize the array up to index i (slice(0, i))
                Enum.take(array, i)

              list ->
                list
            end

          # Merge with the last element in the joined list
          last = List.last(joined_list)
          merged = PmNode.with_text(last, last.text <> node.text)
          updated = List.replace_at(joined_list, length(joined_list) - 1, merged)
          {updated, new_size, node}
        else
          new_joined =
            case joined do
              nil -> nil
              list -> list ++ [node]
            end

          {new_joined, new_size, node}
        end
      end)

    # If we never started joining, use the original array
    {result || array, size}
  end

  @doc """
  Create a fragment from something that can be interpreted as a set of nodes.
  For nil, it returns the empty fragment. For a fragment, the fragment itself
  is returned. For a node or array of nodes, a fragment containing those
  nodes is returned.
  """
  def from(nil), do: empty()
  def from(%__MODULE__{} = fragment), do: fragment

  def from(%PmNode{} = node) do
    from_array([node])
  end

  def from(nodes) when is_list(nodes) do
    from_array(nodes)
  end

  @doc """
  Cut out the sub-fragment between the two given positions.

  Positions are document positions (not child indices). For text nodes,
  positions map to character offsets. For non-text non-leaf nodes,
  positions are adjusted by -1 to account for the opening token.
  """
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
    child_end = pos + PmNode.node_size(child)

    if child_end <= from do
      # This child is entirely before the cut range, skip it
      if child_end < to do
        do_cut(rest, from, to, result, size, child_end)
      else
        # We've passed the cut range
        new(Enum.reverse(result), size)
      end
    else
      # This child overlaps with the cut range
      cut_child =
        if pos < from or child_end > to do
          # Need to partially cut this child
          if PmNode.is_text(child) do
            PmNode.cut(
              child,
              max(0, from - pos),
              min(String.length(child.text), to - pos)
            )
          else
            PmNode.cut(
              child,
              max(0, from - pos - 1),
              min(child.content.size, to - pos - 1)
            )
          end
        else
          child
        end

      new_size = size + PmNode.node_size(cut_child)

      if child_end >= to do
        # This is the last child in the range
        new(Enum.reverse([cut_child | result]), new_size)
      else
        do_cut(rest, from, to, [cut_child | result], new_size, child_end)
      end
    end
  end

  @doc "Cut by child index rather than position."
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
  def replace_child(%__MODULE__{content: content, size: size}, index, node) do
    old = Enum.at(content, index)
    old_size = PmNode.node_size(old)
    new_size = PmNode.node_size(node)
    new_content = List.replace_at(content, index, node)
    new(new_content, size - old_size + new_size)
  end

  @doc "Add a node to the start of the fragment, joining it with the first child if possible."
  def add_to_start(%__MODULE__{} = frag, node) do
    append(from_array([node]), frag)
  end

  @doc "Add a node to the end of the fragment, joining it with the last child if possible."
  def add_to_end(%__MODULE__{} = frag, node) do
    append(frag, from_array([node]))
  end

  @doc """
  Concatenate two fragments, joining adjacent text nodes with the same
  markup if possible.
  """
  def append(%__MODULE__{size: 0}, %__MODULE__{} = other), do: other
  def append(%__MODULE__{} = this, %__MODULE__{size: 0}), do: this

  def append(%__MODULE__{} = this, %__MODULE__{} = other) do
    last = last_child(this)
    first = first_child(other)

    if PmNode.is_text(last) and PmNode.same_markup(last, first) do
      # Join the last child of `this` with the first child of `other`
      merged = PmNode.with_text(last, last.text <> first.text)

      new_content =
        List.replace_at(this.content, length(this.content) - 1, merged) ++
          Enum.drop(other.content, 1)

      new(new_content, this.size + other.size)
    else
      new(this.content ++ other.content, this.size + other.size)
    end
  end

  @doc """
  Find the index and inner offset corresponding to a given document position.
  Returns {index, offset}.
  """
  def find_index(%__MODULE__{}, pos) when pos == 0 do
    {0, pos}
  end

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

  @doc """
  Serialize the content of this fragment to JSON. Returns nil if empty.
  """
  def to_json(%__MODULE__{content: []}), do: nil

  def to_json(%__MODULE__{content: content}) do
    Enum.map(content, &PmNode.to_json/1)
  end
end
