defmodule ProsemirrorEx.Transform.Mapping do
  @moduledoc """
  A mapping represents a pipeline of zero or more StepMaps. It has special
  provisions for losslessly handling mapping positions through a series of
  steps in which some steps are inverted versions of earlier steps.

  Ports `Mapping` from prosemirror-transform/src/map.ts.
  """

  import Bitwise

  alias ProsemirrorEx.Transform.{Mappable, MapResult, StepMap}

  defstruct maps: [], mirror: nil, mirror_map: nil, from: 0, to: 0

  @type t :: %__MODULE__{
          maps: [StepMap.t()],
          mirror: [non_neg_integer()] | nil,
          mirror_map: %{optional(non_neg_integer()) => non_neg_integer()} | nil,
          from: non_neg_integer(),
          to: non_neg_integer()
        }

  @doc """
  Create a new Mapping, optionally initialized with `maps`, `mirror` pairs,
  and active slice bounds `from`..`to`.
  """
  @spec new([StepMap.t()], [non_neg_integer()] | nil, non_neg_integer(), non_neg_integer() | nil) ::
          t()
  def new(maps \\ [], mirror \\ nil, from \\ 0, to \\ nil) when is_list(maps) do
    len = length(maps)
    to = if to == nil, do: len, else: to

    unless is_integer(from) and is_integer(to) and from >= 0 and from <= to and to <= len do
      raise ArgumentError,
            "Invalid slice range #{inspect(from)}..#{inspect(to)} for mapping of length #{len}"
    end

    mirror_map = build_mirror_map(mirror)

    %__MODULE__{
      maps: maps,
      mirror: mirror,
      mirror_map: mirror_map,
      from: from,
      to: to
    }
  end

  @doc "Create a mapping that maps only through a part of this one."
  @spec slice(t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def slice(%__MODULE__{} = mapping, from \\ 0, to \\ nil) do
    max_to = length(mapping.maps)
    to = if to == nil, do: max_to, else: to

    unless is_integer(from) and is_integer(to) and from >= 0 and from <= to and to <= max_to do
      raise ArgumentError,
            "Invalid slice range #{inspect(from)}..#{inspect(to)} for mapping of length #{max_to}"
    end

    %__MODULE__{mapping | from: from, to: to}
  end

  @doc """
  Add a step map to the end of this mapping. If `mirrors` is given,
  it should be the index of the step map that is the mirror image of this one.
  """
  @spec append_map(t(), StepMap.t(), non_neg_integer() | nil) :: t()
  def append_map(%__MODULE__{} = mapping, %StepMap{} = map, mirrors \\ nil) do
    new_maps = mapping.maps ++ [map]
    new_to = length(new_maps)

    mapping = %{mapping | maps: new_maps, to: new_to}

    if mirrors != nil do
      set_mirror(mapping, new_to - 1, mirrors)
    else
      mapping
    end
  end

  @doc """
  Add all the step maps in a given mapping to this one (preserving mirroring information).
  """
  @spec append_mapping(t(), t()) :: t()
  def append_mapping(%__MODULE__{} = mapping, %__MODULE__{maps: []}), do: mapping

  def append_mapping(%__MODULE__{} = mapping, %__MODULE__{maps: other_maps} = other) do
    start_size = length(mapping.maps)
    rev_maps = Enum.reverse(mapping.maps)
    rev_mirror = init_rev_mirror(mapping.mirror)
    mirror_map = ensure_mirror_map(mapping)

    {rev_maps, rev_mirror, mirror_map, total_len} =
      do_append_mapping(other_maps, other, 0, start_size, rev_maps, rev_mirror, mirror_map)

    mirror = finalize_mirror(rev_mirror)
    final_mirror_map = if mirror == nil, do: nil, else: mirror_map

    %{
      mapping
      | maps: Enum.reverse(rev_maps),
        mirror: mirror,
        mirror_map: final_mirror_map,
        to: total_len
    }
  end

  defp do_append_mapping([], _other, _i, idx, rev_maps, rev_mirror, mirror_map) do
    {rev_maps, rev_mirror, mirror_map, idx}
  end

  defp do_append_mapping([map | rest], other, i, idx, rev_maps, rev_mirror, mirror_map) do
    mirr = get_mirror(other, i)

    {rev_mirror, mirror_map} =
      if mirr != nil and mirr < i do
        partner = idx - i + mirr

        {[{partner, idx} | rev_mirror],
         mirror_map |> Map.put(idx, partner) |> Map.put(partner, idx)}
      else
        {rev_mirror, mirror_map}
      end

    do_append_mapping(
      rest,
      other,
      i + 1,
      idx + 1,
      [map | rev_maps],
      rev_mirror,
      mirror_map
    )
  end

  @doc """
  Finds the offset of the step map that mirrors the map at the given offset.
  """
  @spec get_mirror(t(), non_neg_integer()) :: non_neg_integer() | nil
  def get_mirror(%__MODULE__{mirror: nil}, _n), do: nil
  def get_mirror(%__MODULE__{mirror_map: %{} = mirror_map}, n), do: Map.get(mirror_map, n)

  def get_mirror(%__MODULE__{mirror: mirror, mirror_map: nil}, n) do
    find_mirror(mirror, n)
  end

  defp find_mirror([], _n), do: nil
  defp find_mirror([a, b | _rest], a), do: b
  defp find_mirror([a, b | _rest], b), do: a
  defp find_mirror([_a, _b | rest], n), do: find_mirror(rest, n)
  defp find_mirror([_], _n), do: nil

  @doc false
  @spec set_mirror(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_mirror(%__MODULE__{} = mapping, n, m) do
    mirror = (mapping.mirror || []) ++ [n, m]

    mirror_map =
      mapping
      |> ensure_mirror_map()
      |> Map.put(n, m)
      |> Map.put(m, n)

    %{mapping | mirror: mirror, mirror_map: mirror_map}
  end

  @doc """
  Append the inverse of the given mapping to this one.
  """
  @spec append_mapping_inverted(t(), t()) :: t()
  def append_mapping_inverted(%__MODULE__{} = mapping, %__MODULE__{maps: []}), do: mapping

  def append_mapping_inverted(%__MODULE__{} = mapping, %__MODULE__{maps: other_maps} = other) do
    start_size = length(mapping.maps)
    other_len = length(other_maps)
    total_size = start_size + other_len
    rev_maps = Enum.reverse(mapping.maps)
    rev_mirror = init_rev_mirror(mapping.mirror)
    mirror_map = ensure_mirror_map(mapping)

    {rev_maps, rev_mirror, mirror_map} =
      do_append_inverted(
        Enum.reverse(other_maps),
        other,
        other_len - 1,
        start_size,
        total_size,
        rev_maps,
        rev_mirror,
        mirror_map
      )

    mirror = finalize_mirror(rev_mirror)
    final_mirror_map = if mirror == nil, do: nil, else: mirror_map

    %{
      mapping
      | maps: Enum.reverse(rev_maps),
        mirror: mirror,
        mirror_map: final_mirror_map,
        to: total_size
    }
  end

  defp do_append_inverted(
         [],
         _other,
         _i,
         _cur_idx,
         _total_size,
         rev_maps,
         rev_mirror,
         mirror_map
       ) do
    {rev_maps, rev_mirror, mirror_map}
  end

  defp do_append_inverted(
         [map | rest],
         other,
         i,
         cur_idx,
         total_size,
         rev_maps,
         rev_mirror,
         mirror_map
       ) do
    mirr = get_mirror(other, i)

    {rev_mirror, mirror_map} =
      if mirr != nil and mirr > i do
        partner = total_size - mirr - 1

        {[{partner, cur_idx} | rev_mirror],
         mirror_map |> Map.put(cur_idx, partner) |> Map.put(partner, cur_idx)}
      else
        {rev_mirror, mirror_map}
      end

    do_append_inverted(
      rest,
      other,
      i - 1,
      cur_idx + 1,
      total_size,
      [StepMap.invert(map) | rev_maps],
      rev_mirror,
      mirror_map
    )
  end

  @doc "Create an inverted version of this mapping."
  @spec invert(t()) :: t()
  def invert(%__MODULE__{} = mapping) do
    new() |> append_mapping_inverted(mapping)
  end

  @doc "Map a position through this mapping."
  @spec map(t(), integer(), integer()) :: integer()
  def map(%__MODULE__{} = mapping, pos, assoc \\ 1) do
    if mapping.mirror != nil do
      do_map(mapping, pos, assoc, true)
    else
      map_simple(mapping, pos, assoc)
    end
  end

  defp map_simple(%__MODULE__{maps: maps, from: from, to: to}, pos, assoc) do
    if from >= to do
      pos
    else
      maps
      |> Enum.drop(from)
      |> do_map_simple(to - from, pos, assoc)
    end
  end

  defp do_map_simple(_maps, 0, pos, _assoc), do: pos
  defp do_map_simple([], _remaining, pos, _assoc), do: pos

  defp do_map_simple([step_map | rest], remaining, pos, assoc) do
    next_pos =
      case step_map do
        %StepMap{} -> StepMap.do_map(step_map, pos, assoc, true)
        other -> Mappable.map(other, pos, assoc)
      end

    do_map_simple(rest, remaining - 1, next_pos, assoc)
  end

  @doc "Map a position through this mapping, returning a MapResult."
  @spec map_result(t(), integer(), integer()) :: MapResult.t()
  def map_result(%__MODULE__{} = mapping, pos, assoc \\ 1) do
    do_map(mapping, pos, assoc, false)
  end

  @doc false
  @spec do_map(t(), integer(), integer(), true) :: integer()
  @spec do_map(t(), integer(), integer(), false) :: MapResult.t()
  def do_map(%__MODULE__{maps: maps, from: from, to: to} = mapping, pos, assoc, simple) do
    {final_pos, del_info} =
      if from >= to do
        {pos, 0}
      else
        maps
        |> Enum.drop(from)
        |> do_map_walk(from, to, mapping, pos, assoc, 0)
      end

    if simple do
      final_pos
    else
      %MapResult{pos: final_pos, del_info: del_info, recover: nil}
    end
  end

  defp do_map_walk(_maps, i, to, _mapping, pos, _assoc, del_info) when i >= to do
    {pos, del_info}
  end

  defp do_map_walk([], _i, _to, _mapping, pos, _assoc, del_info), do: {pos, del_info}

  defp do_map_walk([step_map | rest], i, to, mapping, pos, assoc, del_info) do
    result =
      case step_map do
        %StepMap{} -> StepMap.do_map(step_map, pos, assoc, false)
        other -> Mappable.map_result(other, pos, assoc)
      end

    if result.recover != nil do
      corr = get_mirror(mapping, i)

      if corr != nil and corr > i and corr < to do
        [corr_map | after_corr] = drop_leading(rest, corr - i - 1)
        recovered_pos = StepMap.recover(corr_map, result.recover)
        do_map_walk(after_corr, corr + 1, to, mapping, recovered_pos, assoc, del_info)
      else
        do_map_walk(rest, i + 1, to, mapping, result.pos, assoc, bor(del_info, result.del_info))
      end
    else
      do_map_walk(rest, i + 1, to, mapping, result.pos, assoc, bor(del_info, result.del_info))
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp drop_leading(list, 0), do: list
  defp drop_leading([_ | rest], n) when n > 0, do: drop_leading(rest, n - 1)

  defp build_mirror_map(nil), do: nil

  defp build_mirror_map(mirror) when is_list(mirror) do
    do_build_mirror_map(mirror, %{})
  end

  defp build_mirror_map(_), do: raise(ArgumentError, "Invalid mirror list")

  defp do_build_mirror_map([], acc), do: acc

  defp do_build_mirror_map([a, b | rest], acc) when is_integer(a) and is_integer(b) do
    do_build_mirror_map(rest, acc |> Map.put(a, b) |> Map.put(b, a))
  end

  defp do_build_mirror_map(_, _acc), do: raise(ArgumentError, "Invalid mirror list")

  defp ensure_mirror_map(%__MODULE__{mirror_map: %{} = mirror_map}), do: mirror_map
  defp ensure_mirror_map(%__MODULE__{mirror: nil}), do: %{}
  defp ensure_mirror_map(%__MODULE__{mirror: mirror}), do: build_mirror_map(mirror)

  defp init_rev_mirror(nil), do: []
  defp init_rev_mirror(mirror), do: pair_reverse(mirror, [])

  defp pair_reverse([], acc), do: acc
  defp pair_reverse([a, b | rest], acc), do: pair_reverse(rest, [{b, a} | acc])

  defp finalize_mirror([]), do: nil

  defp finalize_mirror(rev_pairs) do
    Enum.reduce(rev_pairs, [], fn {b, a}, acc -> [a, b | acc] end)
  end
end

# ── Mappable protocol implementation ─────────────────────────────────

defimpl ProsemirrorEx.Transform.Mappable, for: ProsemirrorEx.Transform.Mapping do
  def map(mapping, pos, assoc) do
    ProsemirrorEx.Transform.Mapping.map(mapping, pos, assoc)
  end

  def map_result(mapping, pos, assoc) do
    ProsemirrorEx.Transform.Mapping.map_result(mapping, pos, assoc)
  end
end
