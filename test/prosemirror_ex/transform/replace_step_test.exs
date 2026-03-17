defmodule ProsemirrorEx.Transform.ReplaceStepTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Fragment, Slice, Node, Schema, NodeType}
  alias ProsemirrorEx.Transform.{Step, StepMap, ReplaceStep, ReplaceAroundStep}

  # Helper to test step JSON round-trip
  defp test_step_json(doc_node, step) do
    schema = test_schema()

    # Apply the step
    result = ReplaceStep.apply(step, doc_node)
    assert result.failed == nil, "Step should apply successfully: #{inspect(result.failed)}"

    # Serialize to JSON
    json = ReplaceStep.to_json(step)

    # Deserialize
    recovered = Step.from_json(schema, json)

    # Apply the recovered step
    result2 = ReplaceStep.apply(recovered, doc_node)
    assert result2.failed == nil, "Recovered step should apply successfully"

    # Results should be equal
    assert Node.eq(result.doc, result2.doc),
           "JSON round-trip should produce same result"
  end

  defp test_replace_around_step_json(doc_node, step) do
    schema = test_schema()

    # Apply the step
    result = ReplaceAroundStep.apply(step, doc_node)
    assert result.failed == nil, "Step should apply successfully: #{inspect(result.failed)}"

    # Serialize to JSON
    json = ReplaceAroundStep.to_json(step)

    # Deserialize
    recovered = Step.from_json(schema, json)

    # Apply the recovered step
    result2 = ReplaceAroundStep.apply(recovered, doc_node)
    assert result2.failed == nil, "Recovered step should apply successfully"

    # Results should be equal
    assert Node.eq(result.doc, result2.doc),
           "JSON round-trip should produce same result"
  end

  describe "ReplaceStep" do
    test "basic deletion" do
      {doc_node, _} = doc([p(["hello"])])
      # Delete "ell" (positions 2..5)
      step = ReplaceStep.new(2, 5, Slice.empty())
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p(["ho"])])
      assert Node.eq(result.doc, expected)
    end

    test "basic insertion" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      text = Schema.text(schema, "X")
      slice = Slice.new(Fragment.from(text), 0, 0)

      step = ReplaceStep.new(2, 2, slice)
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p(["hXello"])])
      assert Node.eq(result.doc, expected)
    end

    test "replacement" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      text = Schema.text(schema, "XY")
      slice = Slice.new(Fragment.from(text), 0, 0)

      step = ReplaceStep.new(2, 5, slice)
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([p(["hXYo"])])
      assert Node.eq(result.doc, expected)
    end

    test "step_map returns correct StepMap" do
      step = ReplaceStep.new(5, 8, Slice.empty())
      map = ReplaceStep.step_map(step)
      assert map.ranges == [5, 3, 0]
    end

    test "step_map with insertion" do
      schema = test_schema()
      text = Schema.text(schema, "ab")
      slice = Slice.new(Fragment.from(text), 0, 0)
      step = ReplaceStep.new(5, 5, slice)
      map = ReplaceStep.step_map(step)
      assert map.ranges == [5, 0, 2]
    end

    test "invert produces inverse step" do
      {doc_node, _} = doc([p(["hello"])])
      step = ReplaceStep.new(2, 5, Slice.empty())
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed == nil

      inv = ReplaceStep.invert(step, doc_node)
      inv_result = ReplaceStep.apply(inv, result.doc)
      assert inv_result.failed == nil
      assert Node.eq(inv_result.doc, doc_node)
    end

    test "map through identity produces same step" do
      step = ReplaceStep.new(2, 5, Slice.empty())
      map = StepMap.empty()
      mapped = ReplaceStep.map(step, map)
      assert mapped.from == 2
      assert mapped.to == 5
    end

    test "map returns nil when range is deleted" do
      step = ReplaceStep.new(2, 5, Slice.empty())
      # Create a StepMap that deletes positions 1-6
      map = %StepMap{ranges: [1, 5, 0], inverted: false}
      mapped = ReplaceStep.map(step, map)
      assert mapped == nil
    end

    test "structure replace fails when content exists" do
      {doc_node, _} = doc([p(["hello"])])
      step = ReplaceStep.new(1, 6, Slice.empty(), true)
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "JSON round-trip for empty replace (deletion)" do
      {doc_node, _} = doc([p(["foobar"])])
      step = ReplaceStep.new(2, 5, Slice.empty())
      test_step_json(doc_node, step)
    end

    test "JSON round-trip for replace with content" do
      {doc_node, _} = doc([p(["foobar"])])
      schema = test_schema()
      text = Schema.text(schema, "XYZ")
      slice = Slice.new(Fragment.from(text), 0, 0)
      step = ReplaceStep.new(2, 5, slice)
      test_step_json(doc_node, step)
    end

    test "to_json does not include slice when empty" do
      step = ReplaceStep.new(2, 5, Slice.empty())
      json = ReplaceStep.to_json(step)
      assert json == %{"stepType" => "replace", "from" => 2, "to" => 5}
    end

    test "to_json includes structure when true" do
      step = ReplaceStep.new(2, 5, Slice.empty(), true)
      json = ReplaceStep.to_json(step)
      assert json["structure"] == true
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        ReplaceStep.from_json(schema, %{})
      end
    end

    test "merge adjacent inserts" do
      schema = test_schema()
      text_a = Schema.text(schema, "a")
      text_b = Schema.text(schema, "b")
      slice_a = Slice.new(Fragment.from(text_a), 0, 0)
      slice_b = Slice.new(Fragment.from(text_b), 0, 0)

      step1 = ReplaceStep.new(2, 2, slice_a)
      step2 = ReplaceStep.new(3, 3, slice_b)

      merged = ReplaceStep.merge(step1, step2)
      assert merged != nil
      assert merged.from == 2
      assert merged.to == 2
    end

    test "merge adjacent deletes" do
      step1 = ReplaceStep.new(3, 4, Slice.empty())
      step2 = ReplaceStep.new(2, 3, Slice.empty())

      merged = ReplaceStep.merge(step1, step2)
      assert merged != nil
    end

    test "does not merge separated inserts" do
      schema = test_schema()
      text_a = Schema.text(schema, "a")
      text_b = Schema.text(schema, "b")
      slice_a = Slice.new(Fragment.from(text_a), 0, 0)
      slice_b = Slice.new(Fragment.from(text_b), 0, 0)

      step1 = ReplaceStep.new(2, 2, slice_a)
      step2 = ReplaceStep.new(4, 4, slice_b)

      merged = ReplaceStep.merge(step1, step2)
      assert merged == nil
    end

    test "does not merge structured replaces" do
      step1 = ReplaceStep.new(2, 3, Slice.empty(), true)
      step2 = ReplaceStep.new(2, 3, Slice.empty())

      merged = ReplaceStep.merge(step1, step2)
      assert merged == nil
    end

    test "doesn't fail when the position is mapped to the same position" do
      schema = test_schema()
      {doc_node, _} = doc([p(["foobar"])])

      text = Schema.text(schema, "a")
      slice = Slice.new(Fragment.from(text), 0, 0)
      step = ReplaceStep.new(1, 1, slice)

      # Apply original step
      result1 = ReplaceStep.apply(step, doc_node)
      assert result1.failed == nil

      # Map through an identity step map
      step_map = %StepMap{ranges: [1, 0, 1], inverted: false}
      mapped = ReplaceStep.map(step, step_map)
      assert mapped != nil

      # Apply mapped step to original doc
      result2 = ReplaceStep.apply(mapped, doc_node)
      assert result2.failed == nil
    end
  end

  describe "ReplaceAroundStep" do
    test "basic replace around (wrap)" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      bq_type = Schema.node_type(schema, "blockquote")
      bq = NodeType.create(bq_type, nil, Fragment.empty(), nil)
      # Wrapping creates a slice with open_start=0, open_end=0 containing the empty wrapper,
      # and insert=number_of_wrappers (1 for blockquote).
      # The gap content (the paragraph) gets inserted inside the wrapper.
      slice = Slice.new(Fragment.from(bq), 0, 0)
      step = ReplaceAroundStep.new(0, 7, 0, 7, slice, 1, true)
      result = ReplaceAroundStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([blockquote([p(["hello"])])])
      assert Node.eq(result.doc, expected)
    end

    test "step_map returns correct StepMap" do
      step = ReplaceAroundStep.new(0, 7, 0, 7, Slice.empty(), 0)
      map = ReplaceAroundStep.step_map(step)
      assert map.ranges == [0, 0, 0, 7, 0, 0]
    end

    test "invert produces inverse step" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      bq_type = Schema.node_type(schema, "blockquote")
      bq = NodeType.create(bq_type, nil, Fragment.empty(), nil)
      slice = Slice.new(Fragment.from(bq), 0, 0)
      step = ReplaceAroundStep.new(0, 7, 0, 7, slice, 1, true)

      result = ReplaceAroundStep.apply(step, doc_node)
      assert result.failed == nil

      inv = ReplaceAroundStep.invert(step, doc_node)
      inv_result = ReplaceAroundStep.apply(inv, result.doc)
      assert inv_result.failed == nil
      assert Node.eq(inv_result.doc, doc_node)
    end

    test "map returns nil when range is deleted" do
      step = ReplaceAroundStep.new(2, 8, 3, 7, Slice.empty(), 0)
      map = %StepMap{ranges: [1, 10, 0], inverted: false}
      mapped = ReplaceAroundStep.map(step, map)
      assert mapped == nil
    end

    test "to_json serializes all fields" do
      step = ReplaceAroundStep.new(1, 10, 2, 8, Slice.empty(), 3)
      json = ReplaceAroundStep.to_json(step)
      assert json["stepType"] == "replaceAround"
      assert json["from"] == 1
      assert json["to"] == 10
      assert json["gapFrom"] == 2
      assert json["gapTo"] == 8
      assert json["insert"] == 3
    end

    test "to_json includes structure when true" do
      step = ReplaceAroundStep.new(1, 10, 2, 8, Slice.empty(), 3, true)
      json = ReplaceAroundStep.to_json(step)
      assert json["structure"] == true
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        ReplaceAroundStep.from_json(schema, %{})
      end
    end

    test "JSON round-trip for replace around step" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      bq_type = Schema.node_type(schema, "blockquote")
      bq = NodeType.create(bq_type, nil, Fragment.empty(), nil)
      slice = Slice.new(Fragment.from(bq), 0, 0)
      step = ReplaceAroundStep.new(0, 7, 0, 7, slice, 1, true)
      test_replace_around_step_json(doc_node, step)
    end

    test "structure replace around fails when content exists between from and gap_from" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      step = ReplaceAroundStep.new(0, 14, 7, 14, Slice.empty(), 0, true)
      result = ReplaceAroundStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "gap with open start/end fails" do
      {doc_node, _} = doc([p(["hello"])])
      # The gap itself should be a flat range
      # Using positions that create an open gap
      step = ReplaceAroundStep.new(0, 7, 1, 6, Slice.empty(), 0)
      result = ReplaceAroundStep.apply(step, doc_node)
      assert result.failed != nil
    end
  end
end
