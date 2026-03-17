defmodule ProsemirrorEx.Transform.StepMapTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Transform.{StepMap, MapResult, Mappable}

  describe "empty/0" do
    test "returns a StepMap with empty ranges" do
      empty = StepMap.empty()
      assert empty.ranges == []
      assert empty.inverted == false
    end
  end

  describe "offset/1" do
    test "returns empty for offset 0" do
      assert StepMap.offset(0) == StepMap.empty()
    end

    test "returns insertion at 0 for positive offset" do
      map = StepMap.offset(3)
      assert map.ranges == [0, 0, 3]
    end

    test "returns deletion at 0 for negative offset" do
      map = StepMap.offset(-3)
      assert map.ranges == [0, 3, 0]
    end
  end

  describe "map/3 via Mappable protocol" do
    test "maps position through empty StepMap" do
      empty = StepMap.empty()
      assert Mappable.map(empty, 5, 1) == 5
    end

    test "maps position before an insertion" do
      map = %StepMap{ranges: [5, 0, 3], inverted: false}
      assert Mappable.map(map, 3, 1) == 3
    end

    test "maps position after an insertion" do
      map = %StepMap{ranges: [5, 0, 3], inverted: false}
      assert Mappable.map(map, 8, 1) == 11
    end

    test "maps position at insertion point with positive assoc" do
      map = %StepMap{ranges: [5, 0, 3], inverted: false}
      assert Mappable.map(map, 5, 1) == 8
    end

    test "maps position at insertion point with negative assoc" do
      map = %StepMap{ranges: [5, 0, 3], inverted: false}
      assert Mappable.map(map, 5, -1) == 5
    end

    test "maps position through a deletion" do
      map = %StepMap{ranges: [2, 4, 0], inverted: false}
      # Position before deletion
      assert Mappable.map(map, 1, 1) == 1
      # Position at start of deletion
      assert Mappable.map(map, 2, -1) == 2
      # Position inside deletion maps to start
      assert Mappable.map(map, 4, 1) == 2
      # Position at end of deletion
      assert Mappable.map(map, 6, 1) == 2
      # Position after deletion
      assert Mappable.map(map, 7, 1) == 3
    end

    test "maps position through a replacement" do
      map = %StepMap{ranges: [2, 4, 4], inverted: false}
      assert Mappable.map(map, 0, 1) == 0
      assert Mappable.map(map, 2, 1) == 2
      assert Mappable.map(map, 8, 1) == 8
    end
  end

  describe "map_result/3 via Mappable protocol" do
    test "returns MapResult for position outside changed range" do
      map = %StepMap{ranges: [5, 0, 3], inverted: false}
      result = Mappable.map_result(map, 3, 1)
      assert %MapResult{} = result
      assert result.pos == 3
      assert result.del_info == 0
      assert result.recover == nil
    end

    test "returns MapResult with del_info for deleted position" do
      map = %StepMap{ranges: [2, 4, 0], inverted: false}
      result = Mappable.map_result(map, 4, 1)
      assert result.pos == 2
      assert result.del_info > 0
    end
  end

  describe "for_each/2" do
    test "iterates over ranges" do
      map = %StepMap{ranges: [2, 3, 5, 10, 2, 4], inverted: false}

      results =
        StepMap.for_each(map, fn old_start, old_end, new_start, new_end ->
          {old_start, old_end, new_start, new_end}
        end)

      assert results == [{2, 5, 2, 7}, {10, 12, 12, 16}]
    end

    test "iterates over ranges in inverted mode" do
      map = %StepMap{ranges: [2, 3, 5, 10, 2, 4], inverted: true}

      results =
        StepMap.for_each(map, fn old_start, old_end, new_start, new_end ->
          {old_start, old_end, new_start, new_end}
        end)

      # When inverted: old_index=2 (newSize), new_index=1 (oldSize)
      # First triple: start=2, old_size=ranges[2]=5, new_size=ranges[1]=3
      #   old_start = 2 - 0 = 2, old_end = 7, new_start = 2, new_end = 5
      # diff = 3 - 5 = -2
      # Second triple: start=10, old_size=ranges[5]=4, new_size=ranges[4]=2
      #   old_start = 10 - (-2) = 12, old_end = 16, new_start = 10, new_end = 12
      assert results == [{2, 7, 2, 5}, {12, 16, 10, 12}]
    end
  end

  describe "invert/1" do
    test "returns a StepMap with inverted flag toggled" do
      map = %StepMap{ranges: [2, 3, 5], inverted: false}
      inverted = StepMap.invert(map)
      assert inverted.ranges == [2, 3, 5]
      assert inverted.inverted == true
    end

    test "double invert returns to original" do
      map = %StepMap{ranges: [2, 3, 5], inverted: false}
      assert StepMap.invert(StepMap.invert(map)).inverted == false
    end
  end

  describe "recover/2" do
    test "recovers position from a recover value" do
      map = %StepMap{ranges: [5, 3, 0], inverted: false}
      # make_recover(0, 2) = 0 + 2 * 0x10000 = 131072
      recover_value = StepMap.make_recover(0, 2)
      recovered = StepMap.recover(map, recover_value)
      # ranges[0*3] + diff + recover_offset
      # For non-inverted, diff calculated from i=0 to index=0: diff = 0
      # ranges[0] + 0 + 2 = 5 + 2 = 7
      assert recovered == 7
    end
  end

  describe "recovery encoding helpers" do
    test "make_recover encodes index and offset" do
      assert StepMap.make_recover(3, 5) == 3 + 5 * 0x10000
    end

    test "recover_index extracts index" do
      value = StepMap.make_recover(3, 5)
      assert StepMap.recover_index(value) == 3
    end

    test "recover_offset extracts offset" do
      value = StepMap.make_recover(3, 5)
      assert StepMap.recover_offset(value) == 5
    end

    test "round trips correctly" do
      for index <- [0, 1, 100, 0xFFFF], offset <- [0, 1, 50, 1000] do
        value = StepMap.make_recover(index, offset)
        assert StepMap.recover_index(value) == index
        assert StepMap.recover_offset(value) == offset
      end
    end
  end

  describe "touches/3" do
    test "returns true when position is within the recovered range" do
      map = %StepMap{ranges: [5, 3, 0], inverted: false}
      recover_value = StepMap.make_recover(0, 1)
      assert StepMap.touches(map, 5, recover_value) == true
    end

    test "returns false when position is outside the recovered range" do
      map = %StepMap{ranges: [5, 3, 0], inverted: false}
      recover_value = StepMap.make_recover(0, 1)
      assert StepMap.touches(map, 10, recover_value) == false
    end
  end
end
