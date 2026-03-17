defmodule ProsemirrorEx.Transform.MapResultTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Transform.MapResult

  describe "struct creation" do
    test "creates a MapResult with pos, del_info, and recover" do
      result = %MapResult{pos: 5, del_info: 0, recover: nil}
      assert result.pos == 5
      assert result.del_info == 0
      assert result.recover == nil
    end

    test "creates a MapResult with recover value" do
      result = %MapResult{pos: 3, del_info: 1, recover: 42}
      assert result.recover == 42
    end
  end

  describe "deleted?/1" do
    test "returns false when del_info has no DEL_SIDE bit" do
      result = %MapResult{pos: 0, del_info: 0, recover: nil}
      refute MapResult.deleted?(result)
    end

    test "returns true when del_info has DEL_SIDE bit set" do
      # DEL_SIDE = 8
      result = %MapResult{pos: 0, del_info: 8, recover: nil}
      assert MapResult.deleted?(result)
    end

    test "returns true when del_info has DEL_SIDE combined with other flags" do
      # DEL_BEFORE | DEL_SIDE = 1 | 8 = 9
      result = %MapResult{pos: 0, del_info: 9, recover: nil}
      assert MapResult.deleted?(result)
    end
  end

  describe "deleted_before?/1" do
    test "returns false when no before or across flag" do
      result = %MapResult{pos: 0, del_info: 0, recover: nil}
      refute MapResult.deleted_before?(result)
    end

    test "returns true when DEL_BEFORE is set" do
      # DEL_BEFORE = 1
      result = %MapResult{pos: 0, del_info: 1, recover: nil}
      assert MapResult.deleted_before?(result)
    end

    test "returns true when DEL_ACROSS is set" do
      # DEL_ACROSS = 4
      result = %MapResult{pos: 0, del_info: 4, recover: nil}
      assert MapResult.deleted_before?(result)
    end
  end

  describe "deleted_after?/1" do
    test "returns false when no after or across flag" do
      result = %MapResult{pos: 0, del_info: 0, recover: nil}
      refute MapResult.deleted_after?(result)
    end

    test "returns true when DEL_AFTER is set" do
      # DEL_AFTER = 2
      result = %MapResult{pos: 0, del_info: 2, recover: nil}
      assert MapResult.deleted_after?(result)
    end

    test "returns true when DEL_ACROSS is set" do
      # DEL_ACROSS = 4
      result = %MapResult{pos: 0, del_info: 4, recover: nil}
      assert MapResult.deleted_after?(result)
    end
  end

  describe "deleted_across?/1" do
    test "returns false when DEL_ACROSS is not set" do
      result = %MapResult{pos: 0, del_info: 3, recover: nil}
      refute MapResult.deleted_across?(result)
    end

    test "returns true when DEL_ACROSS is set" do
      # DEL_ACROSS = 4
      result = %MapResult{pos: 0, del_info: 4, recover: nil}
      assert MapResult.deleted_across?(result)
    end

    test "returns true when DEL_ACROSS combined with other flags" do
      # DEL_BEFORE | DEL_AFTER | DEL_ACROSS = 1 | 2 | 4 = 7
      result = %MapResult{pos: 0, del_info: 7, recover: nil}
      assert MapResult.deleted_across?(result)
    end
  end
end
