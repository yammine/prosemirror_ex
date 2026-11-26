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

    test "handles multi-range and inverted maps" do
      map = StepMap.new([2, 3, 5, 10, 4, 1])
      # Range 1 starts at 10 (old_start = 10, old_end = 14)
      r1 = StepMap.make_recover(1, 2)
      assert StepMap.touches(map, 12, r1) == true
      assert StepMap.touches(map, 3, r1) == false
      assert StepMap.touches(map, 15, r1) == false

      inv = StepMap.invert(map)

      # In inverted mode: first triple old=5, new=3, diff=-2; second triple start = 10 - (-2) = 12, old=1
      assert StepMap.touches(inv, 12, r1) == true
      assert StepMap.touches(inv, 13, r1) == true
      assert StepMap.touches(inv, 14, r1) == false
    end
  end

  describe "pure insertion del_info" do
    test "pure insertion at pos = 0 sets del_info = 0" do
      map = StepMap.new([0, 0, 7])

      for assoc <- [-1, 1] do
        res = StepMap.map_result(map, 0, assoc)
        assert res.del_info == 0
        assert res.recover == nil
        refute MapResult.deleted?(res)
        refute MapResult.deleted_before?(res)
        refute MapResult.deleted_after?(res)
        refute MapResult.deleted_across?(res)
        assert res.pos == if(assoc < 0, do: 0, else: 7)
      end
    end

    test "pure insertion at non-zero pos sets del_info = 0" do
      map = StepMap.new([5, 0, 3])
      res_pos = StepMap.map_result(map, 5, 1)
      res_neg = StepMap.map_result(map, 5, -1)

      assert res_pos.del_info == 0
      assert res_pos.pos == 8
      assert res_neg.del_info == 0
      assert res_neg.pos == 5
    end
  end

  describe "new/1-2, map/2-3, map_result/2-3, fold/3, and multi-range recover/2" do
    test "new/1-2 and convenience map/2-3 / map_result/2-3" do
      map = StepMap.new([2, 0, 4])
      assert map == %StepMap{ranges: [2, 0, 4], inverted: false}
      assert StepMap.map(map, 2) == 6
      assert StepMap.map(map, 2, -1) == 2
      assert StepMap.map_result(map, 2).pos == 6

      inv = StepMap.new([2, 0, 4], true)
      assert inv.inverted == true
      assert StepMap.map(inv, 4, 1) == 2
    end

    test "recover/2 works across multiple ranges in normal and inverted mode" do
      map = StepMap.new([2, 3, 5, 10, 4, 1])
      # index 1: diff from range 0 is (5 - 3) = 2; range 1 start = 10 -> 10 + 2 + offset(2) = 14
      r1 = StepMap.make_recover(1, 2)
      assert StepMap.recover(map, r1) == 14

      inv = StepMap.invert(map)
      # inverted: diff = 0 -> 10 + 0 + 2 = 12
      assert StepMap.recover(inv, r1) == 12
    end

    test "fold/3 accumulates over ranges matching for_each/2" do
      map = StepMap.new([2, 3, 5, 10, 2, 4])

      folded =
        StepMap.fold(map, [], fn os, oe, ns, ne, acc ->
          [{os, oe, ns, ne} | acc]
        end)
        |> Enum.reverse()

      assert folded == StepMap.for_each(map, &{&1, &2, &3, &4})
    end
  end
end
