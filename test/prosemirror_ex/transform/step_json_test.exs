defmodule ProsemirrorEx.Transform.StepJsonTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Node, Slice, Fragment, MarkType, Schema}

  alias ProsemirrorEx.Transform.{
    Step,
    StepMap,
    ReplaceStep,
    ReplaceAroundStep,
    AddMarkStep,
    RemoveMarkStep,
    AddNodeMarkStep,
    RemoveNodeMarkStep,
    AttrStep,
    DocAttrStep
  }

  # ── Generic JSON round-trip test helper ──────────────────────────────

  # The standard testStepJSON pattern from the JS test suite:
  # 1. Apply step to document -> result
  # 2. Serialize step to JSON via to_json/1
  # 3. Deserialize from JSON via Step.from_json(schema, json)
  # 4. Apply deserialized step to same document
  # 5. Assert both results are equal
  defp test_step_json(doc_node, step_struct) do
    step_module = step_struct.__struct__
    schema = doc_node.type.schema

    # Apply the step
    result = step_module.apply(step_struct, doc_node)
    assert result.failed == nil, "Step should apply successfully: #{inspect(result.failed)}"

    # Serialize to JSON
    json = step_module.to_json(step_struct)
    assert is_map(json), "to_json should return a map"
    assert Map.has_key?(json, "stepType"), "JSON should have a stepType key"

    # Deserialize from JSON
    recovered = Step.from_json(schema, json)
    assert recovered.__struct__ == step_module, "Recovered step should be the same type"

    # Apply the recovered step
    result2 = step_module.apply(recovered, doc_node)
    assert result2.failed == nil, "Recovered step should apply successfully"

    # Results should be equal
    assert Node.eq(result.doc, result2.doc),
           "JSON round-trip should produce same result.\nOriginal: #{Node.debug_string(result.doc)}\nRecovered: #{Node.debug_string(result2.doc)}"

    # Return results for further testing
    {result.doc, json, recovered}
  end

  # Test that step.invert(doc) applied to the result gives back the original doc.
  defp test_invertibility(doc_node, step_struct) do
    step_module = step_struct.__struct__

    # Apply step
    result = step_module.apply(step_struct, doc_node)
    assert result.failed == nil, "Step should apply successfully"

    # Invert step
    inverted = step_module.invert(step_struct, doc_node)
    inv_module = inverted.__struct__

    # Apply inverted step to result
    inv_result = inv_module.apply(inverted, result.doc)
    assert inv_result.failed == nil, "Inverted step should apply successfully"

    # Should get back original doc
    assert Node.eq(inv_result.doc, doc_node),
           "Invert should restore original doc.\nOriginal: #{Node.debug_string(doc_node)}\nAfter invert: #{Node.debug_string(inv_result.doc)}"
  end

  # ── ReplaceStep JSON round-trip tests ────────────────────────────────

  describe "ReplaceStep JSON round-trip" do
    test "simple text replacement" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      text_node = Schema.text(schema, "goodbye")
      slice = Slice.new(Fragment.from(text_node), 0, 0)
      step = ReplaceStep.new(1, 6, slice)

      test_step_json(doc_node, step)
    end

    test "empty deletion" do
      {doc_node, _tags} = doc([p(["hello world"])])
      step = ReplaceStep.new(1, 6, Slice.empty())

      test_step_json(doc_node, step)
    end

    test "insertion at cursor" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()
      text_node = Schema.text(schema, " world")
      slice = Slice.new(Fragment.from(text_node), 0, 0)
      step = ReplaceStep.new(6, 6, slice)

      test_step_json(doc_node, step)
    end

    test "slice with marks" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      text_node = Schema.text(schema, "emphasized")
      marked_text = Node.mark(text_node, [em_mark])
      slice = Slice.new(Fragment.from(marked_text), 0, 0)
      step = ReplaceStep.new(1, 6, slice)

      test_step_json(doc_node, step)
    end

    test "replace across paragraphs with open slice" do
      {doc_node, _tags} = doc([p(["hello"]), p(["world"])])
      {p1, _} = p(["a"])
      {p2, _} = p(["b"])
      slice = Slice.new(Fragment.from_array([p1, p2]), 1, 1)
      step = ReplaceStep.new(3, 10, slice)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType" do
      step = ReplaceStep.new(1, 3, Slice.empty())
      json = ReplaceStep.to_json(step)

      assert json["stepType"] == "replace"
      assert json["from"] == 1
      assert json["to"] == 3
    end

    test "JSON omits slice when empty" do
      step = ReplaceStep.new(1, 3, Slice.empty())
      json = ReplaceStep.to_json(step)

      refute Map.has_key?(json, "slice")
    end

    test "JSON includes structure when true" do
      step = ReplaceStep.new(1, 3, Slice.empty(), true)
      json = ReplaceStep.to_json(step)

      assert json["structure"] == true
    end

    test "JSON omits structure when false" do
      step = ReplaceStep.new(1, 3, Slice.empty(), false)
      json = ReplaceStep.to_json(step)

      refute Map.has_key?(json, "structure")
    end
  end

  # ── ReplaceAroundStep JSON round-trip tests ──────────────────────────

  describe "ReplaceAroundStep JSON round-trip" do
    test "wrapping a paragraph in blockquote" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()
      bq_type = Schema.node_type(schema, "blockquote")
      bq_node = ProsemirrorEx.Model.NodeType.create(bq_type, nil, Fragment.empty(), nil)
      content = Fragment.from(bq_node)

      # Wrapping pattern: from=0, to=7, gap_from=0, gap_to=7, slice with wrapper content, insert=1, structure=true
      step = ReplaceAroundStep.new(0, 7, 0, 7, Slice.new(content, 0, 0), 1, true)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType" do
      slice = Slice.empty()
      step = ReplaceAroundStep.new(0, 10, 2, 8, slice, 0)
      json = ReplaceAroundStep.to_json(step)

      assert json["stepType"] == "replaceAround"
      assert json["from"] == 0
      assert json["to"] == 10
      assert json["gapFrom"] == 2
      assert json["gapTo"] == 8
      assert json["insert"] == 0
    end

    test "JSON includes structure when true" do
      step = ReplaceAroundStep.new(0, 10, 2, 8, Slice.empty(), 0, true)
      json = ReplaceAroundStep.to_json(step)

      assert json["structure"] == true
    end
  end

  # ── AddMarkStep JSON round-trip tests ────────────────────────────────

  describe "AddMarkStep JSON round-trip" do
    test "add em to text range" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddMarkStep.new(1, 6, em_mark)

      test_step_json(doc_node, step)
    end

    test "add strong to entire paragraph" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()
      strong_mark = MarkType.create(schema.marks["strong"])
      step = AddMarkStep.new(1, 6, strong_mark)

      test_step_json(doc_node, step)
    end

    test "add link mark with attrs" do
      {doc_node, _tags} = doc([p(["click here"])])
      schema = test_schema()

      link_mark =
        MarkType.create(schema.marks["link"], %{
          "href" => "https://example.com",
          "title" => "Example"
        })

      step = AddMarkStep.new(1, 11, link_mark)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType and fields" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddMarkStep.new(1, 6, em_mark)
      json = AddMarkStep.to_json(step)

      assert json["stepType"] == "addMark"
      assert json["from"] == 1
      assert json["to"] == 6
      assert is_map(json["mark"])
      assert json["mark"]["type"] == "em"
    end
  end

  # ── RemoveMarkStep JSON round-trip tests ─────────────────────────────

  describe "RemoveMarkStep JSON round-trip" do
    test "remove em from text range" do
      {doc_node, _tags} = doc([p([em(["hello"]), " world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = RemoveMarkStep.new(1, 6, em_mark)

      test_step_json(doc_node, step)
    end

    test "remove strong from text range" do
      {doc_node, _tags} = doc([p([strong(["hello world"])])])
      schema = test_schema()
      strong_mark = MarkType.create(schema.marks["strong"])
      step = RemoveMarkStep.new(1, 12, strong_mark)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = RemoveMarkStep.new(1, 6, em_mark)
      json = RemoveMarkStep.to_json(step)

      assert json["stepType"] == "removeMark"
      assert json["from"] == 1
      assert json["to"] == 6
      assert is_map(json["mark"])
    end
  end

  # ── AddNodeMarkStep JSON round-trip tests ────────────────────────────

  describe "AddNodeMarkStep JSON round-trip" do
    test "add mark to image node" do
      {doc_node, _tags} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      # Position of the image is at position 1 (inside paragraph)
      step = AddNodeMarkStep.new(1, em_mark)

      test_step_json(doc_node, step)
    end

    test "add link mark to image node" do
      {doc_node, _tags} = doc([p([img()])])
      schema = test_schema()
      link_mark = MarkType.create(schema.marks["link"], %{"href" => "https://example.com"})
      step = AddNodeMarkStep.new(1, link_mark)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType and fields" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddNodeMarkStep.new(5, em_mark)
      json = AddNodeMarkStep.to_json(step)

      assert json["stepType"] == "addNodeMark"
      assert json["pos"] == 5
      assert is_map(json["mark"])
    end
  end

  # ── RemoveNodeMarkStep JSON round-trip tests ─────────────────────────

  describe "RemoveNodeMarkStep JSON round-trip" do
    test "remove mark from image node" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      # Build an image with a mark on it
      {img_node, _} = img()
      marked_img = Node.mark(img_node, [em_mark])

      # Manually build a doc with the marked image inside a paragraph
      p_type = Schema.node_type(schema, "paragraph")
      p_node = ProsemirrorEx.Model.NodeType.create(p_type, nil, Fragment.from(marked_img), nil)
      doc_type = Schema.node_type(schema, "doc")
      doc_node = ProsemirrorEx.Model.NodeType.create(doc_type, nil, Fragment.from(p_node), nil)

      step = RemoveNodeMarkStep.new(1, em_mark)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType and fields" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = RemoveNodeMarkStep.new(3, em_mark)
      json = RemoveNodeMarkStep.to_json(step)

      assert json["stepType"] == "removeNodeMark"
      assert json["pos"] == 3
      assert is_map(json["mark"])
    end
  end

  # ── AttrStep JSON round-trip tests ───────────────────────────────────

  describe "AttrStep JSON round-trip" do
    test "set heading level" do
      {doc_node, _tags} = doc([h1(["heading text"])])
      step = AttrStep.new(0, "level", 2)

      test_step_json(doc_node, step)
    end

    test "set heading level to 3" do
      {doc_node, _tags} = doc([h2(["another heading"])])
      step = AttrStep.new(0, "level", 3)

      test_step_json(doc_node, step)
    end

    test "set image src attribute" do
      {doc_node, _tags} = doc([p([img()])])
      step = AttrStep.new(1, "src", "new_image.png")

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType and fields" do
      step = AttrStep.new(0, "level", 2)
      json = AttrStep.to_json(step)

      assert json["stepType"] == "attr"
      assert json["pos"] == 0
      assert json["attr"] == "level"
      assert json["value"] == 2
    end
  end

  # ── DocAttrStep JSON round-trip tests ────────────────────────────────

  describe "DocAttrStep JSON round-trip" do
    test "set doc attribute" do
      {doc_node, _tags} = doc([p(["hello"])])
      step = DocAttrStep.new("title", "My Document")

      test_step_json(doc_node, step)
    end

    test "set doc attribute to number" do
      {doc_node, _tags} = doc([p(["hello"])])
      step = DocAttrStep.new("version", 42)

      test_step_json(doc_node, step)
    end

    test "set doc attribute to nil" do
      {doc_node, _tags} = doc([p(["hello"])])
      step = DocAttrStep.new("metadata", nil)

      test_step_json(doc_node, step)
    end

    test "JSON has correct stepType and fields" do
      step = DocAttrStep.new("title", "Test")
      json = DocAttrStep.to_json(step)

      assert json["stepType"] == "docAttr"
      assert json["attr"] == "title"
      assert json["value"] == "Test"
    end
  end

  # ── Invertibility tests ──────────────────────────────────────────────

  describe "step invertibility" do
    test "ReplaceStep: text replacement is invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      text_node = Schema.text(schema, "goodbye")
      slice = Slice.new(Fragment.from(text_node), 0, 0)
      step = ReplaceStep.new(1, 6, slice)

      test_invertibility(doc_node, step)
    end

    test "ReplaceStep: deletion is invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      step = ReplaceStep.new(1, 6, Slice.empty())

      test_invertibility(doc_node, step)
    end

    test "ReplaceStep: insertion is invertible" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()
      text_node = Schema.text(schema, " world")
      slice = Slice.new(Fragment.from(text_node), 0, 0)
      step = ReplaceStep.new(6, 6, slice)

      test_invertibility(doc_node, step)
    end

    test "AddMarkStep: adding em is invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddMarkStep.new(1, 6, em_mark)

      test_invertibility(doc_node, step)
    end

    test "RemoveMarkStep: removing em is invertible" do
      {doc_node, _tags} = doc([p([em(["hello"]), " world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = RemoveMarkStep.new(1, 6, em_mark)

      test_invertibility(doc_node, step)
    end

    test "AddNodeMarkStep: adding mark to node is invertible" do
      {doc_node, _tags} = doc([p([img()])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddNodeMarkStep.new(1, em_mark)

      test_invertibility(doc_node, step)
    end

    test "RemoveNodeMarkStep: removing mark from node is invertible" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      {img_node, _} = img()
      marked_img = Node.mark(img_node, [em_mark])

      p_type = Schema.node_type(schema, "paragraph")
      p_node = ProsemirrorEx.Model.NodeType.create(p_type, nil, Fragment.from(marked_img), nil)
      doc_type = Schema.node_type(schema, "doc")
      doc_node = ProsemirrorEx.Model.NodeType.create(doc_type, nil, Fragment.from(p_node), nil)

      step = RemoveNodeMarkStep.new(1, em_mark)

      test_invertibility(doc_node, step)
    end

    test "AttrStep: changing heading level is invertible" do
      {doc_node, _tags} = doc([h1(["heading"])])
      step = AttrStep.new(0, "level", 2)

      test_invertibility(doc_node, step)
    end

    test "DocAttrStep: setting doc attribute is invertible" do
      {doc_node, _tags} = doc([p(["hello"])])
      step = DocAttrStep.new("title", "My Document")

      test_invertibility(doc_node, step)
    end

    test "ReplaceAroundStep: wrapping is invertible" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()
      bq_type = Schema.node_type(schema, "blockquote")
      bq_node = ProsemirrorEx.Model.NodeType.create(bq_type, nil, Fragment.empty(), nil)
      content = Fragment.from(bq_node)
      step = ReplaceAroundStep.new(0, 7, 0, 7, Slice.new(content, 0, 0), 1, true)

      test_invertibility(doc_node, step)
    end
  end

  # ── Step mapping tests ──────────────────────────────────────────────

  describe "step mapping" do
    test "ReplaceStep maps through an earlier insertion" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      # First step: insert "xx" at position 1
      insert_text = Schema.text(schema, "xx")
      insert_slice = Slice.new(Fragment.from(insert_text), 0, 0)
      insert_step = ReplaceStep.new(1, 1, insert_slice)
      result1 = ReplaceStep.apply(insert_step, doc_node)
      assert result1.failed == nil

      # Second step: delete "world" (positions 7..12 in original, 9..14 after insert)
      delete_step = ReplaceStep.new(7, 12, Slice.empty())

      # Map the delete step through the insert step's map
      insert_map = ReplaceStep.step_map(insert_step)
      mapped = ReplaceStep.map(delete_step, insert_map)

      assert mapped != nil
      # After inserting "xx" at 1, positions shift by 2
      assert mapped.from == 9
      assert mapped.to == 14

      # The mapped step should apply to the result of step 1
      result2 = ReplaceStep.apply(mapped, result1.doc)
      assert result2.failed == nil
    end

    test "AddMarkStep maps through an earlier deletion" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      # First step: delete "hel" at positions 1..4
      delete_step = ReplaceStep.new(1, 4, Slice.empty())
      result1 = ReplaceStep.apply(delete_step, doc_node)
      assert result1.failed == nil

      # AddMarkStep on positions 5..12 in the original doc
      mark_step = AddMarkStep.new(5, 12, em_mark)

      # Map through deletion
      delete_map = ReplaceStep.step_map(delete_step)
      mapped = AddMarkStep.map(mark_step, delete_map)

      assert mapped != nil
      # After deleting 3 chars at 1..4, positions shift by -3
      assert mapped.from == 2
      assert mapped.to == 9
    end

    test "AttrStep maps through an earlier insertion" do
      {doc_node, _tags} = doc([p(["before"]), h1(["heading"])])

      # Insert a paragraph before everything
      {new_p, _} = p(["inserted"])
      insert_slice = Slice.new(Fragment.from(new_p), 0, 0)
      insert_step = ReplaceStep.new(0, 0, insert_slice)
      result1 = ReplaceStep.apply(insert_step, doc_node)
      assert result1.failed == nil

      # AttrStep on the heading, which was at position 8 in the original doc
      attr_step = AttrStep.new(8, "level", 2)

      # Map through insertion
      insert_map = ReplaceStep.step_map(insert_step)
      mapped = AttrStep.map(attr_step, insert_map)

      assert mapped != nil
      # The heading position should shift by the inserted paragraph size (10)
      assert mapped.pos == 18
      assert mapped.value == 2
    end

    test "step returns nil when mapped position is deleted" do
      {_doc_node, _tags} = doc([p(["hello"]), p(["world"])])

      # Delete the second paragraph entirely (positions 7..14)
      delete_step = ReplaceStep.new(7, 14, Slice.empty())

      # AttrStep targeting the second paragraph which will be deleted
      # (but AttrStep only targets nodes, so let's use a mark step instead)
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      mark_step = AddMarkStep.new(8, 13, em_mark)

      # Map through deletion
      delete_map = ReplaceStep.step_map(delete_step)
      mapped = AddMarkStep.map(mark_step, delete_map)

      # The range 8..13 falls entirely within the deleted range 7..14,
      # so both from and to are deleted. The step should be nil.
      assert mapped == nil
    end

    test "DocAttrStep is unaffected by mapping" do
      step = DocAttrStep.new("title", "Test")
      map = %StepMap{ranges: [0, 5, 3], inverted: false}
      mapped = DocAttrStep.map(step, map)

      assert mapped == step
    end
  end

  # ── from_json error handling ─────────────────────────────────────────

  describe "from_json error handling" do
    test "Step.from_json raises for missing stepType" do
      assert_raise ArgumentError, ~r/Invalid input/, fn ->
        Step.from_json(test_schema(), %{"from" => 1, "to" => 3})
      end
    end

    test "Step.from_json raises for unknown stepType" do
      assert_raise ArgumentError, ~r/No step type/, fn ->
        Step.from_json(test_schema(), %{"stepType" => "nonexistent"})
      end
    end

    test "ReplaceStep.from_json raises for missing from/to" do
      assert_raise ArgumentError, fn ->
        ReplaceStep.from_json(test_schema(), %{"stepType" => "replace"})
      end
    end

    test "ReplaceAroundStep.from_json raises for missing fields" do
      assert_raise ArgumentError, fn ->
        ReplaceAroundStep.from_json(test_schema(), %{"stepType" => "replaceAround", "from" => 0})
      end
    end

    test "AddMarkStep.from_json raises for missing from/to" do
      assert_raise ArgumentError, fn ->
        AddMarkStep.from_json(test_schema(), %{"stepType" => "addMark"})
      end
    end

    test "RemoveMarkStep.from_json raises for missing from/to" do
      assert_raise ArgumentError, fn ->
        RemoveMarkStep.from_json(test_schema(), %{"stepType" => "removeMark"})
      end
    end

    test "AddNodeMarkStep.from_json raises for missing pos" do
      assert_raise ArgumentError, fn ->
        AddNodeMarkStep.from_json(test_schema(), %{"stepType" => "addNodeMark"})
      end
    end

    test "RemoveNodeMarkStep.from_json raises for missing pos" do
      assert_raise ArgumentError, fn ->
        RemoveNodeMarkStep.from_json(test_schema(), %{"stepType" => "removeNodeMark"})
      end
    end

    test "AttrStep.from_json raises for missing pos/attr" do
      assert_raise ArgumentError, fn ->
        AttrStep.from_json(test_schema(), %{"stepType" => "attr"})
      end
    end

    test "DocAttrStep.from_json raises for missing attr" do
      assert_raise ArgumentError, fn ->
        DocAttrStep.from_json(test_schema(), %{"stepType" => "docAttr"})
      end
    end
  end

  # ── Comprehensive round-trip with invert + JSON ──────────────────────

  describe "combined JSON round-trip and invertibility" do
    test "ReplaceStep: JSON round-trip of inverted step" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      text_node = Schema.text(schema, "goodbye")
      slice = Slice.new(Fragment.from(text_node), 0, 0)
      step = ReplaceStep.new(1, 6, slice)

      # Apply original
      result = ReplaceStep.apply(step, doc_node)
      assert result.failed == nil

      # Invert
      inverted = ReplaceStep.invert(step, doc_node)

      # JSON round-trip the inverted step
      json = inverted.__struct__.to_json(inverted)
      recovered = Step.from_json(schema, json)

      # Apply recovered inverted step to the result
      inv_result = recovered.__struct__.apply(recovered, result.doc)
      assert inv_result.failed == nil

      # Should restore original
      assert Node.eq(inv_result.doc, doc_node)
    end

    test "AddMarkStep: JSON round-trip of inverted step" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddMarkStep.new(1, 6, em_mark)

      # Apply
      result = AddMarkStep.apply(step, doc_node)
      assert result.failed == nil

      # Invert (returns RemoveMarkStep)
      inverted = AddMarkStep.invert(step, doc_node)
      assert inverted.__struct__ == RemoveMarkStep

      # JSON round-trip
      json = inverted.__struct__.to_json(inverted)
      recovered = Step.from_json(schema, json)
      assert recovered.__struct__ == RemoveMarkStep

      # Apply to get back original
      inv_result = recovered.__struct__.apply(recovered, result.doc)
      assert inv_result.failed == nil
      assert Node.eq(inv_result.doc, doc_node)
    end

    test "AttrStep: JSON round-trip of inverted step" do
      {doc_node, _tags} = doc([h1(["heading"])])
      schema = test_schema()
      step = AttrStep.new(0, "level", 3)

      # Apply
      result = AttrStep.apply(step, doc_node)
      assert result.failed == nil

      # Invert
      inverted = AttrStep.invert(step, doc_node)
      # original level was 1
      assert inverted.value == 1

      # JSON round-trip
      json = inverted.__struct__.to_json(inverted)
      recovered = Step.from_json(schema, json)

      inv_result = recovered.__struct__.apply(recovered, result.doc)
      assert inv_result.failed == nil
      assert Node.eq(inv_result.doc, doc_node)
    end
  end
end
