defmodule ProsemirrorEx.Model.FromJsonTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Schema, Node, Fragment, Mark, NodeType}
  alias ProsemirrorEx.Model.Node, as: PmNode

  # ── Mark.from_json ─────────────────────────────────────────────────────

  describe "Mark.from_json" do
    test "deserializes a simple mark" do
      schema = test_schema()
      mark = Mark.from_json(schema, %{"type" => "em"})
      assert mark.type.name == "em"
      assert mark.attrs == %{}
    end

    test "deserializes a mark with attrs" do
      schema = test_schema()

      mark =
        Mark.from_json(schema, %{"type" => "link", "attrs" => %{"href" => "http://example.com"}})

      assert mark.type.name == "link"
      assert mark.attrs["href"] == "http://example.com"
      assert mark.attrs["title"] == nil
    end

    test "raises on nil input" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/Invalid input/, fn ->
        Mark.from_json(schema, nil)
      end
    end

    test "raises on unknown mark type" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/no mark type/, fn ->
        Mark.from_json(schema, %{"type" => "nonexistent"})
      end
    end
  end

  # ── Fragment.from_json ─────────────────────────────────────────────────

  describe "Fragment.from_json" do
    test "deserializes nil to empty fragment" do
      schema = test_schema()
      frag = Fragment.from_json(schema, nil)
      assert frag == Fragment.empty()
    end

    test "deserializes an array of node JSON" do
      schema = test_schema()

      json = [
        %{"type" => "text", "text" => "hello"}
      ]

      frag = Fragment.from_json(schema, json)
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0).text == "hello"
    end

    test "raises on invalid input" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/Invalid input/, fn ->
        Fragment.from_json(schema, "not a list")
      end
    end
  end

  # ── Node.from_json ─────────────────────────────────────────────────────

  describe "Node.from_json" do
    test "deserializes a text node" do
      schema = test_schema()
      json = %{"type" => "text", "text" => "hello"}
      node = PmNode.from_json(schema, json)
      assert node.text == "hello"
      assert node.type.name == "text"
    end

    test "deserializes a text node with marks" do
      schema = test_schema()

      json = %{
        "type" => "text",
        "text" => "bold",
        "marks" => [%{"type" => "strong"}]
      }

      node = PmNode.from_json(schema, json)
      assert node.text == "bold"
      assert length(node.marks) == 1
      assert hd(node.marks).type.name == "strong"
    end

    test "deserializes a paragraph" do
      schema = test_schema()

      json = %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "text", "text" => "hello"}
        ]
      }

      node = PmNode.from_json(schema, json)
      assert node.type.name == "paragraph"
      assert PmNode.child_count(node) == 1
      assert PmNode.first_child(node).text == "hello"
    end

    test "deserializes a doc with nested content" do
      schema = test_schema()

      json = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "hi"}
            ]
          }
        ]
      }

      node = PmNode.from_json(schema, json)
      assert node.type.name == "doc"
      assert PmNode.child_count(node) == 1
    end

    test "deserializes a heading with attrs" do
      schema = test_schema()

      json = %{
        "type" => "heading",
        "attrs" => %{"level" => 2},
        "content" => [
          %{"type" => "text", "text" => "Title"}
        ]
      }

      node = PmNode.from_json(schema, json)
      assert node.type.name == "heading"
      assert node.attrs["level"] == 2
    end

    test "raises on nil input" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/Invalid input/, fn ->
        PmNode.from_json(schema, nil)
      end
    end

    test "raises on unknown node type" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/no mark type|Unknown node type|no node type/, fn ->
        PmNode.from_json(schema, %{"type" => "nonexistent"})
      end
    end

    test "raises on text node without text" do
      schema = test_schema()

      assert_raise RuntimeError, ~r/Invalid text/, fn ->
        PmNode.from_json(schema, %{"type" => "text"})
      end
    end

    test "raises on invalid marks" do
      schema = test_schema()

      assert_raise RuntimeError, fn ->
        PmNode.from_json(schema, %{
          "type" => "text",
          "text" => "hi",
          "marks" => "not a list"
        })
      end
    end
  end

  # ── toJSON round-trip tests ────────────────────────────────────────────

  describe "toJSON round-trip" do
    test "can serialize and deserialize a simple node" do
      {node, _} = doc([p(["hello"])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can serialize and deserialize marks" do
      {node, _} = doc([p([em(["hello"]), strong([" world"])])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can serialize and deserialize inline leaf nodes" do
      {node, _} = doc([p(["before", br(), "after"])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can serialize and deserialize block leaf nodes" do
      {node, _} = doc([p(["a"]), hr(), p(["b"])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can serialize and deserialize nested nodes" do
      {node, _} =
        doc([
          blockquote([
            p(["hello"]),
            p([em(["world"])])
          ]),
          p(["end"])
        ])

      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can round-trip a heading with attrs" do
      {node, _} = doc([h1(["Title"]), p(["body"])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can round-trip a list" do
      {node, _} = doc([ul([li([p(["item 1"])]), li([p(["item 2"])])])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end

    test "can round-trip a link mark" do
      {node, _} = doc([p([a(["click"])])])
      json = PmNode.to_json(node)
      schema = test_schema()
      restored = PmNode.from_json(schema, json)
      assert eq(node, restored)
    end
  end

  # ── Node.check ─────────────────────────────────────────────────────────

  describe "Node.check" do
    test "passes for a valid document" do
      {node, _} = doc([p(["hello"])])
      # Should not raise
      PmNode.check(node)
    end

    test "passes for a valid complex document" do
      {node, _} =
        doc([
          h1(["Title"]),
          p([em(["emphasized"]), " text"]),
          blockquote([p(["quote"])]),
          ul([li([p(["item"])])])
        ])

      PmNode.check(node)
    end

    test "notices invalid content" do
      # A doc containing a list_item directly (should require block+)
      schema = test_schema()
      li_type = schema.nodes["list_item"]
      p_node = Schema.node(schema, "paragraph", nil, [])
      li_node = NodeType.create(li_type, nil, [p_node])
      bad_doc = NodeType.create(schema.nodes["doc"], nil, [li_node])

      # list_item is not in the "block" group, so doc shouldn't accept it
      # Actually, let me check - list_item doesn't have group "block"
      # So this should fail content validation
      assert_raise RuntimeError, ~r/Invalid content/, fn ->
        PmNode.check(bad_doc)
      end
    end

    test "notices marks in wrong places" do
      # Create a schema where paragraph disallows marks
      restricted_schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block", "marks" => ""}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{}}
          ]
        })

      em_mark = Schema.mark(restricted_schema, "em")
      marked_text = Schema.text(restricted_schema, "hello", [em_mark])
      # Force-create a paragraph with em-marked text (bypassing validation)
      bad_para = NodeType.create(restricted_schema.nodes["paragraph"], nil, [marked_text])
      bad_doc = NodeType.create(restricted_schema.nodes["doc"], nil, [bad_para])

      assert_raise RuntimeError, ~r/Invalid content/, fn ->
        PmNode.check(bad_doc)
      end
    end

    test "notices incorrect sets of marks (duplicate em)" do
      # Create a node with duplicate em marks in its mark list
      schema = test_schema()
      em = Schema.mark(schema, "em")

      # Manually construct a text node with duplicate em marks
      text_type = schema.nodes["text"]
      bad_text = %Node{type: text_type, text: "hello", marks: [em, em], attrs: %{}, content: nil}
      para = NodeType.create(schema.nodes["paragraph"], nil, [bad_text])
      bad_doc = NodeType.create(schema.nodes["doc"], nil, [para])

      assert_raise RuntimeError, ~r/Invalid collection of marks/, fn ->
        PmNode.check(bad_doc)
      end
    end
  end

  # ── Node.content_match_at ──────────────────────────────────────────────

  describe "Node.content_match_at" do
    test "returns content match at index 0" do
      {node, _} = doc([p(["hello"]), p(["world"])])
      match = PmNode.content_match_at(node, 0)
      assert match != nil
    end

    test "returns content match after all children" do
      {node, _} = doc([p(["hello"])])
      match = PmNode.content_match_at(node, 1)
      assert match != nil
      assert match.valid_end == true
    end
  end

  # ── Node.can_replace ───────────────────────────────────────────────────

  describe "Node.can_replace" do
    test "can replace empty range with valid content" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      new_para = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "new")])
      replacement = Fragment.from([new_para])

      assert PmNode.can_replace(doc_node, 1, 1, replacement)
    end

    test "can replace a range" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      new_para = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "new")])
      replacement = Fragment.from([new_para])

      assert PmNode.can_replace(doc_node, 0, 1, replacement)
    end

    test "rejects invalid replacement" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"])])
      # Try to insert inline content into doc (requires block+)
      text = Schema.text(schema, "bad")
      replacement = Fragment.from([text])

      refute PmNode.can_replace(doc_node, 0, 0, replacement)
    end
  end

  # ── Node.can_replace_with ──────────────────────────────────────────────

  describe "Node.can_replace_with" do
    test "can replace with a valid node type" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"]), p(["world"])])

      assert PmNode.can_replace_with(doc_node, 1, 1, schema.nodes["paragraph"])
    end

    test "rejects invalid node type" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"])])

      refute PmNode.can_replace_with(doc_node, 0, 0, schema.nodes["text"])
    end

    test "rejects disallowed marks" do
      # Use a restricted schema where doc disallows marks on its children
      restricted_schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+", "marks" => ""}},
            {"paragraph", %{"content" => "inline*", "group" => "block"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{}}
          ]
        })

      em_mark = Schema.mark(restricted_schema, "em")
      para = NodeType.create(restricted_schema.nodes["paragraph"], nil, [])
      doc_node = NodeType.create(restricted_schema.nodes["doc"], nil, [para])

      # doc disallows marks, so canReplaceWith with marks should be false
      refute PmNode.can_replace_with(
               doc_node,
               0,
               0,
               restricted_schema.nodes["paragraph"],
               [em_mark]
             )
    end
  end

  # ── Node.can_append ────────────────────────────────────────────────────

  describe "Node.can_append" do
    test "can append compatible content" do
      {doc1, _} = doc([p(["hello"])])
      {doc2, _} = doc([p(["world"])])

      assert PmNode.can_append(doc1, doc2)
    end

    test "can append same type" do
      {p1, _} = p(["hello"])
      {p2, _} = p(["world"])

      assert PmNode.can_append(p1, p2)
    end
  end
end
