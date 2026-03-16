defmodule ProsemirrorEx.Model.CompareDeepTest do
  use ExUnit.Case, async: true
  alias ProsemirrorEx.Model.CompareDeep

  describe "compare/2" do
    test "identical values are equal" do
      assert CompareDeep.compare(1, 1)
      assert CompareDeep.compare("foo", "foo")
      assert CompareDeep.compare(nil, nil)
      assert CompareDeep.compare(true, true)
    end

    test "different primitives are not equal" do
      refute CompareDeep.compare(1, 2)
      refute CompareDeep.compare("foo", "bar")
      refute CompareDeep.compare(true, false)
      refute CompareDeep.compare(nil, 0)
    end

    test "compares flat maps" do
      assert CompareDeep.compare(%{"a" => 1, "b" => 2}, %{"a" => 1, "b" => 2})
      refute CompareDeep.compare(%{"a" => 1}, %{"a" => 2})
      refute CompareDeep.compare(%{"a" => 1}, %{"a" => 1, "b" => 2})
      refute CompareDeep.compare(%{"a" => 1, "b" => 2}, %{"a" => 1})
    end

    test "compares nested maps" do
      assert CompareDeep.compare(%{"a" => %{"b" => 1}}, %{"a" => %{"b" => 1}})
      refute CompareDeep.compare(%{"a" => %{"b" => 1}}, %{"a" => %{"b" => 2}})
    end

    test "compares lists" do
      assert CompareDeep.compare([1, 2, 3], [1, 2, 3])
      refute CompareDeep.compare([1, 2], [1, 2, 3])
      refute CompareDeep.compare([1, 2, 3], [1, 2])
      refute CompareDeep.compare([1, 2], [1, 3])
    end

    test "compares nested lists" do
      assert CompareDeep.compare([[1, 2], [3]], [[1, 2], [3]])
      refute CompareDeep.compare([[1, 2], [3]], [[1, 2], [4]])
    end

    test "map vs list are not equal" do
      refute CompareDeep.compare(%{}, [])
      refute CompareDeep.compare([], %{})
    end

    test "nil vs map/list are not equal" do
      refute CompareDeep.compare(nil, %{})
      refute CompareDeep.compare(%{}, nil)
      refute CompareDeep.compare(nil, [])
    end

    test "handles maps with nil values" do
      assert CompareDeep.compare(%{"a" => nil}, %{"a" => nil})
      refute CompareDeep.compare(%{"a" => nil}, %{})
    end
  end
end
