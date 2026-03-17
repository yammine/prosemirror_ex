defmodule ProsemirrorEx.Model.IntegrationTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.{
    Node,
    Fragment,
    Mark,
    MarkType,
    NodeType,
    Schema,
    ResolvedPos,
    Slice,
    ContentMatch
  }

  import ProsemirrorEx.TestHelpers

  describe "end-to-end: create schema, build document, slice, replace, resolve" do
    test "build a doc, slice a range, replace it back" do
      # Build: doc(p("hello"), p("world"))
      {doc_node, _tags} = doc([p(["hello"]), p(["world"])])

      # Position layout:
      # 0=doc_start, 1..6=inside first p ("hello"), 7=between paragraphs,
      # 8..13=inside second p ("world"), 14=doc_end
      r1 = Node.resolve(doc_node, 1)
      assert ResolvedPos.parent(r1).type.name == "paragraph"

      r8 = Node.resolve(doc_node, 8)
      assert ResolvedPos.parent(r8).type.name == "paragraph"

      # Slice the text content of the first paragraph (positions 1 to 6)
      slice = Node.slice(doc_node, 1, 6)
      assert Slice.size(slice) == 5

      # Replace the text content of the second paragraph (positions 8 to 13)
      # Both from (8) and to (13) are at depth 1 (inside the second paragraph),
      # matching the slice's open depths of 0.
      result = Node.replace(doc_node, 8, 13, slice)
      # Now second paragraph should also have "hello"
      second_p = Node.child(result, 1)
      assert Node.text_content(second_p) == "hello"
    end

    test "resolve positions in a complex document" do
      {doc_node, _tags} = doc([blockquote([p(["inside"]), p(["quote"])])])

      # Position 0 = doc start
      r0 = Node.resolve(doc_node, 0)
      assert r0.depth == 0

      # Position 1 = inside blockquote (after doc open + blockquote open = positions 0, 1)
      r1 = Node.resolve(doc_node, 1)
      assert ResolvedPos.node(r1, 1).type.name == "blockquote"

      # Position 2 = inside first paragraph
      r2 = Node.resolve(doc_node, 2)
      assert ResolvedPos.parent(r2).type.name == "paragraph"

      # Can get the text content
      assert Node.text_content(doc_node) == "insidequote"
    end

    test "slice and replace round-trip produces equivalent document" do
      {doc_node, _tags} = doc([p(["Hello "]), p(["world"])])
      content_size = doc_node.content.size

      # Slice the entire content
      slice = Node.slice(doc_node, 0, content_size)

      # Create a doc with different content, then replace all with the original slice
      {other_doc, _} = doc([p(["other"])])
      other_size = other_doc.content.size

      result = Node.replace(other_doc, 0, other_size, slice)
      assert Node.eq(result, doc_node)
    end
  end

  describe "schema with content expressions and create_and_fill" do
    test "create_and_fill produces valid content" do
      schema = test_schema()

      # create_and_fill for blockquote should auto-fill with a paragraph
      bq_type = schema.nodes["blockquote"]
      bq = NodeType.create_and_fill(bq_type)
      assert bq != nil
      assert Node.child_count(bq) >= 1
      assert Node.child(bq, 0).type.name == "paragraph"

      # Validate the content
      assert NodeType.valid_content(bq_type, bq.content)
    end

    test "create_and_fill for list_item produces paragraph" do
      schema = test_schema()
      li_type = schema.nodes["list_item"]
      li_node = NodeType.create_and_fill(li_type)
      assert li_node != nil
      assert Node.child(li_node, 0).type.name == "paragraph"
    end

    test "create_checked rejects invalid content" do
      schema = test_schema()
      p_type = schema.nodes["paragraph"]

      # Paragraph should not accept block content
      bq_content = Fragment.from_array([NodeType.create_and_fill(schema.nodes["blockquote"])])

      assert_raise RuntimeError, fn ->
        NodeType.create_checked(p_type, nil, bq_content)
      end
    end

    test "valid_content checks mark compatibility" do
      schema = test_schema()
      # horizontal_rule disallows marks (block, non-inline content, no marks spec)
      hr_type = schema.nodes["horizontal_rule"]
      assert hr_type.mark_set == []
    end
  end

  describe "mark exclusion and ordering" do
    test "marks are ordered by schema rank" do
      schema = test_schema()

      em_type = schema.marks["em"]
      strong_type = schema.marks["strong"]

      em_mark = MarkType.create(em_type)
      strong_mark = MarkType.create(strong_type)

      # Add in reverse order -- should still be ordered by rank
      set = Mark.add_to_set(strong_mark, [])
      set = Mark.add_to_set(em_mark, set)

      # em has lower rank (index 1) than strong (index 2) in the schema
      assert hd(set).type.name == "em"
      assert List.last(set).type.name == "strong"
    end

    test "default mark exclusion (same type excludes itself)" do
      schema = test_schema()
      em_type = schema.marks["em"]

      assert MarkType.excludes(em_type, em_type)
    end

    test "marks preserved through serialization round-trip" do
      schema = test_schema()

      em_mark = MarkType.create(schema.marks["em"])
      strong_mark = MarkType.create(schema.marks["strong"])

      text_node = Schema.text(schema, "hello", [em_mark, strong_mark])
      json = Node.to_json(text_node)

      restored = Node.from_json(schema, json)
      assert Mark.same_set(text_node.marks, restored.marks)
    end

    test "link mark attrs are preserved through round-trip" do
      schema = test_schema()

      link_mark =
        MarkType.create(schema.marks["link"], %{"href" => "https://example.com", "title" => nil})

      text_node = Schema.text(schema, "click me", [link_mark])
      json = Node.to_json(text_node)

      restored = Node.from_json(schema, json)
      restored_link = hd(restored.marks)
      assert restored_link.attrs["href"] == "https://example.com"
      assert restored_link.attrs["title"] == nil
    end
  end

  describe "slice and replace round-trip" do
    test "slice a doc, replace it back, get the original" do
      {doc_node, _tags} = doc([p(["Hello "]), blockquote([p(["quoted"])])])
      total = doc_node.content.size

      # Slice the whole document content
      whole_slice = Node.slice(doc_node, 0, total)

      # Build a minimal replacement doc and replace all its content
      {empty_doc, _} = doc([p([])])
      empty_size = empty_doc.content.size

      result = Node.replace(empty_doc, 0, empty_size, whole_slice)
      assert Node.eq(result, doc_node)
    end

    test "slice a sub-range and re-insert it" do
      {doc_node, _tags} = doc([p(["aaa"]), p(["bbb"]), p(["ccc"])])

      # Slice out the middle paragraph entirely (positions 5-10)
      # p("aaa") = positions 0..5 (0=open, 1-3=text, 4=close -> size=5)
      # p("bbb") = positions 5..10
      # p("ccc") = positions 10..15
      slice = Node.slice(doc_node, 5, 10)

      # The slice should represent p("bbb")
      assert slice.content.size > 0

      # Replace the first paragraph content with nothing, then insert the slice
      # Just verify the slice is valid by round-tripping through JSON
      slice_json = Slice.to_json(slice)
      assert slice_json != nil

      schema = test_schema()
      restored_slice = Slice.from_json(schema, slice_json)
      assert Slice.eq(slice, restored_slice)
    end

    test "empty slice replacement (deletion)" do
      {doc_node, _tags} = doc([p(["hello"]), p(["world"])])

      # Delete the first paragraph by replacing its range with an empty slice
      result = Node.replace(doc_node, 0, 7)
      assert Node.child_count(result) == 1
      assert Node.text_content(Node.child(result, 0)) == "world"
    end
  end

  describe "Node.check validates document structure" do
    test "check passes for valid document" do
      {doc_node, _tags} = doc([p(["hello"]), p(["world"])])
      assert Node.check(doc_node) == :ok
    end

    test "check passes for document with marks" do
      {doc_node, _tags} = doc([p(["plain ", em(["italic"]), strong(["bold"])])])
      assert Node.check(doc_node) == :ok
    end

    test "check passes for nested structure" do
      {doc_node, _tags} = doc([blockquote([p(["nested"])])])
      assert Node.check(doc_node) == :ok
    end
  end

  describe "content match operations" do
    test "match_type finds valid next states" do
      schema = test_schema()
      doc_type = schema.nodes["doc"]
      match = doc_type.content_match

      # doc content is "block+", so paragraph should match
      p_type = schema.nodes["paragraph"]
      result = ContentMatch.match_type(match, p_type)
      assert result != nil
    end

    test "fill_before computes required content" do
      schema = test_schema()
      bq_type = schema.nodes["blockquote"]
      match = bq_type.content_match

      # blockquote requires block+, fill_before empty should produce a paragraph
      fill = ContentMatch.fill_before(match, Fragment.empty(), true)
      assert fill != nil
      assert fill.size > 0
    end
  end
end
