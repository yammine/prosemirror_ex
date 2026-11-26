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

    test "merges with non-zero outer open_start / open_end and backward merges with content" do
      schema = test_schema()
      {p1, _} = p(["ab"])
      {p2, _} = p(["cd"])
      {p3, _} = p(["ef"])

      # Forward merge where step1 has open_start = 1, open_end = 0 and step2 has open_start = 0, open_end = 1
      s1 = Slice.new(Fragment.from(p1), 1, 0)
      s2 = Slice.new(Fragment.from(p2), 0, 1)
      step1 = ReplaceStep.new(2, 2, s1)
      step2 = ReplaceStep.new(2 + Slice.size(s1), 2 + Slice.size(s1), s2)
      merged = ReplaceStep.merge(step1, step2)
      assert merged != nil
      assert merged.slice.open_start == 1
      assert merged.slice.open_end == 1

      # Does not merge when touching seam is open (step1.open_end > 0 or step2.open_start > 0)
      open_s1 = Slice.new(Fragment.from(p1), 0, 1)
      step_open = ReplaceStep.new(2, 2, open_s1)
      step_after = ReplaceStep.new(2 + Slice.size(open_s1), 2 + Slice.size(open_s1), s2)
      assert ReplaceStep.merge(step_open, step_after) == nil

      # Backward merge with content (other.to == step.from)
      t1 = Schema.text(schema, "world")
      t2 = Schema.text(schema, "hello ")
      step_later = ReplaceStep.new(6, 8, Slice.new(Fragment.from(t1), 0, 0))
      step_earlier = ReplaceStep.new(2, 6, Slice.new(Fragment.from(t2), 0, 0))
      back_merged = ReplaceStep.merge(step_later, step_earlier)
      assert back_merged != nil
      assert back_merged.from == 2
      assert back_merged.to == 8

      assert Node.text_between(
               Schema.node(schema, "paragraph", nil, back_merged.slice.content),
               0,
               11
             ) == "hello world"

      # Backward merge with open_start on earlier and open_end on later
      b1 = Slice.new(Fragment.from(p3), 0, 1)
      b2 = Slice.new(Fragment.from(p2), 1, 0)
      assert ReplaceStep.merge(ReplaceStep.new(5, 7, b1), ReplaceStep.new(2, 5, b2)) != nil
    end

    test "apply returns fail for out-of-bounds positions" do
      {doc_node, _} = doc([p(["hello"])])
      assert ReplaceStep.apply(ReplaceStep.new(-1, 2, Slice.empty()), doc_node).failed != nil
      assert ReplaceStep.apply(ReplaceStep.new(0, 999, Slice.empty()), doc_node).failed != nil
      assert ReplaceStep.apply(ReplaceStep.new(4, 2, Slice.empty()), doc_node).failed != nil

      assert ReplaceStep.apply(ReplaceStep.new(0, 999, Slice.empty(), true), doc_node).failed !=
               nil
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

    test "structure replace around fails when content exists between gap_to and to" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      step = ReplaceAroundStep.new(0, 14, 0, 7, Slice.empty(), 0, true)
      result = ReplaceAroundStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "apply returns fail for out-of-bounds positions" do
      {doc_node, _} = doc([p(["hello"])])

      assert ReplaceAroundStep.apply(
               ReplaceAroundStep.new(0, 99, 0, 7, Slice.empty(), 0),
               doc_node
             ).failed != nil
    end

    test "map returns nil when gap collapses outside mapped from..to" do
      step = ReplaceAroundStep.new(2, 10, 4, 8, Slice.empty(), 0)

      # Delete 2..5 (collapses from..gap_from cleanly? Wait: delete 4..9 so gap_from maps to 4, gap_to maps to 4, wait:
      # If deletion is 1..6 (pos 2->1 with assoc 1, pos 4->1? No, pos 4 with assoc -1 -> 1; what if 0..5 is deleted and 7..12?))
      # Deletion 3..11: from=2->2, to=10->3 (assoc -1 -> 3), gap_from=4->3 (assoc -1), gap_to=8->11? No, 8 maps to 3 (assoc 1 -> 3).
      # Better: delete 1..5 -> from=2 maps to 1, gap_from=4 maps to 1; insert at 2?
      # Delete 3..9: from=2->2, to=10->4, gap_from=4->3 (Wait: 4 with assoc -1 -> 3), wait if from=2, gap_from=2, to=10, gap_to=8:
      # Actually: if step has from=2, gap_from=3, gap_to=7, to=8, and map deletes 1..4 [1, 3, 0]:
      # from (2, +1) -> 1? No, 2 is inside [1,4], so from=1, gap_from(3,-1)->1.
      # To get gap_from < from.pos: insert at 2? No, from=2(+1)->5, gap_from=3(-1)->6?
      # Delete [2, 3, 0]: from=2(+1)->2, gap_from=3(-1)->2.
      # What if map is [0, 5, 0] (deletes 0..5) and step is (2, 10, 4, 8):
      # Wait: from=2(+1)->0, gap_from=4(-1)->0.
      # What if step is (2, 10, 3, 8) and map is [2, 1, 2] (replaces 2..3 with size 2):
      # from=2(+1)->2, gap_from=3(-1)->4! That's >=.
      # What if map is [2, 2, 0] and step has from=2, gap_from=3, gap_to=7, to=10, followed by [3, 0, 5]?:
      # Wait: if mapping has [2, 0, 4] (pure insertion at 2) and step has from=2, gap_from=3... no, 3>2 so 3->7.
      # How does gap_from < from.pos happen?
      # When from == 2 (assoc +1 -> moves AFTER insertion at 2 -> 6) and gap_from == 2? No, if from == gap_from, code sets gap_from = from.pos!
      # Wait: if from=2, gap_from=3, and map deletes 2..4 [2, 2, 0]: from(2, +1) -> 2, gap_from(3, -1) -> 2. Still equal.
      # What if map is [1, 4, 5] (replaces 1..5 with size 5):
      # from=2 (inside 1..5, assoc +1) -> 1 + 5 = 6!
      # gap_from=3 (inside 1..5, assoc -1) -> 1 + 0 = 1!
      # Now gap_from (1) < from.pos (6)! -> returns nil!
      map = StepMap.new([1, 4, 5])
      assert ReplaceAroundStep.map(step, map) == nil
    end
  end
end
