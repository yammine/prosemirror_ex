defmodule ProsemirrorEx.Transform.Mark do
  @moduledoc """
  Helper functions for adding and removing marks via Transform steps.

  Ports `addMark`, `removeMark`, and `clearIncompatible` from
  prosemirror-transform/src/mark.ts.
  """

  alias ProsemirrorEx.Model.{
    Node,
    Mark,
    MarkType,
    NodeType,
    Slice,
    Fragment,
    ContentMatch,
    Utf16
  }

  alias ProsemirrorEx.Transform.{
    Transform,
    AddMarkStep,
    RemoveMarkStep,
    ReplaceStep
  }

  @type transform_map :: %{
          required(:doc) => Node.t(),
          required(:steps) => [term()],
          required(:docs) => [Node.t()],
          required(:mapping) => ProsemirrorEx.Transform.Mapping.t(),
          optional(atom()) => term()
        }

  @doc """
  Add the given mark to inline content between `from` and `to`.

  Walks the document, collecting RemoveMarkStep entries for any marks that
  the new mark excludes, and AddMarkStep entries for ranges that need the
  mark. Adjacent ranges are coalesced into a single step.
  """
  @spec add_mark(transform_map(), integer(), integer(), Mark.t()) :: transform_map()
  def add_mark(
        %{doc: doc, steps: _steps, docs: _docs, mapping: _mapping} = tr,
        from,
        to,
        %Mark{} = mark
      ) do
    {removed, added} = collect_add_mark_steps(doc, from, to, mark)

    tr =
      Enum.reduce(removed, tr, fn step_struct, acc ->
        Transform.step(acc, step_struct)
      end)

    Enum.reduce(added, tr, fn step_struct, acc ->
      Transform.step(acc, step_struct)
    end)
  end

  defp collect_add_mark_steps(doc, from, to, mark) do
    {removed_rev, added_rev} =
      Node.fold_nodes_between(
        doc,
        from,
        to,
        fn node, pos, parent, _index, {rem_acc, add_acc} = acc ->
          if not Node.is_inline(node) do
            acc
          else
            marks = node.marks || []

            if not Mark.is_in_set(mark, marks) and
                 NodeType.allows_mark_type(parent.type, mark.type) do
              start = max(pos, from)
              end_pos = min(pos + Node.node_size(node), to)
              new_set = Mark.add_to_set(mark, marks)

              rem_acc =
                Enum.reduce(marks, rem_acc, fn existing_mark, r_acc ->
                  if not Mark.is_in_set(existing_mark, new_set) do
                    case r_acc do
                      [%{to: ^start, mark: removing_mark} = removing | rest] ->
                        if Mark.eq(removing_mark, existing_mark) do
                          [%{removing | to: end_pos} | rest]
                        else
                          [RemoveMarkStep.new(start, end_pos, existing_mark) | r_acc]
                        end

                      _ ->
                        [RemoveMarkStep.new(start, end_pos, existing_mark) | r_acc]
                    end
                  else
                    r_acc
                  end
                end)

              add_acc =
                case add_acc do
                  [%{to: ^start} = adding | rest] ->
                    [%{adding | to: end_pos} | rest]

                  _ ->
                    [AddMarkStep.new(start, end_pos, mark) | add_acc]
                end

              {:skip, {rem_acc, add_acc}}
            else
              {:skip, acc}
            end
          end
        end,
        {[], []}
      )

    {Enum.reverse(removed_rev), Enum.reverse(added_rev)}
  end

  @doc """
  Remove marks from inline nodes between `from` and `to`.

  When `mark` is a Mark, remove precisely that mark. When it is a MarkType,
  remove all marks of that type. When it is nil, remove all marks.
  """
  @spec remove_mark(transform_map(), integer(), integer(), Mark.t() | MarkType.t() | nil) ::
          transform_map()
  def remove_mark(
        %{doc: doc, steps: _steps, docs: _docs, mapping: _mapping} = tr,
        from,
        to,
        mark \\ nil
      ) do
    matched = collect_remove_mark_steps(doc, from, to, mark)

    Enum.reduce(matched, tr, fn m, acc ->
      Transform.step(acc, RemoveMarkStep.new(m.from, m.to, m.style))
    end)
  end

  defp collect_remove_mark_steps(doc, from, to, mark) do
    {active, finished, _seq} =
      Node.fold_nodes_between(
        doc,
        from,
        to,
        fn node, pos, _parent, _index, {active, finished, seq} ->
          if not Node.is_inline(node) do
            {active, finished, seq}
          else
            marks = node.marks || []

            case determine_marks_to_remove(mark, marks) do
              nil ->
                {:skip, {[], Enum.reverse(active, finished), seq}}

              to_remove ->
                start = max(pos, from)
                end_pos = min(pos + Node.node_size(node), to)

                {next_active, remaining_active, next_seq} =
                  Enum.reduce(to_remove, {[], active, seq}, fn style,
                                                               {na_acc, rem_active, cur_seq} ->
                    case pop_matching_active(rem_active, style, []) do
                      {:found, entry, rest_active} ->
                        {[%{entry | to: end_pos} | na_acc], rest_active, cur_seq}

                      {:not_found, rest_active} ->
                        new_entry = %{style: style, from: start, to: end_pos, seq: cur_seq}
                        {[new_entry | na_acc], rest_active, cur_seq + 1}
                    end
                  end)

                next_finished = Enum.reverse(remaining_active, finished)
                {:skip, {Enum.reverse(next_active), next_finished, next_seq}}
            end
          end
        end,
        {[], [], 0}
      )

    Enum.sort_by(active ++ finished, & &1.seq)
  end

  defp pop_matching_active([], _style, rev_rest), do: {:not_found, Enum.reverse(rev_rest)}

  defp pop_matching_active([entry | rest], style, rev_rest) do
    if Mark.eq(style, entry.style) do
      {:found, entry, Enum.reverse(rev_rest, rest)}
    else
      pop_matching_active(rest, style, [entry | rev_rest])
    end
  end

  defp determine_marks_to_remove(%MarkType{} = mark_type, marks) do
    case Enum.filter(marks, &(&1.type.name == mark_type.name)) do
      [] -> nil
      found -> found
    end
  end

  defp determine_marks_to_remove(%Mark{} = mark, marks) do
    if Mark.is_in_set(mark, marks), do: [mark], else: nil
  end

  defp determine_marks_to_remove(nil, marks) do
    if marks == [], do: nil, else: marks
  end

  defp determine_marks_to_remove(other, _marks) do
    raise ArgumentError,
          "Expected a Mark, MarkType, or nil in remove_mark, got: #{inspect(other)}"
  end

  @doc """
  Removes all marks and nodes from the content of the node at `pos` that
  don't match the given new parent node type. Optionally accepts a starting
  content match and a flag for clearing newlines.
  """
  @spec clear_incompatible(
          transform_map(),
          integer(),
          NodeType.t(),
          ContentMatch.t() | nil,
          boolean()
        ) :: transform_map()
  def clear_incompatible(
        %{doc: doc} = tr,
        pos,
        %NodeType{} = parent_type,
        match \\ nil,
        clear_newlines \\ true
      ) do
    match = match || parent_type.content_match
    node = Node.node_at(doc, pos)

    if node == nil do
      raise ArgumentError, "No node at position #{pos}"
    end

    children = if node.content, do: node.content.content, else: []

    {tr, repl_steps_rev, final_match, final_cur} =
      Enum.reduce(children, {tr, [], match, pos + 1}, fn child,
                                                         {tr_acc, repl_acc, match_acc, cur} ->
        end_pos = cur + Node.node_size(child)
        allowed = ContentMatch.match_type(match_acc, child.type)

        if allowed == nil do
          {tr_acc, [ReplaceStep.new(cur, end_pos, Slice.empty()) | repl_acc], match_acc, end_pos}
        else
          new_match = allowed
          child_marks = child.marks || []

          tr_acc =
            Enum.reduce(child_marks, tr_acc, fn child_mark, t ->
              if not NodeType.allows_mark_type(parent_type, child_mark.type) do
                Transform.step(t, RemoveMarkStep.new(cur, end_pos, child_mark))
              else
                t
              end
            end)

          repl_acc =
            if clear_newlines and Node.is_text(child) and
                 NodeType.whitespace(parent_type) != "pre" do
              clear_text_newlines(
                child.text,
                cur,
                parent_type,
                child_marks,
                repl_acc
              )
            else
              repl_acc
            end

          {tr_acc, repl_acc, new_match, end_pos}
        end
      end)

    tr =
      if not final_match.valid_end do
        fill = ContentMatch.fill_before(final_match, Fragment.empty(), true)

        if fill do
          Transform.step(tr, ReplaceStep.new(final_cur, final_cur, Slice.new(fill, 0, 0)))
        else
          tr
        end
      else
        tr
      end

    # `repl_steps_rev` was built in forward position order by prepending,
    # so iterating it directly applies steps from end to start.
    Enum.reduce(repl_steps_rev, tr, fn step_struct, acc ->
      Transform.step(acc, step_struct)
    end)
  end

  defp clear_text_newlines(text, cur, parent_type, child_marks, repl_acc) do
    case Regex.scan(~r/\r?\n|\r/, text, return: :index) do
      [] ->
        repl_acc

      matches ->
        allowed_marks = NodeType.allowed_marks(parent_type, child_marks)

        slice =
          Slice.new(
            Fragment.from(
              ProsemirrorEx.Model.Schema.text(
                parent_type.schema,
                " ",
                allowed_marks
              )
            ),
            0,
            0
          )

        {next_repl_acc, _prev_byte, _prev_u16} =
          Enum.reduce(matches, {repl_acc, 0, 0}, fn [{match_start, match_len}],
                                                    {acc, prev_byte, prev_u16} ->
            chunk = binary_part(text, prev_byte, match_start - prev_byte)
            u16_start = prev_u16 + Utf16.byte_offset_to_utf16(chunk, byte_size(chunk))

            step = ReplaceStep.new(cur + u16_start, cur + u16_start + match_len, slice)
            {[step | acc], match_start + match_len, u16_start + match_len}
          end)

        next_repl_acc
    end
  end
end
