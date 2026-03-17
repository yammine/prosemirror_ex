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
