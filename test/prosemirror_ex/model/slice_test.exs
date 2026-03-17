defmodule ProsemirrorEx.Model.SliceTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Slice

  describe "Node.slice" do
    # Helper: slice doc from tag "a" (or 0) to tag "b", then check
    # content equality, openStart, and openEnd against expected.
    defp t(doc_with_tags, expected_with_tags, open_start, open_end) do
      {doc_node, doc_tags} = doc_with_tags
      {expected_node, _} = expected_with_tags

      from = Map.get(doc_tags, "a", 0)
      to = Map.get(doc_tags, "b")

      slice = PmNode.slice(doc_node, from, to)

      assert Fragment.eq(slice.content, expected_node.content),
             "Slice content mismatch.\n  Expected: #{Fragment.to_string_inner(expected_node.content)}\n  Got:      #{Fragment.to_string_inner(slice.content)}"

      assert slice.open_start == open_start,
             "openStart mismatch: expected #{open_start}, got #{slice.open_start}"

      assert slice.open_end == open_end,
             "openEnd mismatch: expected #{open_end}, got #{slice.open_end}"
    end

    test "can cut half a paragraph" do
      t(doc([p(["hello<b> world"])]), doc([p(["hello"])]), 0, 1)
    end

    test "can cut to the end of a paragraph" do
      t(doc([p(["hello<b>"])]), doc([p(["hello"])]), 0, 1)
    end

    test "leaves off extra content" do
      t(doc([p(["hello<b> world"]), p(["rest"])]), doc([p(["hello"])]), 0, 1)
    end

    test "preserves styles" do
      t(doc([p(["hello ", em(["WOR<b>LD"])])]), doc([p(["hello ", em(["WOR"])])]), 0, 1)
    end

    test "can cut multiple blocks" do
      t(doc([p(["a"]), p(["b<b>"])]), doc([p(["a"]), p(["b"])]), 0, 1)
    end

    test "can cut to a top-level position" do
      t(doc([p(["a"]), "<b>", p(["b"])]), doc([p(["a"])]), 0, 0)
    end

    test "can cut to a deep position" do
      t(
        doc([blockquote([ul([li([p(["a"])]), li([p(["b<b>"])])])])]),
        doc([blockquote([ul([li([p(["a"])]), li([p(["b"])])])])]),
        0,
        4
      )
    end

    test "can cut everything after a position" do
      t(doc([p(["hello<a> world"])]), doc([p([" world"])]), 1, 0)
    end

    test "can cut from the start of a textblock" do
      t(doc([p(["<a>hello"])]), doc([p(["hello"])]), 1, 0)
    end

    test "leaves off extra content before" do
      t(doc([p(["foo"]), p(["bar<a>baz"])]), doc([p(["baz"])]), 1, 0)
    end

    test "preserves styles after cut" do
      t(
        doc([p(["a sentence with an ", em(["emphasized ", a(["li<a>nk"])]), " in it"])]),
        doc([p([em([a(["nk"])]), " in it"])]),
        1,
        0
      )
    end

    test "preserves styles started after cut" do
      t(
        doc([p(["a ", em(["sentence"]), " wi<a>th ", em(["text"]), " in it"])]),
        doc([p(["th ", em(["text"]), " in it"])]),
        1,
        0
      )
    end

    test "can cut from a top-level position" do
      t(doc([p(["a"]), "<a>", p(["b"])]), doc([p(["b"])]), 0, 0)
    end

    test "can cut from a deep position" do
      t(
        doc([blockquote([ul([li([p(["a"])]), li([p(["<a>b"])])])])]),
        doc([blockquote([ul([li([p(["b"])])])])]),
        4,
        0
      )
    end

    test "can cut part of a text node" do
      t(doc([p(["hell<a>o wo<b>rld"])]), p(["o wo"]), 0, 0)
    end

    test "can cut across paragraphs" do
      t(doc([p(["on<a>e"]), p(["t<b>wo"])]), doc([p(["e"]), p(["t"])]), 1, 1)
    end

    test "can cut part of marked text" do
      t(
        doc([p(["here's noth<a>ing and ", em(["here's e<b>m"])])]),
        p(["ing and ", em(["here's e"])]),
        0,
        0
      )
    end

    test "can cut across different depths" do
      t(
        doc([
          ul([li([p(["hello"])]), li([p(["wo<a>rld"])]), li([p(["x"])])]),
          p([em(["bo<b>o"])])
        ]),
        doc([ul([li([p(["rld"])]), li([p(["x"])])]), p([em(["bo"])])]),
        3,
        1
      )
    end

    test "can cut between deeply nested nodes" do
      t(
        doc([
          blockquote([
            p(["foo<a>bar"]),
            ul([li([p(["a"])]), li([p(["b"]), "<b>", p(["c"])])]),
            p(["d"])
          ])
        ]),
        blockquote([p(["bar"]), ul([li([p(["a"])]), li([p(["b"])])])]),
        1,
        2
      )
    end

    test "can include parents" do
      {d, tags} = doc([blockquote([p(["fo<a>o"]), p(["bar<b>"])])])
      slice = PmNode.slice(d, tags["a"], tags["b"], true)

      assert Slice.to_string(slice) ==
               "<blockquote(paragraph(\"o\"), paragraph(\"bar\"))>(2,2)"
    end
  end

  # ── Slice module tests ─────────────────────────────────────────────

  describe "Slice.size/1" do
    test "returns 0 for the empty slice" do
      assert Slice.size(Slice.empty()) == 0
    end

    test "returns content size when no open sides" do
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 0, 0)
      # p("hello") has size 7 (1 open + 5 text + 1 close)
      assert Slice.size(slice) == 7
    end

    test "subtracts open_start and open_end from content size" do
      # Build a paragraph with text, wrap it in a fragment
      {p_node, _} = p(["hello"])
      fragment = Fragment.from(p_node)
      # fragment.size == 7 (paragraph wrapper + 5 chars)
      slice = Slice.new(fragment, 1, 1)
      # size = 7 - 1 - 1 = 5
      assert Slice.size(slice) == 5
    end

    test "returns 0 when open_start + open_end equals content size" do
      {p_node, _} = p()
      fragment = Fragment.from(p_node)
      # empty paragraph: size = 2 (open + close)
      slice = Slice.new(fragment, 1, 1)
      assert Slice.size(slice) == 0
    end

    test "works with a slice created from Node.slice" do
      {d, _} = doc([p(["hello world"])])
      # Slice from start to position 6 ("hello") - cuts after "hello"
      slice = PmNode.slice(d, 0, 6)
      # The slice content is <p("hello")>, open_start=0, open_end=1
      # content.size=7, so size = 7 - 0 - 1 = 6
      assert Slice.size(slice) == 6
    end
  end

  describe "Slice.eq/2" do
    test "empty slices are equal" do
      assert Slice.eq(Slice.empty(), Slice.empty())
    end

    test "identical slices are equal" do
      {p_node, _} = p(["hello"])
      s1 = Slice.new(Fragment.from(p_node), 1, 1)
      s2 = Slice.new(Fragment.from(p_node), 1, 1)
      assert Slice.eq(s1, s2)
    end

    test "slices with different content are not equal" do
      {p1, _} = p(["hello"])
      {p2, _} = p(["world"])
      s1 = Slice.new(Fragment.from(p1), 0, 0)
      s2 = Slice.new(Fragment.from(p2), 0, 0)
      refute Slice.eq(s1, s2)
    end

    test "slices with different open_start are not equal" do
      {p_node, _} = p(["hello"])
      s1 = Slice.new(Fragment.from(p_node), 0, 0)
      s2 = Slice.new(Fragment.from(p_node), 1, 0)
      refute Slice.eq(s1, s2)
    end

    test "slices with different open_end are not equal" do
      {p_node, _} = p(["hello"])
      s1 = Slice.new(Fragment.from(p_node), 0, 0)
      s2 = Slice.new(Fragment.from(p_node), 0, 1)
      refute Slice.eq(s1, s2)
    end

    test "slices from equivalent Node.slice calls are equal" do
      {d, _} = doc([p(["hello world"])])
      s1 = PmNode.slice(d, 0, 6)
      s2 = PmNode.slice(d, 0, 6)
      assert Slice.eq(s1, s2)
    end
  end

  describe "Slice.insert_at/3" do
    test "inserts a fragment at the beginning of a flat slice" do
      {p_node, _} = p(["world"])
      slice = Slice.new(Fragment.from(p_node), 0, 0)

      schema = test_schema()
      hello_text = ProsemirrorEx.Model.Schema.text(schema, "hello ")
      insert_frag = Fragment.from(hello_text)

      # Insert at position 0 in the slice; the actual content pos = 0 + open_start(0) = 0
      result = Slice.insert_at(slice, 0, insert_frag)
      assert result != nil

      # The result should have "hello " prepended outside the paragraph node
      # Since we're inserting at pos 0 in the fragment (before the paragraph),
      # the fragment now has the text node + paragraph node
      assert result.open_start == 0
      assert result.open_end == 0
    end

    test "inserts a fragment inside a text node in a slice" do
      # Create a flat text-only slice (no wrapping paragraph)
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "helloworld")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      insert_text = ProsemirrorEx.Model.Schema.text(schema, " ")
      insert_frag = Fragment.from(insert_text)

      # Insert at position 5 (between "hello" and "world")
      result = Slice.insert_at(slice, 5, insert_frag)
      assert result != nil
      assert result.open_start == 0
      assert result.open_end == 0
      # The content size should now be 11 ("hello world")
      assert result.content.size == 11
    end

    test "inserts a fragment at the end of a flat slice" do
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "hello")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      insert_text = ProsemirrorEx.Model.Schema.text(schema, " world")
      insert_frag = Fragment.from(insert_text)

      result = Slice.insert_at(slice, 5, insert_frag)
      assert result != nil
      assert result.content.size == 11
    end

    test "inserts between two block nodes" do
      {p1, _} = p(["first"])
      {p2, _} = p(["second"])
      fragment = Fragment.from([p1, p2])
      slice = Slice.new(fragment, 0, 0)

      # Insert a new paragraph between the two existing ones.
      # p1 size = 7 (1+5+1), so position 7 is between p1 and p2.
      {p_new, _} = p(["middle"])
      result = Slice.insert_at(slice, 7, Fragment.from(p_new))
      assert result != nil
      assert Fragment.child_count(result.content) == 3
    end

    test "preserves open_start and open_end" do
      schema = test_schema()
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 1, 1)

      insert_text = ProsemirrorEx.Model.Schema.text(schema, "!")
      insert_frag = Fragment.from(insert_text)

      # Insert inside the paragraph (at text position within the open paragraph)
      result = Slice.insert_at(slice, 5, insert_frag)
      assert result != nil
      assert result.open_start == 1
      assert result.open_end == 1
    end

    test "inserts an empty fragment (no-op)" do
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 0, 0)

      result = Slice.insert_at(slice, 0, Fragment.empty())
      assert result != nil
      assert Slice.eq(result, slice)
    end
  end

  describe "Slice.remove_between/3" do
    test "removes a range from a flat text slice" do
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "hello world")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      # Remove " world" (positions 5 to 11)
      result = Slice.remove_between(slice, 5, 11)
      assert result.content.size == 5
      assert result.open_start == 0
      assert result.open_end == 0
    end

    test "removes a range from the beginning" do
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "hello world")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      # Remove "hello " (positions 0 to 6)
      result = Slice.remove_between(slice, 0, 6)
      assert result.content.size == 5
    end

    test "removes entire content" do
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "hello")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      result = Slice.remove_between(slice, 0, 5)
      assert result.content.size == 0
    end

    test "preserves open_start and open_end" do
      {p_node, _} = p(["hello world"])
      slice = Slice.new(Fragment.from(p_node), 1, 1)

      # Remove within the paragraph text (positions are relative to slice,
      # then offset by open_start internally)
      result = Slice.remove_between(slice, 5, 11)
      assert result.open_start == 1
      assert result.open_end == 1
    end

    test "removing zero-width range is a no-op" do
      schema = test_schema()
      text_node = ProsemirrorEx.Model.Schema.text(schema, "hello")
      slice = Slice.new(Fragment.from(text_node), 0, 0)

      result = Slice.remove_between(slice, 3, 3)
      assert Fragment.eq(result.content, slice.content)
    end
  end

  describe "Slice.max_open/1" do
    test "returns empty slice for empty fragment" do
      slice = Slice.max_open(Fragment.empty())
      assert slice.open_start == 0
      assert slice.open_end == 0
      assert slice.content.size == 0
    end

    test "computes open depth 1 for a single paragraph" do
      {p_node, _} = p(["hello"])
      fragment = Fragment.from(p_node)
      slice = Slice.max_open(fragment)

      # paragraph > text: text is a leaf, so open depth = 1 (paragraph level)
      assert slice.open_start == 1
      assert slice.open_end == 1
    end

    test "computes open depth 2 for a blockquote containing a paragraph" do
      {bq_node, _} = blockquote([p(["hello"])])
      fragment = Fragment.from(bq_node)
      slice = Slice.max_open(fragment)

      # blockquote > paragraph > text: depth = 2
      assert slice.open_start == 2
      assert slice.open_end == 2
    end

    test "computes different open_start and open_end for asymmetric structures" do
      # blockquote with first child = paragraph, last child = blockquote(paragraph)
      {bq_node, _} = blockquote([p(["first"]), blockquote([p(["nested"])])])
      fragment = Fragment.from(bq_node)
      slice = Slice.max_open(fragment)

      # open_start: blockquote > paragraph > text => 2
      # open_end: blockquote > blockquote > paragraph > text => 3
      assert slice.open_start == 2
      assert slice.open_end == 3
    end

    test "stops at leaf nodes (horizontal_rule)" do
      {hr_node, _} = hr()
      fragment = Fragment.from(hr_node)
      slice = Slice.max_open(fragment)

      # hr is a leaf node, so depth = 0
      assert slice.open_start == 0
      assert slice.open_end == 0
    end

    test "computes depth for a list structure" do
      {ul_node, _} = ul([li([p(["item"])])])
      fragment = Fragment.from(ul_node)
      slice = Slice.max_open(fragment)

      # ul > li > paragraph > text => depth 3
      assert slice.open_start == 3
      assert slice.open_end == 3
    end

    test "preserves the fragment content" do
      {p_node, _} = p(["hello"])
      fragment = Fragment.from(p_node)
      slice = Slice.max_open(fragment)

      assert Fragment.eq(slice.content, fragment)
    end

    test "computes depth for an empty paragraph" do
      {p_node, _} = p()
      fragment = Fragment.from(p_node)
      slice = Slice.max_open(fragment)

      # paragraph with no children: first_child is nil, depth stays at 1
      # because we enter the paragraph (depth+1) then first_child is nil => depth=1
      assert slice.open_start == 1
      assert slice.open_end == 1
    end
  end

  describe "Slice.from_json/2 and Slice.to_json/1" do
    test "empty slice serializes to nil" do
      assert Slice.to_json(Slice.empty()) == nil
    end

    test "from_json with nil returns empty slice" do
      schema = test_schema()
      slice = Slice.from_json(schema, nil)
      assert Slice.eq(slice, Slice.empty())
    end

    test "from_json with empty map returns empty slice" do
      schema = test_schema()
      slice = Slice.from_json(schema, %{})
      assert Slice.eq(slice, Slice.empty())
    end

    test "round-trips a slice with no open values" do
      schema = test_schema()
      {p_node, _} = p(["hello"])
      original = Slice.new(Fragment.from(p_node), 0, 0)

      json = Slice.to_json(original)
      restored = Slice.from_json(schema, json)

      assert Fragment.eq(restored.content, original.content)
      assert restored.open_start == 0
      assert restored.open_end == 0
    end

    test "round-trips a slice with open_start and open_end" do
      schema = test_schema()
      {p_node, _} = p(["hello"])
      original = Slice.new(Fragment.from(p_node), 1, 1)

      json = Slice.to_json(original)
      restored = Slice.from_json(schema, json)

      assert Fragment.eq(restored.content, original.content)
      assert restored.open_start == 1
      assert restored.open_end == 1
    end

    test "to_json omits openStart and openEnd when zero" do
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 0, 0)

      json = Slice.to_json(slice)
      assert is_map(json)
      assert Map.has_key?(json, "content")
      refute Map.has_key?(json, "openStart")
      refute Map.has_key?(json, "openEnd")
    end

    test "to_json includes openStart when non-zero" do
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 1, 0)

      json = Slice.to_json(slice)
      assert json["openStart"] == 1
      refute Map.has_key?(json, "openEnd")
    end

    test "to_json includes openEnd when non-zero" do
      {p_node, _} = p(["hello"])
      slice = Slice.new(Fragment.from(p_node), 0, 1)

      json = Slice.to_json(slice)
      refute Map.has_key?(json, "openStart")
      assert json["openEnd"] == 1
    end

    test "round-trips a slice with marked content" do
      schema = test_schema()
      {p_node, _} = p(["hello ", em(["world"])])
      original = Slice.new(Fragment.from(p_node), 1, 1)

      json = Slice.to_json(original)
      restored = Slice.from_json(schema, json)

      assert Fragment.eq(restored.content, original.content)
      assert restored.open_start == 1
      assert restored.open_end == 1
    end

    test "round-trips a slice with multiple block nodes" do
      schema = test_schema()
      {p1, _} = p(["first"])
      {p2, _} = p(["second"])
      fragment = Fragment.from([p1, p2])
      original = Slice.new(fragment, 1, 1)

      json = Slice.to_json(original)
      restored = Slice.from_json(schema, json)

      assert Fragment.eq(restored.content, original.content)
      assert restored.open_start == 1
      assert restored.open_end == 1
    end
  end
end
