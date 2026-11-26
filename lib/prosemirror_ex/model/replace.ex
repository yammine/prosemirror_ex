defmodule ProsemirrorEx.Model.Replace do
  @moduledoc """
  The replace algorithm for ProseMirror documents.

  Ported from ProseMirror's replace.ts replace/replaceOuter/replaceThreeWay
  and related helper functions.
  """

  alias ProsemirrorEx.Model.{
    Fragment,
    Node,
    NodeType,
    ReplaceError,
    ResolvedPos,
    Slice
  }

  @doc """
  Replace the content between `$from` and `$to` with the given slice.
  """
  @spec replace(ResolvedPos.t(), ResolvedPos.t(), Slice.t()) :: Node.t()
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

  # ── addNode (reversed accumulator) ───────────────────────────────

  defp add_node(child, [last | rest] = rev_target) do
    if Node.is_text(child) and Node.same_markup(child, last) do
      merged_size = Node.node_size(last) + Node.node_size(child)
      merged = Node.with_text_and_size(last, last.text <> child.text, merged_size)
      [merged | rest]
    else
      [child | rev_target]
    end
  end

  defp add_node(child, []), do: [child]

  # ── addRange (reversed accumulator) ──────────────────────────────

  defp add_range(start_pos, end_pos, depth, rev_target) do
    node = ResolvedPos.node(end_pos || start_pos, depth)
    end_index = if end_pos, do: ResolvedPos.index(end_pos, depth), else: Node.child_count(node)

    {start_index, rev_target} =
      if start_pos do
        si = ResolvedPos.index(start_pos, depth)

        if ResolvedPos.resolve_depth(start_pos, depth) < start_pos.depth do
          {si + 1, rev_target}
        else
          if ResolvedPos.text_offset(start_pos) > 0 do
            {si + 1, add_node(ResolvedPos.node_after(start_pos), rev_target)}
          else
            {si, rev_target}
          end
        end
      else
        {0, rev_target}
      end

    count = end_index - start_index

    rev_target =
      if count > 0 do
        children = (node.content || Fragment.empty()).content
        add_children_slice(Enum.drop(children, start_index), count, rev_target)
      else
        rev_target
      end

    if end_pos && ResolvedPos.resolve_depth(end_pos, depth) == end_pos.depth &&
         ResolvedPos.text_offset(end_pos) > 0 do
      add_node(ResolvedPos.node_before(end_pos), rev_target)
    else
      rev_target
    end
  end

  defp add_children_slice(_children, 0, rev_target), do: rev_target
  defp add_children_slice([], _count, rev_target), do: rev_target

  defp add_children_slice([child | rest], count, rev_target) do
    add_children_slice(rest, count - 1, add_node(child, rev_target))
  end

  defp finalize_fragment(rev_nodes), do: do_finalize_fragment(rev_nodes, [], 0)

  defp do_finalize_fragment([], acc, size), do: Fragment.new(acc, size)

  defp do_finalize_fragment([node | rest], acc, size) do
    do_finalize_fragment(rest, [node | acc], size + Node.node_size(node))
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

    rev_content = add_range(nil, from_pos, depth, [])

    rev_content =
      if open_start && open_end &&
           ResolvedPos.index(start_pos, depth) == ResolvedPos.index(end_pos, depth) do
        check_join(open_start, open_end)

        add_node(
          close(open_start, replace_three_way(from_pos, start_pos, end_pos, to_pos, depth + 1)),
          rev_content
        )
      else
        rev_content =
          if open_start do
            add_node(
              close(open_start, replace_two_way(from_pos, start_pos, depth + 1)),
              rev_content
            )
          else
            rev_content
          end

        rev_content = add_range(start_pos, end_pos, depth, rev_content)

        if open_end do
          add_node(
            close(open_end, replace_two_way(end_pos, to_pos, depth + 1)),
            rev_content
          )
        else
          rev_content
        end
      end

    rev_content = add_range(to_pos, nil, depth, rev_content)

    finalize_fragment(rev_content)
  end

  # ── replaceTwoWay ───────────────────────────────────────────────

  defp replace_two_way(from_pos, to_pos, depth) do
    rev_content = add_range(nil, from_pos, depth, [])

    rev_content =
      if from_pos.depth > depth do
        type = joinable(from_pos, to_pos, depth + 1)
        add_node(close(type, replace_two_way(from_pos, to_pos, depth + 1)), rev_content)
      else
        rev_content
      end

    rev_content = add_range(to_pos, nil, depth, rev_content)

    finalize_fragment(rev_content)
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
