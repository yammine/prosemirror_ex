defmodule ProsemirrorEx.Transform.Replace do
  @moduledoc """
  Fitter algorithm and replace helpers for fitting slices into document gaps.

  Ports `replace.ts` from prosemirror-transform/src/replace.ts.
  """

  alias ProsemirrorEx.Model.{
    Fragment,
    Slice,
    Node,
    ResolvedPos,
    ContentMatch,
    NodeType
  }

  alias ProsemirrorEx.Transform.{
    ReplaceStep,
    ReplaceAroundStep,
    Transform
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  'Fit' a slice into a given position in the document, producing a
  step that inserts it. Will return nil if there's no meaningful way
  to insert the slice here, or inserting it would be a no-op.
  """
  def replace_step(doc, from, to \\ nil, slice \\ nil) do
    to = to || from
    slice = slice || Slice.empty()

    if from == to and Slice.size(slice) == 0 do
      nil
    else
      from_pos = Node.resolve(doc, from)
      to_pos = Node.resolve(doc, to)

      if fits_trivially(from_pos, to_pos, slice) do
        ReplaceStep.new(from, to, slice)
      else
        fitter_fit(from_pos, to_pos, slice)
      end
    end
  end

  @doc """
  WYSIWYG-aware replace. Expands/contracts the range for best structural fit.
  """
  def replace_range(tr, from, to, slice) do
    if Slice.size(slice) == 0 do
      Transform.delete_range(tr, from, to)
    else
      from_pos = Node.resolve(tr.doc, from)
      to_pos = Node.resolve(tr.doc, to)

      if fits_trivially(from_pos, to_pos, slice) do
        Transform.step(tr, ReplaceStep.new(from, to, slice))
      else
        do_replace_range(tr, from, to, from_pos, to_pos, slice)
      end
    end
  end

  @doc """
  WYSIWYG-aware single-node replacement.
  """
  def replace_range_with(tr, from, to, node) do
    if !Node.is_inline(node) and from == to and
         Node.child_count(ResolvedPos.parent(Node.resolve(tr.doc, from))) > 0 do
      point = insert_point(tr.doc, from, node.type)

      {from, to} =
        if point != nil do
          {point, point}
        else
          {from, to}
        end

      replace_range(tr, from, to, Slice.new(Fragment.from(node), 0, 0))
    else
      replace_range(tr, from, to, Slice.new(Fragment.from(node), 0, 0))
    end
  end

  @doc """
  Smart delete that expands to cover parent nodes when appropriate.
  """
  def delete_range(tr, from, to) do
    from_pos = Node.resolve(tr.doc, from)
    to_pos = Node.resolve(tr.doc, to)
    covered = covered_depths(from_pos, to_pos)
    do_delete_range(tr, from, to, from_pos, to_pos, covered, 0)
  end

  @doc """
  Find a position at or around the given position where a node of the
  given type can be inserted. Returns nil when no position was found.
  """
  def insert_point(doc, pos, node_type) do
    rpos = Node.resolve(doc, pos)

    if Node.can_replace_with(
         ResolvedPos.parent(rpos),
         ResolvedPos.index(rpos),
         ResolvedPos.index(rpos),
         node_type
       ) do
      pos
    else
      result =
        if rpos.parent_offset == 0 do
          find_insert_point_before(rpos, node_type)
        end

      result =
        if result == nil and rpos.parent_offset == ResolvedPos.parent(rpos).content.size do
          find_insert_point_after(rpos, node_type) || result
        else
          result
        end

      result
    end
  end

  defp find_insert_point_before(rpos, node_type) do
    find_insert_point_before_loop(rpos, node_type, rpos.depth - 1)
  end

  defp find_insert_point_before_loop(_rpos, _node_type, d) when d < 0, do: nil

  defp find_insert_point_before_loop(rpos, node_type, d) do
    idx = ResolvedPos.index(rpos, d)

    if Node.can_replace_with(ResolvedPos.node(rpos, d), idx, idx, node_type) do
      ResolvedPos.before(rpos, d + 1)
    else
      if idx > 0 do
        nil
      else
        find_insert_point_before_loop(rpos, node_type, d - 1)
      end
    end
  end

  defp find_insert_point_after(rpos, node_type) do
    find_insert_point_after_loop(rpos, node_type, rpos.depth - 1)
  end

  defp find_insert_point_after_loop(_rpos, _node_type, d) when d < 0, do: nil

  defp find_insert_point_after_loop(rpos, node_type, d) do
    idx = ResolvedPos.index_after(rpos, d)

    if Node.can_replace_with(ResolvedPos.node(rpos, d), idx, idx, node_type) do
      ResolvedPos.after_pos(rpos, d + 1)
    else
      if idx < Node.child_count(ResolvedPos.node(rpos, d)) do
        nil
      else
        find_insert_point_after_loop(rpos, node_type, d - 1)
      end
    end
  end

  # ── Trivial fit check ──────────────────────────────────────────────

  defp fits_trivially(from_pos, to_pos, slice) do
    slice.open_start == 0 and slice.open_end == 0 and
      ResolvedPos.start(from_pos) == ResolvedPos.start(to_pos) and
      Node.can_replace(
        ResolvedPos.parent(from_pos),
        ResolvedPos.index(from_pos),
        ResolvedPos.index(to_pos),
        slice.content
      )
  end

  # ── Fitter ─────────────────────────────────────────────────────────
  # The Fitter manages fitting a Slice into a document gap.
  # We use a map to hold the mutable state and pass it through functions.

  defp fitter_new(from_pos, to_pos, unplaced) do
    # Build frontier
    frontier =
      Enum.map(0..from_pos.depth, fn i ->
        node = ResolvedPos.node(from_pos, i)

        %{
          type: node.type,
          match: Node.content_match_at(node, ResolvedPos.index_after(from_pos, i))
        }
      end)

    # Build initial placed
    placed =
      Enum.reduce(from_pos.depth..1//-1, Fragment.empty(), fn i, acc ->
        Fragment.from(Node.copy(ResolvedPos.node(from_pos, i), acc))
      end)

    %{
      from: from_pos,
      to: to_pos,
      frontier: frontier,
      unplaced: unplaced,
      placed: placed
    }
  end

  defp fitter_depth(%{frontier: frontier}), do: length(frontier) - 1

  defp fitter_fit(from_pos, to_pos, slice) do
    state = fitter_new(from_pos, to_pos, slice)
    state = fit_loop(state)

    move_inline = must_move_inline(state)

    placed_size =
      state.placed.size - fitter_depth(state) - state.from.depth

    from = state.from

    close_to =
      if move_inline < 0 do
        state.to
      else
        Node.resolve(ResolvedPos.doc(from), move_inline)
      end

    to_result = close(state, close_to)

    case to_result do
      nil ->
        nil

      {state, closed_to} ->
        content = state.placed
        open_start = from.depth
        open_end = closed_to.depth

        # Normalize by dropping open parent nodes
        {content, open_start, open_end} =
          normalize_open(content, open_start, open_end)

        slice = Slice.new(content, open_start, open_end)

        if move_inline > -1 do
          ReplaceAroundStep.new(
            from.pos,
            move_inline,
            state.to.pos,
            ResolvedPos.end_pos(state.to),
            slice,
            placed_size
          )
        else
          if Slice.size(slice) > 0 or from.pos != state.to.pos do
            ReplaceStep.new(from.pos, closed_to.pos, slice)
          else
            nil
          end
        end
    end
  end

  defp normalize_open(content, open_start, open_end) do
    if open_start > 0 and open_end > 0 and Fragment.child_count(content) == 1 do
      first = Fragment.first_child(content)
      normalize_open(first.content, open_start - 1, open_end - 1)
    else
      {content, open_start, open_end}
    end
  end

  defp fit_loop(state) do
    if Slice.size(state.unplaced) == 0 do
      state
    else
      case find_fittable(state) do
        nil ->
          state =
            case open_more(state) do
              {:ok, new_state} -> new_state
              false -> drop_node(state)
            end

          fit_loop(state)

        fit ->
          state = place_nodes(state, fit)
          fit_loop(state)
      end
    end
  end

  # ── findFittable ────────────────────────────────────────────────────

  defp find_fittable(state) do
    start_depth = compute_start_depth(state)

    # Pass 1: try without wrapping
    case find_fittable_pass(state, 1, start_depth) do
      nil ->
        # Pass 2: try with wrapping
        find_fittable_pass(state, 2, state.unplaced.open_start)

      result ->
        result
    end
  end

  defp compute_start_depth(state) do
    start_depth = state.unplaced.open_start

    do_compute_start_depth(
      state.unplaced.content,
      0,
      state.unplaced.open_end,
      start_depth,
      start_depth
    )
  end

  defp do_compute_start_depth(_cur, d, _open_end, start_depth, _orig_start_depth)
       when d >= start_depth do
    start_depth
  end

  defp do_compute_start_depth(cur, d, open_end, start_depth, orig_start_depth) do
    node = Fragment.first_child(cur)

    open_end =
      if Fragment.child_count(cur) > 1, do: 0, else: open_end

    if Map.get(node.type.spec, "isolating", false) and open_end <= d do
      d
    else
      do_compute_start_depth(node.content, d + 1, open_end, start_depth, orig_start_depth)
    end
  end

  defp find_fittable_pass(state, pass, max_slice_depth) do
    start =
      if pass == 1, do: max_slice_depth, else: state.unplaced.open_start

    find_fittable_slice_depth(state, pass, start)
  end

  defp find_fittable_slice_depth(_state, _pass, slice_depth) when slice_depth < 0, do: nil

  defp find_fittable_slice_depth(state, pass, slice_depth) do
    {fragment, parent} =
      if slice_depth > 0 do
        p = Fragment.first_child(content_at(state.unplaced.content, slice_depth - 1))
        {p.content, p}
      else
        {state.unplaced.content, nil}
      end

    first = Fragment.first_child(fragment)

    case find_fittable_frontier_depth(
           state,
           pass,
           slice_depth,
           fragment,
           first,
           parent,
           fitter_depth(state)
         ) do
      nil ->
        find_fittable_slice_depth(state, pass, slice_depth - 1)

      result ->
        result
    end
  end

  defp find_fittable_frontier_depth(
         _state,
         _pass,
         _slice_depth,
         _fragment,
         _first,
         _parent,
         frontier_depth
       )
       when frontier_depth < 0,
       do: nil

  defp find_fittable_frontier_depth(
         state,
         pass,
         slice_depth,
         fragment,
         first,
         parent,
         frontier_depth
       ) do
    %{type: type, match: match} = Enum.at(state.frontier, frontier_depth)

    result =
      if pass == 1 do
        cond do
          first != nil ->
            match_result = ContentMatch.match_type(match, first.type)

            if match_result do
              %{
                slice_depth: slice_depth,
                frontier_depth: frontier_depth,
                parent: parent,
                inject: nil,
                wrap: nil
              }
            else
              inject = ContentMatch.fill_before(match, Fragment.from(first), false)

              if inject do
                %{
                  slice_depth: slice_depth,
                  frontier_depth: frontier_depth,
                  parent: parent,
                  inject: inject,
                  wrap: nil
                }
              else
                nil
              end
            end

          parent != nil and NodeType.compatible_content(type, parent.type) ->
            %{
              slice_depth: slice_depth,
              frontier_depth: frontier_depth,
              parent: parent,
              inject: nil,
              wrap: nil
            }

          true ->
            nil
        end
      else
        if first do
          wrap = ContentMatch.find_wrapping(match, first.type)

          if wrap do
            %{
              slice_depth: slice_depth,
              frontier_depth: frontier_depth,
              parent: parent,
              inject: nil,
              wrap: wrap
            }
          else
            nil
          end
        else
          nil
        end
      end

    if result do
      result
    else
      # Don't continue looking further up if the parent node would fit here.
      if parent && ContentMatch.match_type(match, parent.type) do
        nil
      else
        find_fittable_frontier_depth(
          state,
          pass,
          slice_depth,
          fragment,
          first,
          parent,
          frontier_depth - 1
        )
      end
    end
  end

  # ── openMore ────────────────────────────────────────────────────────

  defp open_more(state) do
    %{content: content, open_start: open_start, open_end: open_end} = state.unplaced
    inner = content_at(content, open_start)

    if Fragment.child_count(inner) == 0 or Node.is_leaf(Fragment.first_child(inner)) do
      false
    else
      new_open_end =
        if inner.size + open_start >= content.size - open_end do
          open_start + 1
        else
          0
        end

      new_open_end = max(open_end, new_open_end)

      {:ok, %{state | unplaced: Slice.new(content, open_start + 1, new_open_end)}}
    end
  end

  # ── dropNode ────────────────────────────────────────────────────────

  defp drop_node(state) do
    %{content: content, open_start: open_start, open_end: open_end} = state.unplaced
    inner = content_at(content, open_start)

    if Fragment.child_count(inner) <= 1 and open_start > 0 do
      open_at_end = content.size - open_start <= open_start + inner.size

      %{
        state
        | unplaced:
            Slice.new(
              drop_from_fragment(content, open_start - 1, 1),
              open_start - 1,
              if(open_at_end, do: open_start - 1, else: open_end)
            )
      }
    else
      %{
        state
        | unplaced:
            Slice.new(
              drop_from_fragment(content, open_start, 1),
              open_start,
              open_end
            )
      }
    end
  end

  # ── placeNodes ──────────────────────────────────────────────────────

  defp place_nodes(state, %{
         slice_depth: slice_depth,
         frontier_depth: frontier_depth,
         parent: parent,
         inject: inject,
         wrap: wrap
       }) do
    # Close frontier nodes down to frontier_depth
    state = close_frontier_to(state, frontier_depth)

    # Open wrapping nodes
    state =
      if wrap do
        Enum.reduce(wrap, state, fn w, acc ->
          open_frontier_node(acc, w)
        end)
      else
        state
      end

    slice = state.unplaced
    fragment = if parent, do: parent.content, else: slice.content
    open_start = slice.open_start - slice_depth

    %{match: match, type: type} = Enum.at(state.frontier, frontier_depth)

    {add, match} =
      if inject do
        inject_children =
          Enum.map(0..(Fragment.child_count(inject) - 1), fn i ->
            Fragment.child(inject, i)
          end)

        new_match = ContentMatch.match_fragment(match, inject)
        {inject_children, new_match}
      else
        {[], match}
      end

    # Computes the amount of (end) open nodes at the end of the fragment.
    open_end_count =
      fragment.size + slice_depth - (slice.content.size - slice.open_end)

    # Scan over the fragment, fitting as many child nodes as possible.
    {taken, add, match, _} =
      take_fitting_children(fragment, match, type, open_start, open_end_count, add, 0)

    to_end = taken == Fragment.child_count(fragment)
    open_end_count = if !to_end, do: -1, else: open_end_count

    state = %{state | placed: add_to_fragment(state.placed, frontier_depth, Fragment.from(add))}
    state = put_in_frontier_match(state, frontier_depth, match)

    # If the parent types match, and the entire node was moved, and
    # it's not open, close this frontier node right away.
    state =
      if to_end and open_end_count < 0 and parent != nil and
           parent.type.name == Enum.at(state.frontier, fitter_depth(state)).type.name and
           length(state.frontier) > 1 do
        close_frontier_node(state)
      else
        state
      end

    # Add new frontier nodes for any open nodes at the end.
    state =
      if open_end_count > 0 do
        add_open_end_frontier(state, fragment, open_end_count)
      else
        state
      end

    # Update unplaced
    new_unplaced =
      if !to_end do
        Slice.new(
          drop_from_fragment(slice.content, slice_depth, taken),
          slice.open_start,
          slice.open_end
        )
      else
        if slice_depth == 0 do
          Slice.empty()
        else
          Slice.new(
            drop_from_fragment(slice.content, slice_depth - 1, 1),
            slice_depth - 1,
            if(open_end_count < 0, do: slice.open_end, else: slice_depth - 1)
          )
        end
      end

    %{state | unplaced: new_unplaced}
  end

  defp take_fitting_children(fragment, match, type, open_start, open_end_count, add, taken) do
    if taken >= Fragment.child_count(fragment) do
      {taken, add, match, open_end_count}
    else
      next = Fragment.child(fragment, taken)

      case ContentMatch.match_type(match, next.type) do
        nil ->
          {taken, add, match, open_end_count}

        matches ->
          new_taken = taken + 1

          if new_taken > 1 or open_start == 0 or next.content.size > 0 do
            closed =
              close_node_start(
                Node.mark(next, NodeType.allowed_marks(type, next.marks || [])),
                if(new_taken == 1, do: open_start, else: 0),
                if(new_taken == Fragment.child_count(fragment), do: open_end_count, else: -1)
              )

            take_fitting_children(
              fragment,
              matches,
              type,
              open_start,
              open_end_count,
              add ++ [closed],
              new_taken
            )
          else
            take_fitting_children(
              fragment,
              matches,
              type,
              open_start,
              open_end_count,
              add,
              new_taken
            )
          end
      end
    end
  end

  defp add_open_end_frontier(state, fragment, open_end_count) do
    Enum.reduce(1..open_end_count, {state, fragment}, fn _i, {st, cur} ->
      node = Fragment.last_child(cur)

      new_frontier =
        st.frontier ++
          [%{type: node.type, match: Node.content_match_at(node, Node.child_count(node))}]

      {%{st | frontier: new_frontier}, node.content}
    end)
    |> elem(0)
  end

  # ── mustMoveInline ──────────────────────────────────────────────────

  defp must_move_inline(state) do
    to = state.to

    if !Node.is_textblock(ResolvedPos.parent(to)) do
      -1
    else
      depth = fitter_depth(state)
      top = Enum.at(state.frontier, depth)

      if !top.type.is_textblock do
        -1
      else
        if !content_after_fits(to, to.depth, top.type, top.match, false) do
          -1
        else
          if to.depth == depth do
            level = find_close_level(state, to)

            if level && level.depth == depth do
              -1
            else
              compute_move_inline_pos(to)
            end
          else
            compute_move_inline_pos(to)
          end
        end
      end
    end
  end

  defp compute_move_inline_pos(to) do
    depth = to.depth
    after_val = ResolvedPos.after_pos(to, depth)
    compute_move_inline_loop(to, depth, after_val)
  end

  defp compute_move_inline_loop(to, depth, after_val) do
    if depth > 1 and after_val == ResolvedPos.end_pos(to, depth - 1) do
      compute_move_inline_loop(to, depth - 1, after_val + 1)
    else
      after_val
    end
  end

  # ── findCloseLevel ──────────────────────────────────────────────────

  defp find_close_level(state, to) do
    find_close_level_loop(state, to, min(fitter_depth(state), to.depth))
  end

  defp find_close_level_loop(_state, _to, i) when i < 0, do: nil

  defp find_close_level_loop(state, to, i) do
    %{match: match, type: type} = Enum.at(state.frontier, i)

    drop_inner =
      i < to.depth and ResolvedPos.end_pos(to, i + 1) == to.pos + (to.depth - (i + 1))

    fit = content_after_fits(to, i, type, match, drop_inner)

    if !fit do
      find_close_level_loop(state, to, i - 1)
    else
      # Check that all frontier nodes below this level also close properly
      if check_close_below(state, to, i) do
        move =
          if drop_inner do
            Node.resolve(ResolvedPos.doc(to), ResolvedPos.after_pos(to, i + 1))
          else
            to
          end

        %{depth: i, fit: fit, move: move}
      else
        find_close_level_loop(state, to, i - 1)
      end
    end
  end

  defp check_close_below(state, to, i) do
    Enum.all?(0..(i - 1)//1, fn d ->
      %{match: match, type: type} = Enum.at(state.frontier, d)
      matches = content_after_fits(to, d, type, match, true)
      matches != nil and (matches == Fragment.empty() or Fragment.child_count(matches) == 0)
    end)
  end

  # ── close ───────────────────────────────────────────────────────────

  defp close(state, to) do
    case find_close_level(state, to) do
      nil ->
        nil

      close_info ->
        state = close_frontier_to(state, close_info.depth)

        state =
          if Fragment.child_count(close_info.fit) > 0 do
            %{
              state
              | placed: add_to_fragment(state.placed, close_info.depth, close_info.fit)
            }
          else
            state
          end

        to = close_info.move

        state =
          if close_info.depth + 1 <= to.depth do
            Enum.reduce((close_info.depth + 1)..to.depth, state, fn d, acc ->
              node = ResolvedPos.node(to, d)

              add =
                ContentMatch.fill_before(
                  node.type.content_match,
                  node.content,
                  true,
                  ResolvedPos.index(to, d)
                )

              open_frontier_node(acc, node.type, node.attrs, add)
            end)
          else
            state
          end

        {state, to}
    end
  end

  # ── Frontier operations ─────────────────────────────────────────────

  defp open_frontier_node(state, type, attrs \\ nil, content \\ nil) do
    depth = fitter_depth(state)
    top = Enum.at(state.frontier, depth)

    new_match = ContentMatch.match_type(top.match, type)

    frontier =
      List.replace_at(state.frontier, depth, %{top | match: new_match})

    placed =
      add_to_fragment(
        state.placed,
        depth,
        Fragment.from(NodeType.create(type, attrs, content))
      )

    new_entry = %{type: type, match: type.content_match}
    frontier = frontier ++ [new_entry]

    %{state | frontier: frontier, placed: placed}
  end

  defp close_frontier_node(state) do
    open = List.last(state.frontier)
    frontier = Enum.drop(state.frontier, -1)
    add = ContentMatch.fill_before(open.match, Fragment.empty(), true)

    placed =
      if add && Fragment.child_count(add) > 0 do
        add_to_fragment(state.placed, length(frontier), add)
      else
        state.placed
      end

    %{state | frontier: frontier, placed: placed}
  end

  defp close_frontier_to(state, target_depth) do
    if fitter_depth(state) > target_depth do
      state = close_frontier_node(state)
      close_frontier_to(state, target_depth)
    else
      state
    end
  end

  defp put_in_frontier_match(state, index, match) do
    entry = Enum.at(state.frontier, index)
    frontier = List.replace_at(state.frontier, index, %{entry | match: match})
    %{state | frontier: frontier}
  end

  # ── Fragment helpers ────────────────────────────────────────────────

  defp drop_from_fragment(fragment, depth, count) do
    if depth == 0 do
      Fragment.cut_by_index(fragment, count, Fragment.child_count(fragment))
    else
      first = Fragment.first_child(fragment)

      Fragment.replace_child(
        fragment,
        0,
        Node.copy(first, drop_from_fragment(first.content, depth - 1, count))
      )
    end
  end

  defp add_to_fragment(fragment, depth, content) do
    if depth == 0 do
      Fragment.append(fragment, content)
    else
      last = Fragment.last_child(fragment)

      Fragment.replace_child(
        fragment,
        Fragment.child_count(fragment) - 1,
        Node.copy(last, add_to_fragment(last.content, depth - 1, content))
      )
    end
  end

  defp content_at(fragment, depth) do
    if depth <= 0 do
      fragment
    else
      content_at(Fragment.first_child(fragment).content, depth - 1)
    end
  end

  defp close_node_start(node, open_start, open_end) do
    if open_start <= 0 do
      node
    else
      frag = node.content

      frag =
        if open_start > 1 do
          first = Fragment.first_child(frag)

          inner_open_end =
            if Fragment.child_count(frag) == 1, do: open_end - 1, else: 0

          Fragment.replace_child(
            frag,
            0,
            close_node_start(first, open_start - 1, inner_open_end)
          )
        else
          frag
        end

      if open_start > 0 do
        fill = ContentMatch.fill_before(node.type.content_match, frag)
        frag = Fragment.append(fill, frag)

        frag =
          if open_end <= 0 do
            matched = ContentMatch.match_fragment(node.type.content_match, frag)
            after_fill = ContentMatch.fill_before(matched, Fragment.empty(), true)
            Fragment.append(frag, after_fill)
          else
            frag
          end

        Node.copy(node, frag)
      else
        Node.copy(node, frag)
      end
    end
  end

  defp content_after_fits(to, depth, type, match, open) do
    node = ResolvedPos.node(to, depth)
    index = if open, do: ResolvedPos.index_after(to, depth), else: ResolvedPos.index(to, depth)

    if index == Node.child_count(node) and !NodeType.compatible_content(type, node.type) do
      nil
    else
      fit = ContentMatch.fill_before(match, node.content, true, index)

      if fit && !invalid_marks(type, node.content, index) do
        fit
      else
        nil
      end
    end
  end

  defp invalid_marks(type, fragment, start) do
    Enum.any?(start..(Fragment.child_count(fragment) - 1)//1, fn i ->
      !NodeType.allows_marks(type, Fragment.child(fragment, i).marks || [])
    end)
  end

  # ── replaceRange implementation ─────────────────────────────────────

  defp do_replace_range(tr, from, to, from_pos, to_pos, slice) do
    target_depths = covered_depths(from_pos, to_pos)

    # Can't replace the whole document, so remove 0 if it's present at end
    target_depths =
      if List.last(target_depths) == 0 do
        Enum.drop(target_depths, -1)
      else
        target_depths
      end

    # Negative numbers represent not expansion over the whole node at
    # that depth, but replacing from $from.before(-D) to $to.pos.
    preferred_target = -(from_pos.depth + 1)
    target_depths = [preferred_target | target_depths]

    # This loop picks a preferred target depth
    {target_depths, preferred_target} =
      compute_preferred_target(from_pos, target_depths, preferred_target)

    preferred_target_index = find_index(target_depths, preferred_target)

    # Build left nodes
    {left_nodes, _} =
      Enum.reduce(0..slice.open_start, {[], slice.content}, fn i, {nodes, content} ->
        node = Fragment.first_child(content)
        nodes = nodes ++ [node]

        if i == slice.open_start do
          {nodes, content}
        else
          {nodes, node.content}
        end
      end)

    # Back up preferredDepth to cover defining textblocks
    preferred_depth =
      compute_preferred_depth(left_nodes, from_pos, preferred_target, slice.open_start)

    # Try each openDepth / targetDepth combination
    result =
      try_replace_range_fits(
        tr,
        from_pos,
        to_pos,
        slice,
        left_nodes,
        target_depths,
        preferred_target_index,
        preferred_depth,
        to
      )

    case result do
      {:ok, tr} ->
        tr

      :not_found ->
        # Fallback: try expanding from/to
        fallback_replace_range(tr, from, to, slice, target_depths, from_pos, to_pos)
    end
  end

  defp compute_preferred_target(from_pos, target_depths, preferred_target) do
    if from_pos.depth < 1 do
      {target_depths, preferred_target}
    else
      Enum.reduce_while(
        from_pos.depth..1//-1,
        {target_depths, preferred_target, from_pos.pos - 1},
        fn d, {tds, pt, pos} ->
          spec = ResolvedPos.node(from_pos, d).type.spec

          if Map.get(spec, "defining", false) or Map.get(spec, "definingAsContext", false) or
               Map.get(spec, "isolating", false) do
            {:halt, {tds, pt, pos}}
          else
            new_pt =
              if Enum.member?(tds, d), do: d, else: pt

            new_tds =
              if ResolvedPos.before(from_pos, d) == pos do
                # Add negative depth after preferred_target
                List.insert_at(tds, 1, -d)
              else
                tds
              end

            {:cont, {new_tds, new_pt, pos - 1}}
          end
        end
      )
      |> case do
        {tds, pt, _pos} -> {tds, pt}
      end
    end
  end

  defp compute_preferred_depth(left_nodes, from_pos, preferred_target, preferred_depth) do
    Enum.reduce_while((preferred_depth - 1)..0//-1, preferred_depth, fn d, pd ->
      left_node = Enum.at(left_nodes, d)
      def_content = defines_content(left_node.type)

      if def_content and
           !Node.same_markup(left_node, ResolvedPos.node(from_pos, abs(preferred_target) - 1)) do
        {:cont, d}
      else
        if def_content or !left_node.type.is_textblock do
          {:halt, pd}
        else
          {:cont, pd}
        end
      end
    end)
  end

  defp try_replace_range_fits(
         tr,
         from_pos,
         to_pos,
         slice,
         left_nodes,
         target_depths,
         preferred_target_index,
         preferred_depth,
         to
       ) do
    num_depths = length(target_depths)

    Enum.reduce_while(slice.open_start..0//-1, :not_found, fn j, _acc ->
      open_depth = rem(j + preferred_depth + 1, slice.open_start + 1)
      insert = Enum.at(left_nodes, open_depth)

      if insert == nil do
        {:cont, :not_found}
      else
        result =
          Enum.reduce_while(0..(num_depths - 1), :not_found, fn i, _inner_acc ->
            idx = rem(i + preferred_target_index, num_depths)
            raw_depth = Enum.at(target_depths, idx)
            expand = raw_depth >= 0

            target_depth =
              if raw_depth < 0, do: -raw_depth, else: raw_depth

            parent = ResolvedPos.node(from_pos, target_depth - 1)
            index = ResolvedPos.index(from_pos, target_depth - 1)

            if Node.can_replace_with(parent, index, index, insert.type, insert.marks || []) do
              replace_to = if expand, do: ResolvedPos.after_pos(to_pos, target_depth), else: to

              new_tr =
                Transform.replace(
                  tr,
                  ResolvedPos.before(from_pos, target_depth),
                  replace_to,
                  Slice.new(
                    close_fragment(slice.content, 0, slice.open_start, open_depth),
                    open_depth,
                    slice.open_end
                  )
                )

              {:halt, {:ok, new_tr}}
            else
              {:cont, :not_found}
            end
          end)

        case result do
          {:ok, _} -> {:halt, result}
          :not_found -> {:cont, :not_found}
        end
      end
    end)
  end

  defp fallback_replace_range(tr, from, to, slice, target_depths, from_pos, to_pos) do
    start_steps = length(tr.steps)

    Enum.reduce_while(Enum.reverse(target_depths), {tr, from, to}, fn depth, {t, f, tt} ->
      t = Transform.replace(t, f, tt, slice)

      if length(t.steps) > start_steps do
        {:halt, {t, f, tt}}
      else
        if depth < 0 do
          {:cont, {t, f, tt}}
        else
          {:cont, {t, ResolvedPos.before(from_pos, depth), ResolvedPos.after_pos(to_pos, depth)}}
        end
      end
    end)
    |> elem(0)
  end

  defp close_fragment(fragment, depth, old_open, new_open, parent \\ nil) do
    fragment =
      if depth < old_open do
        first = Fragment.first_child(fragment)

        Fragment.replace_child(
          fragment,
          0,
          Node.copy(first, close_fragment(first.content, depth + 1, old_open, new_open, first))
        )
      else
        fragment
      end

    if depth > new_open do
      match = parent.type.content_match
      start = Fragment.append(ContentMatch.fill_before(match, fragment), fragment)
      matched = ContentMatch.match_fragment(match, start)
      after_fill = ContentMatch.fill_before(matched, Fragment.empty(), true)
      Fragment.append(start, after_fill)
    else
      fragment
    end
  end

  # ── deleteRange implementation ──────────────────────────────────────

  defp do_delete_range(tr, from, to, from_pos, to_pos, covered, i) do
    if i >= length(covered) do
      # Last fallback - d loop
      do_delete_range_fallback(tr, from, to, from_pos, to_pos)
    else
      depth = Enum.at(covered, i)
      last = i == length(covered) - 1

      cond do
        (last and depth == 0) or
            ResolvedPos.node(from_pos, depth).type.content_match.valid_end ->
          Transform.delete(
            tr,
            ResolvedPos.start(from_pos, depth),
            ResolvedPos.end_pos(to_pos, depth)
          )

        depth > 0 and
            (last or
               Node.can_replace(
                 ResolvedPos.node(from_pos, depth - 1),
                 ResolvedPos.index(from_pos, depth - 1),
                 ResolvedPos.index_after(to_pos, depth - 1)
               )) ->
          Transform.delete(
            tr,
            ResolvedPos.before(from_pos, depth),
            ResolvedPos.after_pos(to_pos, depth)
          )

        true ->
          do_delete_range(tr, from, to, from_pos, to_pos, covered, i + 1)
      end
    end
  end

  defp do_delete_range_fallback(tr, from, to, from_pos, to_pos) do
    max_d = min(from_pos.depth, to_pos.depth)

    result =
      Enum.reduce_while(1..max_d//1, nil, fn d, _acc ->
        if from - ResolvedPos.start(from_pos, d) == from_pos.depth - d and
             to > ResolvedPos.end_pos(from_pos, d) and
             ResolvedPos.end_pos(to_pos, d) - to != to_pos.depth - d and
             ResolvedPos.start(from_pos, d - 1) == ResolvedPos.start(to_pos, d - 1) and
             Node.can_replace(
               ResolvedPos.node(from_pos, d - 1),
               ResolvedPos.index(from_pos, d - 1),
               ResolvedPos.index(to_pos, d - 1)
             ) do
          {:halt, Transform.delete(tr, ResolvedPos.before(from_pos, d), to)}
        else
          {:cont, nil}
        end
      end)

    result || Transform.delete(tr, from, to)
  end

  # ── coveredDepths ───────────────────────────────────────────────────

  defp covered_depths(from_pos, to_pos) do
    min_depth = min(from_pos.depth, to_pos.depth)
    covered_depths_loop(from_pos, to_pos, min_depth, [])
  end

  defp covered_depths_loop(_from_pos, _to_pos, d, result) when d < 0, do: result

  defp covered_depths_loop(from_pos, to_pos, d, result) do
    start = ResolvedPos.start(from_pos, d)

    if start < from_pos.pos - (from_pos.depth - d) or
         ResolvedPos.end_pos(to_pos, d) > to_pos.pos + (to_pos.depth - d) or
         Map.get(ResolvedPos.node(from_pos, d).type.spec, "isolating", false) or
         Map.get(ResolvedPos.node(to_pos, d).type.spec, "isolating", false) do
      result
    else
      should_add =
        start == ResolvedPos.start(to_pos, d) or
          (d == from_pos.depth and d == to_pos.depth and
             Node.inline_content(ResolvedPos.parent(from_pos)) and
             Node.inline_content(ResolvedPos.parent(to_pos)) and
             d > 0 and
             ResolvedPos.start(to_pos, d - 1) == start - 1)

      if should_add do
        covered_depths_loop(from_pos, to_pos, d - 1, result ++ [d])
      else
        covered_depths_loop(from_pos, to_pos, d - 1, result)
      end
    end
  end

  defp defines_content(type) do
    Map.get(type.spec, "defining", false) or Map.get(type.spec, "definingForContent", false)
  end

  defp find_index(list, val) do
    Enum.find_index(list, &(&1 == val)) || 0
  end
end
