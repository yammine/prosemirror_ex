defmodule ProsemirrorEx.Model.ResolvedPosTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Node, ResolvedPos, Mark, Schema, NodeType, NodeRange}

  # ── Test document setup ──────────────────────────────────────────────

  # Equivalent to JS: doc(p("ab"), blockquote(p(em("cd"), "ef")))
  defp test_doc do
    {d, _tags} = doc([p(["ab"]), blockquote([p([em(["cd"]), "ef"])])])
    d
  end

  # ── resolve / structure tests ────────────────────────────────────────

  describe "resolve" do
    test "should reflect the document structure" do
      d = test_doc()

      # Build expected data matching the JS test
      # doc_info = {node: testDoc, start: 0, end: 12}
      # p1_info = {node: testDoc.child(0), start: 1, end: 3}
      # blk_info = {node: testDoc.child(1), start: 5, end: 11}
      # p2_info = {node: blk_info.node.child(0), start: 6, end: 10}
      p1_node = Node.child(d, 0)
      blk_node = Node.child(d, 1)
      p2_node = Node.child(blk_node, 0)

      doc_info = %{node: d, start: 0, end_pos: 12}
      p1_info = %{node: p1_node, start: 1, end_pos: 3}
      blk_info = %{node: blk_node, start: 5, end_pos: 11}
      p2_info = %{node: p2_node, start: 6, end_pos: 10}

      # expected[pos] = {ancestors_list, parentOffset, nodeBefore, nodeAfter}
      expected = %{
        0 => {[doc_info], 0, nil, {:node, p1_node}},
        1 => {[doc_info, p1_info], 0, nil, {:text, "ab"}},
        2 => {[doc_info, p1_info], 1, {:text, "a"}, {:text, "b"}},
        3 => {[doc_info, p1_info], 2, {:text, "ab"}, nil},
        4 => {[doc_info], 4, {:node, p1_node}, {:node, blk_node}},
        5 => {[doc_info, blk_info], 0, nil, {:node, p2_node}},
        6 => {[doc_info, blk_info, p2_info], 0, nil, {:text, "cd"}},
        7 => {[doc_info, blk_info, p2_info], 1, {:text, "c"}, {:text, "d"}},
        8 => {[doc_info, blk_info, p2_info], 2, {:text, "cd"}, {:text, "ef"}},
        9 => {[doc_info, blk_info, p2_info], 3, {:text, "e"}, {:text, "f"}},
        10 => {[doc_info, blk_info, p2_info], 4, {:text, "ef"}, nil},
        11 => {[doc_info, blk_info], 6, {:node, p2_node}, nil},
        12 => {[doc_info], 12, {:node, blk_node}, nil}
      }

      for pos <- 0..d.content.size do
        rpos = Node.resolve(d, pos)
        {ancestors, parent_offset, exp_before, exp_after} = expected[pos]

        # Check depth
        assert rpos.depth == length(ancestors) - 1,
               "pos #{pos}: expected depth #{length(ancestors) - 1}, got #{rpos.depth}"

        # Check each ancestor level
        for i <- 0..(length(ancestors) - 1) do
          anc = Enum.at(ancestors, i)

          assert Node.eq(ResolvedPos.node(rpos, i), anc.node),
                 "pos #{pos}: node at depth #{i} mismatch"

          assert ResolvedPos.start(rpos, i) == anc.start,
                 "pos #{pos}: start at depth #{i} expected #{anc.start}, got #{ResolvedPos.start(rpos, i)}"

          assert ResolvedPos.end_pos(rpos, i) == anc.end_pos,
                 "pos #{pos}: end at depth #{i} expected #{anc.end_pos}, got #{ResolvedPos.end_pos(rpos, i)}"

          if i > 0 do
            assert ResolvedPos.before(rpos, i) == anc.start - 1,
                   "pos #{pos}: before at depth #{i} expected #{anc.start - 1}"

            assert ResolvedPos.after_pos(rpos, i) == anc.end_pos + 1,
                   "pos #{pos}: after at depth #{i} expected #{anc.end_pos + 1}"
          end
        end

        # Check parentOffset
        assert rpos.parent_offset == parent_offset,
               "pos #{pos}: expected parentOffset #{parent_offset}, got #{rpos.parent_offset}"

        # Check nodeBefore
        node_before = ResolvedPos.node_before(rpos)
        assert_node_match(node_before, exp_before, "pos #{pos}: nodeBefore")

        # Check nodeAfter
        node_after = ResolvedPos.node_after(rpos)
        assert_node_match(node_after, exp_after, "pos #{pos}: nodeAfter")
      end
    end

    test "has a working posAtIndex method" do
      {d, _tags} =
        doc([blockquote([p(["one"]), blockquote([p(["two ", em(["three"])]), p(["four"])])])])

      p_three = Node.resolve(d, 12)

      assert ResolvedPos.pos_at_index(p_three, 0) == 8
      assert ResolvedPos.pos_at_index(p_three, 1) == 12
      assert ResolvedPos.pos_at_index(p_three, 2) == 17
      assert ResolvedPos.pos_at_index(p_three, 0, 2) == 7
      assert ResolvedPos.pos_at_index(p_three, 1, 2) == 18
      assert ResolvedPos.pos_at_index(p_three, 2, 2) == 24
      assert ResolvedPos.pos_at_index(p_three, 0, 1) == 1
      assert ResolvedPos.pos_at_index(p_three, 1, 1) == 6
      assert ResolvedPos.pos_at_index(p_three, 2, 1) == 25
      assert ResolvedPos.pos_at_index(p_three, 0, 0) == 0
      assert ResolvedPos.pos_at_index(p_three, 1, 0) == 26
    end
  end

  # ── ResolvedPos.marks tests ─────────────────────────────────────────

  describe "ResolvedPos.marks" do
    test "recognizes a mark exists inside marked text" do
      {doc_node, tags} = doc([p([em(["fo<a>o"])])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      assert Mark.is_in_set(em_mark, marks)
    end

    test "recognizes a mark doesn't exist in non-marked text" do
      {doc_node, tags} = doc([p([em(["fo<a>o"])])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      strong_mark = Schema.mark(schema, "strong")
      refute Mark.is_in_set(strong_mark, marks)
    end

    test "considers a mark active after the mark" do
      {doc_node, tags} = doc([p([em(["hi"]), "<a> there"])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      assert Mark.is_in_set(em_mark, marks)
    end

    test "considers a mark inactive before the mark" do
      {doc_node, tags} = doc([p(["one <a>", em(["two"])])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      refute Mark.is_in_set(em_mark, marks)
    end

    test "considers a mark active at the start of the textblock" do
      {doc_node, tags} = doc([p([em(["<a>one"])])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      assert Mark.is_in_set(em_mark, marks)
    end

    test "notices that attributes differ" do
      {doc_node, tags} = doc([p([a(["li<a>nk"])])])
      pos = tags["a"]
      resolved = Node.resolve(doc_node, pos)
      marks = ResolvedPos.marks(resolved)
      schema = test_schema()
      link_mark = Schema.mark(schema, "link", %{"href" => "http://baz"})
      refute Mark.is_in_set(link_mark, marks)
    end

    # Tests with custom schema for non-inclusive marks
    test "omits non-inclusive marks at end of mark" do
      {custom_schema, custom_doc} = custom_schema_doc()
      # Position 4 is at the end of "one" (which has [remark1, customStrong])
      # At the boundary, non-inclusive remark1 should be omitted, leaving [customStrong]
      resolved = Node.resolve(custom_doc, 4)
      marks = ResolvedPos.marks(resolved)
      custom_strong = Schema.mark(custom_schema, "strong")
      assert Mark.same_set(marks, [custom_strong])
    end

    test "includes non-inclusive marks inside a text node" do
      {custom_schema, custom_doc} = custom_schema_doc()
      # Position 3 is inside "one" (which has [remark1, customStrong])
      resolved = Node.resolve(custom_doc, 3)
      marks = ResolvedPos.marks(resolved)
      remark1 = Schema.mark(custom_schema, "remark", %{"id" => 1})
      custom_strong = Schema.mark(custom_schema, "strong")
      assert Mark.same_set(marks, [remark1, custom_strong])
    end

    test "omits non-inclusive marks at the end of a line" do
      {_custom_schema, custom_doc} = custom_schema_doc()
      # Doc structure:
      # doc(p("one"[remark1,strong] + "two"), p("one" + "two"[remark1] + "three"[remark1]), p("one"[remark2] + "two"[remark1]))
      # Para 1: open(1) + "one"(3) + "two"(3) + close(1) = 8  -> positions 0..8
      # Para 2: open(1) + "one"(3) + "two"(3) + "three"(5) + close(1) = 13 -> positions 8..21
      # Position 20 = end of para 2 content = 8+1+11 = 20
      resolved = Node.resolve(custom_doc, 20)
      marks = ResolvedPos.marks(resolved)
      assert Mark.same_set(marks, [])
    end

    test "includes non-inclusive marks between two marked nodes" do
      {custom_schema, custom_doc} = custom_schema_doc()
      # Position 15 is between "two"[remark1] and "three"[remark1] in the second paragraph
      # Para 2 starts at pos 9, "one"(3) = pos 12, "two"(3) = pos 15
      resolved = Node.resolve(custom_doc, 15)
      marks = ResolvedPos.marks(resolved)
      remark1 = Schema.mark(custom_schema, "remark", %{"id" => 1})
      assert Mark.same_set(marks, [remark1])
    end

    test "excludes non-inclusive marks at a point where mark attrs change" do
      {_custom_schema, custom_doc} = custom_schema_doc()
      # Position 25 is between "one"[remark2] and "two"[remark1] in the third paragraph
      # Para 3 starts at pos 22, "one"(3) => pos 25
      resolved = Node.resolve(custom_doc, 25)
      marks = ResolvedPos.marks(resolved)
      assert Mark.same_set(marks, [])
    end
  end

  # ── shared_depth tests ──────────────────────────────────────────────

  describe "shared_depth" do
    test "returns 0 for positions in different top-level nodes" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      assert ResolvedPos.shared_depth(rpos, 8) == 0
    end

    test "returns the depth of the common ancestor" do
      d = test_doc()
      rpos = Node.resolve(d, 7)
      assert ResolvedPos.shared_depth(rpos, 9) == 2
    end
  end

  # ── block_range tests ───────────────────────────────────────────────

  describe "block_range" do
    test "returns a range in the same textblock" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 3)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      assert range.depth == 0
      assert NodeRange.start_index(range) == 0
      assert NodeRange.end_index(range) == 1
    end

    test "returns a range across blocks" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 9)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      assert range.depth == 0
    end
  end

  # ── same_parent tests ──────────────────────────────────────────────

  describe "same_parent" do
    test "returns true for positions in the same parent" do
      d = test_doc()
      a = Node.resolve(d, 2)
      b = Node.resolve(d, 3)
      assert ResolvedPos.same_parent(a, b)
    end

    test "returns false for positions in different parents" do
      d = test_doc()
      a = Node.resolve(d, 2)
      b = Node.resolve(d, 8)
      refute ResolvedPos.same_parent(a, b)
    end
  end

  # ── max/min tests ──────────────────────────────────────────────────

  describe "max and min" do
    test "max returns the greater position" do
      d = test_doc()
      a = Node.resolve(d, 2)
      b = Node.resolve(d, 8)
      assert ResolvedPos.max(a, b).pos == 8
    end

    test "min returns the smaller position" do
      d = test_doc()
      a = Node.resolve(d, 2)
      b = Node.resolve(d, 8)
      assert ResolvedPos.min(a, b).pos == 2
    end
  end

  # ── text_offset tests ───────────────────────────────────────────────

  describe "ResolvedPos.text_offset" do
    test "returns 0 at the start of a textblock" do
      d = test_doc()
      # Position 1 is at the start of p("ab") content
      rpos = Node.resolve(d, 1)
      assert ResolvedPos.text_offset(rpos) == 0
    end

    test "returns offset inside a text node" do
      d = test_doc()
      # Position 2 is inside "ab" (after "a"), text_offset = 1
      rpos = Node.resolve(d, 2)
      assert ResolvedPos.text_offset(rpos) == 1
    end

    test "returns 0 at block boundary" do
      d = test_doc()
      # Position 4 is between p and blockquote at doc level
      rpos = Node.resolve(d, 4)
      assert ResolvedPos.text_offset(rpos) == 0
    end

    test "returns offset inside deeper text node" do
      d = test_doc()
      # Position 7 is inside "cd" (after "c"), text_offset = 1
      rpos = Node.resolve(d, 7)
      assert ResolvedPos.text_offset(rpos) == 1
    end

    test "returns 0 at end of textblock" do
      d = test_doc()
      # Position 3 is at end of p("ab") content. The resolve loop finds
      # rem == 0 after the text node, so the path's last offset equals pos.
      # text_offset = pos - last(path) = 3 - 3 = 0
      rpos = Node.resolve(d, 3)
      assert ResolvedPos.text_offset(rpos) == 0
    end
  end

  # ── index / index_after tests ──────────────────────────────────────

  describe "ResolvedPos.index and index_after" do
    test "index is 0 at start of block" do
      d = test_doc()
      # Position 1 is at start of p("ab"), index into p is 0
      rpos = Node.resolve(d, 1)
      assert ResolvedPos.index(rpos) == 0
    end

    test "index_after reflects position after current node" do
      d = test_doc()
      # Position 3 is at end of p("ab") content, past the "ab" text node.
      # index = 1 (past the text child), text_offset = 0,
      # index_after = 1 + 0 = 1
      rpos = Node.resolve(d, 3)
      assert ResolvedPos.index(rpos) == 1
      assert ResolvedPos.index_after(rpos) == 1
    end

    test "index at doc level" do
      d = test_doc()
      # Position 0: at doc level, before first child
      rpos = Node.resolve(d, 0)
      assert ResolvedPos.index(rpos, 0) == 0
      assert ResolvedPos.index_after(rpos, 0) == 0

      # Position 4: between p and blockquote at doc level, index = 1
      rpos4 = Node.resolve(d, 4)
      assert ResolvedPos.index(rpos4, 0) == 1
      assert ResolvedPos.index_after(rpos4, 0) == 1

      # Position 12: at end of doc, past both children, index = 2
      rpos12 = Node.resolve(d, 12)
      assert ResolvedPos.index(rpos12, 0) == 2
      assert ResolvedPos.index_after(rpos12, 0) == 2
    end

    test "index at various depths in nested content" do
      d = test_doc()
      # Position 8 is between "cd" (em) and "ef" in the inner paragraph
      # At depth 2 (the inner p), index = 1 (after "cd" node, before "ef" node)
      rpos = Node.resolve(d, 8)
      assert ResolvedPos.index(rpos, 2) == 1
      assert ResolvedPos.index_after(rpos, 2) == 1

      # At depth 1 (the blockquote), index = 0 (the inner p)
      assert ResolvedPos.index(rpos, 1) == 0
    end
  end

  # ── marks_across tests ─────────────────────────────────────────────

  describe "ResolvedPos.marks_across" do
    test "returns marks within same marked text" do
      {doc_node, _tags} = doc([p([em(["hello"])])])
      from = Node.resolve(doc_node, 2)
      to = Node.resolve(doc_node, 4)
      marks = ResolvedPos.marks_across(from, to)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      assert marks != nil
      assert Mark.is_in_set(em_mark, marks)
    end

    test "returns marks across boundary between marked and unmarked text" do
      {doc_node, _tags} = doc([p([em(["hello"]), " world"])])
      # Position 1 is start of p content, "hello" is at positions 1-6 (with em)
      # " world" is at positions 6-12
      # from is inside "hello" (em), to is inside " world" (no marks)
      from = Node.resolve(doc_node, 2)
      to = Node.resolve(doc_node, 8)
      marks = ResolvedPos.marks_across(from, to)
      schema = test_schema()
      em_mark = Schema.mark(schema, "em")
      # marks_across returns the marks of the node after `from`, filtered by non-inclusive
      # The node after from at index is the em text, so em mark is present
      assert marks != nil
      assert Mark.is_in_set(em_mark, marks)
    end

    test "returns nil when no inline content after position" do
      {doc_node, _tags} = doc([p(["hello"])])
      # Position 6 is at the end of p content, no node after
      from = Node.resolve(doc_node, 6)
      to = Node.resolve(doc_node, 6)
      marks = ResolvedPos.marks_across(from, to)
      assert marks == nil
    end
  end

  # ── parent and doc tests ───────────────────────────────────────────

  describe "ResolvedPos.parent and doc" do
    test "parent returns the immediate parent node" do
      d = test_doc()
      # Position 2 is inside p("ab"), parent should be the paragraph
      rpos = Node.resolve(d, 2)
      parent = ResolvedPos.parent(rpos)
      assert parent.type.name == "paragraph"
    end

    test "doc returns the top-level document" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      doc_node = ResolvedPos.doc(rpos)
      assert Node.eq(doc_node, d)
    end

    test "parent at deeper nesting returns the inner parent" do
      d = test_doc()
      # Position 8 is inside the inner p within blockquote
      rpos = Node.resolve(d, 8)
      parent = ResolvedPos.parent(rpos)
      assert parent.type.name == "paragraph"
      # The parent should be the inner paragraph (has 2 children: em("cd") and "ef")
      assert Node.child_count(parent) == 2
    end

    test "parent at blockquote level" do
      d = test_doc()
      # Position 5 is at start of blockquote content
      rpos = Node.resolve(d, 5)
      parent = ResolvedPos.parent(rpos)
      assert parent.type.name == "blockquote"
    end

    test "doc always returns the same root regardless of depth" do
      d = test_doc()
      rpos_shallow = Node.resolve(d, 0)
      rpos_deep = Node.resolve(d, 8)
      assert Node.eq(ResolvedPos.doc(rpos_shallow), ResolvedPos.doc(rpos_deep))
    end
  end

  # ── start and end_pos tests ────────────────────────────────────────

  describe "ResolvedPos.start and end_pos" do
    test "at depth 0 (doc level)" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      assert ResolvedPos.start(rpos, 0) == 0
      assert ResolvedPos.end_pos(rpos, 0) == 12
    end

    test "at depth 1 (first-level block)" do
      d = test_doc()
      # Position 2 is inside p("ab"), at depth 1
      rpos = Node.resolve(d, 2)
      assert ResolvedPos.start(rpos, 1) == 1
      assert ResolvedPos.end_pos(rpos, 1) == 3
    end

    test "at deeper level (inner paragraph)" do
      d = test_doc()
      # Position 8 is inside the inner p, depth 2
      rpos = Node.resolve(d, 8)
      assert ResolvedPos.start(rpos, 2) == 6
      assert ResolvedPos.end_pos(rpos, 2) == 10
    end

    test "blockquote level start and end" do
      d = test_doc()
      rpos = Node.resolve(d, 8)
      # At depth 1 (blockquote)
      assert ResolvedPos.start(rpos, 1) == 5
      assert ResolvedPos.end_pos(rpos, 1) == 11
    end

    test "default depth uses current depth" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      # Default depth is rpos.depth which is 1 (inside paragraph)
      assert ResolvedPos.start(rpos) == 1
      assert ResolvedPos.end_pos(rpos) == 3
    end
  end

  # ── before and after_pos tests ─────────────────────────────────────

  describe "ResolvedPos.before and after_pos" do
    test "position before and after block node at depth 1" do
      d = test_doc()
      # Position 2 is inside p("ab"), depth 1
      rpos = Node.resolve(d, 2)
      # before(depth=1) = start(1) - 1 = 1 - 1 = 0
      assert ResolvedPos.before(rpos, 1) == 0
      # after_pos(depth=1) = end_pos(1) + 1 = 3 + 1 = 4
      assert ResolvedPos.after_pos(rpos, 1) == 4
    end

    test "position before and after blockquote" do
      d = test_doc()
      rpos = Node.resolve(d, 8)
      # At depth 1 (blockquote): before = 4, after = 12
      assert ResolvedPos.before(rpos, 1) == 4
      assert ResolvedPos.after_pos(rpos, 1) == 12
    end

    test "position before and after inner paragraph" do
      d = test_doc()
      rpos = Node.resolve(d, 8)
      # At depth 2 (inner p): before = start(2) - 1 = 6 - 1 = 5
      assert ResolvedPos.before(rpos, 2) == 5
      # after_pos(2) = end_pos(2) + 1 = 10 + 1 = 11
      assert ResolvedPos.after_pos(rpos, 2) == 11
    end

    test "raises for depth 0" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      assert_raise ArgumentError, fn -> ResolvedPos.before(rpos, 0) end
      assert_raise ArgumentError, fn -> ResolvedPos.after_pos(rpos, 0) end
    end

    test "at depth+1 returns original position" do
      d = test_doc()
      rpos = Node.resolve(d, 2)
      # depth+1 = 2, before returns rpos.pos, after returns rpos.pos
      assert ResolvedPos.before(rpos, rpos.depth + 1) == 2
      assert ResolvedPos.after_pos(rpos, rpos.depth + 1) == 2
    end
  end

  # ── NodeRange accessor tests ───────────────────────────────────────

  describe "NodeRange accessors" do
    test "parent returns the shared ancestor" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 3)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      parent = NodeRange.parent(range)
      # The range at depth 0 means the parent is the doc
      assert Node.eq(parent, d)
    end

    test "start returns the correct position" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 3)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      # Range depth is 0, start = before(from, 1) = 0
      assert NodeRange.start(range) == 0
    end

    test "end_pos returns the correct position" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 3)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      # Range depth is 0, end_pos = after_pos(to, 1) = 4
      assert NodeRange.end_pos(range) == 4
    end

    test "start_index and end_index on cross-block range" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 9)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      assert range.depth == 0
      # start_index = index(from, 0) = 0
      assert NodeRange.start_index(range) == 0
      # end_index = index_after(to, 0) = 2 (both children covered)
      assert NodeRange.end_index(range) == 2
    end

    test "parent of range within blockquote" do
      d = test_doc()
      # Both positions in the inner paragraph within blockquote
      from = Node.resolve(d, 7)
      to = Node.resolve(d, 9)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      parent = NodeRange.parent(range)
      # The inner p has inline content, so block_range goes up to depth 1 (blockquote)
      assert parent.type.name == "blockquote"
    end
  end

  # ── block_range edge cases ─────────────────────────────────────────

  describe "block_range edge cases" do
    test "returns nil when predicate rejects all ancestors" do
      d = test_doc()
      from = Node.resolve(d, 2)
      to = Node.resolve(d, 3)
      # Predicate that always returns false
      range = ResolvedPos.block_range(from, to, fn _node -> false end)
      assert range == nil
    end

    test "with custom predicate accepting only specific node type" do
      d = test_doc()
      from = Node.resolve(d, 7)
      to = Node.resolve(d, 9)
      # Accept only blockquote
      range =
        ResolvedPos.block_range(from, to, fn node -> node.type.name == "blockquote" end)

      assert range != nil
      assert range.depth == 1
      parent = NodeRange.parent(range)
      assert parent.type.name == "blockquote"
    end

    test "range spanning multiple blocks at same level" do
      {d, _tags} = doc([p(["one"]), p(["two"]), p(["three"])])
      from = Node.resolve(d, 2)
      # Position in "three" — doc structure: <p>one</p><p>two</p><p>three</p>
      # p("one") = 1+3+1 = 5, p("two") = 1+3+1 = 5, p("three") = 1+5+1 = 7
      # Positions: 0 [doc open], 1-4 p("one"), 5 [between], 6-9 p("two"), 10 [between], 11-16 p("three"), 17
      to = Node.resolve(d, 14)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      assert range.depth == 0
      assert NodeRange.start_index(range) == 0
      assert NodeRange.end_index(range) == 3
    end

    test "block_range with single position defaults to self" do
      d = test_doc()
      from = Node.resolve(d, 2)
      range = ResolvedPos.block_range(from)
      assert range != nil
      # When from == to and both in a textblock (inline content), depth goes to parent
      assert range.depth == 0
    end

    test "swaps from and to when to < from" do
      d = test_doc()
      from = Node.resolve(d, 9)
      to = Node.resolve(d, 7)
      range = ResolvedPos.block_range(from, to)
      assert range != nil
      assert range.depth == 1
    end
  end

  # ── Helper functions ────────────────────────────────────────────────

  defp assert_node_match(nil, nil, _msg), do: :ok

  defp assert_node_match(node, {:text, text}, msg) do
    assert node != nil, "#{msg}: expected text '#{text}', got nil"

    assert Node.text_content(node) == text,
           "#{msg}: expected text '#{text}', got '#{Node.text_content(node)}'"
  end

  defp assert_node_match(node, {:node, expected}, msg) do
    assert node != nil, "#{msg}: expected a node, got nil"
    assert Node.eq(node, expected), "#{msg}: node mismatch"
  end

  defp assert_node_match(node, nil, msg) do
    assert node == nil, "#{msg}: expected nil, got a node"
  end

  # Build custom schema and document for non-inclusive mark tests
  defp custom_schema_doc do
    schema =
      Schema.new(%{
        "nodes" => [
          {"doc", %{"content" => "paragraph+"}},
          {"paragraph", %{"content" => "text*"}},
          {"text", %{}}
        ],
        "marks" => [
          {"remark", %{"attrs" => %{"id" => %{}}, "excludes" => "", "inclusive" => false}},
          {"user", %{"attrs" => %{"id" => %{}}, "excludes" => "_"}},
          {"strong", %{"excludes" => "em-group"}},
          {"em", %{"group" => "em-group"}}
        ]
      })

    remark1 = Schema.mark(schema, "remark", %{"id" => 1})
    remark2 = Schema.mark(schema, "remark", %{"id" => 2})
    custom_strong = Schema.mark(schema, "strong")

    doc_type = schema.nodes["doc"]
    p_type = schema.nodes["paragraph"]

    p1 =
      NodeType.create(p_type, nil, [
        Schema.text(schema, "one", [remark1, custom_strong]),
        Schema.text(schema, "two")
      ])

    p2 =
      NodeType.create(p_type, nil, [
        Schema.text(schema, "one"),
        Schema.text(schema, "two", [remark1]),
        Schema.text(schema, "three", [remark1])
      ])

    p3 =
      NodeType.create(p_type, nil, [
        Schema.text(schema, "one", [remark2]),
        Schema.text(schema, "two", [remark1])
      ])

    custom_doc = NodeType.create(doc_type, nil, [p1, p2, p3])

    {schema, custom_doc}
  end
end
