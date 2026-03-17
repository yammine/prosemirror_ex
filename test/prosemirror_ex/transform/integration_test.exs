defmodule ProsemirrorEx.Transform.IntegrationTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Node, Schema, MarkType, Fragment, Slice, ResolvedPos}

  alias ProsemirrorEx.Transform.{
    Transform,
    Mapping,
    StepMap,
    Step,
    ReplaceStep,
    AddMarkStep
  }

  # ── Helper: invert a transform ────────────────────────────────────────

  defp invert_transform(tr) do
    out = Transform.new(tr.doc)

    Enum.reduce((length(tr.steps) - 1)..0//-1, out, fn i, acc ->
      step_struct = Enum.at(tr.steps, i)
      step_module = step_struct.__struct__
      inverted = step_module.invert(step_struct, Enum.at(tr.docs, i))
      Transform.step(acc, inverted)
    end)
  end

  # ── 1. Transform chaining ────────────────────────────────────────────

  describe "transform chaining: multiple steps in sequence" do
    test "insert text then add mark" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.insert(6, Schema.text(schema, " world"))
        |> Transform.add_mark(7, 12, MarkType.create(schema.marks["strong"]))

      # Document should have "hello world" with "world" bolded
      assert length(tr.steps) == 2
      assert length(tr.docs) == 2
      assert Transform.doc_changed?(tr)

      # The before doc should be the original
      assert Node.eq(Transform.before(tr), doc_node)
    end

    test "delete then insert" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.delete(1, 6)
        |> Transform.insert(1, Schema.text(schema, "goodbye"))

      # Result should be "goodbye world"
      assert length(tr.steps) == 2
    end

    test "multiple marks on same range" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.add_mark(1, 6, MarkType.create(schema.marks["em"]))
        |> Transform.add_mark(1, 6, MarkType.create(schema.marks["strong"]))

      # Both marks should be present
      assert length(tr.steps) == 2
    end

    test "three sequential replacements" do
      {doc_node, _tags} = doc([p(["aaa bbb ccc"])])
      schema = test_schema()

      # Replace "aaa" with "xxx"
      tr =
        Transform.new(doc_node)
        |> Transform.replace_with(1, 4, Schema.text(schema, "xxx"))

      # Replace "bbb" with "yyy" (positions shifted: "xxx bbb ccc")
      tr = Transform.replace_with(tr, 5, 8, Schema.text(schema, "yyy"))

      # Replace "ccc" with "zzz"
      tr = Transform.replace_with(tr, 9, 12, Schema.text(schema, "zzz"))

      assert length(tr.steps) == 3

      # Verify the final doc has the expected text
      {expected, _} = doc([p(["xxx yyy zzz"])])
      assert Node.eq(tr.doc, expected)
    end

    test "mapping tracks positions correctly through multiple steps" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        # Insert "XX" at start of text -> "XXhello world"
        |> Transform.insert(1, Schema.text(schema, "XX"))

      # Position 1 (before 'h') should map to 3 (after 'XX')
      mapped = Mapping.map(tr.mapping, 1, 1)
      assert mapped == 3

      # Position 6 (before ' ') should map to 8
      mapped = Mapping.map(tr.mapping, 6, 1)
      assert mapped == 8
    end
  end

  # ── 2. Position mapping through transforms ───────────────────────────

  describe "position mapping through transforms" do
    test "map position after insertion" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.insert(3, Schema.text(schema, "XX"))

      # Position before insertion stays the same
      assert Mapping.map(tr.mapping, 1, 1) == 1

      # Position at insertion point maps to after insertion with assoc 1
      assert Mapping.map(tr.mapping, 3, 1) == 5

      # Position at insertion point maps to before insertion with assoc -1
      assert Mapping.map(tr.mapping, 3, -1) == 3

      # Position after insertion shifts
      assert Mapping.map(tr.mapping, 4, 1) == 6
    end

    test "map position after deletion" do
      {doc_node, _tags} = doc([p(["hello world"])])

      tr =
        Transform.new(doc_node)
        |> Transform.delete(3, 8)

      # Position before deletion stays
      assert Mapping.map(tr.mapping, 1, 1) == 1

      # Positions in deleted range collapse
      assert Mapping.map(tr.mapping, 5, 1) == 3
      assert Mapping.map(tr.mapping, 5, -1) == 3

      # Position after deleted range shifts
      assert Mapping.map(tr.mapping, 9, 1) == 4
    end

    test "map position through multiple steps" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        # Insert "AA" at position 1 -> "AAhello world"
        |> Transform.insert(1, Schema.text(schema, "AA"))
        # Delete "hel" (now at 3..6) -> "AAlo world"
        |> Transform.delete(3, 6)

      # Position 1 was before "hello"
      # After insert AA: 1 -> 3 (pushed right by AA)
      # After delete hel (3..6): 3 -> 3 (at start of deletion, stays)
      # Actually with assoc 1, it maps to 3 (collapsed)
      mapped = Mapping.map(tr.mapping, 1, 1)
      assert mapped == 3

      # Position 12 (end of " world")
      # After insert AA: 12 -> 14
      # After delete hel (3..6): 14 -> 11
      mapped_end = Mapping.map(tr.mapping, 12, 1)
      assert mapped_end == 11
    end
  end

  # ── 3. Invertibility ─────────────────────────────────────────────────

  describe "invertibility: apply N steps, invert all, get back original" do
    test "single replace step is invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.replace_with(1, 6, Schema.text(schema, "goodbye"))

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "multiple replace steps are invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.replace_with(1, 6, Schema.text(schema, "goodbye"))
        |> Transform.replace_with(9, 14, Schema.text(schema, "earth"))

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "add and remove marks are invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      tr =
        Transform.new(doc_node)
        |> Transform.add_mark(1, 6, em_mark)
        |> Transform.add_mark(7, 12, MarkType.create(schema.marks["strong"]))

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "mixed operations are invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.insert(6, Schema.text(schema, " beautiful"))
        |> Transform.add_mark(7, 16, MarkType.create(schema.marks["em"]))

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "deletion is invertible" do
      {doc_node, _tags} = doc([p(["hello world"])])

      tr =
        Transform.new(doc_node)
        |> Transform.delete(1, 6)

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "attr step is invertible in transform" do
      {doc_node, _tags} = doc([h1(["heading text"])])

      tr =
        Transform.new(doc_node)
        |> Transform.set_node_attribute(0, "level", 3)

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "doc attr step is invertible in transform" do
      {doc_node, _tags} = doc([p(["hello"])])

      tr =
        Transform.new(doc_node)
        |> Transform.set_doc_attribute("title", "My Doc")

      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end
  end

  # ── 4. Complex workflows ────────────────────────────────────────────

  describe "complex workflows" do
    test "build doc -> add marks -> split -> verify" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      # Add emphasis to "hello"
      tr =
        Transform.new(doc_node)
        |> Transform.add_mark(1, 6, MarkType.create(schema.marks["em"]))

      # Split the paragraph at position 7 (between "hello " and "world")
      tr = Transform.split(tr, 7)

      # Should now have two paragraphs
      assert Node.child_count(tr.doc) == 2

      # The transform should be invertible
      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "split then join roundtrips" do
      {doc_node, _tags} = doc([p(["hello world"])])

      # Split the paragraph
      tr =
        Transform.new(doc_node)
        |> Transform.split(6)

      assert Node.child_count(tr.doc) == 2

      # Join it back together at the boundary
      # The join position is between the two paragraphs: after first p
      # First p: 0..7 (0=open, 1-5=hello, 6=split, 7=close -> after split: 0..6)
      # Actually split at 6 means: p("hello") and p(" world")
      # Join position is at 7 (boundary between the two paragraphs)
      tr = Transform.join(tr, 7)

      # Should be back to one paragraph
      assert Node.child_count(tr.doc) == 1

      # The final doc should match the original
      assert Node.eq(tr.doc, doc_node)
    end

    test "wrap in blockquote -> lift -> verify roundtrip" do
      {doc_node, _tags} = doc([p(["hello"])])
      schema = test_schema()

      # Wrap the paragraph in a blockquote
      from_pos = Node.resolve(doc_node, 0)
      to_pos = Node.resolve(doc_node, 7)
      range = ResolvedPos.block_range(from_pos, to_pos)
      bq_type = Schema.node_type(schema, "blockquote")

      wrappers = ProsemirrorEx.Transform.Structure.find_wrapping(range, bq_type)
      assert wrappers != nil

      tr =
        Transform.new(doc_node)
        |> Transform.wrap(range, wrappers)

      # Should now have blockquote > paragraph
      assert tr.doc.content.content |> hd() |> Map.get(:type) |> Map.get(:name) == "blockquote"

      # Now lift the paragraph out of the blockquote
      # Need to resolve in the new doc
      from_pos2 = Node.resolve(tr.doc, 2)
      range2 = ResolvedPos.block_range(from_pos2)
      target = ProsemirrorEx.Transform.Structure.lift_target(range2)
      assert target != nil

      tr = Transform.lift(tr, range2, target)

      # Should be back to just a paragraph
      assert Node.eq(tr.doc, doc_node)
    end

    test "set block type -> add mark -> delete range" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()
      heading_type = Schema.node_type(schema, "heading")

      # Set paragraph to heading level 2
      tr =
        Transform.new(doc_node)
        |> Transform.set_block_type(1, 1, heading_type, %{"level" => 2})

      # Verify it's now a heading
      first_child = hd(tr.doc.content.content)
      assert first_child.type.name == "heading"
      assert first_child.attrs["level"] == 2

      # Add emphasis to "hello"
      tr = Transform.add_mark(tr, 1, 6, MarkType.create(schema.marks["em"]))

      # Delete "world"
      tr = Transform.delete(tr, 7, 12)

      # Verify the result
      first_child = hd(tr.doc.content.content)
      assert first_child.type.name == "heading"

      # The whole thing should be invertible
      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end

    test "multiple paragraph operations" do
      {doc_node, _tags} = doc([p(["aaa"]), p(["bbb"]), p(["ccc"])])
      schema = test_schema()

      # Add emphasis to first paragraph
      tr =
        Transform.new(doc_node)
        |> Transform.add_mark(1, 4, MarkType.create(schema.marks["em"]))

      # Delete the second paragraph's content
      tr = Transform.delete(tr, 6, 9)

      # Insert new content in second paragraph
      tr = Transform.insert(tr, 6, Schema.text(schema, "xxx"))

      # All steps should be invertible
      inverted = invert_transform(tr)
      assert Node.eq(inverted.doc, doc_node)
    end
  end

  # ── 5. Transform extensibility ──────────────────────────────────────

  describe "transform extensibility" do
    test "custom struct with required fields works with Transform functions" do
      {doc_node, _tags} = doc([p(["hello"])])

      # Create a custom struct-like map with the required fields
      custom_tr = %{
        doc: doc_node,
        steps: [],
        docs: [],
        mapping: Mapping.new(),
        # extra field for extensibility
        metadata: %{user: "test_user", timestamp: 12345}
      }

      # Transform.step should work with any map that has the right keys
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      step = AddMarkStep.new(1, 6, em_mark)

      result = Transform.step(custom_tr, step)

      # Verify the result has all original fields plus updates
      assert result.metadata == %{user: "test_user", timestamp: 12345}
      assert length(result.steps) == 1
      assert length(result.docs) == 1
      assert result.doc != doc_node

      # Transform.before should work
      assert Transform.before(result) == doc_node

      # Transform.doc_changed? should work
      assert Transform.doc_changed?(result)
    end

    test "maybe_step works with custom struct" do
      {doc_node, _tags} = doc([p(["hello"])])

      custom_tr = %{
        doc: doc_node,
        steps: [],
        docs: [],
        mapping: Mapping.new(),
        custom_field: :some_value
      }

      schema = test_schema()
      step = ReplaceStep.new(1, 4, Slice.new(Fragment.from(Schema.text(schema, "hey")), 0, 0))

      {result_tr, result} = Transform.maybe_step(custom_tr, step)
      assert result.failed == nil
      assert result_tr.custom_field == :some_value
      assert length(result_tr.steps) == 1
    end
  end

  # ── 6. Mapping mirror recovery ──────────────────────────────────────

  describe "mapping mirror recovery" do
    test "mirror pairs allow position recovery through deletion" do
      # Create a mapping with mirror pairs (step and its inverse)
      # Step: delete positions 2..5 (delete 3 chars)
      map1 = %StepMap{ranges: [2, 3, 0], inverted: false}
      # Inverse: insert 3 chars at position 2
      map2 = %StepMap{ranges: [2, 0, 3], inverted: false}

      mapping =
        Mapping.new()
        |> Mapping.append_map(map1)
        |> Mapping.append_map(map2, 0)

      # Position 3 (inside deleted range) should be recoverable
      # With mirrors, position 3 should map back through the mirror pair
      result = Mapping.map(mapping, 3, 1)

      # Position 3 was deleted in map1, but map2 is the mirror (inverse)
      # so it should recover position 3
      assert result == 3
    end

    test "mirror pairs in mapping preserve positions" do
      # Simulate: delete at 5..8, then undo (insert at 5)
      delete_map = %StepMap{ranges: [5, 3, 0], inverted: false}
      undo_map = %StepMap{ranges: [5, 0, 3], inverted: false}

      mapping =
        Mapping.new()
        |> Mapping.append_map(delete_map)
        |> Mapping.append_map(undo_map, 0)

      # Position 6 (in deleted range) should map back to 6
      assert Mapping.map(mapping, 6) == 6

      # Position 10 (after deleted range) should stay at 10
      assert Mapping.map(mapping, 10) == 10

      # Position 3 (before deleted range) should stay at 3
      assert Mapping.map(mapping, 3) == 3
    end

    test "mapping inversion" do
      # Create a mapping with one change: delete 3 chars at position 2
      map1 = %StepMap{ranges: [2, 3, 0], inverted: false}
      mapping = Mapping.new() |> Mapping.append_map(map1)

      # Position 10 -> maps to 7 (shifted left by 3)
      assert Mapping.map(mapping, 10) == 7

      # Invert the mapping
      inv = Mapping.invert(mapping)

      # Position 7 in post-step -> maps to 10 in pre-step
      assert Mapping.map(inv, 7) == 10
    end

    test "append_mapping preserves mirror information" do
      map1 = %StepMap{ranges: [2, 3, 0], inverted: false}
      map2 = %StepMap{ranges: [2, 0, 3], inverted: false}

      # When we combine maps with mirror info, the mirror should
      # allow position recovery
      combined =
        Mapping.new()
        |> Mapping.append_map(map1)
        |> Mapping.append_map(map2, 0)

      # Position inside deleted range should be recoverable
      assert Mapping.map(combined, 3) == 3
    end
  end

  # ── 7. JSON round-trip through Transform ─────────────────────────────

  describe "JSON round-trip through Transform" do
    test "all steps in a transform can be serialized and replayed" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.replace_with(1, 6, Schema.text(schema, "goodbye"))
        |> Transform.add_mark(1, 8, MarkType.create(schema.marks["em"]))

      # Serialize all steps
      jsons = Enum.map(tr.steps, fn step -> step.__struct__.to_json(step) end)

      # Replay from JSON
      replay_tr = Transform.new(doc_node)

      replay_tr =
        Enum.reduce(jsons, replay_tr, fn json, acc ->
          step = Step.from_json(schema, json)
          Transform.step(acc, step)
        end)

      # Results should match
      assert Node.eq(tr.doc, replay_tr.doc)
    end

    test "inverted steps can be serialized and replayed" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.delete(1, 6)
        |> Transform.insert(1, Schema.text(schema, "goodbye"))

      # Invert the transform
      inverted = invert_transform(tr)

      # Serialize the inverted steps
      jsons = Enum.map(inverted.steps, fn step -> step.__struct__.to_json(step) end)

      # Replay from JSON starting from the modified doc
      replay_tr = Transform.new(tr.doc)

      replay_tr =
        Enum.reduce(jsons, replay_tr, fn json, acc ->
          step = Step.from_json(schema, json)
          Transform.step(acc, step)
        end)

      # Should get back original doc
      assert Node.eq(replay_tr.doc, doc_node)
    end
  end

  # ── 8. changed_range ─────────────────────────────────────────────────

  describe "changed_range" do
    test "returns nil for empty transform" do
      {doc_node, _tags} = doc([p(["hello"])])
      tr = Transform.new(doc_node)
      assert Transform.changed_range(tr) == nil
    end

    test "returns range for single replacement" do
      {doc_node, _tags} = doc([p(["hello world"])])
      schema = test_schema()

      tr =
        Transform.new(doc_node)
        |> Transform.replace_with(1, 6, Schema.text(schema, "goodbye"))

      range = Transform.changed_range(tr)
      assert range != nil
      assert range.from <= 1
      assert range.to >= 8
    end
  end

  # ── 9. Edge cases ───────────────────────────────────────────────────

  describe "edge cases" do
    test "empty replacement is a no-op" do
      {doc_node, _tags} = doc([p(["hello"])])

      tr =
        Transform.new(doc_node)
        |> Transform.replace(1, 1)

      # No steps should have been added for a no-op replacement
      assert length(tr.steps) == 0
      assert Node.eq(tr.doc, doc_node)
    end

    test "maybe_step doesn't raise on failure" do
      {doc_node, _tags} = doc([p(["hello"])])
      # Structure replace on content will fail
      step = ReplaceStep.new(1, 6, Slice.empty(), true)

      tr = Transform.new(doc_node)
      {returned_tr, result} = Transform.maybe_step(tr, step)

      assert result.failed != nil
      assert returned_tr == tr
    end

    test "step raises TransformError on failure" do
      {doc_node, _tags} = doc([p(["hello"])])
      step = ReplaceStep.new(1, 6, Slice.empty(), true)

      tr = Transform.new(doc_node)

      assert_raise ProsemirrorEx.Transform.TransformError, fn ->
        Transform.step(tr, step)
      end
    end
  end
end
