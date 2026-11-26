defmodule ProsemirrorEx.Model.ResolvedPos do
  @moduledoc """
  Represents a resolved position in a ProseMirror document.

  You can resolve a position to get more information about it. Objects of this
  struct represent such a resolved position, providing various pieces of context
  information, and some helper methods.

  Throughout this module, functions that take an optional `depth` parameter
  will interpret nil as `self.depth` and negative numbers as `self.depth + value`.

  Ported from ProseMirror's resolvedpos.ts.
  """

  alias ProsemirrorEx.Model.{Fragment, Mark, Node, NodeRange}

  defstruct [:pos, :path, :parent_offset, :depth]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          path: tuple(),
          parent_offset: non_neg_integer(),
          depth: non_neg_integer()
        }

  @doc """
  Resolve the given position in the given document, returning a ResolvedPos.
  """
  @spec resolve(Node.t(), integer()) :: t()
  def resolve(%Node{} = doc, pos) when is_integer(pos) do
    doc_size = (doc.content || Fragment.empty()).size

    if pos < 0 or pos > doc_size do
      raise ArgumentError, "Position #{pos} out of range"
    end

    resolve_loop(doc, [], 0, pos, pos)
  end

  def resolve(%Node{}, pos) do
    raise ArgumentError, "Position #{inspect(pos)} must be an integer"
  end

  defp resolve_loop(node, rev_path, start, parent_offset, pos) do
    content = node.content || Fragment.empty()
    {index, offset} = Fragment.find_index(content, parent_offset)
    rem = parent_offset - offset
    rev_path = [start + offset, index, node | rev_path]

    if rem == 0 do
      new(pos, rev_path, parent_offset)
    else
      child = Node.child(node, index)

      if Node.is_text(child) do
        new(pos, rev_path, parent_offset)
      else
        resolve_loop(child, rev_path, start + offset + 1, rem - 1, pos)
      end
    end
  end

  defp new(pos, rev_path, parent_offset) do
    path = rev_path |> Enum.reverse() |> List.to_tuple()

    %__MODULE__{
      pos: pos,
      path: path,
      parent_offset: parent_offset,
      depth: div(tuple_size(path), 3) - 1
    }
  end

  @doc """
  Normalize a depth value. nil becomes self.depth, negative values
  become self.depth + val.
  """
  @spec resolve_depth(t(), integer() | nil) :: non_neg_integer()
  def resolve_depth(%__MODULE__{depth: depth}, nil), do: depth

  def resolve_depth(%__MODULE__{depth: depth}, val) when is_integer(val) do
    d = if val < 0, do: depth + val, else: val

    if d < 0 or d > depth + 1 do
      raise ArgumentError, "Depth #{val} out of range for resolved pos with depth #{depth}"
    end

    d
  end

  defp resolve_ancestor_depth(%__MODULE__{depth: depth} = rpos, depth_arg) do
    d = resolve_depth(rpos, depth_arg)

    if d > depth do
      raise ArgumentError, "Depth #{depth_arg} out of range for resolved pos with depth #{depth}"
    end

    d
  end

  @doc """
  The ancestor node at the given level. `node(rpos, rpos.depth)` is the
  same as `parent(rpos)`.
  """
  @spec node(t(), integer() | nil) :: Node.t()
  def node(%__MODULE__{path: path} = rpos, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)
    elem(path, d * 3)
  end

  @doc """
  The index into the ancestor at the given level.
  """
  @spec index(t(), integer() | nil) :: non_neg_integer()
  def index(%__MODULE__{path: path} = rpos, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)
    elem(path, d * 3 + 1)
  end

  @doc """
  The index pointing after this position into the ancestor at the given level.
  """
  @spec index_after(t(), integer() | nil) :: non_neg_integer()
  def index_after(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)
    index(rpos, d) + if(d == rpos.depth and text_offset(rpos) == 0, do: 0, else: 1)
  end

  @doc """
  The (absolute) position at the start of the node at the given level.
  """
  @spec start(t(), integer() | nil) :: non_neg_integer()
  def start(%__MODULE__{path: path} = rpos, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)

    if d == 0 do
      0
    else
      elem(path, d * 3 - 1) + 1
    end
  end

  @doc """
  The (absolute) position at the end of the node at the given level.
  """
  @spec end_pos(t(), integer() | nil) :: non_neg_integer()
  def end_pos(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)
    node_at_d = __MODULE__.node(rpos, d)
    size = (node_at_d.content || Fragment.empty()).size
    start(rpos, d) + size
  end

  @doc """
  The (absolute) position directly before the wrapping node at the given level,
  or, when `depth` is `self.depth + 1`, the original position.
  """
  @spec before(t(), integer() | nil) :: non_neg_integer()
  def before(%__MODULE__{path: path} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)

    if d == 0 do
      raise ArgumentError, "There is no position before the top-level node"
    end

    if d == rpos.depth + 1 do
      rpos.pos
    else
      elem(path, d * 3 - 1)
    end
  end

  @doc """
  The (absolute) position directly after the wrapping node at the given level,
  or the original position when `depth` is `self.depth + 1`.
  """
  @spec after_pos(t(), integer() | nil) :: non_neg_integer()
  def after_pos(%__MODULE__{path: path} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)

    if d == 0 do
      raise ArgumentError, "There is no position after the top-level node"
    end

    if d == rpos.depth + 1 do
      rpos.pos
    else
      elem(path, d * 3 - 1) + Node.node_size(elem(path, d * 3))
    end
  end

  @doc """
  When this position points into a text node, this returns the distance
  between the position and the start of the text node. Will be zero for
  positions that point between nodes.
  """
  @spec text_offset(t()) :: non_neg_integer()
  def text_offset(%__MODULE__{pos: pos, path: path}) do
    pos - elem(path, tuple_size(path) - 1)
  end

  @doc """
  The parent node that the position points into.
  """
  @spec parent(t()) :: Node.t()
  def parent(%__MODULE__{} = rpos), do: __MODULE__.node(rpos, rpos.depth)

  @doc """
  The root node in which the position was resolved.
  """
  @spec doc(t()) :: Node.t()
  def doc(%__MODULE__{} = rpos), do: __MODULE__.node(rpos, 0)

  @doc """
  Get the node directly after the position, if any. If the position points
  into a text node, only the part of that node after the position is returned.
  """
  @spec node_after(t()) :: Node.t() | nil
  def node_after(%__MODULE__{} = rpos) do
    parent_node = parent(rpos)
    idx = index(rpos, rpos.depth)

    if idx == Node.child_count(parent_node) do
      nil
    else
      d_off = text_offset(rpos)
      child = Node.child(parent_node, idx)

      if d_off > 0 do
        Node.cut(child, d_off)
      else
        child
      end
    end
  end

  @doc """
  Get the node directly before the position, if any. If the position points
  into a text node, only the part of that node before the position is returned.
  """
  @spec node_before(t()) :: Node.t() | nil
  def node_before(%__MODULE__{} = rpos) do
    idx = index(rpos, rpos.depth)
    d_off = text_offset(rpos)

    if d_off > 0 do
      Node.cut(Node.child(parent(rpos), idx), 0, d_off)
    else
      if idx == 0 do
        nil
      else
        Node.child(parent(rpos), idx - 1)
      end
    end
  end

  @doc """
  Get the position at the given index in the parent node at the given depth
  (which defaults to `self.depth`).
  """
  @spec pos_at_index(t(), non_neg_integer(), integer() | nil) :: non_neg_integer()
  def pos_at_index(%__MODULE__{path: path} = rpos, child_index, depth \\ nil) do
    d = resolve_ancestor_depth(rpos, depth)
    node_at_depth = elem(path, d * 3)
    pos = if d == 0, do: 0, else: elem(path, d * 3 - 1) + 1
    children = (node_at_depth.content || Fragment.empty()).content
    sum_child_sizes(children, child_index, pos)
  end

  defp sum_child_sizes(_children, count, pos) when count <= 0, do: pos
  defp sum_child_sizes([], _count, pos), do: pos

  defp sum_child_sizes([child | rest], count, pos) do
    sum_child_sizes(rest, count - 1, pos + Node.node_size(child))
  end

  @doc """
  Get the marks at this position, factoring in the surrounding marks'
  `inclusive` property.
  """
  @spec marks(t()) :: [Mark.t()]
  def marks(%__MODULE__{} = rpos) do
    parent_node = parent(rpos)
    idx = index(rpos)
    parent_size = (parent_node.content || Fragment.empty()).size

    if parent_size == 0 do
      Mark.none()
    else
      if text_offset(rpos) > 0 do
        Node.child(parent_node, idx).marks || []
      else
        main = Node.maybe_child(parent_node, idx - 1)
        other = Node.maybe_child(parent_node, idx)
        {main, other} = if main == nil, do: {other, main}, else: {main, other}

        if main == nil do
          Mark.none()
        else
          filter_non_inclusive(main.marks || [], other)
        end
      end
    end
  end

  defp filter_non_inclusive(mark_list, other) do
    other_marks = if other, do: other.marks || [], else: []

    Enum.reduce(mark_list, mark_list, fn mark, acc ->
      spec = mark.type.spec || %{}
      inclusive = Map.get(spec, "inclusive", :not_set)

      if inclusive == false and !Mark.is_in_set(mark, other_marks) do
        Mark.remove_from_set(mark, acc)
      else
        acc
      end
    end)
  end

  @doc """
  Get the marks after the current position, if any, except those that are
  non-inclusive and not present at position `end_rpos`. This is mostly useful
  for getting the set of marks to preserve after a deletion.
  """
  @spec marks_across(t(), t()) :: [Mark.t()] | nil
  def marks_across(%__MODULE__{} = rpos, %__MODULE__{} = end_rpos) do
    after_node = Node.maybe_child(parent(rpos), index(rpos))

    if after_node == nil or !Node.is_inline(after_node) do
      nil
    else
      mark_list = after_node.marks || []
      next = Node.maybe_child(parent(end_rpos), index(end_rpos))
      filter_non_inclusive(mark_list, next)
    end
  end

  @doc """
  The depth up to which this position and the given (non-resolved) position
  share the same parent nodes.
  """
  @spec shared_depth(t(), integer()) :: non_neg_integer()
  def shared_depth(%__MODULE__{} = rpos, pos) do
    do_shared_depth(rpos, pos, rpos.depth)
  end

  defp do_shared_depth(%__MODULE__{} = rpos, pos, depth) when depth > 0 do
    if start(rpos, depth) <= pos and end_pos(rpos, depth) >= pos do
      depth
    else
      do_shared_depth(rpos, pos, depth - 1)
    end
  end

  defp do_shared_depth(_rpos, _pos, _depth), do: 0

  @doc """
  Returns a range based on the place where this position and the given
  position diverge around block content.
  """
  @spec block_range(t(), t() | nil, (Node.t() -> boolean()) | nil) :: NodeRange.t() | nil
  def block_range(from, to \\ nil, pred \\ nil)

  def block_range(%__MODULE__{} = from, nil, pred) do
    block_range(from, from, pred)
  end

  def block_range(%__MODULE__{} = from, %__MODULE__{} = to, pred) do
    if to.pos < from.pos do
      block_range(to, from, pred)
    else
      d_start =
        if Node.inline_content(parent(from)) or from.pos == to.pos do
          from.depth - 1
        else
          from.depth
        end

      find_block_range(from, to, pred, d_start)
    end
  end

  defp find_block_range(_from, _to, _pred, d) when d < 0, do: nil

  defp find_block_range(from, to, pred, d) do
    if to.pos <= end_pos(from, d) and (pred == nil or pred.(__MODULE__.node(from, d))) do
      %NodeRange{from: from, to: to, depth: d}
    else
      find_block_range(from, to, pred, d - 1)
    end
  end

  @doc """
  Query whether the given position shares the same parent node.
  """
  @spec same_parent(t(), t()) :: boolean()
  def same_parent(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.pos - a.parent_offset == b.pos - b.parent_offset
  end

  @doc """
  Return the greater of this and the given position.
  """
  @spec max(t(), t()) :: t()
  def max(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.pos > a.pos, do: b, else: a
  end

  @doc """
  Return the smaller of this and the given position.
  """
  @spec min(t(), t()) :: t()
  def min(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.pos < a.pos, do: b, else: a
  end

  @doc """
  String representation of this resolved position (for debugging).
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = rpos) do
    str =
      Enum.reduce(1..rpos.depth//1, "", fn i, acc ->
        sep = if acc == "", do: "", else: "/"
        node_at_i = __MODULE__.node(rpos, i)
        acc <> sep <> node_at_i.type.name <> "_" <> Integer.to_string(index(rpos, i - 1))
      end)

    str <> ":" <> Integer.to_string(rpos.parent_offset)
  end
end
