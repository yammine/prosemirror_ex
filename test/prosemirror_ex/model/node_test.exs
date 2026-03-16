defmodule ProsemirrorEx.Model.NodeTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Mark

  # ── Type helpers ──────────────────────────────────────────────────────

  defp text_type,
    do: %{
      name: "text",
      is_leaf: true,
      is_text: true,
      is_block: false,
      is_inline: true,
      inline_content: false,
      spec: %{}
    }

  defp para_type,
    do: %{
      name: "paragraph",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: true,
      is_textblock: true,
      spec: %{}
    }

  defp doc_type,
    do: %{
      name: "doc",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: false,
      spec: %{}
    }

  defp blockquote_type,
    do: %{
      name: "blockquote",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: false,
      spec: %{}
    }

  defp heading_type(level),
    do: %{
      name: "heading",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: true,
      is_textblock: true,
      spec: %{},
      attrs: %{"level" => level}
    }

  defp hr_type,
    do: %{
      name: "horizontal_rule",
      is_leaf: true,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: false,
      spec: %{}
    }

  defp br_type,
    do: %{
      name: "hard_break",
      is_leaf: true,
      is_text: false,
      is_block: false,
      is_inline: true,
      inline_content: false,
      spec: %{}
    }

  defp img_type,
    do: %{
      name: "image",
      is_leaf: true,
      is_text: false,
      is_block: false,
      is_inline: true,
      inline_content: false,
      spec: %{}
    }

  defp ul_type,
    do: %{
      name: "bullet_list",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: false,
      spec: %{}
    }

  defp li_type,
    do: %{
      name: "list_item",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      inline_content: false,
      spec: %{}
    }

  # ── Node builder helpers ──────────────────────────────────────────────

  defp txt(text, marks \\ []) do
    %PmNode{type: text_type(), text: text, marks: marks, attrs: nil, content: nil}
  end

  defp para(children, marks \\ []) do
    content = Fragment.from(children)
    %PmNode{type: para_type(), content: content, marks: marks, attrs: nil, text: nil}
  end

  defp doc(children) do
    content = Fragment.from(children)
    %PmNode{type: doc_type(), content: content, marks: [], attrs: nil, text: nil}
  end

  defp blockquote_node(children) do
    content = Fragment.from(children)

    %PmNode{
      type: blockquote_type(),
      content: content,
      marks: [],
      attrs: nil,
      text: nil
    }
  end

  defp heading(level, children) do
    content = Fragment.from(children)

    %PmNode{
      type: heading_type(level),
      content: content,
      marks: [],
      attrs: %{"level" => level},
      text: nil
    }
  end

  defp hr_node do
    %PmNode{
      type: hr_type(),
      content: Fragment.empty(),
      marks: [],
      attrs: nil,
      text: nil
    }
  end

  defp br_node(marks \\ []) do
    %PmNode{
      type: br_type(),
      content: Fragment.empty(),
      marks: marks,
      attrs: nil,
      text: nil
    }
  end

  defp img_node(marks \\ []) do
    %PmNode{
      type: img_type(),
      content: Fragment.empty(),
      marks: marks,
      attrs: %{"src" => "img.png"},
      text: nil
    }
  end

  defp ul_node(children) do
    content = Fragment.from(children)
    %PmNode{type: ul_type(), content: content, marks: [], attrs: nil, text: nil}
  end

  defp li_node(children) do
    content = Fragment.from(children)
    %PmNode{type: li_type(), content: content, marks: [], attrs: nil, text: nil}
  end

  defp em_mark do
    %Mark{type: %{name: "em", rank: 1}, attrs: %{}}
  end

  defp strong_mark do
    %Mark{type: %{name: "strong", rank: 2}, attrs: %{}}
  end

  # ── debug_string ──────────────────────────────────────────────────────

  describe "debug_string" do
    test "nesting" do
      node = doc([blockquote_node([para([txt("hello")]), para([txt("bye")])])])

      assert PmNode.debug_string(node) ==
               ~s|doc(blockquote(paragraph("hello"), paragraph("bye")))|
    end

    test "shows inline children" do
      node = para([txt("foo"), img_node(), txt("bar"), br_node()])

      assert PmNode.debug_string(node) ==
               ~s|paragraph("foo", image, "bar", hard_break)|
    end

    test "marks wrap nodes" do
      node = para([txt("foo", [em_mark(), strong_mark()]), txt("bar")])

      assert PmNode.debug_string(node) ==
               ~s|paragraph(em(strong("foo")), "bar")|
    end
  end

  # ── cut ───────────────────────────────────────────────────────────────

  describe "cut" do
    test "extracts a full block" do
      node = doc([para([txt("foo")]), para([txt("bar")])])
      # First para starts at 0, ends at 5 (content "foo" = 3 chars + 2 for open/close)
      result = PmNode.cut(node, 0, 5)
      expected = doc([para([txt("foo")])])
      assert PmNode.eq(result, expected)
    end

    test "can cut text" do
      node = para([txt("foobar")])
      result = PmNode.cut(node, 1, 4)
      expected = para([txt("oob")])
      assert PmNode.eq(result, expected)
    end

    test "cuts deeply" do
      node =
        doc([
          blockquote_node([
            ul_node([
              li_node([para([txt("a")])]),
              li_node([para([txt("b")])])
            ])
          ]),
          para([txt("c")])
        ])

      # Cut from the inside - just para("c") at the end
      # The blockquote node size: 2 + content
      # li("a") = li(para("a")) = 2 + (2 + 1) = 5
      # li("b") = 5
      # ul = 2 + 10 = 12
      # blockquote = 2 + 12 = 14
      # para("c") = 2 + 1 = 3
      # total doc content = 17
      # para("c") goes from position 14 to 17
      result = PmNode.cut(node, 14, 17)
      expected = doc([para([txt("c")])])
      assert PmNode.eq(result, expected)
    end

    test "can cut text nodes" do
      node = txt("foobar")
      result = PmNode.cut(node, 2, 5)
      assert result.text == "oba"
    end

    test "preserves marks on cut text" do
      marks = [em_mark()]
      node = txt("foobar", marks)
      result = PmNode.cut(node, 1, 4)
      assert result.text == "oob"
      assert result.marks == marks
    end
  end

  # ── nodes_between ─────────────────────────────────────────────────────

  describe "nodes_between" do
    test "iterates over text" do
      node = doc([para([txt("foo")])])
      results = collect_nodes_between(node, 0, node.content.size)

      # We expect: para at pos 0, text "foo" at pos 1
      assert length(results) == 2
      [{n1, p1, _, _}, {n2, p2, _, _}] = results
      assert n1.type.name == "paragraph"
      assert p1 == 0
      assert n2.type.name == "text"
      assert n2.text == "foo"
      assert p2 == 1
    end

    test "descends multiple levels" do
      node = doc([blockquote_node([para([txt("hello")])])])
      results = collect_nodes_between(node, 0, node.content.size)

      assert length(results) == 3
      [{n1, p1, _, _}, {n2, p2, _, _}, {n3, p3, _, _}] = results
      assert n1.type.name == "blockquote"
      assert p1 == 0
      assert n2.type.name == "paragraph"
      assert p2 == 1
      assert n3.type.name == "text"
      assert n3.text == "hello"
      assert p3 == 2
    end

    test "finds inline nodes" do
      node = doc([para([txt("foo"), img_node(), txt("bar")])])
      results = collect_nodes_between(node, 0, node.content.size)

      # para at 0, text "foo" at 1, img at 4, text "bar" at 5
      assert length(results) == 4
      names = Enum.map(results, fn {n, _, _, _} -> n.type.name end)
      assert names == ["paragraph", "text", "image", "text"]
    end

    test "passes correct parent" do
      node = doc([para([txt("hello")])])
      results = collect_nodes_between(node, 0, node.content.size)

      [{_para, _, parent1, _}, {_text, _, parent2, _}] = results
      # para's parent is the doc
      assert parent1.type.name == "doc"
      # text's parent is the para
      assert parent2.type.name == "paragraph"
    end
  end

  # ── text_between ──────────────────────────────────────────────────────

  describe "text_between" do
    test "gets text from a text node" do
      node = txt("hello world")
      assert PmNode.text_between(node, 2, 7) == "llo w"
    end

    test "gets text across nodes with block separator" do
      node = doc([para([txt("foo")]), para([txt("bar")])])

      # Positions: doc open not counted, para1 at 0..5 (text at 1..4), para2 at 5..10 (text at 6..9)
      assert PmNode.text_between(node, 0, node.content.size, "\n") == "foo\nbar"
    end

    test "gets text without separator" do
      node = doc([para([txt("foo")]), para([txt("bar")])])
      assert PmNode.text_between(node, 0, node.content.size, "") == "foobar"
    end

    test "supports custom leaf text function" do
      node = doc([para([txt("a"), img_node(), txt("b")])])
      result = PmNode.text_between(node, 0, node.content.size, "", fn _n -> "[img]" end)
      assert result == "a[img]b"
    end

    test "supports leaf text string" do
      node = doc([para([txt("a"), img_node(), txt("b")])])
      result = PmNode.text_between(node, 0, node.content.size, "", "*")
      assert result == "a*b"
    end

    test "block separator on empty paragraphs" do
      node = doc([para([]), para([])])
      result = PmNode.text_between(node, 0, node.content.size, "\n")
      assert result == "\n"
    end
  end

  # ── text_content ──────────────────────────────────────────────────────

  describe "text_content" do
    test "returns text of a text node" do
      node = txt("hello")
      assert PmNode.text_content(node) == "hello"
    end

    test "extracts text from a whole doc" do
      node = doc([para([txt("foo")]), para([txt("bar")])])
      assert PmNode.text_content(node) == "foobar"
    end

    test "extracts text from nested elements" do
      node = doc([blockquote_node([para([txt("hello")])])])
      assert PmNode.text_content(node) == "hello"
    end
  end

  # ── Fragment.from ─────────────────────────────────────────────────────

  describe "Fragment.from" do
    test "wraps a single node in a fragment" do
      node = txt("hi")
      frag = Fragment.from(node)
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0) == node
    end

    test "wraps an array of nodes" do
      nodes = [txt("a", [em_mark()]), txt("b")]
      frag = Fragment.from(nodes)
      assert Fragment.child_count(frag) == 2
    end

    test "preserves a fragment" do
      frag = Fragment.from([txt("a")])
      assert Fragment.from(frag) == frag
    end

    test "accepts nil" do
      assert Fragment.from(nil) == Fragment.empty()
    end

    test "joins adjacent text with same markup" do
      frag = Fragment.from([txt("a"), txt("b")])
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0).text == "ab"
    end
  end

  # ── property accessors ───────────────────────────────────────────────

  describe "property accessors" do
    test "is_block" do
      assert PmNode.is_block(para([]))
      refute PmNode.is_block(txt("hi"))
    end

    test "is_textblock" do
      assert PmNode.is_textblock(para([]))
      refute PmNode.is_textblock(doc([]))
    end

    test "is_inline" do
      assert PmNode.is_inline(txt("hi"))
      refute PmNode.is_inline(para([]))
    end

    test "is_leaf" do
      assert PmNode.is_leaf(txt("hi"))
      assert PmNode.is_leaf(hr_node())
      refute PmNode.is_leaf(para([]))
    end

    test "child_count" do
      node = para([txt("a"), img_node(), txt("b")])
      assert PmNode.child_count(node) == 3
    end

    test "child_count on empty" do
      node = para([])
      assert PmNode.child_count(node) == 0
    end
  end

  # ── child access ─────────────────────────────────────────────────────

  describe "child access" do
    test "child returns the child at index" do
      node = para([txt("a"), img_node(), txt("b")])
      assert PmNode.child(node, 0).text == "a"
      assert PmNode.child(node, 1).type.name == "image"
      assert PmNode.child(node, 2).text == "b"
    end

    test "maybe_child returns nil for out-of-range" do
      node = para([txt("a")])
      assert PmNode.maybe_child(node, 5) == nil
    end

    test "first_child" do
      node = para([txt("first", [em_mark()]), txt("second")])
      assert PmNode.first_child(node).text == "first"
    end

    test "first_child on empty" do
      assert PmNode.first_child(para([])) == nil
    end

    test "last_child" do
      node = para([txt("first", [em_mark()]), txt("second")])
      assert PmNode.last_child(node).text == "second"
    end
  end

  # ── mark/2 ───────────────────────────────────────────────────────────

  describe "mark/2" do
    test "returns same node when marks unchanged" do
      node = txt("hi", [em_mark()])
      result = PmNode.mark(node, [em_mark()])
      assert result == node
    end

    test "returns new node with different marks" do
      node = txt("hi", [])
      result = PmNode.mark(node, [em_mark()])
      assert result.marks == [em_mark()]
      assert result.text == "hi"
    end
  end

  # ── for_each ──────────────────────────────────────────────────────────

  describe "for_each" do
    test "calls function for each child" do
      node = para([txt("a"), img_node(), txt("b")])
      me = self()

      PmNode.for_each(node, fn child, offset, index ->
        send(me, {:child, child.type.name, offset, index})
      end)

      assert_received {:child, "text", 0, 0}
      assert_received {:child, "image", 1, 1}
      assert_received {:child, "text", 2, 2}
    end
  end

  # ── descendants ──────────────────────────────────────────────────────

  describe "descendants" do
    test "visits all descendants" do
      node = doc([para([txt("foo")]), blockquote_node([para([txt("bar")])])])
      results = collect_descendants(node)

      names = Enum.map(results, fn {n, _, _, _} -> n.type.name end)
      assert "paragraph" in names
      assert "blockquote" in names
      assert "text" in names
      assert length(results) == 5
    end
  end

  # ── node_at ──────────────────────────────────────────────────────────

  describe "node_at" do
    test "finds text node at offset" do
      node = doc([para([txt("hello")])])
      # Position 1 is inside the paragraph, at the text node
      result = PmNode.node_at(node, 1)
      assert result.type.name == "text"
      assert result.text == "hello"
    end

    test "finds block node" do
      node = doc([para([txt("hello")])])
      result = PmNode.node_at(node, 0)
      assert result.type.name == "paragraph"
    end

    test "returns nil for invalid position" do
      node = doc([para([txt("hello")])])
      result = PmNode.node_at(node, 100)
      assert result == nil
    end
  end

  # ── child_after / child_before ────────────────────────────────────────

  describe "child_after" do
    test "returns child after position" do
      node = doc([para([txt("a")]), para([txt("b")])])
      # Position 0: first child starts there
      {child, index, offset} = PmNode.child_after(node, 0)
      assert child.type.name == "paragraph"
      assert index == 0
      assert offset == 0
    end

    test "returns child after middle position" do
      node = doc([para([txt("a")]), para([txt("b")])])
      # Position 3 = after first para (size 3)
      {child, index, offset} = PmNode.child_after(node, 3)
      assert child.type.name == "paragraph"
      assert index == 1
      assert offset == 3
    end
  end

  describe "child_before" do
    test "returns nil for position 0" do
      node = doc([para([txt("a")])])
      {child, index, offset} = PmNode.child_before(node, 0)
      assert child == nil
      assert index == 0
      assert offset == 0
    end

    test "returns child before position" do
      node = doc([para([txt("a")]), para([txt("b")])])
      # Position 3 = end of first para
      {child, index, offset} = PmNode.child_before(node, 3)
      assert child.type.name == "paragraph"
      assert index == 0
      assert offset == 0
    end
  end

  # ── range_has_mark ───────────────────────────────────────────────────

  describe "range_has_mark" do
    test "finds mark in range" do
      node = doc([para([txt("plain"), txt("bold", [strong_mark()])])])
      mark = strong_mark()
      assert PmNode.range_has_mark(node, 0, node.content.size, mark)
    end

    test "does not find missing mark" do
      node = doc([para([txt("plain")])])
      mark = em_mark()
      refute PmNode.range_has_mark(node, 0, node.content.size, mark)
    end

    test "returns false for empty range" do
      node = doc([para([txt("bold", [strong_mark()])])])
      mark = strong_mark()
      refute PmNode.range_has_mark(node, 0, 0, mark)
    end
  end

  # ── has_markup ───────────────────────────────────────────────────────

  describe "has_markup" do
    test "matches type" do
      node = para([txt("hi")])
      assert PmNode.has_markup(node, para_type())
    end

    test "does not match different type" do
      node = para([txt("hi")])
      refute PmNode.has_markup(node, doc_type())
    end

    test "checks attributes" do
      node = heading(2, [txt("hi")])
      assert PmNode.has_markup(node, heading_type(2), %{"level" => 2})
      refute PmNode.has_markup(node, heading_type(1), %{"level" => 1})
    end

    test "checks marks" do
      marks = [em_mark()]
      node = para([txt("hi")], marks)
      assert PmNode.has_markup(node, para_type(), nil, marks)
      refute PmNode.has_markup(node, para_type(), nil, [strong_mark()])
    end
  end

  # ── stubs ─────────────────────────────────────────────────────────────

  describe "stubs" do
    test "resolve raises" do
      node = doc([])
      assert_raise RuntimeError, ~r/not yet implemented/, fn -> PmNode.resolve(node, 0) end
    end

    test "slice raises" do
      node = doc([])

      assert_raise RuntimeError, ~r/not yet implemented/, fn ->
        PmNode.slice(node, 0, 0)
      end
    end

    test "replace raises" do
      node = doc([])

      assert_raise RuntimeError, ~r/not yet implemented/, fn ->
        PmNode.replace(node, 0, 0, nil)
      end
    end

    test "check raises" do
      node = doc([])
      assert_raise RuntimeError, ~r/not yet implemented/, fn -> PmNode.check(node) end
    end

    test "from_json raises" do
      assert_raise RuntimeError, ~r/not yet implemented/, fn ->
        PmNode.from_json(nil, %{})
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp collect_nodes_between(node, from, to) do
    ref = make_ref()
    me = self()

    PmNode.nodes_between(node, from, to, fn child, pos, parent, index ->
      send(me, {ref, {child, pos, parent, index}})
      true
    end)

    collect_messages(ref)
  end

  defp collect_descendants(node) do
    ref = make_ref()
    me = self()

    PmNode.descendants(node, fn child, pos, parent, index ->
      send(me, {ref, {child, pos, parent, index}})
      true
    end)

    collect_messages(ref)
  end

  defp collect_messages(ref) do
    receive do
      {^ref, msg} -> [msg | collect_messages(ref)]
    after
      0 -> []
    end
  end
end
