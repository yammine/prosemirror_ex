defmodule ProsemirrorEx.Model.Replace do
  @moduledoc """
  The replace algorithm for ProseMirror documents.

  Ported from ProseMirror's replace.ts replace/replaceOuter/replaceThreeWay
  and related helper functions.
  """

  alias ProsemirrorEx.Model.{
    Fragment,
    Node,
    ResolvedPos,
    ReplaceError,
    Slice,
    NodeType
  }

  @doc """
  Replace the content between `$from` and `$to` with the given slice.
  """
  def replace(%ResolvedPos{} = from_pos, %ResolvedPos{} = to_pos, %Slice{} = slice) do
    if slice.open_start > from_pos.depth do
      raise ReplaceError, "Inserted content deeper than insertion position"
    end

    if from_pos.depth - slice.open_start != to_pos.depth - slice.open_end do
      raise ReplaceError, "Inconsistent open depths"
    end

    replace_outer(from_pos, to_pos, slice, 0)
  end

  # ── replaceOuter ──────────────────────────────────────────────────

  defp replace_outer(from_pos, to_pos, slice, depth) do
    index = ResolvedPos.index(from_pos, depth)
    node = ResolvedPos.node(from_pos, depth)

    if index == ResolvedPos.index(to_pos, depth) and depth < from_pos.depth - slice.open_start do
      inner = replace_outer(from_pos, to_pos, slice, depth + 1)
      Node.copy(node, Fragment.replace_child(node.content, index, inner))
    else
      if slice.content.size == 0 do
        close(node, replace_two_way(from_pos, to_pos, depth))
      else
        if slice.open_start == 0 and slice.open_end == 0 and
             from_pos.depth == depth and to_pos.depth == depth do
          # Simple, flat case
          parent = ResolvedPos.parent(from_pos)
          content = parent.content

          close(
            parent,
            content
            |> Fragment.cut(0, from_pos.parent_offset)
            |> Fragment.append(slice.content)
            |> Fragment.append(Fragment.cut(content, to_pos.parent_offset))
          )
        else
          {start_pos, end_pos} = prepare_slice_for_replace(slice, from_pos)
          close(node, replace_three_way(from_pos, start_pos, end_pos, to_pos, depth))
        end
      end
    end
  end

  # ── checkJoin ────────────────────────────────────────────────────

  defp check_join(main, sub) do
    unless NodeType.compatible_content(sub.type, main.type) do
      raise ReplaceError, "Cannot join #{sub.type.name} onto #{main.type.name}"
    end
  end

  # ── joinable ─────────────────────────────────────────────────────

  defp joinable(before_pos, after_pos, depth) do
    node = ResolvedPos.node(before_pos, depth)
    check_join(node, ResolvedPos.node(after_pos, depth))
    node
  end

  # ── addNode ──────────────────────────────────────────────────────

  defp add_node(child, target) do
    case target do
      [] ->
        [child]

      _ ->
        last = List.last(target)

        if Node.is_text(child) and Node.same_markup(child, last) do
          merged = Node.with_text(last, last.text <> child.text)
          List.replace_at(target, length(target) - 1, merged)
        else
          target ++ [child]
        end
    end
  end

  # ── addRange ─────────────────────────────────────────────────────

  defp add_range(start_pos, end_pos, depth, target) do
    node = ResolvedPos.node(end_pos || start_pos, depth)
    start_index = 0
    end_index = if end_pos, do: ResolvedPos.index(end_pos, depth), else: Node.child_count(node)

    {start_index, target} =
      if start_pos do
        si = ResolvedPos.index(start_pos, depth)

        if ResolvedPos.resolve_depth(start_pos, depth) < start_pos.depth do
          # $start.depth > depth
          {si + 1, target}
        else
          text_off = ResolvedPos.text_offset(start_pos)

          if text_off > 0 do
            node_after = ResolvedPos.node_after(start_pos)
            {si + 1, add_node(node_after, target)}
          else
            {si, target}
          end
        end
      else
        {start_index, target}
      end

    target =
      Enum.reduce(start_index..(end_index - 1)//1, target, fn i, acc ->
        add_node(Node.child(node, i), acc)
      end)

    target =
      if end_pos && ResolvedPos.resolve_depth(end_pos, depth) == end_pos.depth &&
           ResolvedPos.text_offset(end_pos) > 0 do
        add_node(ResolvedPos.node_before(end_pos), target)
      else
        target
      end

    target
  end

  # ── close ────────────────────────────────────────────────────────

  defp close(node, content) do
    try do
      NodeType.check_content(node.type, content)
    rescue
      e in RuntimeError ->
        raise ReplaceError, e.message
    end

    Node.copy(node, content)
  end

  # ── replaceThreeWay ──────────────────────────────────────────────

  defp replace_three_way(from_pos, start_pos, end_pos, to_pos, depth) do
    open_start =
      if from_pos.depth > depth do
        joinable(from_pos, start_pos, depth + 1)
      else
        nil
      end

    open_end =
      if to_pos.depth > depth do
        joinable(end_pos, to_pos, depth + 1)
      else
        nil
      end

    content = []
    content = add_range(nil, from_pos, depth, content)

    content =
      if open_start && open_end &&
           ResolvedPos.index(start_pos, depth) == ResolvedPos.index(end_pos, depth) do
        check_join(open_start, open_end)

        add_node(
          close(open_start, replace_three_way(from_pos, start_pos, end_pos, to_pos, depth + 1)),
          content
        )
      else
        content =
          if open_start do
            add_node(
              close(open_start, replace_two_way(from_pos, start_pos, depth + 1)),
              content
            )
          else
            content
          end

        content = add_range(start_pos, end_pos, depth, content)

        content =
          if open_end do
            add_node(
              close(open_end, replace_two_way(end_pos, to_pos, depth + 1)),
              content
            )
          else
            content
          end

        content
      end

    content = add_range(to_pos, nil, depth, content)

    Fragment.from(content)
  end

  # ── replaceTwoWay ───────────────────────────────────────────────

  defp replace_two_way(from_pos, to_pos, depth) do
    content = []
    content = add_range(nil, from_pos, depth, content)

    content =
      if from_pos.depth > depth do
        type = joinable(from_pos, to_pos, depth + 1)
        add_node(close(type, replace_two_way(from_pos, to_pos, depth + 1)), content)
      else
        content
      end

    content = add_range(to_pos, nil, depth, content)

    Fragment.from(content)
  end

  # ── prepareSliceForReplace ─────────────────────────────────────

  defp prepare_slice_for_replace(%Slice{} = slice, %ResolvedPos{} = along) do
    extra = along.depth - slice.open_start
    parent = ResolvedPos.node(along, extra)
    node = Node.copy(parent, slice.content)

    node =
      Enum.reduce((extra - 1)..0//-1, node, fn i, acc ->
        Node.copy(ResolvedPos.node(along, i), Fragment.from(acc))
      end)

    start_pos = ResolvedPos.resolve(node, slice.open_start + extra)
    end_pos = ResolvedPos.resolve(node, node.content.size - slice.open_end - extra)

    {start_pos, end_pos}
  end
end
