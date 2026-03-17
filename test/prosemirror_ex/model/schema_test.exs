defmodule ProsemirrorEx.Model.SchemaTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.Schema
  alias ProsemirrorEx.Model.NodeType
  alias ProsemirrorEx.Model.MarkType
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode

  defp test_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"horizontal_rule", %{"group" => "block"}},
        {"heading",
         %{
           "content" => "inline*",
           "group" => "block",
           "attrs" => %{"level" => %{"default" => 1}}
         }},
        {"code_block", %{"content" => "text*", "group" => "block", "code" => true}},
        {"text", %{"group" => "inline"}},
        {"image",
         %{
           "group" => "inline",
           "inline" => true,
           "attrs" => %{
             "src" => %{},
             "alt" => %{"default" => nil},
             "title" => %{"default" => nil}
           }
         }},
        {"hard_break", %{"group" => "inline", "inline" => true}},
        {"ordered_list",
         %{
           "content" => "list_item+",
           "group" => "block",
           "attrs" => %{"order" => %{"default" => 1}}
         }},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"list_item", %{"content" => "paragraph block*"}}
      ],
      "marks" => [
        {"link",
         %{
           "attrs" => %{"href" => %{}, "title" => %{"default" => nil}},
           "inclusive" => false
         }},
        {"em", %{}},
        {"strong", %{}},
        {"code", %{}}
      ]
    })
  end

  # ── Schema construction ──────────────────────────────────────────

  describe "Schema construction" do
    test "creates node types from spec" do
      schema = test_schema()
      assert Map.has_key?(schema.nodes, "doc")
      assert Map.has_key?(schema.nodes, "paragraph")
      assert Map.has_key?(schema.nodes, "text")
      assert Map.has_key?(schema.nodes, "heading")
      assert Map.has_key?(schema.nodes, "image")
      assert Map.has_key?(schema.nodes, "blockquote")
      assert Map.has_key?(schema.nodes, "horizontal_rule")
      assert Map.has_key?(schema.nodes, "code_block")
      assert Map.has_key?(schema.nodes, "hard_break")
      assert Map.has_key?(schema.nodes, "ordered_list")
      assert Map.has_key?(schema.nodes, "bullet_list")
      assert Map.has_key?(schema.nodes, "list_item")
    end

    test "creates mark types from spec" do
      schema = test_schema()
      assert Map.has_key?(schema.marks, "link")
      assert Map.has_key?(schema.marks, "em")
      assert Map.has_key?(schema.marks, "strong")
      assert Map.has_key?(schema.marks, "code")
    end

    test "sets top_node_type to doc by default" do
      schema = test_schema()
      assert schema.top_node_type.name == "doc"
    end

    test "allows custom top node" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "text*", "group" => "block"}},
            {"text", %{"group" => "inline"}}
          ],
          "topNode" => "doc"
        })

      assert schema.top_node_type.name == "doc"
    end

    test "raises when missing top node type" do
      assert_raise RuntimeError, fn ->
        Schema.new(%{
          "nodes" => [
            {"paragraph", %{"content" => "text*"}},
            {"text", %{}}
          ]
        })
      end
    end

    test "raises when missing text node type" do
      assert_raise RuntimeError, fn ->
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "paragraph+"}},
            {"paragraph", %{}}
          ]
        })
      end
    end

    test "node types have correct block/inline flags" do
      schema = test_schema()

      assert schema.nodes["doc"].is_block == true
      assert schema.nodes["paragraph"].is_block == true
      assert schema.nodes["heading"].is_block == true
      assert schema.nodes["blockquote"].is_block == true
      assert schema.nodes["text"].is_block == false
      assert schema.nodes["text"].is_inline == true
      assert schema.nodes["image"].is_inline == true
      assert schema.nodes["hard_break"].is_inline == true
    end

    test "node types have correct inline_content flags" do
      schema = test_schema()

      assert schema.nodes["paragraph"].inline_content == true
      assert schema.nodes["heading"].inline_content == true
      assert schema.nodes["doc"].inline_content == false
      assert schema.nodes["blockquote"].inline_content == false
    end

    test "node types have correct is_textblock" do
      schema = test_schema()

      assert schema.nodes["paragraph"].is_textblock == true
      assert schema.nodes["heading"].is_textblock == true
      assert schema.nodes["doc"].is_textblock == false
      assert schema.nodes["blockquote"].is_textblock == false
    end

    test "node types have correct is_leaf" do
      schema = test_schema()

      assert schema.nodes["horizontal_rule"].is_leaf == true
      assert schema.nodes["image"].is_leaf == true
      assert schema.nodes["hard_break"].is_leaf == true
      assert schema.nodes["paragraph"].is_leaf == false
      assert schema.nodes["doc"].is_leaf == false
    end

    test "node types have correct groups" do
      schema = test_schema()

      assert "block" in schema.nodes["paragraph"].groups
      assert "block" in schema.nodes["heading"].groups
      assert "inline" in schema.nodes["text"].groups
      assert "inline" in schema.nodes["image"].groups
    end

    test "node types have correct is_text" do
      schema = test_schema()

      assert schema.nodes["text"].is_text == true
      assert schema.nodes["paragraph"].is_text == false
    end

    test "node types have content_match set" do
      schema = test_schema()

      assert schema.nodes["doc"].content_match != nil
      assert schema.nodes["paragraph"].content_match != nil
    end

    test "name collision between node and mark raises" do
      assert_raise RuntimeError, fn ->
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "em+"}},
            {"em", %{"group" => "block"}},
            {"text", %{}}
          ],
          "marks" => [
            {"em", %{}}
          ]
        })
      end
    end
  end

  # ── Attributes ──────────────────────────────────────────────────

  describe "attributes" do
    test "heading has default attrs with level 1" do
      schema = test_schema()
      heading = schema.nodes["heading"]
      assert heading.default_attrs == %{"level" => 1}
    end

    test "image has required src and optional alt/title" do
      schema = test_schema()
      image = schema.nodes["image"]
      assert image.has_required_attrs == true
      assert image.default_attrs == nil
    end

    test "paragraph has no required attrs" do
      schema = test_schema()
      paragraph = schema.nodes["paragraph"]
      assert paragraph.has_required_attrs == false
    end

    test "ordered_list has default order attr" do
      schema = test_schema()
      ol = schema.nodes["ordered_list"]
      assert ol.default_attrs == %{"order" => 1}
    end

    test "link mark has required href and optional title" do
      schema = test_schema()
      link = schema.marks["link"]
      # has required attrs, no default instance
      assert link.instance == nil
    end

    test "em mark has cached default instance" do
      schema = test_schema()
      em = schema.marks["em"]
      assert em.instance != nil
    end
  end

  # ── Node creation via Schema ────────────────────────────────────

  describe "Schema.node/5" do
    test "creates a paragraph with text" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      p = Schema.node(schema, "paragraph", nil, [text])

      assert p.type.name == "paragraph"
      assert PmNode.child_count(p) == 1
    end

    test "creates a heading with level" do
      schema = test_schema()
      text = Schema.text(schema, "Title")
      h = Schema.node(schema, "heading", %{"level" => 2}, [text])

      assert h.type.name == "heading"
      assert h.attrs == %{"level" => 2}
    end

    test "heading uses default level when nil attrs" do
      schema = test_schema()
      text = Schema.text(schema, "Title")
      h = Schema.node(schema, "heading", nil, [text])

      assert h.attrs == %{"level" => 1}
    end

    test "raises on unknown node type" do
      schema = test_schema()

      assert_raise RuntimeError, fn ->
        Schema.node(schema, "unknown_type", nil, nil)
      end
    end
  end

  # ── Text creation ───────────────────────────────────────────────

  describe "Schema.text/3" do
    test "creates a text node" do
      schema = test_schema()
      text = Schema.text(schema, "hello")

      assert text.text == "hello"
      assert text.type.name == "text"
      assert text.marks == []
    end

    test "creates a text node with marks" do
      schema = test_schema()
      em = Schema.mark(schema, "em")
      text = Schema.text(schema, "hello", [em])

      assert text.text == "hello"
      assert length(text.marks) == 1
      assert hd(text.marks).type.name == "em"
    end

    test "raises on empty text" do
      schema = test_schema()

      assert_raise RuntimeError, fn ->
        Schema.text(schema, "")
      end
    end
  end

  # ── Mark creation ───────────────────────────────────────────────

  describe "Schema.mark/3" do
    test "creates a simple mark" do
      schema = test_schema()
      em = Schema.mark(schema, "em")

      assert em.type.name == "em"
      assert em.attrs == %{}
    end

    test "creates a mark with attrs" do
      schema = test_schema()
      link = Schema.mark(schema, "link", %{"href" => "https://example.com"})

      assert link.type.name == "link"
      assert link.attrs["href"] == "https://example.com"
      assert link.attrs["title"] == nil
    end

    test "returns cached instance for marks with defaults" do
      schema = test_schema()
      em1 = Schema.mark(schema, "em")
      em2 = Schema.mark(schema, "em")

      # Same object (cached)
      assert em1 === em2
    end
  end

  # ── Mark sets on node types ─────────────────────────────────────

  describe "NodeType mark sets" do
    test "paragraph allows all marks (nil mark_set)" do
      schema = test_schema()
      assert schema.nodes["paragraph"].mark_set == nil
    end

    test "code_block with inline content and no marks spec allows all marks" do
      schema = test_schema()
      # code_block has content "text*". text is inline, so inline_content=true.
      # With no "marks" spec and inline_content=true, markSet defaults to nil (all allowed).
      assert schema.nodes["code_block"].mark_set == nil
    end

    test "horizontal_rule disallows marks (not inline content, no marks spec)" do
      schema = test_schema()
      assert schema.nodes["horizontal_rule"].mark_set == []
    end

    test "allows_mark_type works for paragraph" do
      schema = test_schema()
      em = schema.marks["em"]
      assert NodeType.allows_mark_type(schema.nodes["paragraph"], em) == true
    end

    test "allows_mark_type for node with empty mark_set" do
      schema = test_schema()
      em = schema.marks["em"]
      assert NodeType.allows_mark_type(schema.nodes["horizontal_rule"], em) == false
    end
  end

  # ── Mark exclusion ──────────────────────────────────────────────

  describe "MarkType.excludes" do
    test "marks exclude themselves by default" do
      schema = test_schema()
      em = schema.marks["em"]
      assert MarkType.excludes(em, em) == true
    end

    test "different marks don't exclude each other by default" do
      schema = test_schema()
      em = schema.marks["em"]
      strong = schema.marks["strong"]
      assert MarkType.excludes(em, strong) == false
    end
  end

  # ── NodeType.valid_content ──────────────────────────────────────

  describe "NodeType.valid_content" do
    test "doc accepts block+ content" do
      schema = test_schema()
      p = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "hi")])
      content = Fragment.from([p])
      assert NodeType.valid_content(schema.nodes["doc"], content) == true
    end

    test "doc rejects empty content" do
      schema = test_schema()
      assert NodeType.valid_content(schema.nodes["doc"], Fragment.empty()) == false
    end

    test "paragraph accepts inline* content" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      content = Fragment.from([text])
      assert NodeType.valid_content(schema.nodes["paragraph"], content) == true
    end

    test "paragraph accepts empty content" do
      schema = test_schema()
      assert NodeType.valid_content(schema.nodes["paragraph"], Fragment.empty()) == true
    end

    test "paragraph rejects block content" do
      schema = test_schema()
      inner = Schema.node(schema, "paragraph", nil, [])
      content = Fragment.from([inner])
      assert NodeType.valid_content(schema.nodes["paragraph"], content) == false
    end

    test "doc rejects inline content" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      content = Fragment.from([text])
      assert NodeType.valid_content(schema.nodes["doc"], content) == false
    end
  end

  # ── NodeType.create_checked ─────────────────────────────────────

  describe "NodeType.create_checked" do
    test "succeeds with valid content" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      p = NodeType.create_checked(schema.nodes["paragraph"], nil, [text])
      assert p.type.name == "paragraph"
    end

    test "raises on invalid content" do
      schema = test_schema()
      p = Schema.node(schema, "paragraph", nil, [])

      assert_raise RuntimeError, fn ->
        NodeType.create_checked(schema.nodes["paragraph"], nil, [p])
      end
    end
  end

  # ── NodeType.create_and_fill ────────────────────────────────────

  describe "NodeType.create_and_fill" do
    test "fills empty content for doc" do
      schema = test_schema()
      doc = NodeType.create_and_fill(schema.nodes["doc"])
      assert doc != nil
      assert doc.type.name == "doc"
      assert PmNode.child_count(doc) >= 1
    end

    test "fills content for blockquote" do
      schema = test_schema()
      bq = NodeType.create_and_fill(schema.nodes["blockquote"])
      assert bq != nil
      assert bq.type.name == "blockquote"
    end

    test "keeps provided content if valid" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      p = NodeType.create_and_fill(schema.nodes["paragraph"], nil, [text])
      assert p != nil
      assert PmNode.child_count(p) == 1
    end

    test "returns nil when content can't be fit" do
      schema = test_schema()
      # Try to put a paragraph inside a paragraph (invalid for inline* content)
      inner = Schema.node(schema, "paragraph", nil, [])
      result = NodeType.create_and_fill(schema.nodes["paragraph"], nil, [inner])
      assert result == nil
    end
  end

  # ── NodeType utility methods ────────────────────────────────────

  describe "NodeType utilities" do
    test "is_in_group" do
      schema = test_schema()
      assert NodeType.is_in_group(schema.nodes["paragraph"], "block") == true
      assert NodeType.is_in_group(schema.nodes["text"], "inline") == true
      assert NodeType.is_in_group(schema.nodes["doc"], "block") == false
    end

    test "has_required_attrs?" do
      schema = test_schema()
      assert NodeType.has_required_attrs?(schema.nodes["image"]) == true
      assert NodeType.has_required_attrs?(schema.nodes["paragraph"]) == false
    end

    test "compatible_content" do
      schema = test_schema()
      p = schema.nodes["paragraph"]
      h = schema.nodes["heading"]
      # paragraph and heading both have inline* content
      assert NodeType.compatible_content(p, h) == true
    end

    test "whitespace returns pre for code blocks" do
      schema = test_schema()
      assert NodeType.whitespace(schema.nodes["code_block"]) == "pre"
    end

    test "whitespace returns normal for paragraph" do
      schema = test_schema()
      assert NodeType.whitespace(schema.nodes["paragraph"]) == "normal"
    end

    test "allows_marks with all allowed" do
      schema = test_schema()
      em = Schema.mark(schema, "em")
      strong = Schema.mark(schema, "strong")
      assert NodeType.allows_marks(schema.nodes["paragraph"], [em, strong]) == true
    end

    test "allowed_marks filters marks" do
      schema = test_schema()
      em = Schema.mark(schema, "em")
      marks = NodeType.allowed_marks(schema.nodes["horizontal_rule"], [em])
      assert marks == []
    end
  end

  # ── MarkType methods ────────────────────────────────────────────

  describe "MarkType methods" do
    test "create returns cached instance for no-attr marks" do
      schema = test_schema()
      em = schema.marks["em"]
      m1 = MarkType.create(em)
      m2 = MarkType.create(em)
      assert m1 === m2
    end

    test "create with explicit empty map attrs returns cached instance" do
      schema = test_schema()
      em = schema.marks["em"]
      m = MarkType.create(em, %{})
      assert m === em.instance
    end

    test "create with attrs" do
      schema = test_schema()
      link = schema.marks["link"]
      m = MarkType.create(link, %{"href" => "http://example.com"})
      assert m.attrs["href"] == "http://example.com"
      assert m.attrs["title"] == nil
    end

    test "remove_from_set" do
      schema = test_schema()
      em = schema.marks["em"]
      strong = schema.marks["strong"]
      em_mark = MarkType.create(em)
      strong_mark = MarkType.create(strong)
      set = [em_mark, strong_mark]

      result = MarkType.remove_from_set(em, set)
      assert length(result) == 1
      assert hd(result).type.name == "strong"
    end

    test "is_in_set finds mark" do
      schema = test_schema()
      em = schema.marks["em"]
      em_mark = MarkType.create(em)
      set = [em_mark]

      assert MarkType.is_in_set(em, set) == em_mark
    end

    test "is_in_set returns nil when not found" do
      schema = test_schema()
      em = schema.marks["em"]
      strong = schema.marks["strong"]
      strong_mark = MarkType.create(strong)
      set = [strong_mark]

      assert MarkType.is_in_set(em, set) == nil
    end
  end

  # ── MarkType.check_attrs ────────────────────────────────────────

  describe "MarkType.check_attrs" do
    test "raises on unsupported attribute name" do
      schema = test_schema()
      em = schema.marks["em"]

      assert_raise RuntimeError, ~r/Unsupported attribute/, fn ->
        MarkType.check_attrs(em, %{"bogus" => "value"})
      end
    end

    test "calls validate function when present" do
      test_pid = self()

      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{}}
          ],
          "marks" => [
            {"validated",
             %{
               "attrs" => %{
                 "color" => %{
                   "default" => "red",
                   "validate" => fn val -> send(test_pid, {:validated, val}) end
                 }
               }
             }}
          ]
        })

      mark_type = schema.marks["validated"]
      MarkType.check_attrs(mark_type, %{"color" => "blue"})

      assert_received {:validated, "blue"}
    end

    test "handles non-function validate gracefully" do
      mark_type = %MarkType{
        name: "test",
        attrs: %{
          "size" => %{has_default: true, default: 12, validate: :some_atom}
        }
      }

      assert MarkType.check_attrs(mark_type, %{"size" => 14}) == :ok
    end

    test "passes when all attrs are valid and no validate function" do
      schema = test_schema()
      link = schema.marks["link"]

      assert MarkType.check_attrs(link, %{"href" => "https://example.com", "title" => "Ex"}) ==
               :ok
    end
  end

  # ── Content expression integration ──────────────────────────────

  describe "content expression validation" do
    test "doc content accepts multiple blocks" do
      schema = test_schema()
      p1 = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "a")])
      p2 = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "b")])
      content = Fragment.from([p1, p2])
      assert NodeType.valid_content(schema.nodes["doc"], content) == true
    end

    test "heading content accepts inline" do
      schema = test_schema()
      text = Schema.text(schema, "Title")
      content = Fragment.from([text])
      assert NodeType.valid_content(schema.nodes["heading"], content) == true
    end

    test "blockquote requires at least one block" do
      schema = test_schema()
      assert NodeType.valid_content(schema.nodes["blockquote"], Fragment.empty()) == false
      p = Schema.node(schema, "paragraph", nil, [])
      content = Fragment.from([p])
      assert NodeType.valid_content(schema.nodes["blockquote"], content) == true
    end

    test "list_item content matches 'paragraph block*'" do
      schema = test_schema()
      p = Schema.node(schema, "paragraph", nil, [])
      content = Fragment.from([p])
      assert NodeType.valid_content(schema.nodes["list_item"], content) == true

      # paragraph followed by blockquote
      bq = Schema.node(schema, "blockquote", nil, [p])
      content2 = Fragment.from([p, bq])
      assert NodeType.valid_content(schema.nodes["list_item"], content2) == true

      # just a blockquote (no leading paragraph) should fail
      content3 = Fragment.from([bq])
      assert NodeType.valid_content(schema.nodes["list_item"], content3) == false
    end
  end

  # ── Schema helper methods ──────────────────────────────────────

  describe "Schema.node_type/2" do
    test "returns the node type for a known name" do
      schema = test_schema()
      type = Schema.node_type(schema, "paragraph")
      assert type.name == "paragraph"
    end

    test "raises for unknown name" do
      schema = test_schema()

      assert_raise RuntimeError, fn ->
        Schema.node_type(schema, "nonexistent")
      end
    end
  end

  # ── Mark ranks ──────────────────────────────────────────────────

  describe "mark ranks" do
    test "marks have ranks matching their definition order" do
      schema = test_schema()
      assert schema.marks["link"].rank == 0
      assert schema.marks["em"].rank == 1
      assert schema.marks["strong"].rank == 2
      assert schema.marks["code"].rank == 3
    end
  end

  # ── Schema with marks spec on nodes ─────────────────────────────

  describe "marks spec on node types" do
    test "explicit marks='' disallows all marks" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block", "marks" => ""}},
            {"text", %{"group" => "inline"}}
          ]
        })

      assert schema.nodes["paragraph"].mark_set == []
    end

    test "marks='_' allows all marks" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block", "marks" => "_"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{}},
            {"strong", %{}}
          ]
        })

      assert schema.nodes["paragraph"].mark_set == nil
    end

    test "marks='em strong' allows only em and strong" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block", "marks" => "em strong"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{}},
            {"strong", %{}},
            {"code", %{}}
          ]
        })

      mark_set = schema.nodes["paragraph"].mark_set
      assert length(mark_set) == 2
      names = Enum.map(mark_set, & &1.name)
      assert "em" in names
      assert "strong" in names
    end
  end

  # ── Mark exclusion with explicit excludes spec ──────────────────

  describe "mark exclusion with excludes spec" do
    test "excludes='_' excludes all marks" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"code", %{"excludes" => "_"}},
            {"em", %{}}
          ]
        })

      code = schema.marks["code"]
      em = schema.marks["em"]
      assert MarkType.excludes(code, em) == true
      assert MarkType.excludes(code, code) == true
    end

    test "excludes='' excludes nothing (allows coexistence)" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{"excludes" => ""}},
            {"strong", %{}}
          ]
        })

      em = schema.marks["em"]
      strong = schema.marks["strong"]
      assert MarkType.excludes(em, em) == false
      assert MarkType.excludes(em, strong) == false
    end
  end

  # ── Whitespace ──────────────────────────────────────────────────

  describe "whitespace" do
    test "code_block returns pre" do
      schema = test_schema()
      assert NodeType.whitespace(schema.nodes["code_block"]) == "pre"
    end

    test "explicit whitespace spec overrides code" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph",
             %{
               "content" => "text*",
               "group" => "block",
               "code" => true,
               "whitespace" => "normal"
             }},
            {"text", %{"group" => "inline"}}
          ]
        })

      assert NodeType.whitespace(schema.nodes["paragraph"]) == "normal"
    end
  end

  # ── NodeType.create ─────────────────────────────────────────────

  describe "NodeType.create" do
    test "raises when trying to create text node with create" do
      schema = test_schema()

      assert_raise RuntimeError, fn ->
        NodeType.create(schema.nodes["text"], nil, nil)
      end
    end

    test "creates a simple node" do
      schema = test_schema()
      p = NodeType.create(schema.nodes["paragraph"], nil, nil)
      assert p.type.name == "paragraph"
      assert p.content == Fragment.empty()
      assert p.marks == []
    end

    test "creates a node with content" do
      schema = test_schema()
      text = Schema.text(schema, "hello")
      p = NodeType.create(schema.nodes["paragraph"], nil, [text])
      assert PmNode.child_count(p) == 1
    end
  end

  # ── Schema with node back-reference ─────────────────────────────

  describe "node type schema back-reference" do
    test "node types have a schema reference with correct nodes" do
      schema = test_schema()
      node_schema = schema.nodes["paragraph"].schema
      assert node_schema != nil
      assert Map.has_key?(node_schema.nodes, "paragraph")
      assert Map.has_key?(node_schema.nodes, "doc")
      assert Map.has_key?(node_schema.nodes, "text")
    end

    test "mark types have a schema reference with correct marks" do
      schema = test_schema()
      mark_schema = schema.marks["em"].schema
      assert mark_schema != nil
      assert Map.has_key?(mark_schema.marks, "em")
      assert Map.has_key?(mark_schema.marks, "strong")
    end
  end

  # ── NodeType.is_in_group with nil groups ──────────────────────────

  describe "NodeType.is_in_group with nil groups" do
    test "returns false when groups is nil" do
      node_type = %NodeType{name: "test", groups: nil}
      assert NodeType.is_in_group(node_type, "block") == false
    end
  end

  # ── NodeType.allowed_marks partial filtering ──────────────────────

  describe "NodeType.allowed_marks partial filtering" do
    test "returns only the allowed marks when some are filtered out" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block", "marks" => "em"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => [
            {"em", %{}},
            {"strong", %{}}
          ]
        })

      em = Schema.mark(schema, "em")
      strong = Schema.mark(schema, "strong")
      result = NodeType.allowed_marks(schema.nodes["paragraph"], [em, strong])

      assert length(result) == 1
      assert hd(result).type.name == "em"
    end
  end

  # ── NodeType.check_attrs ──────────────────────────────────────────

  describe "NodeType.check_attrs" do
    test "raises on unsupported attribute name" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph", %{"content" => "inline*", "group" => "block"}},
            {"text", %{"group" => "inline"}}
          ]
        })

      assert_raise RuntimeError, ~r/Unsupported attribute/, fn ->
        NodeType.check_attrs(schema.nodes["paragraph"], %{"bogus" => "value"})
      end
    end

    test "calls validate function when present" do
      test_pid = self()

      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"paragraph",
             %{
               "content" => "inline*",
               "group" => "block",
               "attrs" => %{
                 "align" => %{
                   "default" => "left",
                   "validate" => fn val -> send(test_pid, {:validated, val}) end
                 }
               }
             }},
            {"text", %{"group" => "inline"}}
          ]
        })

      NodeType.check_attrs(schema.nodes["paragraph"], %{"align" => "center"})

      assert_received {:validated, "center"}
    end

    test "handles non-function validate gracefully" do
      node_type = %NodeType{
        name: "test",
        attrs: %{
          "size" => %{has_default: true, default: 12, validate: :some_atom}
        }
      }

      assert NodeType.check_attrs(node_type, %{"size" => 14}) == :ok
    end

    test "passes when all attrs are valid and no validate function" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "block+"}},
            {"heading",
             %{
               "content" => "inline*",
               "group" => "block",
               "attrs" => %{"level" => %{"default" => 1}}
             }},
            {"text", %{"group" => "inline"}}
          ]
        })

      assert NodeType.check_attrs(schema.nodes["heading"], %{"level" => 2}) == :ok
    end
  end
end
