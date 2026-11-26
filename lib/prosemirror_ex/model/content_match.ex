defmodule ProsemirrorEx.Model.ContentMatch do
  @moduledoc """
  Instances of this struct represent a match state of a node type's
  content expression, and can be used to find out whether further
  content matches here, and whether a given position is a valid end
  of the node.

  Ported from ProseMirror's content.ts.

  DFA states (including cycles such as `image*`) are represented as an
  immutable, garbage-collected state graph stored in `states` keyed by
  integer `state_id`, with zero ETS tables or mutable process state.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.NodeType

  @type state_id :: non_neg_integer()
  @type edge :: {NodeType.t(), state_id()}
  @type dfa_state :: %{
          valid_end: boolean(),
          edges: [edge()],
          edge_map: %{String.t() => state_id()},
          wrap_cache: %{String.t() => [NodeType.t()]} | nil
        }

  @type t :: %__MODULE__{
          valid_end: boolean(),
          next: [{NodeType.t(), t()}],
          wrap_cache: %{String.t() => [NodeType.t()]} | nil,
          states: %{state_id() => dfa_state()} | nil,
          state_id: state_id()
        }

  defstruct valid_end: true, next: [], wrap_cache: %{}, states: nil, state_id: 0

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Parse a content expression string into a ContentMatch DFA.

  `node_types` is a map of name => `%NodeType{}`.
  Optional `node_order` specifies the ordered list of node names for group
  resolution (matching JS `OrderedMap` definition order).
  """
  @spec parse(String.t(), %{String.t() => NodeType.t()}, [String.t()] | nil) :: t()
  def parse(string, node_types, node_order \\ nil)

  def parse("", _node_types, _node_order), do: empty()

  def parse(string, node_types, node_order)
      when is_binary(string) and is_map(node_types) do
    stream = tokenize(string, node_types, node_order)

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
  @spec match_type(t() | nil, NodeType.t()) :: t() | nil
  def match_type(nil, _type), do: nil

  def match_type(%__MODULE__{states: nil, next: next}, %NodeType{name: name}) do
    Enum.find_value(next, fn {edge_type, next_cm} ->
      if edge_type.name == name, do: next_cm
    end)
  end

  def match_type(%__MODULE__{states: states, state_id: id}, %NodeType{name: name}) do
    state = Map.fetch!(states, id)

    case Map.get(state.edge_map, name) do
      nil -> nil
      next_id -> build_state(states, next_id)
    end
  end

  @doc "Try to match a fragment. Returns the resulting match when successful."
  @spec match_fragment(t() | nil, Fragment.t(), non_neg_integer(), non_neg_integer() | nil) ::
          t() | nil
  def match_fragment(match, frag, start \\ 0, end_val \\ nil)

  def match_fragment(nil, _frag, _start, _end_val), do: nil

  def match_fragment(%__MODULE__{} = match, %Fragment{content: content}, start, nil) do
    sliced = if start == 0, do: content, else: Enum.drop(content, start)
    match_node_list(match, sliced)
  end

  def match_fragment(%__MODULE__{} = match, %Fragment{content: content}, start, end_val) do
    if start >= end_val do
      match
    else
      sliced = if start == 0, do: content, else: Enum.drop(content, start)
      match_node_list_take(match, sliced, end_val - start)
    end
  end

  defp match_node_list(match, []), do: match

  defp match_node_list(%__MODULE__{states: nil} = match, [child | rest]) do
    case match_type(match, child.type) do
      nil -> nil
      next -> match_node_list(next, rest)
    end
  end

  defp match_node_list(%__MODULE__{states: states, state_id: id} = match, list) do
    case step_states(list, states, id) do
      nil -> nil
      ^id -> match
      final_id -> build_state(states, final_id)
    end
  end

  defp step_states([], _states, id), do: id

  defp step_states([child | rest], states, id) do
    edge_map = Map.fetch!(states, id).edge_map

    case Map.get(edge_map, child.type.name) do
      nil -> nil
      next_id -> step_states(rest, states, next_id)
    end
  end

  defp match_node_list_take(match, _list, 0), do: match
  defp match_node_list_take(match, [], _remaining), do: match

  defp match_node_list_take(%__MODULE__{states: nil} = match, [child | rest], remaining) do
    case match_type(match, child.type) do
      nil -> nil
      next -> match_node_list_take(next, rest, remaining - 1)
    end
  end

  defp match_node_list_take(
         %__MODULE__{states: states, state_id: id} = match,
         list,
         remaining
       ) do
    case step_states_take(list, remaining, states, id) do
      nil -> nil
      ^id -> match
      final_id -> build_state(states, final_id)
    end
  end

  defp step_states_take(_list, 0, _states, id), do: id
  defp step_states_take([], _remaining, _states, id), do: id

  defp step_states_take([child | rest], remaining, states, id) do
    edge_map = Map.fetch!(states, id).edge_map

    case Map.get(edge_map, child.type.name) do
      nil -> nil
      next_id -> step_states_take(rest, remaining - 1, states, next_id)
    end
  end

  @doc """
  Try to match the given fragment, and if that fails, see if it can
  be made to match by inserting nodes in front of it. When successful,
  return a fragment of inserted nodes (which may be empty if nothing
  had to be inserted). When `to_end` is true, only return a fragment
  if the resulting match goes to the end of the content expression.
  """
  @spec fill_before(t(), Fragment.t(), boolean(), non_neg_integer()) :: Fragment.t() | nil
  def fill_before(
        %__MODULE__{} = match,
        %Fragment{} = after_frag,
        to_end \\ false,
        start_index \\ 0
      ) do
    seen = MapSet.new([match.state_id])
    {result, _seen} = do_fill_before(match, [], after_frag, to_end, start_index, seen)
    result
  end

  defp do_fill_before(%__MODULE__{} = match, rev_types, after_frag, to_end, start_index, seen) do
    finished = match_fragment(match, after_frag, start_index)

    if finished != nil and (not to_end or finished.valid_end) do
      nodes = rev_types |> Enum.reverse() |> Enum.map(&NodeType.create_and_fill/1)
      {Fragment.from(nodes), seen}
    else
      edges = get_edges(match)
      find_fill(edges, match, rev_types, after_frag, to_end, start_index, seen)
    end
  end

  defp find_fill([], _match, _rev_types, _after_frag, _to_end, _start_index, seen),
    do: {nil, seen}

  defp find_fill(
         [{type, target} | rest],
         match,
         rev_types,
         after_frag,
         to_end,
         start_index,
         seen
       ) do
    target_id = edge_target_id(target)

    if not type.is_text and not (type.has_required_attrs == true) and
         not MapSet.member?(seen, target_id) do
      seen = MapSet.put(seen, target_id)
      next = resolve_edge_target(match, target)

      case do_fill_before(next, [type | rev_types], after_frag, to_end, start_index, seen) do
        {nil, seen} ->
          find_fill(rest, match, rev_types, after_frag, to_end, start_index, seen)

        {found, seen} ->
          {found, seen}
      end
    else
      find_fill(rest, match, rev_types, after_frag, to_end, start_index, seen)
    end
  end

  @doc """
  Find a set of wrapping node types that would allow a node of the
  given type to appear at this position.
  """
  @spec find_wrapping(t(), NodeType.t()) :: [NodeType.t()] | nil
  def find_wrapping(%__MODULE__{wrap_cache: wrap_cache}, %NodeType{} = target)
      when is_map(wrap_cache) do
    Map.get(wrap_cache, target.name)
  end

  def find_wrapping(%__MODULE__{} = match, %NodeType{} = target) do
    compute_wrapping(match, target)
  end

  @doc "Compute wrapping using BFS."
  @spec compute_wrapping(t(), NodeType.t()) :: [NodeType.t()] | nil
  def compute_wrapping(%__MODULE__{} = match, %NodeType{} = target) do
    seen = MapSet.new()
    active = :queue.from_list([{match, []}])
    do_compute_wrapping(active, seen, target)
  end

  defp do_compute_wrapping(active, seen, target) do
    case :queue.out(active) do
      {:empty, _} ->
        nil

      {{:value, {match, rev_path}}, rest_queue} ->
        if match_type(match, target) != nil do
          Enum.reverse(rev_path)
        else
          edges = get_edges(match)

          {new_queue, new_seen} =
            Enum.reduce(edges, {rest_queue, seen}, fn {edge_type, target_ref}, {q, s} ->
              next = resolve_edge_target(match, target_ref)

              if not edge_type.is_leaf and
                   not (edge_type.has_required_attrs == true) and
                   not MapSet.member?(s, edge_type.name) and
                   (rev_path == [] or next.valid_end) do
                content_match = edge_type.content_match || empty()

                {
                  :queue.in({content_match, [edge_type | rev_path]}, q),
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

  @doc """
  Precompute wrapping lookup tables (`wrap_cache`) for every state in this
  ContentMatch DFA using a single BFS per state.
  """
  @spec precompute_wrappings(t()) :: t()
  def precompute_wrappings(%__MODULE__{states: nil} = cm), do: cm

  def precompute_wrappings(%__MODULE__{states: states, state_id: state_id}) do
    updated_states =
      Map.new(states, fn {id, state} ->
        cm = build_state(states, id)
        wc = compute_all_wrappings(cm)
        {id, %{state | wrap_cache: wc}}
      end)

    build_state(updated_states, state_id)
  end

  defp compute_all_wrappings(start_match) do
    active = :queue.from_list([{start_match, []}])
    do_compute_all_wrappings(active, MapSet.new(), %{})
  end

  defp do_compute_all_wrappings(active, seen, wrappings) do
    case :queue.out(active) do
      {:empty, _} ->
        wrappings

      {{:value, {match, rev_path}}, rest_queue} ->
        path = Enum.reverse(rev_path)
        edges = get_edges(match)

        {new_wrappings, new_queue, new_seen} =
          Enum.reduce(edges, {wrappings, rest_queue, seen}, fn {edge_type, target_ref},
                                                               {w, q, s} ->
            w = Map.put_new(w, edge_type.name, path)

            if not edge_type.is_leaf and
                 not (edge_type.has_required_attrs == true) and
                 not MapSet.member?(s, edge_type.name) do
              next = resolve_edge_target(match, target_ref)

              if rev_path == [] or next.valid_end do
                content_match = edge_type.content_match || empty()

                {
                  w,
                  :queue.in({content_match, [edge_type | rev_path]}, q),
                  MapSet.put(s, edge_type.name)
                }
              else
                {w, q, s}
              end
            else
              {w, q, s}
            end
          end)

        do_compute_all_wrappings(new_queue, new_seen, new_wrappings)
    end
  end

  @doc "Get the first matching node type that can be generated."
  @spec default_type(t()) :: NodeType.t() | nil
  def default_type(%__MODULE__{} = cm) do
    edges = get_edges(cm)

    Enum.find_value(edges, fn {type, _target} ->
      if not type.is_text and not (type.has_required_attrs == true), do: type
    end)
  end

  @doc "Whether the match state has inline content."
  @spec inline_content(t()) :: boolean()
  def inline_content(%__MODULE__{} = cm) do
    case get_edges(cm) do
      [] -> false
      [{type, _} | _] -> type.is_inline == true
    end
  end

  @doc "The number of outgoing edges."
  @spec edge_count(t()) :: non_neg_integer()
  def edge_count(%__MODULE__{} = cm) do
    length(get_edges(cm))
  end

  @doc "Get the nth outgoing edge as {type, next_match}."
  @spec edge(t(), non_neg_integer()) :: {NodeType.t(), t()}
  def edge(%__MODULE__{} = cm, n) do
    edges = get_edges(cm)

    case Enum.fetch(edges, n) do
      {:ok, {type, target}} -> {type, resolve_edge_target(cm, target)}
      :error -> raise "There's no #{n}th edge in this content match"
    end
  end

  @doc "Whether this match state is compatible with another."
  @spec compatible(t(), t()) :: boolean()
  def compatible(%__MODULE__{} = cm_a, %__MODULE__{} = cm_b) do
    edges_a = get_edges(cm_a)
    edges_b = get_edges(cm_b)

    Enum.any?(edges_a, fn {type_a, _} ->
      Enum.any?(edges_b, fn {type_b, _} -> type_a.name == type_b.name end)
    end)
  end

  @doc "The empty content match (matches only empty content)."
  @spec empty() :: t()
  def empty do
    %__MODULE__{valid_end: true, next: [], wrap_cache: %{}, states: nil, state_id: 0}
  end

  @doc """
  Update the node types stored in this content match's DFA edges.
  Takes a map of `name => updated_node_type` and returns the updated
  ContentMatch struct.
  """
  @spec update_node_types(t(), %{String.t() => NodeType.t()}) :: t()
  def update_node_types(%__MODULE__{states: nil} = cm, _node_types), do: cm

  def update_node_types(%__MODULE__{states: states, state_id: state_id}, node_types)
      when is_map(node_types) do
    updated_states =
      Map.new(states, fn {id, state} ->
        updated_edges =
          Enum.map(state.edges, fn {type, target_id} ->
            {Map.get(node_types, type.name, type), target_id}
          end)

        updated_wrap_cache =
          case state.wrap_cache do
            nil ->
              nil

            wc ->
              Map.new(wc, fn {target_name, wrappers} ->
                {target_name, Enum.map(wrappers, fn w -> Map.get(node_types, w.name, w) end)}
              end)
          end

        {id, %{state | edges: updated_edges, wrap_cache: updated_wrap_cache}}
      end)

    build_state(updated_states, state_id)
  end

  # ── State helpers ──────────────────────────────────────────────────

  defp get_edges(%__MODULE__{states: nil, next: next}), do: next
  defp get_edges(%__MODULE__{states: states, state_id: id}), do: Map.fetch!(states, id).edges

  defp build_state(states, id) do
    state = Map.fetch!(states, id)

    %__MODULE__{
      valid_end: state.valid_end,
      next: [],
      wrap_cache: state.wrap_cache,
      states: states,
      state_id: id
    }
  end

  defp resolve_edge_target(%__MODULE__{states: nil}, %__MODULE__{} = next_cm), do: next_cm
  defp resolve_edge_target(%__MODULE__{states: states}, next_id), do: build_state(states, next_id)

  defp edge_target_id(%__MODULE__{state_id: id}), do: id
  defp edge_target_id(id), do: id

  # ── Tokenizer ─────────────────────────────────────────────────────

  defmodule TokenStream do
    @moduledoc false
    defstruct [:string, :node_types, :node_names_ordered, :tokens, :inline]
  end

  defp tokenize(string, node_types, node_order) do
    tokens =
      Regex.split(~r/\s*(?=\b|\W|$)/, string)
      |> Enum.reject(&(&1 == ""))

    ordered_names =
      case node_order do
        nil -> Map.keys(node_types) |> Enum.sort()
        names when is_list(names) -> names
      end

    %TokenStream{
      string: string,
      node_types: node_types,
      node_names_ordered: ordered_names,
      tokens: tokens,
      inline: nil
    }
  end

  defp current_token(%TokenStream{tokens: []}), do: nil
  defp current_token(%TokenStream{tokens: [tok | _]}), do: tok

  defp eat(%TokenStream{tokens: [tok | rest]} = stream, tok),
    do: {true, %{stream | tokens: rest}}

  defp eat(%TokenStream{} = stream, _tok), do: {false, stream}

  defp advance(%TokenStream{tokens: [_ | rest]} = stream), do: %{stream | tokens: rest}
  defp advance(%TokenStream{} = stream), do: stream

  defp parse_err(%TokenStream{string: string}, msg) do
    raise "#{msg} (in content expression '#{string}')"
  end

  # ── Parser ────────────────────────────────────────────────────────

  defp parse_expr(stream) do
    {first, stream} = parse_expr_seq(stream)
    do_parse_choice([first], stream)
  end

  defp do_parse_choice(rev_exprs, stream) do
    {ate, stream} = eat(stream, "|")

    if ate do
      {next, stream} = parse_expr_seq(stream)
      do_parse_choice([next | rev_exprs], stream)
    else
      expr =
        case rev_exprs do
          [single] -> single
          _ -> {:choice, Enum.reverse(rev_exprs)}
        end

      {expr, stream}
    end
  end

  defp parse_expr_seq(stream) do
    {first, stream} = parse_expr_subscript(stream)
    do_parse_seq([first], stream)
  end

  defp do_parse_seq(rev_exprs, stream) do
    tok = current_token(stream)

    if tok != nil and tok != ")" and tok != "|" do
      {next, stream} = parse_expr_subscript(stream)
      do_parse_seq([next | rev_exprs], stream)
    else
      expr =
        case rev_exprs do
          [single] -> single
          _ -> {:seq, Enum.reverse(rev_exprs)}
        end

      {expr, stream}
    end
  end

  defp parse_expr_subscript(stream) do
    {expr, stream} = parse_expr_atom(stream)
    do_parse_subscript(expr, stream)
  end

  defp do_parse_subscript(expr, stream) do
    case current_token(stream) do
      "+" ->
        do_parse_subscript({:plus, expr}, advance(stream))

      "*" ->
        do_parse_subscript({:star, expr}, advance(stream))

      "?" ->
        do_parse_subscript({:opt, expr}, advance(stream))

      "{" ->
        stream = advance(stream)
        {range_expr, stream} = parse_expr_range(stream, expr)
        do_parse_subscript(range_expr, stream)

      _ ->
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

    if max != -1 and max < min do
      parse_err(stream, "Invalid range {#{min}, #{max}}")
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

      {rev_exprs, stream} =
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

          {[{:name, type} | acc], s}
        end)

      stream = advance(stream)

      expr =
        case rev_exprs do
          [single] -> single
          _ -> {:choice, Enum.reverse(rev_exprs)}
        end

      {expr, stream}
    end
  end

  defp resolve_name(stream, name) do
    types = stream.node_types

    case Map.get(types, name) do
      nil ->
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
    state = %{nodes: %{0 => []}, next_id: 1, edge_seq: 0}
    {edge_ids, state} = compile_nfa(expr, 0, state)
    {final_id, state} = nfa_new_node(state)
    state = nfa_connect(state, edge_ids, final_id)

    nfa_map = state.nodes
    max_id = state.next_id - 1

    for i <- 0..max_id do
      nfa_map
      |> Map.get(i, [])
      |> Enum.reverse()
      |> Enum.map(fn {_eid, term, to} -> {term, to} end)
    end
  end

  defp nfa_new_node(%{nodes: nodes, next_id: id} = state) do
    {id, %{state | nodes: Map.put(nodes, id, []), next_id: id + 1}}
  end

  defp nfa_add_edge(%{nodes: nodes, edge_seq: seq} = state, from, to, term) do
    edge_id = {from, seq}
    edges = Map.get(nodes, from, [])
    updated_nodes = Map.put(nodes, from, [{edge_id, term, to} | edges])
    {edge_id, %{state | nodes: updated_nodes, edge_seq: seq + 1}}
  end

  defp nfa_connect(state, [], _to), do: state

  defp nfa_connect(%{nodes: nodes} = state, edge_ids, to) do
    by_from =
      Enum.reduce(edge_ids, %{}, fn {from, _seq} = eid, acc ->
        Map.update(acc, from, MapSet.new([eid]), &MapSet.put(&1, eid))
      end)

    updated_nodes =
      Enum.reduce(by_from, nodes, fn {from, eid_set}, acc ->
        updated_edges =
          acc
          |> Map.get(from, [])
          |> Enum.map(fn {eid, term, edge_to} = edge ->
            if edge_to == nil and MapSet.member?(eid_set, eid) do
              {eid, term, to}
            else
              edge
            end
          end)

        Map.put(acc, from, updated_edges)
      end)

    %{state | nodes: updated_nodes}
  end

  defp compile_nfa(expr, from, state) do
    case expr do
      {:choice, exprs} ->
        {rev_edges, state} =
          Enum.reduce(exprs, {[], state}, fn e, {acc, s} ->
            {edges, s} = compile_nfa(e, from, s)
            {Enum.reverse(edges, acc), s}
          end)

        {Enum.reverse(rev_edges), state}

      {:seq, exprs} ->
        compile_nfa_seq(exprs, from, state)

      {:star, inner} ->
        {loop, state} = nfa_new_node(state)
        {_e, state} = nfa_add_edge(state, from, loop, nil)
        {inner_edges, state} = compile_nfa(inner, loop, state)
        state = nfa_connect(state, inner_edges, loop)
        {out_edge, state} = nfa_add_edge(state, loop, nil, nil)
        {[out_edge], state}

      {:plus, inner} ->
        {loop, state} = nfa_new_node(state)
        {inner_edges, state} = compile_nfa(inner, from, state)
        state = nfa_connect(state, inner_edges, loop)
        {inner_edges2, state} = compile_nfa(inner, loop, state)
        state = nfa_connect(state, inner_edges2, loop)
        {out_edge, state} = nfa_add_edge(state, loop, nil, nil)
        {[out_edge], state}

      {:opt, inner} ->
        {skip_edge, state} = nfa_add_edge(state, from, nil, nil)
        {inner_edges, state} = compile_nfa(inner, from, state)
        {[skip_edge | inner_edges], state}

      {:range, min, max, inner} ->
        {cur, state} = compile_nfa_required(min, from, inner, state)

        if max == -1 do
          {inner_edges, state} = compile_nfa(inner, cur, state)
          state = nfa_connect(state, inner_edges, cur)
          {out_edge, state} = nfa_add_edge(state, cur, nil, nil)
          {[out_edge], state}
        else
          {cur, state} = compile_nfa_optional(max - min, cur, inner, state)
          {out_edge, state} = nfa_add_edge(state, cur, nil, nil)
          {[out_edge], state}
        end

      {:name, type} ->
        {edge, state} = nfa_add_edge(state, from, nil, type)
        {[edge], state}
    end
  end

  defp compile_nfa_seq([last], from, state), do: compile_nfa(last, from, state)

  defp compile_nfa_seq([first | rest], from, state) do
    {edges, state} = compile_nfa(first, from, state)
    {next, state} = nfa_new_node(state)
    state = nfa_connect(state, edges, next)
    compile_nfa_seq(rest, next, state)
  end

  defp compile_nfa_required(0, cur, _inner, state), do: {cur, state}

  defp compile_nfa_required(n, cur, inner, state) when n > 0 do
    {next, state} = nfa_new_node(state)
    {inner_edges, state} = compile_nfa(inner, cur, state)
    state = nfa_connect(state, inner_edges, next)
    compile_nfa_required(n - 1, next, inner, state)
  end

  defp compile_nfa_optional(n, cur, _inner, state) when n <= 0, do: {cur, state}

  defp compile_nfa_optional(n, cur, inner, state) do
    {next, state} = nfa_new_node(state)
    {_skip, state} = nfa_add_edge(state, cur, next, nil)
    {inner_edges, state} = compile_nfa(inner, cur, state)
    state = nfa_connect(state, inner_edges, next)
    compile_nfa_optional(n - 1, next, inner, state)
  end

  # ── NFA to DFA conversion ─────────────────────────────────────────

  defp build_dfa(nfa) do
    nfa_len = length(nfa)
    nfa_arr = :array.from_list(nfa)

    initial_states = null_from(nfa_arr, 0)

    {initial_id, {states_graph, _key_to_id, _next_id}} =
      dfa_explore(initial_states, nfa_arr, nfa_len, {%{}, %{}, 0})

    build_state(states_graph, initial_id)
  end

  defp dfa_explore(states, nfa_arr, nfa_len, {graph, key_to_id, next_id} = acc) do
    case Map.get(key_to_id, states) do
      id when is_integer(id) ->
        {id, acc}

      nil ->
        id = next_id
        acc = {graph, Map.put(key_to_id, states, id), next_id + 1}

        valid_end = Enum.member?(states, nfa_len - 1)
        out = collect_dfa_transitions(states, nfa_arr)

        {rev_edges, edge_map, {graph, key_to_id, next_id}} =
          Enum.reduce(out, {[], %{}, acc}, fn {type, target_states}, {es, em, a} ->
            {target_id, a} = dfa_explore(target_states, nfa_arr, nfa_len, a)
            {[{type, target_id} | es], Map.put(em, type.name, target_id), a}
          end)

        state_entry = %{
          valid_end: valid_end,
          edges: Enum.reverse(rev_edges),
          edge_map: edge_map,
          wrap_cache: nil
        }

        {id, {Map.put(graph, id, state_entry), key_to_id, next_id}}
    end
  end

  defp collect_dfa_transitions(states, nfa_arr) do
    {rev_order, by_name} =
      Enum.reduce(states, {[], %{}}, fn node_id, {order, map} ->
        edges = :array.get(node_id, nfa_arr)

        Enum.reduce(edges, {order, map}, fn {term, to}, {ord, m} ->
          if term == nil do
            {ord, m}
          else
            target_set = null_from(nfa_arr, to) |> MapSet.new()

            case Map.get(m, term.name) do
              nil ->
                {[term.name | ord], Map.put(m, term.name, {term, target_set})}

              {existing_term, existing_set} ->
                {ord,
                 Map.put(m, term.name, {existing_term, MapSet.union(existing_set, target_set)})}
            end
          end
        end)
      end)

    rev_order
    |> Enum.reverse()
    |> Enum.map(fn name ->
      {term, set} = Map.fetch!(by_name, name)
      {term, set |> MapSet.to_list() |> Enum.sort(:desc)}
    end)
  end

  defp null_from(nfa_arr, node_id) do
    {result, _seen} = null_scan(nfa_arr, node_id, [], MapSet.new())
    Enum.sort(result, :desc)
  end

  defp null_scan(nfa_arr, node_id, result, seen) do
    case :array.get(node_id, nfa_arr) do
      [{nil, to}] when to != nil ->
        if MapSet.member?(seen, node_id) do
          {result, seen}
        else
          null_scan(nfa_arr, to, result, MapSet.put(seen, node_id))
        end

      edges ->
        if MapSet.member?(seen, node_id) do
          {result, seen}
        else
          result = [node_id | result]
          seen = MapSet.put(seen, node_id)

          Enum.reduce(edges, {result, seen}, fn
            {nil, to}, {res, s} when to != nil ->
              if MapSet.member?(s, to), do: {res, s}, else: null_scan(nfa_arr, to, res, s)

            _, acc ->
              acc
          end)
        end
    end
  end

  # ── Dead-end checker ──────────────────────────────────────────────

  defp check_for_dead_ends(%__MODULE__{} = match, stream) do
    queue = :queue.from_list([match])
    seen = MapSet.new([match.state_id])
    do_check_dead_ends(queue, seen, stream)
  end

  defp do_check_dead_ends(queue, seen, stream) do
    case :queue.out(queue) do
      {:empty, _} ->
        :ok

      {{:value, state}, rest_queue} ->
        edges = get_edges(state)
        dead = not state.valid_end
        nodes = Enum.map(edges, fn {type, _} -> type.name end)

        {dead, new_queue, new_seen} =
          Enum.reduce(edges, {dead, rest_queue, seen}, fn {type, next_id}, {d, q, s} ->
            d =
              if d and not type.is_text and not (type.has_required_attrs == true),
                do: false,
                else: d

            if MapSet.member?(s, next_id) do
              {d, q, s}
            else
              next = resolve_edge_target(state, next_id)
              {d, :queue.in(next, q), MapSet.put(s, next_id)}
            end
          end)

        if dead and nodes != [] do
          parse_err(
            stream,
            "Only non-generatable nodes (#{Enum.join(nodes, ", ")}) in a required position"
          )
        end

        do_check_dead_ends(new_queue, new_seen, stream)
    end
  end
end
