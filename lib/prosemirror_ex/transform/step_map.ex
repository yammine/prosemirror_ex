defmodule ProsemirrorEx.Transform.StepMap do
  @moduledoc """
  A map describing the deletions and insertions made by a step, which
  can be used to find the correspondence between positions in the
  pre-step version of a document and the same position in the post-step version.

  Ports `StepMap` from prosemirror-transform/src/map.ts.
  """

  import Bitwise

  alias ProsemirrorEx.Transform.MapResult

  @factor16 0x10000
  @lower16 0xFFFF

  defstruct ranges: [], inverted: false

  @type t :: %__MODULE__{
          ranges: [non_neg_integer()],
          inverted: boolean()
        }

  # ── Recovery encoding helpers ────────────────────────────────────────

  @doc false
  @spec make_recover(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def make_recover(index, offset), do: index + offset * @factor16

  @doc false
  @spec recover_index(non_neg_integer()) :: non_neg_integer()
  def recover_index(value), do: band(value, @lower16)

  @doc false
  @spec recover_offset(non_neg_integer()) :: non_neg_integer()
  def recover_offset(value), do: div(value - band(value, @lower16), @factor16)

  # ── Constructor helpers ──────────────────────────────────────────────

  @doc """
  Create a new StepMap from a flat list of `[start, old_size, new_size, ...]` triples.
  """
  @spec new([non_neg_integer()], boolean()) :: t()
  def new(ranges, inverted \\ false) when is_list(ranges) and is_boolean(inverted) do
    %__MODULE__{ranges: ranges, inverted: inverted}
  end

  @doc "A StepMap that contains no changed ranges."
  @spec empty() :: t()
  def empty, do: %__MODULE__{ranges: [], inverted: false}

  @doc """
  Create a map that moves all positions by offset `n` (which may be negative).
  """
  @spec offset(integer()) :: t()
  def offset(0), do: empty()
  def offset(n) when n < 0, do: %__MODULE__{ranges: [0, -n, 0], inverted: false}
  def offset(n), do: %__MODULE__{ranges: [0, 0, n], inverted: false}

  # ── Public mapping & query APIs ──────────────────────────────────────

  @doc """
  Map a position through this step map. `assoc` determines with which side
  the position is associated (-1 or 1, defaults to 1).
  """
  @spec map(t(), integer(), integer()) :: integer()
  def map(%__MODULE__{} = step_map, pos, assoc \\ 1) do
    do_map(step_map, pos, assoc, true)
  end

  @doc """
  Map a position through this step map, returning a `MapResult`.
  """
  @spec map_result(t(), integer(), integer()) :: MapResult.t()
  def map_result(%__MODULE__{} = step_map, pos, assoc \\ 1) do
    do_map(step_map, pos, assoc, false)
  end

  @doc """
  Test whether the given position touches the range encoded in `recover_value`.
  """
  @spec touches(t(), integer(), non_neg_integer()) :: boolean()
  def touches(%__MODULE__{ranges: ranges, inverted: inverted}, pos, recover_value) do
    index = recover_index(recover_value)
    touches_loop(ranges, pos, index, inverted, 0, 0)
  end

  defp touches_loop([], _pos, _target_index, _inverted, _index, _diff), do: false

  defp touches_loop([raw_start, a, b | rest], pos, target_index, inverted, index, diff) do
    {old_size, new_size, start} =
      if inverted do
        {b, a, raw_start - diff}
      else
        {a, b, raw_start}
      end

    if start > pos do
      false
    else
      end_pos = start + old_size

      if pos <= end_pos and index == target_index do
        true
      else
        touches_loop(rest, pos, target_index, inverted, index + 1, diff + new_size - old_size)
      end
    end
  end

  # ── Recover ──────────────────────────────────────────────────────────

  @doc false
  @spec recover(t(), non_neg_integer()) :: integer()
  def recover(%__MODULE__{ranges: ranges, inverted: inverted}, value) do
    index = recover_index(value)
    {start, diff} = recover_loop(ranges, index, inverted, 0)
    start + diff + recover_offset(value)
  end

  defp recover_loop([start, _a, _b | _rest], 0, _inverted, diff), do: {start, diff}

  defp recover_loop([_start, a, b | rest], index, inverted, diff) when index > 0 do
    next_diff = if inverted, do: diff, else: diff + b - a
    recover_loop(rest, index - 1, inverted, next_diff)
  end

  # ── Core mapping ────────────────────────────────────────────────────

  @doc false
  @spec do_map(t(), integer(), integer(), true) :: integer()
  @spec do_map(t(), integer(), integer(), false) :: MapResult.t()
  def do_map(%__MODULE__{ranges: ranges, inverted: inverted}, pos, assoc, simple) do
    do_map_loop(ranges, pos, assoc, simple, inverted, 0, 0)
  end

  defp do_map_loop([], pos, _assoc, true, _inverted, _index, diff), do: pos + diff

  defp do_map_loop([], pos, _assoc, false, _inverted, _index, diff) do
    %MapResult{pos: pos + diff, del_info: 0, recover: nil}
  end

  defp do_map_loop([raw_start, a, b | rest], pos, assoc, simple, inverted, index, diff) do
    {old_size, new_size, start} =
      if inverted do
        {b, a, raw_start - diff}
      else
        {a, b, raw_start}
      end

    if start > pos do
      if simple, do: pos + diff, else: %MapResult{pos: pos + diff, del_info: 0, recover: nil}
    else
      end_pos = start + old_size

      if pos <= end_pos do
        side =
          cond do
            old_size == 0 -> assoc
            pos == start -> -1
            pos == end_pos -> 1
            true -> assoc
          end

        result = start + diff + if(side < 0, do: 0, else: new_size)

        if simple do
          result
        else
          recover =
            if pos == if(assoc < 0, do: start, else: end_pos) do
              nil
            else
              make_recover(index, pos - start)
            end

          del =
            if old_size == 0 do
              0
            else
              base =
                cond do
                  pos == start -> MapResult.del_after()
                  pos == end_pos -> MapResult.del_before()
                  true -> MapResult.del_across()
                end

              if (assoc < 0 and pos != start) or (assoc >= 0 and pos != end_pos) do
                bor(base, MapResult.del_side())
              else
                base
              end
            end

          %MapResult{pos: result, del_info: del, recover: recover}
        end
      else
        do_map_loop(rest, pos, assoc, simple, inverted, index + 1, diff + new_size - old_size)
      end
    end
  end

  # ── for_each / fold ──────────────────────────────────────────────────

  @doc """
  Calls the given function on each of the changed ranges included in
  this map. The function receives `(old_start, old_end, new_start, new_end)`.
  Returns a list of the results.
  """
  @spec for_each(t(), (integer(), integer(), integer(), integer() -> a)) :: [a] when a: var
  def for_each(%__MODULE__{ranges: ranges, inverted: inverted}, f) do
    for_each_loop(ranges, f, inverted, 0, [])
    |> Enum.reverse()
  end

  defp for_each_loop([], _f, _inverted, _diff, acc), do: acc

  defp for_each_loop([start, a, b | rest], f, inverted, diff, acc) do
    {old_size, new_size, old_start, new_start} =
      if inverted do
        {b, a, start - diff, start}
      else
        {a, b, start, start + diff}
      end

    result = f.(old_start, old_start + old_size, new_start, new_start + new_size)
    for_each_loop(rest, f, inverted, diff + new_size - old_size, [result | acc])
  end

  @doc """
  Folds over each changed range included in this map.
  The function receives `(old_start, old_end, new_start, new_end, acc)`.
  """
  @spec fold(t(), acc, (integer(), integer(), integer(), integer(), acc -> acc)) :: acc
        when acc: var
  def fold(%__MODULE__{ranges: ranges, inverted: inverted}, acc, f) do
    fold_loop(ranges, f, inverted, 0, acc)
  end

  defp fold_loop([], _f, _inverted, _diff, acc), do: acc

  defp fold_loop([start, a, b | rest], f, inverted, diff, acc) do
    {old_size, new_size, old_start, new_start} =
      if inverted do
        {b, a, start - diff, start}
      else
        {a, b, start, start + diff}
      end

    next_acc = f.(old_start, old_start + old_size, new_start, new_start + new_size, acc)
    fold_loop(rest, f, inverted, diff + new_size - old_size, next_acc)
  end

  # ── invert ──────────────────────────────────────────────────────────

  @doc """
  Create an inverted version of this map. The result can be used to
  map positions in the post-step document to the pre-step document.
  """
  @spec invert(t()) :: t()
  def invert(%__MODULE__{} = step_map) do
    %__MODULE__{ranges: step_map.ranges, inverted: not step_map.inverted}
  end
end

# ── Mappable protocol implementation ─────────────────────────────────

defimpl ProsemirrorEx.Transform.Mappable, for: ProsemirrorEx.Transform.StepMap do
  def map(step_map, pos, assoc) do
    ProsemirrorEx.Transform.StepMap.do_map(step_map, pos, assoc, true)
  end

  def map_result(step_map, pos, assoc) do
    ProsemirrorEx.Transform.StepMap.do_map(step_map, pos, assoc, false)
  end
end
