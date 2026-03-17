defmodule ProsemirrorEx.Transform.AttrStepTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Fragment, Node, Schema}

  alias ProsemirrorEx.Transform.{
    Step,
    StepMap,
    AttrStep,
    DocAttrStep
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

  describe "AttrStep" do
    test "sets an attribute on a node" do
      {doc_node, _} = doc([h1(["hello"])])

      step = AttrStep.new(0, "level", 2)
      result = AttrStep.apply(step, doc_node)
      assert result.failed == nil

      {expected, _} = doc([h2(["hello"])])
      assert Node.eq(result.doc, expected)
    end

    test "fails when no node at position" do
      {doc_node, _} = doc([p(["hello"])])

      step = AttrStep.new(100, "level", 2)
      result = AttrStep.apply(step, doc_node)
      assert result.failed != nil
    end

    test "step_map returns empty StepMap" do
      step = AttrStep.new(0, "level", 2)
      map = AttrStep.step_map(step)
      assert map.ranges == []
    end

    test "invert restores original attribute" do
      {doc_node, _} = doc([h1(["hello"])])

      step = AttrStep.new(0, "level", 2)
      result = AttrStep.apply(step, doc_node)
      assert result.failed == nil

      inv = AttrStep.invert(step, doc_node)
      inv_result = AttrStep.apply(inv, result.doc)
      assert inv_result.failed == nil
      assert Node.eq(inv_result.doc, doc_node)
    end

    test "map through identity returns same step" do
      step = AttrStep.new(0, "level", 2)
      mapped = AttrStep.map(step, StepMap.empty())
      assert mapped.pos == 0
      assert mapped.attr == "level"
      assert mapped.value == 2
    end

    test "map returns nil when position is deleted" do
      step = AttrStep.new(2, "level", 2)
      map = %StepMap{ranges: [1, 5, 0], inverted: false}
      mapped = AttrStep.map(step, map)
      assert mapped == nil
    end

    test "to_json serializes correctly" do
      step = AttrStep.new(0, "level", 3)
      json = AttrStep.to_json(step)
      assert json["stepType"] == "attr"
      assert json["pos"] == 0
      assert json["attr"] == "level"
      assert json["value"] == 3
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        AttrStep.from_json(schema, %{})
      end

      assert_raise ArgumentError, fn ->
        AttrStep.from_json(schema, %{"pos" => 0})
      end
    end

    test "from_json deserializes correctly" do
      schema = test_schema()
      json = %{"stepType" => "attr", "pos" => 0, "attr" => "level", "value" => 3}
      step = AttrStep.from_json(schema, json)
      assert step.pos == 0
      assert step.attr == "level"
      assert step.value == 3
    end

    test "JSON round-trip" do
      {doc_node, _} = doc([h1(["hello"])])
      step = AttrStep.new(0, "level", 2)
      test_step_json(doc_node, AttrStep, step)
    end

    test "JSON round-trip with nil value" do
      {doc_node, _} = doc([h1(["hello"])])
      step = AttrStep.new(0, "level", nil)
      test_step_json(doc_node, AttrStep, step)
    end
  end

  describe "DocAttrStep" do
    setup do
      # Create a schema with doc-level attrs for testing
      schema_with_doc_attrs =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+", "attrs" => %{"meta" => %{"default" => nil}}}},
            {"paragraph", %{"content" => "inline*", "group" => "block"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => []
        })

      %{schema: schema_with_doc_attrs}
    end

    test "sets an attribute on the doc node", %{schema: schema} do
      p_type = Schema.node_type(schema, "paragraph")
      text = Schema.text(schema, "hello")
      p_node = ProsemirrorEx.Model.NodeType.create(p_type, nil, Fragment.from(text), nil)
      doc_type = Schema.node_type(schema, "doc")
      doc_node = ProsemirrorEx.Model.NodeType.create(doc_type, nil, Fragment.from(p_node), nil)

      step = DocAttrStep.new("meta", "value")
      result = DocAttrStep.apply(step, doc_node)
      assert result.failed == nil
      assert result.doc.attrs["meta"] == "value"
    end

    test "step_map returns empty StepMap" do
      step = DocAttrStep.new("meta", "value")
      map = DocAttrStep.step_map(step)
      assert map.ranges == []
    end

    test "invert restores original doc attribute", %{schema: schema} do
      p_type = Schema.node_type(schema, "paragraph")
      text = Schema.text(schema, "hello")
      p_node = ProsemirrorEx.Model.NodeType.create(p_type, nil, Fragment.from(text), nil)
      doc_type = Schema.node_type(schema, "doc")
      doc_node = ProsemirrorEx.Model.NodeType.create(doc_type, nil, Fragment.from(p_node), nil)

      step = DocAttrStep.new("meta", "value")
      result = DocAttrStep.apply(step, doc_node)
      assert result.failed == nil

      inv = DocAttrStep.invert(step, doc_node)
      inv_result = DocAttrStep.apply(inv, result.doc)
      assert inv_result.failed == nil
      assert inv_result.doc.attrs == doc_node.attrs
    end

    test "map returns self" do
      step = DocAttrStep.new("meta", "value")
      mapped = DocAttrStep.map(step, StepMap.empty())
      assert mapped == step
    end

    test "to_json serializes correctly" do
      step = DocAttrStep.new("meta", "value")
      json = DocAttrStep.to_json(step)
      assert json["stepType"] == "docAttr"
      assert json["attr"] == "meta"
      assert json["value"] == "value"
    end

    test "from_json raises on invalid input" do
      schema = test_schema()

      assert_raise ArgumentError, fn ->
        DocAttrStep.from_json(schema, %{})
      end
    end

    test "from_json deserializes correctly" do
      schema = test_schema()
      json = %{"stepType" => "docAttr", "attr" => "meta", "value" => "test"}
      step = DocAttrStep.from_json(schema, json)
      assert step.attr == "meta"
      assert step.value == "test"
    end

    test "JSON round-trip", %{schema: schema} do
      p_type = Schema.node_type(schema, "paragraph")
      text = Schema.text(schema, "hello")
      p_node = ProsemirrorEx.Model.NodeType.create(p_type, nil, Fragment.from(text), nil)
      doc_type = Schema.node_type(schema, "doc")
      doc_node = ProsemirrorEx.Model.NodeType.create(doc_type, nil, Fragment.from(p_node), nil)

      step = DocAttrStep.new("meta", "value")

      # Apply the step
      result = DocAttrStep.apply(step, doc_node)
      assert result.failed == nil

      # Serialize to JSON
      json = DocAttrStep.to_json(step)

      # Deserialize (use the schema with doc attrs)
      recovered = DocAttrStep.from_json(schema, json)

      # Apply the recovered step
      result2 = DocAttrStep.apply(recovered, doc_node)
      assert result2.failed == nil

      assert Node.eq(result.doc, result2.doc)
    end

    test "merge returns nil (no merge support)" do
      step1 = DocAttrStep.new("meta", "a")
      step2 = DocAttrStep.new("meta", "b")
      assert DocAttrStep.merge(step1, step2) == nil
    end
  end
end
