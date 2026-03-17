defmodule ProsemirrorEx.Transform.TransformTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.{Transform, TransformError, AddMarkStep, ReplaceStep}
  alias ProsemirrorEx.Model.{Slice, MarkType}

  describe "Transform.new/1" do
    test "creates a transform with empty steps and docs" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      assert tr.doc == document
      assert tr.steps == []
      assert tr.docs == []
      assert tr.mapping != nil
    end
  end

  describe "Transform.before/1" do
    test "returns the original doc when steps have been applied" do
      {document, _tags} = doc([p(["hello there!"])])

      mark = MarkType.create(test_schema().marks["strong"])
      step = AddMarkStep.new(6, 11, mark)

      tr = Transform.new(document)
      tr = Transform.step(tr, step)

      assert Transform.before(tr) == document
    end

    test "returns current doc when no steps applied" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      assert Transform.before(tr) == document
    end
  end

  describe "Transform.doc_changed?/1" do
    test "returns false when no steps applied" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      refute Transform.doc_changed?(tr)
    end

    test "returns true when steps have been applied" do
      {document, _tags} = doc([p(["hello there!"])])

      mark = MarkType.create(test_schema().marks["strong"])
      step = AddMarkStep.new(6, 11, mark)

      tr = Transform.new(document)
      tr = Transform.step(tr, step)

      assert Transform.doc_changed?(tr)
    end
  end

  describe "Transform.step/2" do
    test "applies a step and updates the transform" do
      {document, _tags} = doc([p(["hello there!"])])
      mark = MarkType.create(test_schema().marks["strong"])
      step = AddMarkStep.new(6, 11, mark)

      tr = Transform.new(document)
      tr = Transform.step(tr, step)

      assert length(tr.steps) == 1
      assert length(tr.docs) == 1
      assert tr.docs == [document]
    end

    test "raises TransformError on failure" do
      # structure: true will fail when there's content between from and to
      {document, _tags} = doc([p(["hello"])])
      step = ReplaceStep.new(1, 6, Slice.empty(), true)

      tr = Transform.new(document)

      assert_raise TransformError, fn ->
        Transform.step(tr, step)
      end
    end
  end

  describe "Transform.maybe_step/2" do
    test "returns updated transform on success" do
      {document, _tags} = doc([p(["hello there!"])])
      mark = MarkType.create(test_schema().marks["strong"])
      step = AddMarkStep.new(6, 11, mark)

      tr = Transform.new(document)
      {new_tr, result} = Transform.maybe_step(tr, step)

      assert result.failed == nil
      assert result.doc != nil
      assert length(new_tr.steps) == 1
    end

    test "returns original transform on failure" do
      {document, _tags} = doc([p(["hello"])])
      step = ReplaceStep.new(1, 6, Slice.empty(), true)

      tr = Transform.new(document)
      {returned_tr, result} = Transform.maybe_step(tr, step)

      assert result.failed != nil
      assert returned_tr == tr
    end
  end

  describe "Transform.changed_range/1" do
    test "returns nil when no steps applied" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      assert Transform.changed_range(tr) == nil
    end
  end
end
