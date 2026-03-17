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
  def make_recover(index, offset), do: index + offset * @factor16

  @doc false
  def recover_index(value), do: band(value, @lower16)

  @doc false
  def recover_offset(value), do: div(value - band(value, @lower16), @factor16)

  # ── Constructor helpers ──────────────────────────────────────────────

  @doc "A StepMap that contains no changed ranges."
  def empty, do: %__MODULE__{ranges: [], inverted: false}

  @doc """
  Create a map that moves all positions by offset `n` (which may be negative).
  """
  def offset(0), do: empty()
  def offset(n) when n < 0, do: %__MODULE__{ranges: [0, -n, 0], inverted: false}
  def offset(n), do: %__MODULE__{ranges: [0, 0, n], inverted: false}

  # ── Recover ──────────────────────────────────────────────────────────

  @doc false
  def recover(%__MODULE__{} = step_map, value) do
    index = recover_index(value)

    diff =
      if not step_map.inverted do
        Enum.reduce(0..(index - 1)//1, 0, fn i, acc ->
          acc + Enum.at(step_map.ranges, i * 3 + 2) - Enum.at(step_map.ranges, i * 3 + 1)
        end)
      else
        0
      end

    Enum.at(step_map.ranges, index * 3) + diff + recover_offset(value)
  end

  # ── Core mapping ────────────────────────────────────────────────────

  @doc false
  def do_map(%__MODULE__{} = step_map, pos, assoc, simple) do
    old_index = if step_map.inverted, do: 2, else: 1
    new_index = if step_map.inverted, do: 1, else: 2
    ranges = step_map.ranges

    do_map_loop(ranges, pos, assoc, simple, old_index, new_index, 0, 0)
  end

  defp do_map_loop(ranges, pos, assoc, simple, old_index, new_index, i, diff) do
    range_len = length(ranges)

    if i >= range_len do
      if simple, do: pos + diff, else: %MapResult{pos: pos + diff, del_info: 0, recover: nil}
    else
      start = Enum.at(ranges, i) - if old_index == 2, do: diff, else: 0

      if start > pos do
        if simple, do: pos + diff, else: %MapResult{pos: pos + diff, del_info: 0, recover: nil}
      else
        old_size = Enum.at(ranges, i + old_index)
        new_size = Enum.at(ranges, i + new_index)
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
                make_recover(div(i, 3), pos - start)
              end

            del =
              cond do
                pos == start -> MapResult.del_after()
                pos == end_pos -> MapResult.del_before()
                true -> MapResult.del_across()
              end

            del =
              if (assoc < 0 and pos != start) or (assoc >= 0 and pos != end_pos) do
                bor(del, MapResult.del_side())
              else
                del
              end

            %MapResult{pos: result, del_info: del, recover: recover}
          end
        else
          do_map_loop(
            ranges,
            pos,
            assoc,
            simple,
            old_index,
            new_index,
            i + 3,
            diff + new_size - old_size
          )
        end
      end
    end
  end

  # ── touches ─────────────────────────────────────────────────────────

  @doc false
  def touches(%__MODULE__{} = step_map, pos, recover_value) do
    index = recover_index(recover_value)
    old_index = if step_map.inverted, do: 2, else: 1
    new_index = if step_map.inverted, do: 1, else: 2

    touches_loop(step_map.ranges, pos, index, old_index, new_index, 0, 0)
  end

  defp touches_loop(ranges, pos, index, old_index, new_index, i, diff) do
    range_len = length(ranges)

    if i >= range_len do
      false
    else
      start = Enum.at(ranges, i) - if old_index == 2, do: diff, else: 0

      if start > pos do
        false
      else
        old_size = Enum.at(ranges, i + old_index)
        end_pos = start + old_size

        if pos <= end_pos and i == index * 3 do
          true
        else
          new_size = Enum.at(ranges, i + new_index)

          touches_loop(
            ranges,
            pos,
            index,
            old_index,
            new_index,
            i + 3,
            diff + new_size - old_size
          )
        end
      end
    end
  end

  # ── for_each ────────────────────────────────────────────────────────

  @doc """
  Calls the given function on each of the changed ranges included in
  this map. The function receives (old_start, old_end, new_start, new_end).
  Returns a list of the results.
  """
  def for_each(%__MODULE__{} = step_map, f) do
    old_index = if step_map.inverted, do: 2, else: 1
    new_index = if step_map.inverted, do: 1, else: 2

    for_each_loop(step_map.ranges, f, old_index, new_index, 0, 0, [])
    |> Enum.reverse()
  end

  defp for_each_loop(ranges, f, old_index, new_index, i, diff, acc) do
    range_len = length(ranges)

    if i >= range_len do
      acc
    else
      start = Enum.at(ranges, i)
      old_start = start - if old_index == 2, do: diff, else: 0
      new_start = start + if old_index == 2, do: 0, else: diff
      old_size = Enum.at(ranges, i + old_index)
      new_size = Enum.at(ranges, i + new_index)

      result = f.(old_start, old_start + old_size, new_start, new_start + new_size)

      for_each_loop(
        ranges,
        f,
        old_index,
        new_index,
        i + 3,
        diff + new_size - old_size,
        [result | acc]
      )
    end
  end

  # ── invert ──────────────────────────────────────────────────────────

  @doc """
  Create an inverted version of this map. The result can be used to
  map positions in the post-step document to the pre-step document.
  """
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
