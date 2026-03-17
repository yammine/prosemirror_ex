defmodule ProsemirrorEx.Transform.MarkStepTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Node, Mark, MarkType}

  alias ProsemirrorEx.Transform.{
    Step,
    StepMap,
    AddMarkStep,
    RemoveMarkStep,
    AddNodeMarkStep,
    RemoveNodeMarkStep
  }

  # Helper to test step JSON round-trip
  defp test_step_json(doc_node, step_module, step) do
    schema = test_schema()

    # Apply the step
    result = step_module.apply(step, doc_node)
    assert result.failed == nil, "Step should apply successfully: #{inspect(result.failed)}"

    # Serialize to JSON
    json = step_module.to_json(step)

    # Deserialize
    recovered = Step.from_json(schema, json)

    # Apply the recovered step
    result2 = step_module.apply(recovered, doc_node)
    assert result2.failed == nil, "Recovered step should apply successfully"

    # Results should be equal
    assert Node.eq(result.doc, result2.doc),
           "JSON round-trip should produce same result"
  end

  describe "AddMarkStep" do
    test "adds a mark to inline content" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = AddMarkStep.new(1, 6, em_mark)
      result = AddMarkStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p([em(["hello"])])])
      assert Node.eq(result.doc, expected)
    end

    test "adds a mark to partial inline content" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = AddMarkStep.new(2, 4, em_mark)
      result = AddMarkStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p(["h", em(["el"]), "lo"])])
      assert Node.eq(result.doc, expected)
    end

    test "step_map returns empty StepMap" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(1, 6, em_mark)
      map = AddMarkStep.step_map(step)
      assert map.ranges == []
    end

    test "invert returns RemoveMarkStep" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(1, 6, em_mark)
      inv = AddMarkStep.invert(step, nil)
      assert inv.__struct__ == RemoveMarkStep
      assert inv.from == 1
      assert inv.to == 6
      assert Mark.eq(inv.mark, em_mark)
    end

    test "map through identity returns same range" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(2, 5, em_mark)
      mapped = AddMarkStep.map(step, StepMap.empty())
      assert mapped.from == 2
      assert mapped.to == 5
    end

    test "map returns nil when range is collapsed or deleted" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(2, 5, em_mark)
      # A map that deletes positions 1-6
      map = %StepMap{ranges: [1, 5, 0], inverted: false}
      mapped = AddMarkStep.map(step, map)
      assert mapped == nil
    end

    test "merge overlapping ranges with same mark" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 3, em_mark)
      step2 = AddMarkStep.new(2, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged != nil
      assert merged.from == 1
      assert merged.to == 4
    end

    test "merge adjacent ranges with same mark" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 2, em_mark)
      step2 = AddMarkStep.new(2, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged != nil
      assert merged.from == 1
      assert merged.to == 4
    end

    test "does not merge separate ranges" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 2, em_mark)
      step2 = AddMarkStep.new(3, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged == nil
    end

    test "JSON round-trip" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(1, 6, em_mark)
      test_step_json(doc_node, AddMarkStep, step)
    end

    test "to_json serializes correctly" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddMarkStep.new(1, 6, em_mark)
      json = AddMarkStep.to_json(step)
      assert json["stepType"] == "addMark"
      assert json["from"] == 1
      assert json["to"] == 6
      assert json["mark"]["type"] == "em"
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        AddMarkStep.from_json(schema, %{})
      end
    end
  end

  describe "RemoveMarkStep" do
    test "removes a mark from inline content" do
      {doc_node, _} = doc([p([em(["hello"])])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = RemoveMarkStep.new(1, 6, em_mark)
      result = RemoveMarkStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p(["hello"])])
      assert Node.eq(result.doc, expected)
    end

    test "removes a mark from partial content" do
      {doc_node, _} = doc([p([em(["hello"])])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = RemoveMarkStep.new(2, 4, em_mark)
      result = RemoveMarkStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p([em(["h"]), "el", em(["lo"])])])
      assert Node.eq(result.doc, expected)
    end

    test "step_map returns empty StepMap" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveMarkStep.new(1, 6, em_mark)
      map = RemoveMarkStep.step_map(step)
      assert map.ranges == []
    end

    test "invert returns AddMarkStep" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveMarkStep.new(1, 6, em_mark)
      inv = RemoveMarkStep.invert(step, nil)
      assert inv.__struct__ == AddMarkStep
      assert inv.from == 1
      assert inv.to == 6
    end

    test "merge overlapping ranges with same mark" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = RemoveMarkStep.new(1, 3, em_mark)
      step2 = RemoveMarkStep.new(2, 4, em_mark)
      merged = RemoveMarkStep.merge(step1, step2)
      assert merged != nil
      assert merged.from == 1
      assert merged.to == 4
    end

    test "does not merge separate ranges" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = RemoveMarkStep.new(1, 2, em_mark)
      step2 = RemoveMarkStep.new(3, 4, em_mark)
      merged = RemoveMarkStep.merge(step1, step2)
      assert merged == nil
    end

    test "JSON round-trip" do
      {doc_node, _} = doc([p([em(["hello"])])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveMarkStep.new(1, 6, em_mark)
      test_step_json(doc_node, RemoveMarkStep, step)
    end

    test "to_json serializes correctly" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveMarkStep.new(1, 6, em_mark)
      json = RemoveMarkStep.to_json(step)
      assert json["stepType"] == "removeMark"
      assert json["from"] == 1
      assert json["to"] == 6
      assert json["mark"]["type"] == "em"
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        RemoveMarkStep.from_json(schema, %{})
      end
    end
  end

  describe "AddNodeMarkStep" do
    test "adds a mark to an inline leaf node (image)" do
      # Image is an inline leaf node that can have marks
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      # Add mark to the image node at position 1 (inside paragraph)
      step = AddNodeMarkStep.new(1, em_mark)
      result = AddNodeMarkStep.apply(step, doc_node)
      assert result.failed == nil

      # The image should now have the em mark
      img_node = Node.node_at(result.doc, 1)
      assert Mark.is_in_set(em_mark, img_node.marks || [])
    end

    test "fails when no node at position" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = AddNodeMarkStep.new(100, em_mark)
      result = AddNodeMarkStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "step_map returns empty StepMap" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddNodeMarkStep.new(1, em_mark)
      map = AddNodeMarkStep.step_map(step)
      assert map.ranges == []
    end

    test "invert returns RemoveNodeMarkStep when mark is new" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddNodeMarkStep.new(1, em_mark)
      inv = AddNodeMarkStep.invert(step, doc_node)
      assert inv.__struct__ == RemoveNodeMarkStep
      assert inv.pos == 1
    end

    test "map returns nil when position is deleted" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddNodeMarkStep.new(2, em_mark)
      map = %StepMap{ranges: [1, 5, 0], inverted: false}
      mapped = AddNodeMarkStep.map(step, map)
      assert mapped == nil
    end

    test "to_json serializes correctly" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddNodeMarkStep.new(1, em_mark)
      json = AddNodeMarkStep.to_json(step)
      assert json["stepType"] == "addNodeMark"
      assert json["pos"] == 1
      assert json["mark"]["type"] == "em"
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        AddNodeMarkStep.from_json(schema, %{})
      end
    end

    test "JSON round-trip" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = AddNodeMarkStep.new(1, em_mark)
      test_step_json(doc_node, AddNodeMarkStep, step)
    end
  end

  describe "RemoveNodeMarkStep" do
    test "removes a mark from a node" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      # Add mark first
      add_step = AddNodeMarkStep.new(1, em_mark)
      result = AddNodeMarkStep.apply(add_step, doc_node)
      assert result.failed == nil
      marked_doc = result.doc

      # Now remove it
      step = RemoveNodeMarkStep.new(1, em_mark)
      result2 = RemoveNodeMarkStep.apply(step, marked_doc)
      assert result2.failed == nil
      assert Node.eq(result2.doc, doc_node)
    end

    test "fails when no node at position" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = RemoveNodeMarkStep.new(100, em_mark)
      result = RemoveNodeMarkStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "step_map returns empty StepMap" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveNodeMarkStep.new(1, em_mark)
      map = RemoveNodeMarkStep.step_map(step)
      assert map.ranges == []
    end

    test "invert when mark is in set returns AddNodeMarkStep" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      # Add the mark first
      add_step = AddNodeMarkStep.new(1, em_mark)
      result = AddNodeMarkStep.apply(add_step, doc_node)
      marked_doc = result.doc

      step = RemoveNodeMarkStep.new(1, em_mark)
      inv = RemoveNodeMarkStep.invert(step, marked_doc)
      assert inv.__struct__ == AddNodeMarkStep
      assert inv.pos == 1
    end

    test "invert when mark is not in set returns self" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      step = RemoveNodeMarkStep.new(1, em_mark)
      inv = RemoveNodeMarkStep.invert(step, doc_node)
      # When mark is not in the node's marks, it returns self
      assert inv.__struct__ == RemoveNodeMarkStep
    end

    test "to_json serializes correctly" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step = RemoveNodeMarkStep.new(1, em_mark)
      json = RemoveNodeMarkStep.to_json(step)
      assert json["stepType"] == "removeNodeMark"
      assert json["pos"] == 1
      assert json["mark"]["type"] == "em"
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        RemoveNodeMarkStep.from_json(schema, %{})
      end
    end

    test "JSON round-trip" do
      {doc_node, _} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)

      # First add the mark
      add_step = AddNodeMarkStep.new(1, em_mark)
      result = AddNodeMarkStep.apply(add_step, doc_node)
      marked_doc = result.doc

      step = RemoveNodeMarkStep.new(1, em_mark)
      test_step_json(marked_doc, RemoveNodeMarkStep, step)
    end
  end

  describe "merge (from JS test-step.ts)" do
    # Port of JS merge tests that involve mark steps
    test "merges adding adjacent styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 2, em_mark)
      step2 = AddMarkStep.new(2, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged != nil
    end

    test "merges adding overlapping styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 3, em_mark)
      step2 = AddMarkStep.new(2, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged != nil
    end

    test "doesn't merge separate styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = AddMarkStep.new(1, 2, em_mark)
      step2 = AddMarkStep.new(3, 4, em_mark)
      merged = AddMarkStep.merge(step1, step2)
      assert merged == nil
    end

    test "merges removing adjacent styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = RemoveMarkStep.new(1, 2, em_mark)
      step2 = RemoveMarkStep.new(2, 4, em_mark)
      merged = RemoveMarkStep.merge(step1, step2)
      assert merged != nil
    end

    test "merges removing overlapping styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = RemoveMarkStep.new(1, 3, em_mark)
      step2 = RemoveMarkStep.new(2, 4, em_mark)
      merged = RemoveMarkStep.merge(step1, step2)
      assert merged != nil
    end

    test "doesn't merge removing separate styles" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"], nil)
      step1 = RemoveMarkStep.new(1, 2, em_mark)
      step2 = RemoveMarkStep.new(3, 4, em_mark)
      merged = RemoveMarkStep.merge(step1, step2)
      assert merged == nil
    end
  end
end
