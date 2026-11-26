defmodule ProsemirrorEx.Transform.TransformTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.{
    Transform,
    TransformError,
    AddMarkStep,
    AttrStep,
    Mapping,
    ReplaceStep
  }

  alias ProsemirrorEx.Model.{Mark, MarkType, Node, Schema, Slice}

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

    test "returns original transform on out-of-bounds replace or attr on text node" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      {tr1, res1} = Transform.maybe_step(tr, ReplaceStep.new(1, 999, Slice.empty()))
      assert res1.failed != nil
      assert tr1 == tr

      {tr2, res2} = Transform.maybe_step(tr, AttrStep.new(2, "level", 2))
      assert res2.failed != nil
      assert tr2 == tr
    end
  end

  describe "Transform.changed_range/1" do
    test "returns nil when no steps applied" do
      {document, _tags} = doc([p(["hello"])])
      tr = Transform.new(document)

      assert Transform.changed_range(tr) == nil
    end

    test "returns nil for mark-only steps" do
      {document, _tags} = doc([p(["hello world"])])
      em_mark = MarkType.create(test_schema().marks["em"])

      tr =
        Transform.new(document)
        |> Transform.add_mark(1, 6, em_mark)
        |> Transform.remove_mark(1, 4, em_mark)

      assert Transform.changed_range(tr) == nil
    end

    test "returns range for deletions and insertions" do
      {document, _tags} = doc([p(["hello world"])])
      tr = Transform.new(document) |> Transform.delete(2, 5)
      assert Transform.changed_range(tr) == %{from: 2, to: 2}
    end

    test "maps earlier range across subsequent replacements and mark steps" do
      {document, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      tr =
        Transform.new(document)
        |> Transform.add_mark(1, 6, em_mark)
        |> Transform.insert(2, Schema.text(schema, "XX"))
        |> Transform.insert(10, Schema.text(schema, "YY"))

      # Step 1 (add_mark): nil
      # Step 2 (insert "XX" at 2): {2, 4}
      # Step 3 (insert "YY" at 10): maps {2, 4} -> {2, 4}, combines with {10, 12} -> {2, 12}
      assert Transform.changed_range(tr) == %{from: 2, to: 12}

      # Insertion before earlier change shifts earlier range
      tr2 =
        Transform.new(document)
        |> Transform.insert(8, Schema.text(schema, "AB"))
        |> Transform.insert(2, Schema.text(schema, "CD"))

      # Step 1: {8, 10}; Step 2 inserts 2 at pos 2 -> {8, 10} maps to {10, 12}, combined with {2, 4} -> {2, 12}
      assert Transform.changed_range(tr2) == %{from: 2, to: 12}
    end

    test "respects sliced mapping bounds" do
      {document, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(document)
        |> Transform.insert(1, Schema.text(schema, "AA"))
        |> Transform.insert(8, Schema.text(schema, "BB"))

      sliced_tr = %{tr | mapping: Mapping.slice(tr.mapping, 1)}
      assert Transform.changed_range(sliced_tr) == %{from: 8, to: 10}
    end
  end

  describe "Transform.add_node_mark/3 and remove_node_mark/3" do
    test "adds and removes marks on a node by Mark and MarkType" do
      {document, _tags} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      tr = Transform.new(document) |> Transform.add_node_mark(1, em_mark)
      assert Mark.is_in_set(em_mark, Node.node_at(tr.doc, 1).marks || [])

      tr2 = Transform.remove_node_mark(tr, 1, em_mark)
      assert Node.eq(tr2.doc, document)

      tr3 = Transform.remove_node_mark(tr, 1, schema.marks["em"])
      assert Node.eq(tr3.doc, document)

      assert_raise TransformError, fn ->
        Transform.remove_node_mark(tr, 999, schema.marks["em"])
      end
    end
  end

  describe "Transform.set_block_type/3-5" do
    test "supports 3-, 4-, and 5-argument forms" do
      {document, _tags} = doc([p(["hello"]), p(["world"])])
      schema = test_schema()
      heading = schema.nodes["heading"]

      tr3 = Transform.new(document) |> Transform.set_block_type(1, heading)
      assert Node.child(tr3.doc, 0).type.name == "heading"
      assert Node.child(tr3.doc, 1).type.name == "paragraph"

      tr4 = Transform.new(document) |> Transform.set_block_type(1, 10, heading)
      assert Node.child(tr4.doc, 0).type.name == "heading"
      assert Node.child(tr4.doc, 1).type.name == "heading"

      tr5 = Transform.new(document) |> Transform.set_block_type(1, 10, heading, %{"level" => 3})
      assert Node.child(tr5.doc, 0).attrs["level"] == 3
      assert Node.child(tr5.doc, 1).attrs["level"] == 3
    end
  end
end
