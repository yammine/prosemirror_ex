defmodule ProsemirrorEx.Transform.MappingTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Transform.{Mapping, StepMap, MapResult, Mappable}

  # Port of the JS test helper `mk`
  # Takes a list of arguments which are either:
  # - lists of integers (ranges for a StepMap)
  # - maps of {from => to} (mirror pairs)
  defp mk(args) do
    mapping = Mapping.new()

    Enum.reduce(args, mapping, fn arg, acc ->
      cond do
        is_list(arg) ->
          Mapping.append_map(acc, %StepMap{ranges: arg, inverted: false})

        is_map(arg) ->
          Enum.reduce(arg, acc, fn {from, to}, m ->
            Mapping.set_mirror(m, from, to)
          end)
      end
    end)
  end

  # Port of the JS test helper `testMapping`
  # cases are [{pos, expected_pos}] or [{pos, expected_pos, assoc}] or [{pos, expected_pos, assoc, lossy}]
  defp test_mapping(mapping, cases) do
    inverted = Mapping.invert(mapping)

    for c <- cases do
      {from, to, bias, lossy} =
        case c do
          {from, to} -> {from, to, 1, false}
          {from, to, bias} -> {from, to, bias, false}
          {from, to, bias, lossy} -> {from, to, bias, lossy}
        end

      assert Mappable.map(mapping, from, bias) == to,
             "mapping.map(#{from}, #{bias}) should be #{to}, got #{Mappable.map(mapping, from, bias)}"

      unless lossy do
        assert Mappable.map(inverted, to, bias) == from,
               "inverted.map(#{to}, #{bias}) should be #{from}, got #{Mappable.map(inverted, to, bias)}"
      end
    end
  end

  # Port of the JS test helper `testDel`
  defp test_del(mapping, pos, side, expected_flags) do
    r = Mappable.map_result(mapping, pos, side)

    found =
      [
        if(MapResult.deleted?(r), do: "d", else: ""),
        if(MapResult.deleted_before?(r), do: "b", else: ""),
        if(MapResult.deleted_after?(r), do: "a", else: ""),
        if(MapResult.deleted_across?(r), do: "x", else: "")
      ]
      |> Enum.join("")

    assert found == expected_flags,
           "testDel(#{pos}, #{side}): expected '#{expected_flags}', got '#{found}'"
  end

  describe "Mapping" do
    test "can map through a single insertion" do
      test_mapping(mk([[2, 0, 4]]), [{0, 0}, {2, 6}, {2, 2, -1}, {3, 7}])
    end

    test "can map through a single deletion" do
      test_mapping(
        mk([[2, 4, 0]]),
        [{0, 0}, {2, 2, -1}, {3, 2, 1, true}, {6, 2, 1}, {6, 2, -1, true}, {7, 3}]
      )
    end

    test "can map through a single replace" do
      test_mapping(
        mk([[2, 4, 4]]),
        [{0, 0}, {2, 2, 1}, {4, 6, 1, true}, {4, 2, -1, true}, {6, 6, -1}, {8, 8}]
      )
    end

    test "can map through a mirrored delete-insert" do
      test_mapping(
        mk([[2, 4, 0], [2, 0, 4], %{0 => 1}]),
        [{0, 0}, {2, 2}, {4, 4}, {6, 6}, {7, 7}]
      )
    end

    test "can map through a mirrored insert-delete" do
      test_mapping(
        mk([[2, 0, 4], [2, 4, 0], %{0 => 1}]),
        [{0, 0}, {2, 2}, {3, 3}]
      )
    end

    test "can map through a delete-insert with an insert in between" do
      test_mapping(
        mk([[2, 4, 0], [1, 0, 1], [3, 0, 4], %{0 => 2}]),
        [{0, 0}, {1, 2}, {4, 5}, {6, 7}, {7, 8}]
      )
    end

    test "assigns the correct deleted flags when deletions happen before" do
      test_del(mk([[0, 2, 0]]), 2, -1, "db")
      test_del(mk([[0, 2, 0]]), 2, 1, "b")
      test_del(mk([[0, 2, 2]]), 2, -1, "db")
      test_del(mk([[0, 1, 0], [0, 1, 0]]), 2, -1, "db")
      test_del(mk([[0, 1, 0]]), 2, -1, "")
    end

    test "assigns the correct deleted flags when deletions happen after" do
      test_del(mk([[2, 2, 0]]), 2, -1, "a")
      test_del(mk([[2, 2, 0]]), 2, 1, "da")
      test_del(mk([[2, 2, 2]]), 2, 1, "da")
      test_del(mk([[2, 1, 0], [2, 1, 0]]), 2, 1, "da")
      test_del(mk([[3, 2, 0]]), 2, -1, "")
    end

    test "assigns the correct deleted flags when deletions happen across" do
      test_del(mk([[0, 4, 0]]), 2, -1, "dbax")
      test_del(mk([[0, 4, 0]]), 2, 1, "dbax")
      test_del(mk([[0, 4, 0]]), 2, 1, "dbax")
      test_del(mk([[0, 1, 0], [4, 1, 0], [0, 3, 0]]), 2, 1, "dbax")
    end

    test "assigns the correct deleted flags when deletions happen around" do
      test_del(mk([[4, 1, 0], [0, 1, 0]]), 2, -1, "")
      test_del(mk([[2, 1, 0], [0, 2, 0]]), 2, -1, "dba")
      test_del(mk([[2, 1, 0], [0, 1, 0]]), 2, -1, "a")
      test_del(mk([[3, 1, 0], [0, 2, 0]]), 2, -1, "db")
    end
  end

  describe "Mapping struct operations" do
    test "new/0 creates an empty mapping" do
      mapping = Mapping.new()
      assert mapping.maps == []
      assert mapping.from == 0
      assert mapping.to == 0
      assert mapping.mirror == nil
    end

    test "slice/3 creates a view of the mapping" do
      mapping =
        mk([[2, 0, 4], [10, 3, 0]])

      sliced = Mapping.slice(mapping, 0, 1)
      assert sliced.from == 0
      assert sliced.to == 1
    end

    test "append_mapping/2 preserves mirroring" do
      m1 = mk([[2, 4, 0], [2, 0, 4], %{0 => 1}])
      m2 = Mapping.new()
      m2 = Mapping.append_mapping(m2, m1)
      test_mapping(m2, [{0, 0}, {2, 2}, {4, 4}, {6, 6}])
    end

    test "append_mapping_inverted/2 appends inverted maps" do
      m1 = mk([[2, 4, 0]])
      m2 = Mapping.new()
      m2 = Mapping.append_mapping_inverted(m2, m1)
      # After inverting [2, 4, 0], it becomes a map that converts positions
      # as if the deletion was undone (an insertion)
      assert length(m2.maps) == 1
    end

    test "invert/1 creates an inverted mapping" do
      mapping = mk([[2, 4, 0]])
      inverted = Mapping.invert(mapping)
      # Inverting a deletion should map back
      assert Mappable.map(inverted, 2, 1) == 6
    end

    test "get_mirror/2 finds mirror partner" do
      mapping = mk([[2, 4, 0], [2, 0, 4], %{0 => 1}])
      assert Mapping.get_mirror(mapping, 0) == 1
      assert Mapping.get_mirror(mapping, 1) == 0
      assert Mapping.get_mirror(mapping, 2) == nil
    end

    test "implements Mappable protocol map/3" do
      mapping = mk([[2, 0, 4]])
      assert Mappable.map(mapping, 0, 1) == 0
      assert Mappable.map(mapping, 2, 1) == 6
      assert Mappable.map(mapping, 2, -1) == 2
      assert Mappable.map(mapping, 3, 1) == 7
    end

    test "implements Mappable protocol map_result/3" do
      mapping = mk([[2, 4, 0]])
      result = Mappable.map_result(mapping, 3, 1)
      assert %MapResult{} = result
      assert result.pos == 2
    end
  end
end
