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

  alias ProsemirrorEx.Model.{Node, Fragment, Mark, NodeRange}

  defstruct [:pos, :path, :parent_offset, :depth]

  @doc """
  Resolve the given position in the given document, returning a ResolvedPos.
  """
  def resolve(%Node{} = doc, pos) do
    if pos < 0 or pos > doc.content.size do
      raise ArgumentError, "Position #{pos} out of range"
    end

    path = []
    start = 0
    parent_offset = pos
    resolve_loop(doc, path, start, parent_offset, pos)
  end

  defp resolve_loop(node, path, start, parent_offset, pos) do
    {index, offset} = Fragment.find_index(node.content, parent_offset)
    rem = parent_offset - offset
    path = path ++ [node, index, start + offset]

    if rem == 0 do
      new(pos, path, parent_offset)
    else
      child = Node.child(node, index)

      if Node.is_text(child) do
        new(pos, path, parent_offset)
      else
        resolve_loop(child, path, start + offset + 1, rem - 1, pos)
      end
    end
  end

  defp new(pos, path, parent_offset) do
    %__MODULE__{
      pos: pos,
      path: path,
      parent_offset: parent_offset,
      depth: div(length(path), 3) - 1
    }
  end

  @doc """
  Normalize a depth value. nil becomes self.depth, negative values
  become self.depth + val.
  """
  def resolve_depth(%__MODULE__{depth: depth}, nil), do: depth
  def resolve_depth(%__MODULE__{depth: depth}, val) when val < 0, do: depth + val
  def resolve_depth(%__MODULE__{}, val), do: val

  @doc """
  The ancestor node at the given level. `node(rpos, rpos.depth)` is the
  same as `parent(rpos)`.
  """
  def node(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)
    Enum.at(rpos.path, d * 3)
  end

  @doc """
  The index into the ancestor at the given level.
  """
  def index(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)
    Enum.at(rpos.path, d * 3 + 1)
  end

  @doc """
  The index pointing after this position into the ancestor at the given level.
  """
  def index_after(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)
    index(rpos, d) + if d == rpos.depth and text_offset(rpos) == 0, do: 0, else: 1
  end

  @doc """
  The (absolute) position at the start of the node at the given level.
  """
  def start(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)

    if d == 0 do
      0
    else
      Enum.at(rpos.path, d * 3 - 1) + 1
    end
  end

  @doc """
  The (absolute) position at the end of the node at the given level.
  """
  def end_pos(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)
    start(rpos, d) + __MODULE__.node(rpos, d).content.size
  end

  @doc """
  The (absolute) position directly before the wrapping node at the given level,
  or, when `depth` is `self.depth + 1`, the original position.
  """
  def before(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)

    if d == 0 do
      raise ArgumentError, "There is no position before the top-level node"
    end

    if d == rpos.depth + 1 do
      rpos.pos
    else
      Enum.at(rpos.path, d * 3 - 1)
    end
  end

  @doc """
  The (absolute) position directly after the wrapping node at the given level,
  or the original position when `depth` is `self.depth + 1`.
  """
  def after_pos(%__MODULE__{} = rpos, depth \\ nil) do
    d = resolve_depth(rpos, depth)

    if d == 0 do
      raise ArgumentError, "There is no position after the top-level node"
    end

    if d == rpos.depth + 1 do
      rpos.pos
    else
      Enum.at(rpos.path, d * 3 - 1) + Node.node_size(Enum.at(rpos.path, d * 3))
    end
  end

  @doc """
  When this position points into a text node, this returns the distance
  between the position and the start of the text node. Will be zero for
  positions that point between nodes.
  """
  def text_offset(%__MODULE__{pos: pos, path: path}) do
    pos - List.last(path)
  end

  @doc """
  The parent node that the position points into.
  """
  def parent(%__MODULE__{} = rpos), do: __MODULE__.node(rpos, rpos.depth)

  @doc """
  The root node in which the position was resolved.
  """
  def doc(%__MODULE__{} = rpos), do: __MODULE__.node(rpos, 0)

  @doc """
  Get the node directly after the position, if any. If the position points
  into a text node, only the part of that node after the position is returned.
  """
  def node_after(%__MODULE__{} = rpos) do
    parent_node = parent(rpos)
    idx = index(rpos, rpos.depth)

    if idx == Node.child_count(parent_node) do
      nil
    else
      d_off = rpos.pos - List.last(rpos.path)
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
  def node_before(%__MODULE__{} = rpos) do
    idx = index(rpos, rpos.depth)
    d_off = rpos.pos - List.last(rpos.path)

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
  def pos_at_index(%__MODULE__{} = rpos, child_index, depth \\ nil) do
    d = resolve_depth(rpos, depth)
    node_at_depth = Enum.at(rpos.path, d * 3)
    pos = if d == 0, do: 0, else: Enum.at(rpos.path, d * 3 - 1) + 1

    Enum.reduce(0..(child_index - 1)//1, pos, fn i, acc ->
      acc + Node.node_size(Node.child(node_at_depth, i))
    end)
  end

  @doc """
  Get the marks at this position, factoring in the surrounding marks'
  `inclusive` property.
  """
  def marks(%__MODULE__{} = rpos) do
    parent_node = parent(rpos)
    idx = index(rpos)

    # In an empty parent, return the empty array
    if parent_node.content.size == 0 do
      Mark.none()
    else
      # When inside a text node, just return the text node's marks
      if text_offset(rpos) > 0 do
        Node.child(parent_node, idx).marks || []
      else
        main = Node.maybe_child(parent_node, idx - 1)
        other = Node.maybe_child(parent_node, idx)

        # If there is no node before, swap: make the node after the main reference
        {main, other} = if main == nil, do: {other, main}, else: {main, other}

        if main == nil do
          Mark.none()
        else
          main_marks = main.marks || []

          filter_non_inclusive(main_marks, other)
        end
      end
    end
  end

  defp filter_non_inclusive(mark_list, other) do
    Enum.reduce(mark_list, mark_list, fn mark, acc ->
      if mark in acc do
        spec = mark.type.spec
        inclusive = Map.get(spec, "inclusive", :not_set)

        if inclusive == false do
          other_marks = if other, do: other.marks || [], else: []

          if !Mark.is_in_set(mark, other_marks) do
            Mark.remove_from_set(mark, acc)
          else
            acc
          end
        else
          acc
        end
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
  def same_parent(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.pos - a.parent_offset == b.pos - b.parent_offset
  end

  @doc """
  Return the greater of this and the given position.
  """
  def max(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.pos > a.pos, do: b, else: a
  end

  @doc """
  Return the smaller of this and the given position.
  """
  def min(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.pos < a.pos, do: b, else: a
  end

  @doc """
  String representation of this resolved position (for debugging).
  """
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
