defmodule ProsemirrorEx.Schema.BasicTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.{Node, Schema}
  alias ProsemirrorEx.Schema.Basic

  describe "schema/0" do
    test "builds a schema with expected node types" do
      schema = Basic.schema()

      for name <- ~w(
        doc paragraph blockquote horizontal_rule heading code_block
        text image hard_break
      ) do
        assert Map.has_key?(schema.nodes, name), "missing node #{name}"
      end
    end

    test "builds a schema with expected mark types" do
      schema = Basic.schema()

      for name <- ~w(link em strong code) do
        assert Map.has_key?(schema.marks, name), "missing mark #{name}"
      end
    end

    test "does not include list node types" do
      schema = Basic.schema()

      refute Map.has_key?(schema.nodes, "bullet_list")
      refute Map.has_key?(schema.nodes, "ordered_list")
      refute Map.has_key?(schema.nodes, "list_item")
    end

    test "sets top node to doc" do
      schema = Basic.schema()
      assert schema.top_node_type.name == "doc"
    end
  end

  describe "nodes/0 and marks/0" do
    test "nodes/0 returns spec tuples for all basic node names" do
      names = Basic.nodes() |> Enum.map(&elem(&1, 0))

      assert names == ~w(
        doc paragraph blockquote horizontal_rule heading code_block
        text image hard_break
      )
    end

    test "marks/0 returns spec tuples for all basic mark names" do
      names = Basic.marks() |> Enum.map(&elem(&1, 0))
      assert names == ~w(link em strong code)
    end
  end

  describe "document construction" do
    setup do
      %{schema: Basic.schema()}
    end

    test "creates a paragraph with text", %{schema: schema} do
      text = Schema.text(schema, "hello")
      paragraph = Schema.node(schema, "paragraph", nil, [text])

      assert paragraph.type.name == "paragraph"
      assert Node.child_count(paragraph) == 1
      assert Node.child(paragraph, 0).text == "hello"
    end

    test "creates a heading with level attribute", %{schema: schema} do
      text = Schema.text(schema, "Title")
      heading = Schema.node(schema, "heading", %{"level" => 2}, [text])

      assert heading.type.name == "heading"
      assert heading.attrs == %{"level" => 2}
    end

    test "heading defaults level to 1", %{schema: schema} do
      heading = Schema.node(schema, "heading", nil, [Schema.text(schema, "x")])
      assert heading.attrs == %{"level" => 1}
    end

    test "creates a code_block with text", %{schema: schema} do
      text = Schema.text(schema, "let x = 1")
      code_block = Schema.node(schema, "code_block", nil, [text])

      assert code_block.type.name == "code_block"
      assert code_block.type.is_textblock
      assert Node.child(code_block, 0).text == "let x = 1"
    end

    test "creates horizontal_rule and hard_break leaf nodes", %{schema: schema} do
      hr = Schema.node(schema, "horizontal_rule")
      br = Schema.node(schema, "hard_break")

      assert hr.type.name == "horizontal_rule"
      assert hr.type.is_leaf
      assert br.type.name == "hard_break"
      assert br.type.is_leaf
    end

    test "creates link, em, strong, and code marks", %{schema: schema} do
      link = Schema.mark(schema, "link", %{"href" => "https://example.com"})
      em = Schema.mark(schema, "em")
      strong = Schema.mark(schema, "strong")
      code = Schema.mark(schema, "code")

      assert link.type.name == "link"
      assert link.attrs["href"] == "https://example.com"
      assert em.type.name == "em"
      assert strong.type.name == "strong"
      assert code.type.name == "code"
    end

    test "applies marks to text", %{schema: schema} do
      text =
        Schema.text(schema, "styled", [
          Schema.mark(schema, "em"),
          Schema.mark(schema, "strong")
        ])

      mark_names = Enum.map(text.marks, & &1.type.name) |> Enum.sort()
      assert mark_names == ["em", "strong"]
    end
  end

  describe "JSON round-trip" do
    test "round-trips a small document" do
      schema = Basic.schema()

      doc =
        Schema.node(schema, "doc", nil, [
          Schema.node(schema, "heading", %{"level" => 1}, [
            Schema.text(schema, "Hello", [Schema.mark(schema, "strong")])
          ]),
          Schema.node(schema, "paragraph", nil, [
            Schema.text(schema, "Visit "),
            Schema.text(schema, "us", [
              Schema.mark(schema, "link", %{"href" => "https://example.com"})
            ])
          ]),
          Schema.node(schema, "code_block", nil, [Schema.text(schema, "code()")]),
          Schema.node(schema, "horizontal_rule")
        ])

      json = Node.to_json(doc)
      restored = Node.from_json(schema, json)

      assert Node.to_json(restored) == json
    end
  end
end
