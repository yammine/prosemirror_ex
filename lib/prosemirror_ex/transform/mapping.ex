defmodule ProsemirrorEx.Transform.Mapping do
  @moduledoc """
  A mapping represents a pipeline of zero or more StepMaps. It has special
  provisions for losslessly handling mapping positions through a series of
  steps in which some steps are inverted versions of earlier steps.

  Ports `Mapping` from prosemirror-transform/src/map.ts.
  """

  import Bitwise

  alias ProsemirrorEx.Transform.{StepMap, MapResult, Mappable}

  defstruct maps: [], mirror: nil, from: 0, to: 0

  @type t :: %__MODULE__{
          maps: [StepMap.t()],
          mirror: [non_neg_integer()] | nil,
          from: non_neg_integer(),
          to: non_neg_integer()
        }

  @doc "Create a new empty Mapping."
  def new do
    %__MODULE__{maps: [], mirror: nil, from: 0, to: 0}
  end

  @doc "Create a new Mapping with the given maps."
  def new(maps) when is_list(maps) do
    %__MODULE__{maps: maps, mirror: nil, from: 0, to: length(maps)}
  end

  @doc "Create a mapping that maps only through a part of this one."
  def slice(%__MODULE__{} = mapping, from \\ 0, to) do
    %__MODULE__{maps: mapping.maps, mirror: mapping.mirror, from: from, to: to}
  end

  @doc """
  Add a step map to the end of this mapping. If `mirrors` is given,
  it should be the index of the step map that is the mirror image of this one.
  """
  def append_map(%__MODULE__{} = mapping, %StepMap{} = map, mirrors \\ nil) do
    new_maps = mapping.maps ++ [map]
    new_to = length(new_maps)

    mapping = %{mapping | maps: new_maps, to: new_to}

    if mirrors != nil do
      set_mirror(mapping, length(new_maps) - 1, mirrors)
    else
      mapping
    end
  end

  @doc """
  Add all the step maps in a given mapping to this one (preserving mirroring information).
  """
  def append_mapping(%__MODULE__{} = mapping, %__MODULE__{} = other) do
    start_size = length(mapping.maps)

    Enum.reduce(0..(length(other.maps) - 1)//1, mapping, fn i, acc ->
      mirr = get_mirror(other, i)

      mirrors =
        if mirr != nil and mirr < i do
          start_size + mirr
        else
          nil
        end

      append_map(acc, Enum.at(other.maps, i), mirrors)
    end)
  end

  @doc """
  Finds the offset of the step map that mirrors the map at the given offset.
  """
  def get_mirror(%__MODULE__{mirror: nil}, _n), do: nil

  def get_mirror(%__MODULE__{mirror: mirror}, n) do
    find_mirror(mirror, n, 0)
  end

  defp find_mirror(mirror, n, i) when i < length(mirror) do
    if Enum.at(mirror, i) == n do
      offset = if rem(i, 2) == 1, do: -1, else: 1
      Enum.at(mirror, i + offset)
    else
      find_mirror(mirror, n, i + 1)
    end
  end

  defp find_mirror(_mirror, _n, _i), do: nil

  @doc false
  def set_mirror(%__MODULE__{} = mapping, n, m) do
    mirror = (mapping.mirror || []) ++ [n, m]
    %{mapping | mirror: mirror}
  end

  @doc """
  Append the inverse of the given mapping to this one.
  """
  def append_mapping_inverted(%__MODULE__{} = mapping, %__MODULE__{} = other) do
    total_size = length(mapping.maps) + length(other.maps)

    Enum.reduce((length(other.maps) - 1)..0//-1, mapping, fn i, acc ->
      mirr = get_mirror(other, i)

      mirrors =
        if mirr != nil and mirr > i do
          total_size - mirr - 1
        else
          nil
        end

      append_map(acc, StepMap.invert(Enum.at(other.maps, i)), mirrors)
    end)
  end

  @doc "Create an inverted version of this mapping."
  def invert(%__MODULE__{} = mapping) do
    inverse = new()
    append_mapping_inverted(inverse, mapping)
  end

  @doc "Map a position through this mapping."
  def map(%__MODULE__{} = mapping, pos, assoc \\ 1) do
    if mapping.mirror != nil do
      do_map(mapping, pos, assoc, true)
    else
      map_simple(mapping, pos, assoc)
    end
  end

  defp map_simple(%__MODULE__{} = mapping, pos, assoc) do
    Enum.reduce(mapping.from..(mapping.to - 1)//1, pos, fn i, pos_acc ->
      map = Enum.at(mapping.maps, i)
      Mappable.map(map, pos_acc, assoc)
    end)
  end

  @doc "Map a position through this mapping, returning a MapResult."
  def map_result(%__MODULE__{} = mapping, pos, assoc \\ 1) do
    do_map(mapping, pos, assoc, false)
  end

  @doc false
  def do_map(%__MODULE__{} = mapping, pos, assoc, simple) do
    {final_pos, del_info} =
      Enum.reduce_while(mapping.from..(mapping.to - 1)//1, {pos, 0}, fn i,
                                                                        {pos_acc, del_info_acc} ->
        map = Enum.at(mapping.maps, i)
        result = Mappable.map_result(map, pos_acc, assoc)

        if result.recover != nil do
          corr = get_mirror(mapping, i)

          if corr != nil and corr > i and corr < mapping.to do
            # Skip to the mirror map and recover position
            recovered_pos = StepMap.recover(Enum.at(mapping.maps, corr), result.recover)
            # Continue from after the mirror map
            # We need to continue from corr+1, so we handle this by
            # restarting the reduce from corr+1
            # Since Enum.reduce_while doesn't support jumping, we use a recursive approach
            {final_pos, final_del_info} =
              do_map_from(mapping, recovered_pos, assoc, corr + 1, del_info_acc)

            {:halt, {final_pos, final_del_info}}
          else
            {:cont, {result.pos, bor(del_info_acc, result.del_info)}}
          end
        else
          {:cont, {result.pos, bor(del_info_acc, result.del_info)}}
        end
      end)

    if simple do
      final_pos
    else
      %MapResult{pos: final_pos, del_info: del_info, recover: nil}
    end
  end

  defp do_map_from(%__MODULE__{} = mapping, pos, assoc, from_index, del_info) do
    if from_index >= mapping.to do
      {pos, del_info}
    else
      map = Enum.at(mapping.maps, from_index)
      result = Mappable.map_result(map, pos, assoc)

      if result.recover != nil do
        corr = get_mirror(mapping, from_index)

        if corr != nil and corr > from_index and corr < mapping.to do
          recovered_pos = StepMap.recover(Enum.at(mapping.maps, corr), result.recover)
          do_map_from(mapping, recovered_pos, assoc, corr + 1, del_info)
        else
          do_map_from(mapping, result.pos, assoc, from_index + 1, bor(del_info, result.del_info))
        end
      else
        do_map_from(mapping, result.pos, assoc, from_index + 1, bor(del_info, result.del_info))
      end
    end
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
