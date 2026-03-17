defmodule ProsemirrorEx.Transform.Structure do
  @moduledoc """
  Structural transform operations: lift, wrap, split, join, and
  related utility functions.

  Ports `structure.ts` from prosemirror-transform.
  """

  alias ProsemirrorEx.Model.{
    Node,
    NodeType,
    NodeRange,
    Fragment,
    Slice,
    ContentMatch,
    ResolvedPos
  }

  alias ProsemirrorEx.Transform.{
    Transform,
    ReplaceStep,
    ReplaceAroundStep,
    Mapping
  }

  # ── Private helpers ──────────────────────────────────────────────────

  # Create a mapping that maps only through steps from `from` to the end.
  # In JS: mapping.slice(from) defaults to = maps.length.
  # In Elixir: Mapping.slice(mapping, from \\ 0, to) requires explicit to.
  defp mapping_from(mapping, from) do
    Mapping.slice(mapping, from, length(mapping.maps))
  end

  defp can_cut(node, start_idx, end_idx) do
    (start_idx == 0 or Node.can_replace(node, start_idx, Node.child_count(node))) and
      (end_idx == Node.child_count(node) or Node.can_replace(node, 0, end_idx))
  end

  # ── liftTarget ───────────────────────────────────────────────────────

  @doc """
  Try to find a target depth to which the content in the given range
  can be lifted. Will not go across isolating parent nodes.
  Returns an integer depth or nil.
  """
  def lift_target(%NodeRange{} = range) do
    parent = NodeRange.parent(range)

    content =
      Fragment.cut_by_index(
        parent.content,
        NodeRange.start_index(range),
        NodeRange.end_index(range)
      )

    do_lift_target(range, content, range.depth, 0, 0)
  end

  defp do_lift_target(range, content, depth, content_before, content_after) do
    if depth < 0 do
      nil
    else
      node = ResolvedPos.node(range.from, depth)
      index = ResolvedPos.index(range.from, depth) + content_before
      end_index = ResolvedPos.index_after(range.to, depth) - content_after

      if depth < range.depth and Node.can_replace(node, index, end_index, content) do
        depth
      else
        if depth == 0 or Map.get(node.type.spec, "isolating", false) or
             not can_cut(node, index, end_index) do
          nil
        else
          new_content_before = if index > 0, do: 1, else: content_before
          new_content_after = if end_index < Node.child_count(node), do: 1, else: content_after
          do_lift_target(range, content, depth - 1, new_content_before, new_content_after)
        end
      end
    end
  end

  # ── lift ─────────────────────────────────────────────────────────────

  @doc """
  Lift the content in the given range out of its parent to the
  given target depth.
  """
  def lift(tr, %NodeRange{} = range, target) do
    from = range.from
    to = range.to
    depth = range.depth

    gap_start = ResolvedPos.before(from, depth + 1)
    gap_end = ResolvedPos.after_pos(to, depth + 1)
    start_pos = gap_start
    end_pos = gap_end

    # Build before fragment
    {before, open_start, start_pos} = build_lift_before(from, depth, target, start_pos)

    # Build after fragment
    {after_frag, open_end, end_pos} = build_lift_after(to, depth, target, end_pos)

    slice = Slice.new(Fragment.append(before, after_frag), open_start, open_end)

    Transform.step(
      tr,
      ReplaceAroundStep.new(
        start_pos,
        end_pos,
        gap_start,
        gap_end,
        slice,
        before.size - open_start,
        true
      )
    )
  end

  defp build_lift_before(from, depth, target, start_pos) do
    do_build_lift_before(from, depth, target, Fragment.empty(), 0, start_pos, false)
  end

  defp do_build_lift_before(_from, d, target, before, open_start, start_pos, _splitting)
       when d <= target do
    {before, open_start, start_pos}
  end

  defp do_build_lift_before(from, d, target, before, open_start, start_pos, splitting) do
    if splitting or ResolvedPos.index(from, d) > 0 do
      node_at_d = ResolvedPos.node(from, d)

      do_build_lift_before(
        from,
        d - 1,
        target,
        Fragment.from(Node.copy(node_at_d, before)),
        open_start + 1,
        start_pos,
        true
      )
    else
      do_build_lift_before(from, d - 1, target, before, open_start, start_pos - 1, false)
    end
  end

  defp build_lift_after(to, depth, target, end_pos) do
    do_build_lift_after(to, depth, target, Fragment.empty(), 0, end_pos, false)
  end

  defp do_build_lift_after(_to, d, target, after_frag, open_end, end_pos, _splitting)
       when d <= target do
    {after_frag, open_end, end_pos}
  end

  defp do_build_lift_after(to, d, target, after_frag, open_end, end_pos, splitting) do
    if splitting or ResolvedPos.after_pos(to, d + 1) < ResolvedPos.end_pos(to, d) do
      node_at_d = ResolvedPos.node(to, d)

      do_build_lift_after(
        to,
        d - 1,
        target,
        Fragment.from(Node.copy(node_at_d, after_frag)),
        open_end + 1,
        end_pos,
        true
      )
    else
      do_build_lift_after(to, d - 1, target, after_frag, open_end, end_pos + 1, false)
    end
  end

  # ── findWrapping ─────────────────────────────────────────────────────

  @doc """
  Try to find a valid way to wrap the content in the given range in a
  node of the given type. May introduce extra nodes around and inside
  the wrapper node. Returns nil if no valid wrapping could be found.
  """
  def find_wrapping(%NodeRange{} = range, node_type, attrs \\ nil, inner_range \\ nil) do
    inner_range = inner_range || range
    around = find_wrapping_outside(range, node_type)
    inner = around && find_wrapping_inside(inner_range, node_type)

    if inner do
      outer = Enum.map(around, fn type -> %{type: type, attrs: nil} end)

      outer ++
        [%{type: node_type, attrs: attrs}] ++
        Enum.map(inner, fn type -> %{type: type, attrs: nil} end)
    else
      nil
    end
  end

  defp find_wrapping_outside(%NodeRange{} = range, type) do
    parent = NodeRange.parent(range)
    start_index = NodeRange.start_index(range)
    end_index = NodeRange.end_index(range)
    around = ContentMatch.find_wrapping(Node.content_match_at(parent, start_index), type)

    if around do
      outer = if length(around) > 0, do: List.first(around), else: type
      if Node.can_replace_with(parent, start_index, end_index, outer), do: around, else: nil
    else
      nil
    end
  end

  defp find_wrapping_inside(%NodeRange{} = range, type) do
    parent = NodeRange.parent(range)
    start_index = NodeRange.start_index(range)
    end_index = NodeRange.end_index(range)
    inner = Node.child(parent, start_index)
    inside = ContentMatch.find_wrapping(type.content_match, inner.type)

    if inside do
      last_type = if length(inside) > 0, do: List.last(inside), else: type

      inner_match =
        Enum.reduce_while(start_index..(end_index - 1)//1, last_type.content_match, fn i,
                                                                                       match_acc ->
          if match_acc do
            child = Node.child(parent, i)
            result = ContentMatch.match_type(match_acc, child.type)
            if result, do: {:cont, result}, else: {:halt, nil}
          else
            {:halt, nil}
          end
        end)

      if inner_match && inner_match.valid_end do
        inside
      else
        nil
      end
    else
      nil
    end
  end

  # ── wrap ─────────────────────────────────────────────────────────────

  @doc """
  Wrap the content in the given range in the given wrapper nodes.
  """
  def wrap(tr, %NodeRange{} = range, wrappers) do
    content =
      Enum.reduce((length(wrappers) - 1)..0//-1, Fragment.empty(), fn i, content_acc ->
        wrapper = Enum.at(wrappers, i)

        if content_acc.size > 0 do
          match = ContentMatch.match_fragment(wrapper.type.content_match, content_acc)

          if !match || !match.valid_end do
            raise "Wrapper type given to Transform.wrap does not form valid content of its parent wrapper"
          end
        end

        Fragment.from(
          NodeType.create(
            wrapper.type,
            Map.get(wrapper, :attrs, nil),
            content_acc
          )
        )
      end)

    start_pos = NodeRange.start(range)
    end_pos = NodeRange.end_pos(range)

    Transform.step(
      tr,
      ReplaceAroundStep.new(
        start_pos,
        end_pos,
        start_pos,
        end_pos,
        Slice.new(content, 0, 0),
        length(wrappers),
        true
      )
    )
  end

  # ── setBlockType ─────────────────────────────────────────────────────

  @doc """
  Set the type of all textblocks (partly) between `from` and `to` to the
  given node type with the given attributes.
  """
  def set_block_type(tr, from, to, type, attrs) do
    unless type.is_textblock do
      raise "Type given to setBlockType should be a textblock"
    end

    map_from = length(tr.steps)
    Process.put(:_pm_set_block_type_tr, tr)

    Node.nodes_between(tr.doc, from, to, fn node, pos, _parent, _index ->
      # Read the latest tr from process dict (it gets updated as steps are applied)
      current_tr = Process.get(:_pm_set_block_type_tr)
      attrs_here = if is_function(attrs), do: attrs.(node), else: attrs

      if Node.is_textblock(node) and not Node.has_markup(node, type, attrs_here) and
           can_change_type(
             current_tr.doc,
             Mapping.map(mapping_from(current_tr.mapping, map_from), pos),
             type
           ) do
        convert_newlines = check_linebreak_conversion(type)

        # Replace linebreaks -> newlines if converting FROM pre to non-pre
        current_tr =
          if convert_newlines == false do
            replace_linebreaks(current_tr, node, pos, map_from)
          else
            current_tr
          end

        # Clear incompatible marks/content
        current_tr =
          ProsemirrorEx.Transform.Mark.clear_incompatible(
            current_tr,
            Mapping.map(mapping_from(current_tr.mapping, map_from), pos, 1),
            type,
            nil,
            convert_newlines == nil
          )

        mapping = mapping_from(current_tr.mapping, map_from)
        start_m = Mapping.map(mapping, pos, 1)
        end_m = Mapping.map(mapping, pos + Node.node_size(node), 1)

        current_tr =
          Transform.step(
            current_tr,
            ReplaceAroundStep.new(
              start_m,
              end_m,
              start_m + 1,
              end_m - 1,
              Slice.new(Fragment.from(NodeType.create(type, attrs_here, nil, node.marks)), 0, 0),
              1,
              true
            )
          )

        # Replace newlines -> linebreaks if converting TO pre-like
        current_tr =
          if convert_newlines == true do
            replace_newlines(current_tr, node, pos, map_from)
          else
            current_tr
          end

        # Don't descend into textblocks
        Process.put(:_pm_set_block_type_tr, current_tr)
        false
      else
        true
      end
    end)

    # Retrieve the accumulated tr
    result = Process.get(:_pm_set_block_type_tr, tr)
    Process.delete(:_pm_set_block_type_tr)
    result
  end

  defp check_linebreak_conversion(type) do
    schema = type.schema

    if schema.linebreak_replacement do
      pre = NodeType.whitespace(type) == "pre"

      support_linebreak =
        ContentMatch.match_type(type.content_match, schema.linebreak_replacement) != nil

      cond do
        pre and not support_linebreak -> false
        not pre and support_linebreak -> true
        true -> nil
      end
    else
      nil
    end
  end

  defp can_change_type(doc, pos, type) do
    rpos = Node.resolve(doc, pos)
    index = ResolvedPos.index(rpos)
    Node.can_replace_with(ResolvedPos.parent(rpos), index, index + 1, type)
  end

  defp replace_newlines(tr, node, pos, map_from) do
    Process.put(:_pm_newline_tr, tr)

    Node.for_each(node, fn child, offset, _index ->
      if Node.is_text(child) do
        current_tr = Process.get(:_pm_newline_tr)
        regex = ~r/\r?\n|\r/

        updated_tr =
          Regex.scan(regex, child.text, return: :index)
          |> List.flatten()
          |> Enum.reduce(current_tr, fn {idx, _len}, tr_acc ->
            start = Mapping.map(mapping_from(tr_acc.mapping, map_from), pos + 1 + offset + idx)
            schema = node.type.schema

            Transform.replace_with(
              tr_acc,
              start,
              start + 1,
              NodeType.create(schema.linebreak_replacement)
            )
          end)

        Process.put(:_pm_newline_tr, updated_tr)
      end
    end)

    result = Process.get(:_pm_newline_tr, tr)
    Process.delete(:_pm_newline_tr)
    result
  end

  defp replace_linebreaks(tr, node, pos, map_from) do
    _tr_ref = Process.put(:_pm_linebreak_tr, tr)

    Node.for_each(node, fn child, offset, _index ->
      tr_acc = Process.get(:_pm_linebreak_tr)
      schema = child.type.schema

      if child.type == schema.linebreak_replacement do
        start = Mapping.map(mapping_from(tr_acc.mapping, map_from), pos + 1 + offset)

        new_tr =
          Transform.replace_with(
            tr_acc,
            start,
            start + 1,
            ProsemirrorEx.Model.Schema.text(schema, "\n")
          )

        Process.put(:_pm_linebreak_tr, new_tr)
      end
    end)

    result = Process.get(:_pm_linebreak_tr, tr)
    Process.delete(:_pm_linebreak_tr)
    result
  end

  # ── setNodeMarkup ────────────────────────────────────────────────────

  @doc """
  Change the type, attributes, and/or marks of the node at `pos`.
  When `type` is nil, the existing node type is preserved.
  """
  def set_node_markup(tr, pos, type, attrs, marks) do
    node = Node.node_at(tr.doc, pos)

    unless node do
      raise "No node at given position"
    end

    type = type || node.type
    new_node = NodeType.create(type, attrs, nil, marks || node.marks)

    if Node.is_leaf(node) do
      Transform.replace_with(tr, pos, pos + Node.node_size(node), new_node)
    else
      unless NodeType.valid_content(type, node.content) do
        raise "Invalid content for node type #{type.name}"
      end

      Transform.step(
        tr,
        ReplaceAroundStep.new(
          pos,
          pos + Node.node_size(node),
          pos + 1,
          pos + Node.node_size(node) - 1,
          Slice.new(Fragment.from(new_node), 0, 0),
          1,
          true
        )
      )
    end
  end

  # ── canSplit ─────────────────────────────────────────────────────────

  @doc """
  Check whether splitting at the given position is allowed.
  """
  def can_split(doc, pos, depth \\ 1, types_after \\ nil) do
    rpos = Node.resolve(doc, pos)
    base = rpos.depth - depth

    inner_type =
      if types_after && length(types_after) > 0 do
        List.last(types_after)
      else
        ResolvedPos.parent(rpos)
      end

    inner_type_struct =
      if is_map(inner_type) && Map.has_key?(inner_type, :type), do: inner_type, else: inner_type

    parent_node = ResolvedPos.parent(rpos)

    cond do
      base < 0 ->
        false

      Map.get(parent_node.type.spec, "isolating", false) ->
        false

      not Node.can_replace(parent_node, ResolvedPos.index(rpos), Node.child_count(parent_node)) ->
        false

      true ->
        # Check inner type valid content
        inner_node_type =
          cond do
            is_map(inner_type_struct) && Map.has_key?(inner_type_struct, :type) ->
              inner_type_struct.type

            is_map(inner_type_struct) && Map.has_key?(inner_type_struct, :name) ->
              inner_type_struct.type

            true ->
              parent_node.type
          end

        rest_content =
          Fragment.cut_by_index(
            parent_node.content,
            ResolvedPos.index(rpos),
            Node.child_count(parent_node)
          )

        if not NodeType.valid_content(inner_node_type, rest_content) do
          false
        else
          check_split_levels(rpos, base, depth, types_after)
        end
    end
  end

  defp check_split_levels(rpos, base, depth, types_after) do
    result =
      Enum.reduce_while((rpos.depth - 1)..(base + 1)//-1, {true, depth - 2}, fn d, {_ok, i} ->
        node = ResolvedPos.node(rpos, d)
        index = ResolvedPos.index(rpos, d)

        if Map.get(node.type.spec, "isolating", false) do
          {:halt, {false, i}}
        else
          rest = Fragment.cut_by_index(node.content, index, Node.child_count(node))

          override_child = types_after && Enum.at(types_after, i + 1)

          rest =
            if override_child do
              Fragment.replace_child(
                rest,
                0,
                NodeType.create(override_child.type, Map.get(override_child, :attrs, nil))
              )
            else
              rest
            end

          after_type =
            if types_after && Enum.at(types_after, i) do
              Enum.at(types_after, i)
            else
              node
            end

          after_node_type =
            cond do
              is_map(after_type) && Map.has_key?(after_type, :type) -> after_type.type
              true -> node.type
            end

          if not Node.can_replace(node, index + 1, Node.child_count(node)) or
               not NodeType.valid_content(after_node_type, rest) do
            {:halt, {false, i - 1}}
          else
            {:cont, {true, i - 1}}
          end
        end
      end)

    {ok, _i} = result

    if ok do
      # Check the base level
      index = ResolvedPos.index_after(rpos, base)
      base_type = types_after && Enum.at(types_after, 0)

      base_node_type =
        if base_type do
          base_type.type
        else
          ResolvedPos.node(rpos, base + 1).type
        end

      Node.can_replace_with(ResolvedPos.node(rpos, base), index, index, base_node_type)
    else
      false
    end
  end

  # ── split ────────────────────────────────────────────────────────────

  @doc """
  Split the node at the given position, creating new sibling nodes.
  """
  def split(tr, pos, depth \\ 1, types_after \\ nil) do
    rpos = Node.resolve(tr.doc, pos)

    {before, after_frag} =
      Enum.reduce(
        rpos.depth..(rpos.depth - depth + 1)//-1,
        {Fragment.empty(), Fragment.empty()},
        fn d, {before_acc, after_acc} ->
          i = d - (rpos.depth - depth + 1)
          node_at_d = ResolvedPos.node(rpos, d)
          before_acc = Fragment.from(Node.copy(node_at_d, before_acc))

          type_after = types_after && Enum.at(types_after, i)

          after_acc =
            if type_after do
              Fragment.from(
                NodeType.create(type_after.type, Map.get(type_after, :attrs, nil), after_acc)
              )
            else
              Fragment.from(Node.copy(node_at_d, after_acc))
            end

          {before_acc, after_acc}
        end
      )

    Transform.step(
      tr,
      ReplaceStep.new(
        pos,
        pos,
        Slice.new(Fragment.append(before, after_frag), depth, depth),
        true
      )
    )
  end

  # ── canJoin ──────────────────────────────────────────────────────────

  @doc """
  Test whether the blocks before and after a given position can be joined.
  """
  def can_join(doc, pos) do
    rpos = Node.resolve(doc, pos)
    index = ResolvedPos.index(rpos)

    joinable?(ResolvedPos.node_before(rpos), ResolvedPos.node_after(rpos)) and
      Node.can_replace(ResolvedPos.parent(rpos), index, index + 1)
  end

  defp can_append_with_substituted_linebreaks(a, b) do
    if b.content.size == 0 do
      NodeType.compatible_content(a.type, b.type)
    else
      match = Node.content_match_at(a, Node.child_count(a))
      schema = a.type.schema

      result =
        Enum.reduce_while(0..(Node.child_count(b) - 1)//1, match, fn i, match_acc ->
          child = Node.child(b, i)

          type =
            if schema.linebreak_replacement && child.type == schema.linebreak_replacement do
              schema.nodes["text"]
            else
              child.type
            end

          new_match = ContentMatch.match_type(match_acc, type)

          if new_match == nil do
            {:halt, nil}
          else
            if not NodeType.allows_marks(a.type, child.marks || []) do
              {:halt, nil}
            else
              {:cont, new_match}
            end
          end
        end)

      result != nil and result.valid_end
    end
  end

  defp joinable?(a, b) do
    a != nil and b != nil and not Node.is_leaf(a) and can_append_with_substituted_linebreaks(a, b)
  end

  # ── joinPoint ────────────────────────────────────────────────────────

  @doc """
  Find an ancestor of the given position that can be joined to the
  block before (or after if `dir` is positive). Returns the joinable
  point, or nil.
  """
  def join_point(doc, pos, dir \\ -1) do
    rpos = Node.resolve(doc, pos)
    do_join_point(rpos, rpos.depth, pos, dir)
  end

  defp do_join_point(rpos, d, pos, dir) do
    index = ResolvedPos.index(rpos, d)

    {before, after_node, index} =
      if d == rpos.depth do
        {ResolvedPos.node_before(rpos), ResolvedPos.node_after(rpos), index}
      else
        if dir > 0 do
          before = ResolvedPos.node(rpos, d + 1)
          new_index = index + 1
          after_node = Node.maybe_child(ResolvedPos.node(rpos, d), new_index)
          {before, after_node, new_index}
        else
          before = Node.maybe_child(ResolvedPos.node(rpos, d), index - 1)
          after_node = ResolvedPos.node(rpos, d + 1)
          {before, after_node, index}
        end
      end

    if before != nil and not Node.is_textblock(before) and joinable?(before, after_node) and
         Node.can_replace(ResolvedPos.node(rpos, d), index, index + 1) do
      pos
    else
      if d == 0 do
        nil
      else
        new_pos =
          if dir < 0, do: ResolvedPos.before(rpos, d), else: ResolvedPos.after_pos(rpos, d)

        do_join_point(rpos, d - 1, new_pos, dir)
      end
    end
  end

  # ── join ─────────────────────────────────────────────────────────────

  @doc """
  Join the blocks around the given position.
  """
  def join(tr, pos, depth \\ 1) do
    schema = tr.doc.type.schema
    before_rpos = Node.resolve(tr.doc, pos - depth)
    before_type = ResolvedPos.node(before_rpos).type

    convert_newlines = check_join_linebreak_conversion(schema, before_type)

    map_from = length(tr.steps)

    # Replace linebreaks -> newlines if converting
    tr =
      if convert_newlines == false do
        after_rpos = Node.resolve(tr.doc, pos + depth)

        replace_linebreaks(
          tr,
          ResolvedPos.node(after_rpos),
          ResolvedPos.before(after_rpos),
          map_from
        )
      else
        tr
      end

    # Clear incompatible content if inline
    tr =
      if before_type.inline_content do
        ProsemirrorEx.Transform.Mark.clear_incompatible(
          tr,
          pos + depth - 1,
          before_type,
          Node.content_match_at(ResolvedPos.node(before_rpos), ResolvedPos.index(before_rpos)),
          convert_newlines == nil
        )
      else
        tr
      end

    mapping = mapping_from(tr.mapping, map_from)
    start_pos = Mapping.map(mapping, pos - depth)

    tr =
      Transform.step(
        tr,
        ReplaceStep.new(start_pos, Mapping.map(mapping, pos + depth, -1), Slice.empty(), true)
      )

    # Replace newlines -> linebreaks if converting
    tr =
      if convert_newlines == true do
        full_rpos = Node.resolve(tr.doc, start_pos)

        replace_newlines(
          tr,
          ResolvedPos.node(full_rpos),
          ResolvedPos.before(full_rpos),
          length(tr.steps)
        )
      else
        tr
      end

    tr
  end

  defp check_join_linebreak_conversion(schema, before_type) do
    if schema.linebreak_replacement && before_type.inline_content do
      pre = NodeType.whitespace(before_type) == "pre"

      support_linebreak =
        ContentMatch.match_type(before_type.content_match, schema.linebreak_replacement) != nil

      cond do
        pre and not support_linebreak -> false
        not pre and support_linebreak -> true
        true -> nil
      end
    else
      nil
    end
  end

  # ── insertPoint ──────────────────────────────────────────────────────

  @doc """
  Try to find a point where a node of the given type can be inserted
  near `pos`, by searching up the node hierarchy when `pos` itself
  isn't a valid place but is at the start or end of a node.
  Returns nil if no position was found.
  """
  def insert_point(doc, pos, node_type) do
    # Delegate to the existing implementation in Replace module
    ProsemirrorEx.Transform.Replace.insert_point(doc, pos, node_type)
  end

  # ── dropPoint ────────────────────────────────────────────────────────

  @doc """
  Finds a position at or around the given position where the given
  slice can be inserted. Will look at parent nodes' nearest boundary.
  Returns nil when no position was found.
  """
  def drop_point(doc, pos, %Slice{} = slice) do
    rpos = Node.resolve(doc, pos)

    if slice.content.size == 0 do
      pos
    else
      content = unwrap_open_start(slice)
      max_pass = if slice.open_start == 0 and Slice.size(slice) > 0, do: 2, else: 1

      do_drop_point(rpos, content, 1, max_pass)
    end
  end

  defp unwrap_open_start(slice) do
    Enum.reduce(1..slice.open_start//1, slice.content, fn _i, content ->
      Fragment.first_child(content).content
    end)
  end

  defp do_drop_point(_rpos, _content, pass, max_pass) when pass > max_pass, do: nil

  defp do_drop_point(rpos, content, pass, max_pass) do
    case find_drop_depth(rpos, content, pass, rpos.depth) do
      nil -> do_drop_point(rpos, content, pass + 1, max_pass)
      pos -> pos
    end
  end

  defp find_drop_depth(_rpos, _content, _pass, d) when d < 0, do: nil

  defp find_drop_depth(rpos, content, pass, d) do
    bias =
      if d == rpos.depth do
        0
      else
        mid = div(ResolvedPos.start(rpos, d + 1) + ResolvedPos.end_pos(rpos, d + 1), 2)
        if rpos.pos <= mid, do: -1, else: 1
      end

    insert_pos = ResolvedPos.index(rpos, d) + if bias > 0, do: 1, else: 0
    parent = ResolvedPos.node(rpos, d)

    fits =
      if pass == 1 do
        Node.can_replace(parent, insert_pos, insert_pos, content)
      else
        first_child = Fragment.first_child(content)

        if first_child do
          wrapping =
            ContentMatch.find_wrapping(
              Node.content_match_at(parent, insert_pos),
              first_child.type
            )

          wrapping != nil and
            Node.can_replace_with(parent, insert_pos, insert_pos, List.first(wrapping))
        else
          false
        end
      end

    if fits do
      cond do
        bias == 0 -> rpos.pos
        bias < 0 -> ResolvedPos.before(rpos, d + 1)
        true -> ResolvedPos.after_pos(rpos, d + 1)
      end
    else
      find_drop_depth(rpos, content, pass, d - 1)
    end
  end
end
