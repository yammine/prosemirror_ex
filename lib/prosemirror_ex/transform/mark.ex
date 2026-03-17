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
    ContentMatch
  }

  alias ProsemirrorEx.Transform.{
    Transform,
    AddMarkStep,
    RemoveMarkStep,
    ReplaceStep
  }

  @doc """
  Add the given mark to inline content between `from` and `to`.

  Walks the document, collecting RemoveMarkStep entries for any marks that
  the new mark excludes, and AddMarkStep entries for ranges that need the
  mark. Adjacent ranges are coalesced into a single step.
  """
  def add_mark(
        %{doc: doc, steps: _steps, docs: _docs, mapping: _mapping} = tr,
        from,
        to,
        mark
      ) do
    # Accumulate removed and added steps by walking the document
    {removed, added} = collect_add_mark_steps(doc, from, to, mark)

    # Apply all steps: first removals, then additions
    Enum.reduce(removed ++ added, tr, fn step_struct, acc ->
      Transform.step(acc, step_struct)
    end)
  end

  defp collect_add_mark_steps(doc, from, to, mark) do
    # Use process dictionary to accumulate mutable state during callback
    Process.put(:_pm_add_mark_removed, [])
    Process.put(:_pm_add_mark_added, [])
    Process.put(:_pm_add_mark_removing, nil)
    Process.put(:_pm_add_mark_adding, nil)

    Node.nodes_between(doc, from, to, fn node, pos, parent, _index ->
      if not Node.is_inline(node) do
        # Return non-false to descend into children
        nil
      else
        marks = node.marks || []

        if not Mark.is_in_set(mark, marks) and
             NodeType.allows_mark_type(parent.type, mark.type) do
          start = max(pos, from)
          end_pos = min(pos + Node.node_size(node), to)
          new_set = Mark.add_to_set(mark, marks)

          # Check for marks that need to be removed (excluded by the new mark)
          Enum.each(marks, fn existing_mark ->
            if not Mark.is_in_set(existing_mark, new_set) do
              removing = Process.get(:_pm_add_mark_removing)

              if removing != nil and removing.to == start and
                   Mark.eq(removing.mark, existing_mark) do
                # Extend the existing removing step
                extended = %{removing | to: end_pos}
                Process.put(:_pm_add_mark_removing, extended)
                # Update it in the removed list too
                removed = Process.get(:_pm_add_mark_removed)
                updated = List.replace_at(removed, length(removed) - 1, extended)
                Process.put(:_pm_add_mark_removed, updated)
              else
                new_step = RemoveMarkStep.new(start, end_pos, existing_mark)
                Process.put(:_pm_add_mark_removing, new_step)

                Process.put(
                  :_pm_add_mark_removed,
                  Process.get(:_pm_add_mark_removed) ++ [new_step]
                )
              end
            end
          end)

          # Add the mark
          adding = Process.get(:_pm_add_mark_adding)

          if adding != nil and adding.to == start do
            # Extend the existing adding step
            extended = %{adding | to: end_pos}
            Process.put(:_pm_add_mark_adding, extended)
            added = Process.get(:_pm_add_mark_added)
            updated = List.replace_at(added, length(added) - 1, extended)
            Process.put(:_pm_add_mark_added, updated)
          else
            new_step = AddMarkStep.new(start, end_pos, mark)
            Process.put(:_pm_add_mark_adding, new_step)

            Process.put(
              :_pm_add_mark_added,
              Process.get(:_pm_add_mark_added) ++ [new_step]
            )
          end
        end

        nil
      end
    end)

    removed = Process.get(:_pm_add_mark_removed)
    added = Process.get(:_pm_add_mark_added)

    # Clean up process dictionary
    Process.delete(:_pm_add_mark_removed)
    Process.delete(:_pm_add_mark_added)
    Process.delete(:_pm_add_mark_removing)
    Process.delete(:_pm_add_mark_adding)

    {removed, added}
  end

  @doc """
  Remove marks from inline nodes between `from` and `to`.

  When `mark` is a Mark, remove precisely that mark. When it is a MarkType,
  remove all marks of that type. When it is nil, remove all marks.
  """
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
    Process.put(:_pm_rem_mark_matched, [])
    Process.put(:_pm_rem_mark_step, 0)

    Node.nodes_between(doc, from, to, fn node, pos, _parent, _index ->
      if not Node.is_inline(node) do
        nil
      else
        step_num = Process.get(:_pm_rem_mark_step) + 1
        Process.put(:_pm_rem_mark_step, step_num)

        marks = node.marks || []

        to_remove = determine_marks_to_remove(mark, marks)

        if to_remove != nil and length(to_remove) > 0 do
          end_pos = min(pos + Node.node_size(node), to)

          Enum.each(to_remove, fn style ->
            matched = Process.get(:_pm_rem_mark_matched)

            found_index =
              Enum.find_index(matched, fn m ->
                m.step == step_num - 1 and Mark.eq(style, m.style)
              end)

            if found_index != nil do
              found = Enum.at(matched, found_index)
              updated = %{found | to: end_pos, step: step_num}
              matched = List.replace_at(matched, found_index, updated)
              Process.put(:_pm_rem_mark_matched, matched)
            else
              Process.put(
                :_pm_rem_mark_matched,
                matched ++ [%{style: style, from: max(pos, from), to: end_pos, step: step_num}]
              )
            end
          end)
        end

        nil
      end
    end)

    result = Process.get(:_pm_rem_mark_matched)

    Process.delete(:_pm_rem_mark_matched)
    Process.delete(:_pm_rem_mark_step)

    result
  end

  defp determine_marks_to_remove(mark, marks) do
    cond do
      # MarkType — remove all marks of that type
      is_mark_type?(mark) ->
        collect_marks_of_type(mark, marks)

      # Mark struct — remove that specific mark
      is_mark?(mark) ->
        if Mark.is_in_set(mark, marks), do: [mark], else: nil

      # nil — remove all marks
      true ->
        if marks == [], do: nil, else: marks
    end
  end

  defp collect_marks_of_type(mark_type, marks) do
    collect_marks_of_type_acc(mark_type, marks, [])
  end

  defp collect_marks_of_type_acc(mark_type, marks, acc) do
    found = MarkType.is_in_set(mark_type, marks)

    if found do
      remaining = Mark.remove_from_set(found, marks)
      collect_marks_of_type_acc(mark_type, remaining, acc ++ [found])
    else
      if acc == [], do: nil, else: acc
    end
  end

  defp is_mark_type?(%MarkType{}), do: true
  defp is_mark_type?(_), do: false

  defp is_mark?(%Mark{}), do: true
  defp is_mark?(_), do: false

  @doc """
  Removes all marks and nodes from the content of the node at `pos` that
  don't match the given new parent node type. Optionally accepts a starting
  content match and a flag for clearing newlines.
  """
  def clear_incompatible(
        %{doc: doc} = tr,
        pos,
        parent_type,
        match \\ nil,
        clear_newlines \\ true
      ) do
    match = match || parent_type.content_match
    node = Node.node_at(doc, pos)

    child_count = Node.child_count(node)

    {tr, repl_steps, final_match, final_cur} =
      Enum.reduce(0..(child_count - 1)//1, {tr, [], match, pos + 1}, fn i,
                                                                        {tr_acc, repl_acc,
                                                                         match_acc, cur} ->
        child = Node.child(node, i)
        end_pos = cur + Node.node_size(child)
        allowed = ContentMatch.match_type(match_acc, child.type)

        if allowed == nil do
          # Child not allowed — schedule a replace step
          {tr_acc, repl_acc ++ [ReplaceStep.new(cur, end_pos, Slice.empty())], match_acc, end_pos}
        else
          new_match = allowed

          # Remove incompatible marks immediately
          child_marks = child.marks || []

          tr_acc =
            Enum.reduce(child_marks, tr_acc, fn child_mark, t ->
              if not NodeType.allows_mark_type(parent_type, child_mark.type) do
                Transform.step(t, RemoveMarkStep.new(cur, end_pos, child_mark))
              else
                t
              end
            end)

          # Handle newlines in text nodes for non-pre parent types
          repl_acc =
            if clear_newlines and Node.is_text(child) and
                 NodeType.whitespace(parent_type) != "pre" do
              text = child.text
              newline_regex = ~r/\r?\n|\r/

              case Regex.scan(newline_regex, text, return: :index) do
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

                  Enum.reduce(matches, repl_acc, fn [{match_start, match_len}], acc ->
                    acc ++
                      [ReplaceStep.new(cur + match_start, cur + match_start + match_len, slice)]
                  end)
              end
            else
              repl_acc
            end

          {tr_acc, repl_acc, new_match, end_pos}
        end
      end)

    # If the content match doesn't have a valid end, fill with required content
    {tr, repl_steps} =
      if not final_match.valid_end do
        fill = ContentMatch.fill_before(final_match, Fragment.empty(), true)

        if fill do
          tr = Transform.step(tr, ReplaceStep.new(final_cur, final_cur, Slice.new(fill, 0, 0)))
          {tr, repl_steps}
        else
          {tr, repl_steps}
        end
      else
        {tr, repl_steps}
      end

    # Apply replace steps in reverse order (from end to start)
    tr =
      Enum.reduce(Enum.reverse(repl_steps), tr, fn step_struct, acc ->
        Transform.step(acc, step_struct)
      end)

    tr
  end
end
