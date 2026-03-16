defmodule ProsemirrorEx.Model.ContentMatch do
  @moduledoc """
  Instances of this struct represent a match state of a node type's
  content expression, and can be used to find out whether further
  content matches here, and whether a given position is a valid end
  of the node.

  Ported from ProseMirror's content.ts.

  Because DFA states can form cycles (e.g., `image*` creates a state
  with a self-loop), we use an ETS-backed registry to store the actual
  edge lists. Each ContentMatch holds an `id` that indexes into this
  registry. The `next` field is populated lazily from the registry.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.NodeType

  defstruct [:valid_end, :next, :wrap_cache, :_reg, :_id]

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Parse a content expression string into a ContentMatch DFA.

  `node_types` is a map of name => %NodeType{}.
  """
  def parse("", _node_types), do: empty()

  def parse(string, node_types) when is_binary(string) and is_map(node_types) do
    stream = tokenize(string, node_types)

    case stream.tokens do
      [] ->
        empty()

      _ ->
        {expr, stream} = parse_expr(stream)

        if current_token(stream) != nil do
          parse_err(stream, "Unexpected trailing text")
        end

        nfa_states = build_nfa(expr)
        match = build_dfa(nfa_states)
        check_for_dead_ends(match, stream)
        match
    end
  end

  @doc "Match a node type, returning a match after that node if successful."
  def match_type(%__MODULE__{} = cm, %NodeType{} = type) do
    edges = get_edges(cm)

    Enum.find_value(edges, fn {edge_type, next_id} ->
      if edge_type.name == type.name do
        get_state(cm._reg, next_id)
      end
    end)
  end

  def match_type(nil, _type), do: nil

  @doc "Try to match a fragment. Returns the resulting match when successful."
  def match_fragment(match, frag, start \\ 0, end_val \\ nil)

  def match_fragment(nil, _frag, _start, _end_val), do: nil

  def match_fragment(%__MODULE__{} = match, %Fragment{} = frag, start, end_val) do
    end_val = end_val || Fragment.child_count(frag)

    if start >= end_val do
      match
    else
      Enum.reduce_while(start..(end_val - 1)//1, match, fn i, cur ->
        child = Fragment.child(frag, i)

        case match_type(cur, child.type) do
          nil -> {:halt, nil}
          next -> {:cont, next}
        end
      end)
    end
  end

  @doc """
  Try to match the given fragment, and if that fails, see if it can
  be made to match by inserting nodes in front of it. When successful,
  return a fragment of inserted nodes (which may be empty if nothing
  had to be inserted). When `to_end` is true, only return a fragment
  if the resulting match goes to the end of the content expression.
  """
  def fill_before(
        %__MODULE__{} = match,
        %Fragment{} = after_frag,
        to_end \\ false,
        start_index \\ 0
      ) do
    seen_ref = make_ref()
    Process.put({:fill_before_seen, seen_ref}, MapSet.new([match._id]))

    result = do_fill_before(match, [], after_frag, to_end, start_index, seen_ref)

    Process.delete({:fill_before_seen, seen_ref})
    result
  end

  defp do_fill_before(%__MODULE__{} = match, types, after_frag, to_end, start_index, seen_ref) do
    finished = match_fragment(match, after_frag, start_index)

    if finished != nil and (not to_end or finished.valid_end) do
      nodes = Enum.map(types, fn tp -> NodeType.create_and_fill(tp) end)
      Fragment.from(nodes)
    else
      edges = get_edges(match)

      find_fill(edges, match._reg, types, after_frag, to_end, start_index, seen_ref)
    end
  end

  defp find_fill([], _reg, _types, _after_frag, _to_end, _start_index, _seen_ref), do: nil

  defp find_fill([{type, next_id} | rest], reg, types, after_frag, to_end, start_index, seen_ref) do
    seen = Process.get({:fill_before_seen, seen_ref})

    if not type.is_text and not (type.has_required_attrs == true) and
         not MapSet.member?(seen, next_id) do
      Process.put({:fill_before_seen, seen_ref}, MapSet.put(seen, next_id))
      next = get_state(reg, next_id)

      case do_fill_before(next, types ++ [type], after_frag, to_end, start_index, seen_ref) do
        nil -> find_fill(rest, reg, types, after_frag, to_end, start_index, seen_ref)
        found -> found
      end
    else
      find_fill(rest, reg, types, after_frag, to_end, start_index, seen_ref)
    end
  end

  @doc """
  Find a set of wrapping node types that would allow a node of the
  given type to appear at this position.
  """
  def find_wrapping(%__MODULE__{wrap_cache: wrap_cache} = match, %NodeType{} = target) do
    case find_in_wrap_cache(wrap_cache, target) do
      {:found, result} -> result
      :not_found -> compute_wrapping(match, target)
    end
  end

  defp find_in_wrap_cache([], _target), do: :not_found

  defp find_in_wrap_cache([key, value | rest], target) do
    if key.name == target.name, do: {:found, value}, else: find_in_wrap_cache(rest, target)
  end

  defp find_in_wrap_cache([_], _target), do: :not_found

  @doc "Compute wrapping using BFS."
  def compute_wrapping(%__MODULE__{} = match, %NodeType{} = target) do
    seen = MapSet.new()
    active = :queue.from_list([{match, nil, nil}])
    do_compute_wrapping(active, seen, target)
  end

  defp do_compute_wrapping(active, seen, target) do
    case :queue.out(active) do
      {:empty, _} ->
        nil

      {{:value, {match, type_or_nil, via}}, rest_queue} ->
        if match_type(match, target) != nil do
          build_wrapping_result({match, type_or_nil, via})
          |> Enum.reverse()
        else
          edges = get_edges(match)

          {new_queue, new_seen} =
            Enum.reduce(edges, {rest_queue, seen}, fn {edge_type, next_id}, {q, s} ->
              next = get_state(match._reg, next_id)

              if not edge_type.is_leaf and
                   not (edge_type.has_required_attrs == true) and
                   not MapSet.member?(s, edge_type.name) and
                   (type_or_nil == nil or next.valid_end) do
                content_match = edge_type.content_match || empty()

                {
                  :queue.in({content_match, edge_type, {match, type_or_nil, via}}, q),
                  MapSet.put(s, edge_type.name)
                }
              else
                {q, s}
              end
            end)

          do_compute_wrapping(new_queue, new_seen, target)
        end
    end
  end

  defp build_wrapping_result({_match, nil, _via}), do: []
  defp build_wrapping_result({_match, type, via}), do: [type | build_wrapping_result(via)]

  @doc "Get the first matching node type that can be generated."
  def default_type(%__MODULE__{} = cm) do
    edges = get_edges(cm)

    Enum.find_value(edges, fn {type, _next_id} ->
      if not type.is_text and not (type.has_required_attrs == true), do: type
    end)
  end

  @doc "Whether the match state has inline content."
  def inline_content(%__MODULE__{} = cm) do
    edges = get_edges(cm)

    case edges do
      [] -> false
      [{type, _} | _] -> type.is_inline == true
    end
  end

  @doc "The number of outgoing edges."
  def edge_count(%__MODULE__{} = cm) do
    edges = get_edges(cm)
    length(edges)
  end

  @doc "Get the nth outgoing edge as {type, next_match}."
  def edge(%__MODULE__{} = cm, n) do
    edges = get_edges(cm)

    if n >= length(edges) do
      raise "There's no #{n}th edge in this content match"
    end

    {type, next_id} = Enum.at(edges, n)
    {type, get_state(cm._reg, next_id)}
  end

  @doc "Whether this match state is compatible with another."
  def compatible(%__MODULE__{} = cm_a, %__MODULE__{} = cm_b) do
    edges_a = get_edges(cm_a)
    edges_b = get_edges(cm_b)

    Enum.any?(edges_a, fn {type_a, _} ->
      Enum.any?(edges_b, fn {type_b, _} -> type_a.name == type_b.name end)
    end)
  end

  @doc "The empty content match (matches only empty content)."
  def empty do
    %__MODULE__{valid_end: true, next: [], wrap_cache: [], _reg: nil, _id: nil}
  end

  @doc """
  Update the node types stored in this content match's DFA edges.
  Takes a map of name => updated_node_type. This is needed because
  during schema construction, content expressions are parsed before
  all node types have their content_match set, so the DFA edges
  reference stale types.
  """
  def update_node_types(%__MODULE__{_reg: nil}, _node_types), do: :ok

  def update_node_types(%__MODULE__{_reg: reg}, node_types) when is_map(node_types) do
    # Get all edge entries from the ETS table
    :ets.foldl(
      fn
        {{:edges, key}, edges}, _acc ->
          updated_edges =
            Enum.map(edges, fn {type, target_key} ->
              case Map.get(node_types, type.name) do
                nil -> {type, target_key}
                updated_type -> {updated_type, target_key}
              end
            end)

          :ets.insert(reg, {{:edges, key}, updated_edges})
          :ok

        _, acc ->
          acc
      end,
      :ok,
      reg
    )
  end

  # ── Registry helpers ──────────────────────────────────────────────

  # Get edges for a ContentMatch. For registry-backed states, look up from registry.
  # For simple states (like empty()), use the `next` field directly.
  defp get_edges(%__MODULE__{_reg: nil, next: next}), do: next

  defp get_edges(%__MODULE__{_reg: reg, _id: id}) do
    case :ets.lookup(reg, {:edges, id}) do
      [{_, edges}] -> edges
      [] -> []
    end
  end

  # Get a ContentMatch state from the registry by id
  defp get_state(nil, _id), do: nil

  defp get_state(reg, id) do
    case :ets.lookup(reg, {:state, id}) do
      [{_, state}] -> state
      [] -> nil
    end
  end

  # ── Tokenizer ─────────────────────────────────────────────────────

  defmodule TokenStream do
    @moduledoc false
    defstruct [:string, :node_types, :node_names_ordered, :tokens, :pos, :inline]
  end

  defp tokenize(string, node_types) do
    tokens =
      Regex.split(~r/\s*(?=\b|\W|$)/, string)
      |> Enum.reject(&(&1 == ""))

    # Preserve iteration order by sorting map keys
    # In JS, OrderedMap preserves insertion order. We need a stable order
    # for group resolution to match JS behavior. We store the ordered names.
    ordered_names =
      case Process.get(:_pm_content_match_node_order) do
        nil -> Map.keys(node_types) |> Enum.sort()
        names -> names
      end

    %TokenStream{
      string: string,
      node_types: node_types,
      node_names_ordered: ordered_names,
      tokens: tokens,
      pos: 0,
      inline: nil
    }
  end

  defp current_token(%TokenStream{tokens: tokens, pos: pos}) do
    if pos < length(tokens), do: Enum.at(tokens, pos)
  end

  defp eat(%TokenStream{} = stream, tok) do
    if current_token(stream) == tok do
      {true, %{stream | pos: stream.pos + 1}}
    else
      {false, stream}
    end
  end

  defp advance(%TokenStream{} = stream) do
    %{stream | pos: stream.pos + 1}
  end

  defp parse_err(%TokenStream{string: string}, msg) do
    raise SyntaxError, description: "#{msg} (in content expression '#{string}')"
  end

  # ── Parser ────────────────────────────────────────────────────────

  defp parse_expr(stream) do
    {first, stream} = parse_expr_seq(stream)
    do_parse_choice([first], stream)
  end

  defp do_parse_choice(exprs, stream) do
    {ate, stream} = eat(stream, "|")

    if ate do
      {next, stream} = parse_expr_seq(stream)
      do_parse_choice(exprs ++ [next], stream)
    else
      expr = if length(exprs) == 1, do: hd(exprs), else: {:choice, exprs}
      {expr, stream}
    end
  end

  defp parse_expr_seq(stream) do
    {first, stream} = parse_expr_subscript(stream)
    do_parse_seq([first], stream)
  end

  defp do_parse_seq(exprs, stream) do
    tok = current_token(stream)

    if tok != nil and tok != ")" and tok != "|" do
      {next, stream} = parse_expr_subscript(stream)
      do_parse_seq(exprs ++ [next], stream)
    else
      expr = if length(exprs) == 1, do: hd(exprs), else: {:seq, exprs}
      {expr, stream}
    end
  end

  defp parse_expr_subscript(stream) do
    {expr, stream} = parse_expr_atom(stream)
    do_parse_subscript(expr, stream)
  end

  defp do_parse_subscript(expr, stream) do
    cond do
      current_token(stream) == "+" ->
        do_parse_subscript({:plus, expr}, advance(stream))

      current_token(stream) == "*" ->
        do_parse_subscript({:star, expr}, advance(stream))

      current_token(stream) == "?" ->
        do_parse_subscript({:opt, expr}, advance(stream))

      current_token(stream) == "{" ->
        stream = advance(stream)
        {range_expr, stream} = parse_expr_range(stream, expr)
        do_parse_subscript(range_expr, stream)

      true ->
        {expr, stream}
    end
  end

  defp parse_num(stream) do
    tok = current_token(stream)

    if tok == nil or Regex.match?(~r/\D/, tok) do
      parse_err(stream, "Expected number, got '#{tok}'")
    end

    {result, ""} = Integer.parse(tok)
    {result, advance(stream)}
  end

  defp parse_expr_range(stream, expr) do
    {min, stream} = parse_num(stream)
    {ate_comma, stream} = eat(stream, ",")

    {max, stream} =
      if ate_comma do
        if current_token(stream) != "}" do
          parse_num(stream)
        else
          {-1, stream}
        end
      else
        {min, stream}
      end

    {ate_close, stream} = eat(stream, "}")

    if not ate_close do
      parse_err(stream, "Unclosed braced range")
    end

    {{:range, min, max, expr}, stream}
  end

  defp parse_expr_atom(stream) do
    {ate_paren, stream} = eat(stream, "(")

    if ate_paren do
      {expr, stream} = parse_expr(stream)
      {ate_close, stream} = eat(stream, ")")

      if not ate_close do
        parse_err(stream, "Missing closing paren")
      end

      {expr, stream}
    else
      tok = current_token(stream)

      if tok == nil or Regex.match?(~r/\W/, tok) do
        parse_err(stream, "Unexpected token '#{tok}'")
      end

      {types, stream} = resolve_name(stream, tok)

      {exprs, stream} =
        Enum.reduce(types, {[], stream}, fn type, {acc, s} ->
          s =
            if s.inline == nil do
              %{s | inline: type.is_inline}
            else
              if s.inline != type.is_inline do
                parse_err(s, "Mixing inline and block content")
              end

              s
            end

          {acc ++ [{:name, type}], s}
        end)

      stream = advance(stream)

      expr = if length(exprs) == 1, do: hd(exprs), else: {:choice, exprs}

      {expr, stream}
    end
  end

  defp resolve_name(stream, name) do
    types = stream.node_types

    case Map.get(types, name) do
      nil ->
        # Use ordered names to maintain definition order (matches JS OrderedMap behavior)
        result =
          stream.node_names_ordered
          |> Enum.map(&Map.get(types, &1))
          |> Enum.filter(fn
            nil -> false
            type -> NodeType.is_in_group(type, name)
          end)

        if result == [] do
          parse_err(stream, "No node type or group '#{name}' found")
        end

        {result, stream}

      type ->
        {[type], stream}
    end
  end

  # ── NFA Builder ───────────────────────────────────────────────────

  defp build_nfa(expr) do
    ref = make_ref()
    Process.put({:nfa, ref}, %{0 => []})
    Process.put({:nfa_next_id, ref}, 1)

    edge_ids = compile_nfa(expr, 0, ref)
    final_id = nfa_new_node(ref)
    nfa_connect(edge_ids, final_id, ref)

    nfa_map = Process.get({:nfa, ref})
    max_id = Process.get({:nfa_next_id, ref}) - 1

    Process.delete({:nfa, ref})
    Process.delete({:nfa_next_id, ref})

    for i <- 0..max_id do
      edges = Map.get(nfa_map, i, [])
      Enum.map(edges, fn {_eref, term, to} -> {term, to} end)
    end
  end

  defp nfa_new_node(ref) do
    id = Process.get({:nfa_next_id, ref})
    nfa_map = Process.get({:nfa, ref})
    Process.put({:nfa, ref}, Map.put(nfa_map, id, []))
    Process.put({:nfa_next_id, ref}, id + 1)
    id
  end

  defp nfa_add_edge(from, to, term, ref) do
    edge_ref = make_ref()
    nfa_map = Process.get({:nfa, ref})
    edges = Map.get(nfa_map, from, [])
    Process.put({:nfa, ref}, Map.put(nfa_map, from, edges ++ [{edge_ref, term, to}]))
    edge_ref
  end

  defp nfa_connect(edge_refs, to, ref) do
    nfa_map = Process.get({:nfa, ref})

    updated =
      Enum.reduce(nfa_map, nfa_map, fn {state_id, edges}, acc ->
        updated_edges =
          Enum.map(edges, fn {eref, term, edge_to} = edge ->
            if edge_to == nil and Enum.member?(edge_refs, eref) do
              {eref, term, to}
            else
              edge
            end
          end)

        Map.put(acc, state_id, updated_edges)
      end)

    Process.put({:nfa, ref}, updated)
  end

  defp compile_nfa(expr, from, ref) do
    case expr do
      {:choice, exprs} ->
        Enum.flat_map(exprs, fn e -> compile_nfa(e, from, ref) end)

      {:seq, exprs} ->
        compile_nfa_seq(exprs, 0, from, ref)

      {:star, inner} ->
        loop = nfa_new_node(ref)
        nfa_add_edge(from, loop, nil, ref)
        inner_edges = compile_nfa(inner, loop, ref)
        nfa_connect(inner_edges, loop, ref)
        [nfa_add_edge(loop, nil, nil, ref)]

      {:plus, inner} ->
        loop = nfa_new_node(ref)
        inner_edges = compile_nfa(inner, from, ref)
        nfa_connect(inner_edges, loop, ref)
        inner_edges2 = compile_nfa(inner, loop, ref)
        nfa_connect(inner_edges2, loop, ref)
        [nfa_add_edge(loop, nil, nil, ref)]

      {:opt, inner} ->
        [nfa_add_edge(from, nil, nil, ref) | compile_nfa(inner, from, ref)]

      {:range, min, max, inner} ->
        cur =
          Enum.reduce(0..(min - 1)//1, from, fn _i, c ->
            next = nfa_new_node(ref)
            inner_edges = compile_nfa(inner, c, ref)
            nfa_connect(inner_edges, next, ref)
            next
          end)

        if max == -1 do
          inner_edges = compile_nfa(inner, cur, ref)
          nfa_connect(inner_edges, cur, ref)
          [nfa_add_edge(cur, nil, nil, ref)]
        else
          cur =
            Enum.reduce(min..(max - 1)//1, cur, fn _i, c ->
              next = nfa_new_node(ref)
              nfa_add_edge(c, next, nil, ref)
              inner_edges = compile_nfa(inner, c, ref)
              nfa_connect(inner_edges, next, ref)
              next
            end)

          [nfa_add_edge(cur, nil, nil, ref)]
        end

      {:name, type} ->
        [nfa_add_edge(from, nil, type, ref)]
    end
  end

  defp compile_nfa_seq(exprs, i, from, ref) do
    edges = compile_nfa(Enum.at(exprs, i), from, ref)

    if i == length(exprs) - 1 do
      edges
    else
      next = nfa_new_node(ref)
      nfa_connect(edges, next, ref)
      compile_nfa_seq(exprs, i + 1, next, ref)
    end
  end

  # ── NFA to DFA conversion ─────────────────────────────────────────
  #
  # We build the DFA as a graph stored in an ETS table. Each DFA state
  # is identified by a string key (the sorted NFA state set). States
  # store their valid_end flag and edge list [{type, target_key}].
  #
  # After building the full graph, we create ContentMatch structs that
  # reference the ETS table for edge lookups. This naturally handles
  # cycles because edges are resolved lazily via the shared ETS table.

  defp build_dfa(nfa) do
    nfa_len = length(nfa)
    nfa_arr = :array.from_list(nfa)

    # Build the DFA graph in a temporary map
    graph_ref = make_ref()
    Process.put({:dfa_graph, graph_ref}, %{})

    initial_states = null_from(nfa_arr, 0)
    initial_key = states_key(initial_states)
    dfa_explore(initial_states, nfa_arr, nfa_len, graph_ref)

    graph = Process.get({:dfa_graph, graph_ref})
    Process.delete({:dfa_graph, graph_ref})

    # Create ETS registry for the DFA
    reg = :ets.new(:content_match_reg, [:set, :public])

    # Create ContentMatch structs and store in registry
    Enum.each(graph, fn {key, {valid_end, _edges}} ->
      state = %__MODULE__{
        valid_end: valid_end,
        next: [],
        wrap_cache: [],
        _reg: reg,
        _id: key
      }

      :ets.insert(reg, {{:state, key}, state})
    end)

    # Store edges
    Enum.each(graph, fn {key, {_valid_end, edges}} ->
      :ets.insert(reg, {{:edges, key}, edges})
    end)

    # Return the initial state
    get_state(reg, initial_key)
  end

  defp dfa_explore(states, nfa_arr, nfa_len, graph_ref) do
    key = states_key(states)
    graph = Process.get({:dfa_graph, graph_ref})

    case Map.get(graph, key) do
      nil ->
        valid_end = Enum.member?(states, nfa_len - 1)

        # Collect outgoing transitions
        out = collect_dfa_transitions(states, nfa_arr)

        edge_specs =
          Enum.map(out, fn {type, target_states} ->
            sorted = Enum.sort(target_states, :desc)
            {type, states_key(sorted), sorted}
          end)

        # Store in graph BEFORE exploring children (to handle cycles)
        Process.put(
          {:dfa_graph, graph_ref},
          Map.put(
            Process.get({:dfa_graph, graph_ref}),
            key,
            {valid_end, Enum.map(edge_specs, fn {type, tkey, _} -> {type, tkey} end)}
          )
        )

        # Explore children
        Enum.each(edge_specs, fn {_type, _tkey, sorted} ->
          dfa_explore(sorted, nfa_arr, nfa_len, graph_ref)
        end)

      _ ->
        :ok
    end
  end

  defp collect_dfa_transitions(states, nfa_arr) do
    Enum.reduce(states, [], fn node_id, out ->
      edges = :array.get(node_id, nfa_arr)

      Enum.reduce(edges, out, fn {term, to}, out ->
        if term == nil do
          out
        else
          target_states = null_from(nfa_arr, to)

          case find_out_index(out, term) do
            nil ->
              out ++ [{term, target_states}]

            idx ->
              {_t, existing_states} = Enum.at(out, idx)
              merged = merge_state_sets(existing_states, target_states)
              List.replace_at(out, idx, {term, merged})
          end
        end
      end)
    end)
  end

  defp null_from(nfa_arr, node_id) do
    result_ref = make_ref()
    Process.put({:null_result, result_ref}, [])

    null_scan(nfa_arr, node_id, result_ref)

    result = Process.get({:null_result, result_ref})
    Process.delete({:null_result, result_ref})

    Enum.sort(result, :desc)
  end

  defp null_scan(nfa_arr, node_id, result_ref) do
    edges = :array.get(node_id, nfa_arr)

    case edges do
      [{nil, to}] when to != nil ->
        null_scan(nfa_arr, to, result_ref)

      _ ->
        result = Process.get({:null_result, result_ref})

        if not Enum.member?(result, node_id) do
          Process.put({:null_result, result_ref}, [node_id | result])

          Enum.each(edges, fn {term, to} ->
            if term == nil and to != nil do
              cur_result = Process.get({:null_result, result_ref})

              if not Enum.member?(cur_result, to) do
                null_scan(nfa_arr, to, result_ref)
              end
            end
          end)
        end
    end
  end

  defp find_out_index(out, term) do
    Enum.find_index(out, fn {t, _} -> t.name == term.name end)
  end

  defp merge_state_sets(existing, new_states) do
    Enum.reduce(new_states, existing, fn s, acc ->
      if Enum.member?(acc, s), do: acc, else: acc ++ [s]
    end)
  end

  defp states_key(states), do: Enum.join(states, ",")

  # ── Dead-end checker ──────────────────────────────────────────────

  defp check_for_dead_ends(match, stream) do
    do_check_dead_ends([match], MapSet.new([match._id]), 0, stream)
  end

  defp do_check_dead_ends(work, _seen, i, _stream) when i >= length(work), do: :ok

  defp do_check_dead_ends(work, seen, i, stream) do
    state = Enum.at(work, i)
    edges = get_edges(state)
    dead = not state.valid_end
    nodes = Enum.map(edges, fn {type, _} -> type.name end)

    {dead, work, seen} =
      Enum.reduce(edges, {dead, work, seen}, fn {type, next_id}, {d, w, s} ->
        d =
          if d and not type.is_text and not (type.has_required_attrs == true),
            do: false,
            else: d

        {w, s} =
          if MapSet.member?(s, next_id) do
            {w, s}
          else
            next = get_state(state._reg, next_id)
            {w ++ [next], MapSet.put(s, next_id)}
          end

        {d, w, s}
      end)

    if dead and length(nodes) > 0 do
      parse_err(
        stream,
        "Only non-generatable nodes (#{Enum.join(nodes, ", ")}) in a required position"
      )
    end

    do_check_dead_ends(work, seen, i + 1, stream)
  end
end
