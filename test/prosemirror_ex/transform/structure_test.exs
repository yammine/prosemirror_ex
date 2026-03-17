defmodule ProsemirrorEx.Transform.StructureTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.{Transform, Structure}
  alias ProsemirrorEx.Model.{Node, Slice, Fragment, Schema, NodeType, ResolvedPos}

  # ── Test helper: testTransform equivalent ──────────────────────────

  defp test_transform(tr, {expect_node, expect_tags}) do
    # 1. The result doc should match the expected doc
    assert Node.eq(tr.doc, expect_node),
           "Transform result doesn't match expected.\n\nGot:\n#{Node.debug_string(tr.doc)}\n\nExpected:\n#{Node.debug_string(expect_node)}"

    # 2. Inverting the transform should produce the original doc
    inverted = invert_transform(tr)

    assert Node.eq(inverted.doc, Transform.before(tr)),
           "Inverted transform doesn't produce original doc.\n\nGot:\n#{Node.debug_string(inverted.doc)}\n\nExpected:\n#{Node.debug_string(Transform.before(tr))}"

    # 3. Test step JSON round-trip
    json_tr = Transform.new(Transform.before(tr))

    json_tr =
      Enum.reduce(tr.steps, json_tr, fn step_struct, acc ->
        step_module = step_struct.__struct__
        json = step_module.to_json(step_struct)

        restored =
          ProsemirrorEx.Transform.Step.from_json(tr.doc.type.schema, json)

        Transform.step(acc, restored)
      end)

    assert Node.eq(tr.doc, json_tr.doc),
           "JSON round-trip doesn't produce same result"

    # 4. Test mapping for tagged positions
    Enum.each(expect_tags, fn {tag_name, expect_pos} ->
      before_doc_tags = Process.get(:_pm_test_before_tags, %{})

      case Map.get(before_doc_tags, tag_name) do
        nil ->
          :ok

        before_pos ->
          mapped = ProsemirrorEx.Transform.Mapping.map(tr.mapping, before_pos, 1)

          assert mapped == expect_pos,
                 "Mapping for tag '#{tag_name}': expected #{expect_pos}, got #{mapped}"
      end
    end)
  end

  defp invert_transform(tr) do
    out = Transform.new(tr.doc)

    Enum.reduce((length(tr.steps) - 1)..0//-1, out, fn i, acc ->
      step_struct = Enum.at(tr.steps, i)
      step_module = step_struct.__struct__
      inverted = step_module.invert(step_struct, Enum.at(tr.docs, i))
      Transform.step(acc, inverted)
    end)
  end

  # ── Custom schema for test-structure.ts tests ─────────────────────

  defp structure_schema do
    case Process.get(:_pm_structure_test_schema) do
      nil ->
        s =
          Schema.new(%{
            "nodes" => [
              {"doc", %{"content" => "head? block* sect* closing?"}},
              {"para", %{"content" => "text*", "group" => "block"}},
              {"head", %{"content" => "text*", "marks" => ""}},
              {"figure", %{"content" => "caption figureimage", "group" => "block"}},
              {"quote", %{"content" => "block+", "group" => "block"}},
              {"figureimage", %{}},
              {"caption", %{"content" => "text*", "marks" => ""}},
              {"sect", %{"content" => "head block* sect*"}},
              {"closing", %{"content" => "text*"}},
              {"text", %{"group" => "inline"}},
              {"fixed", %{"content" => "head para closing", "group" => "block"}}
            ],
            "marks" => [
              {"em", %{}}
            ]
          })

        Process.put(:_pm_structure_test_schema, s)
        s

      s ->
        s
    end
  end

  # Helpers to build nodes for the structure schema
  defp sn(schema, name, children) do
    node_type = Schema.node_type(schema, name)
    content = Fragment.from(children)
    NodeType.create(node_type, nil, content, nil)
  end

  defp st(schema, str) do
    Schema.text(schema, str)
  end

  # Build the reference document from test-structure.ts
  defp structure_doc do
    s = structure_schema()

    sn(s, "doc", [
      sn(s, "head", [st(s, "Head")]),
      sn(s, "para", [st(s, "Intro")]),
      sn(s, "sect", [
        sn(s, "head", [st(s, "Section head")]),
        sn(s, "sect", [
          sn(s, "head", [st(s, "Subsection head")]),
          sn(s, "para", [st(s, "Subtext")]),
          sn(s, "figure", [
            sn(s, "caption", [st(s, "Figure caption")]),
            sn(s, "figureimage", [])
          ]),
          sn(s, "quote", [sn(s, "para", [st(s, "!")])])
        ])
      ]),
      sn(s, "sect", [
        sn(s, "head", [st(s, "S2")]),
        sn(s, "para", [st(s, "Yes")])
      ]),
      sn(s, "closing", [st(s, "fin")])
    ])
  end

  defp srange(doc, pos, end_pos \\ nil) do
    from_rpos = Node.resolve(doc, pos)

    if end_pos do
      to_rpos = Node.resolve(doc, end_pos)
      ResolvedPos.block_range(from_rpos, to_rpos)
    else
      ResolvedPos.block_range(from_rpos)
    end
  end

  # ── canSplit tests ─────────────────────────────────────────────────

  describe "canSplit" do
    test "can't at start" do
      doc = structure_doc()
      refute Structure.can_split(doc, 0)
    end

    test "can't in head" do
      doc = structure_doc()
      refute Structure.can_split(doc, 3)
    end

    test "can by making head a para" do
      doc = structure_doc()
      s = structure_schema()
      assert Structure.can_split(doc, 3, 1, [%{type: s.nodes["para"]}])
    end

    test "can't on top level" do
      doc = structure_doc()
      refute Structure.can_split(doc, 6)
    end

    test "can in regular para" do
      doc = structure_doc()
      assert Structure.can_split(doc, 8)
    end

    test "can't at start of section" do
      doc = structure_doc()
      refute Structure.can_split(doc, 14)
    end

    test "can't in section head" do
      doc = structure_doc()
      refute Structure.can_split(doc, 17)
    end

    test "can if also splitting the section" do
      doc = structure_doc()
      assert Structure.can_split(doc, 17, 2)
    end

    test "can if making the remaining head a para" do
      doc = structure_doc()
      s = structure_schema()
      assert Structure.can_split(doc, 18, 1, [%{type: s.nodes["para"]}])
    end

    test "can't after the section head" do
      doc = structure_doc()
      refute Structure.can_split(doc, 46)
    end

    test "can in the first section para" do
      doc = structure_doc()
      assert Structure.can_split(doc, 48)
    end

    test "can't in the figure caption" do
      doc = structure_doc()
      refute Structure.can_split(doc, 60)
    end

    test "can't if it also splits the figure" do
      doc = structure_doc()
      refute Structure.can_split(doc, 62, 2)
    end

    test "can't after the figure caption" do
      doc = structure_doc()
      refute Structure.can_split(doc, 72)
    end

    test "can in the first para in a quote" do
      doc = structure_doc()
      assert Structure.can_split(doc, 76)
    end

    test "can if it also splits the quote" do
      doc = structure_doc()
      assert Structure.can_split(doc, 77, 2)
    end

    test "can't at the end of the document" do
      doc = structure_doc()
      refute Structure.can_split(doc, 97)
    end

    test "doesn't return true when split-off content doesn't fit in given node type" do
      s =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "chapter+"}},
            {"title", %{"content" => "text*"}},
            {"chapter", %{"content" => "title scene+"}},
            {"scene", %{"content" => "para+"}},
            {"para", %{"content" => "text*", "group" => "block"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => []
        })

      doc =
        sn(s, "doc", [
          sn(s, "chapter", [
            sn(s, "title", [st(s, "title")]),
            sn(s, "scene", [sn(s, "para", [st(s, "scene")])])
          ])
        ])

      refute Structure.can_split(doc, 4, 1, [%{type: s.nodes["scene"]}])
    end
  end

  # ── liftTarget tests ────────────────────────────────────────────────

  describe "liftTarget" do
    test "can't at the start of the doc" do
      doc = structure_doc()
      r = srange(doc, 0)
      refute r && Structure.lift_target(r)
    end

    test "can't in the heading" do
      doc = structure_doc()
      r = srange(doc, 3)
      refute r && Structure.lift_target(r)
    end

    test "can't in a subsection para" do
      doc = structure_doc()
      r = srange(doc, 52)
      refute r && Structure.lift_target(r)
    end

    test "can't in a figure caption" do
      doc = structure_doc()
      r = srange(doc, 70)
      refute r && Structure.lift_target(r)
    end

    test "can from a quote" do
      doc = structure_doc()
      r = srange(doc, 76)
      assert r && Structure.lift_target(r)
    end

    test "can't in a section head" do
      doc = structure_doc()
      r = srange(doc, 86)
      refute r && Structure.lift_target(r)
    end

    test "notices unliftable content after or before" do
      s =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "section+"}},
            {"section", %{"content" => "heading? p+"}},
            {"heading", %{"content" => "p+"}},
            {"p", %{"content" => "text*"}},
            {"text", %{"group" => "inline"}}
          ],
          "marks" => []
        })

      p_node = sn(s, "p", [st(s, "A")])

      doc =
        sn(s, "doc", [
          sn(s, "section", [
            sn(s, "heading", [p_node, p_node, p_node]),
            p_node
          ])
        ])

      # Position 3 -> first p inside heading
      r1 = ResolvedPos.block_range(Node.resolve(doc, 3))
      assert Structure.lift_target(r1) == nil

      # Position 6 -> second p inside heading
      r2 = ResolvedPos.block_range(Node.resolve(doc, 6))
      assert Structure.lift_target(r2) == nil

      # Range from 3 to 6
      r3 = ResolvedPos.block_range(Node.resolve(doc, 3), Node.resolve(doc, 6))
      assert Structure.lift_target(r3) == nil

      # Position 9 -> third p inside heading
      r4 = ResolvedPos.block_range(Node.resolve(doc, 9))
      assert Structure.lift_target(r4) == 1
    end
  end

  # ── findWrapping tests ─────────────────────────────────────────────

  describe "findWrapping" do
    test "can wrap the whole doc in a section" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 0, 92)
      assert r && Structure.find_wrapping(r, s.nodes["sect"])
    end

    test "can't wrap a head before a para in a section" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 4, 4)
      refute r && Structure.find_wrapping(r, s.nodes["sect"])
    end

    test "can wrap a top paragraph in a quote" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 8, 8)
      assert r && Structure.find_wrapping(r, s.nodes["quote"])
    end

    test "can't wrap a section head in a quote" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 18, 18)
      refute r && Structure.find_wrapping(r, s.nodes["quote"])
    end

    test "can wrap a figure in a quote" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 55, 74)
      assert r && Structure.find_wrapping(r, s.nodes["quote"])
    end

    test "can't wrap a head in a figure" do
      doc = structure_doc()
      s = structure_schema()
      r = srange(doc, 90, 90)
      refute r && Structure.find_wrapping(r, s.nodes["figure"])
    end
  end

  # ── lift tests (from test-trans.ts) ────────────────────────────────

  describe "lift" do
    defp do_lift({doc_node, doc_tags}, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      from_rpos = Node.resolve(doc_node, a_pos)
      to_rpos = Node.resolve(doc_node, b_pos)
      range = ResolvedPos.block_range(from_rpos, to_rpos)

      target = Structure.lift_target(range)
      tr = Transform.new(doc_node) |> Transform.lift(range, target)
      test_transform(tr, expect)
    end

    test "can lift a block out of the middle of its parent" do
      do_lift(
        doc([blockquote([p(["<before>one"]), p(["<a>two"]), p(["<after>three"])])]),
        doc([blockquote([p(["<before>one"])]), p(["<a>two"]), blockquote([p(["<after>three"])])])
      )
    end

    test "can lift a block from the start of its parent" do
      do_lift(
        doc([blockquote([p(["<a>two"]), p(["<after>three"])])]),
        doc([p(["<a>two"]), blockquote([p(["<after>three"])])])
      )
    end

    test "can lift a block from the end of its parent" do
      do_lift(
        doc([blockquote([p(["<before>one"]), p(["<a>two"])])]),
        doc([blockquote([p(["<before>one"])]), p(["<a>two"])])
      )
    end

    test "can lift a single child" do
      do_lift(
        doc([blockquote([p(["<a>t<in>wo"])])]),
        doc([p(["<a>t<in>wo"])])
      )
    end

    test "can lift multiple blocks" do
      do_lift(
        doc([blockquote([blockquote([p(["on<a>e"]), p(["tw<b>o"])]), p(["three"])])]),
        doc([blockquote([p(["on<a>e"]), p(["tw<b>o"]), p(["three"])])])
      )
    end

    test "finds a valid range from a lopsided selection" do
      do_lift(
        doc([p(["start"]), blockquote([blockquote([p(["a"]), p(["<a>b"])]), p(["<b>c"])])]),
        doc([p(["start"]), blockquote([p(["a"]), p(["<a>b"])]), p(["<b>c"])])
      )
    end

    test "can lift from a nested node" do
      do_lift(
        doc([
          blockquote([
            blockquote([
              p(["<1>one"]),
              p(["<a>two"]),
              p(["<3>three"]),
              p(["<b>four"]),
              p(["<5>five"])
            ])
          ])
        ]),
        doc([
          blockquote([
            blockquote([p(["<1>one"])]),
            p(["<a>two"]),
            p(["<3>three"]),
            p(["<b>four"]),
            blockquote([p(["<5>five"])])
          ])
        ])
      )
    end

    test "can lift from a list" do
      do_lift(
        doc([ul([li([p(["one"])]), li([p(["two<a>"])]), li([p(["three"])])])]),
        doc([ul([li([p(["one"])])]), p(["two<a>"]), ul([li([p(["three"])])])])
      )
    end

    test "can lift from the end of a list" do
      do_lift(
        doc([ul([li([p(["a"])]), li([p(["b<a>"])])])]),
        doc([ul([li([p(["a"])])]), p(["b<a>"])])
      )
    end
  end

  # ── wrap tests (from test-trans.ts) ────────────────────────────────

  describe "wrap" do
    defp do_wrap({doc_node, doc_tags}, expect, type_name, _attrs \\ nil) do
      Process.put(:_pm_test_before_tags, doc_tags)
      schema = doc_node.type.schema

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      from_rpos = Node.resolve(doc_node, a_pos)
      to_rpos = Node.resolve(doc_node, b_pos)
      range = ResolvedPos.block_range(from_rpos, to_rpos)

      wrappers = Structure.find_wrapping(range, schema.nodes[type_name])
      tr = Transform.new(doc_node) |> Transform.wrap(range, wrappers)
      test_transform(tr, expect)
    end

    test "can wrap in a blockquote" do
      do_wrap(
        doc([p(["one"]), p(["<a>two"]), p(["three"])]),
        doc([p(["one"]), blockquote([p(["<a>two"])]), p(["three"])]),
        "blockquote"
      )
    end

    test "can wrap two paragraphs" do
      do_wrap(
        doc([p(["one<1>"]), p(["<a>two"]), p(["<b>three"]), p(["four<4>"])]),
        doc([p(["one<1>"]), blockquote([p(["<a>two"]), p(["three"])]), p(["four<4>"])]),
        "blockquote"
      )
    end

    test "can wrap in a list" do
      do_wrap(
        doc([p(["<a>one"]), p(["<b>two"])]),
        doc([ol([li([p(["<a>one"]), p(["<b>two"])])])]),
        "ordered_list"
      )
    end

    test "can wrap in a nested list" do
      do_wrap(
        doc([
          ol([
            li([p(["<1>one"])]),
            li([p(["..."]), p(["<a>two"]), p(["<b>three"])]),
            li([p(["<4>four"])])
          ])
        ]),
        doc([
          ol([
            li([p(["<1>one"])]),
            li([p(["..."]), ol([li([p(["<a>two"]), p(["<b>three"])])])]),
            li([p(["<4>four"])])
          ])
        ]),
        "ordered_list"
      )
    end

    test "includes half-covered parent nodes" do
      do_wrap(
        doc([blockquote([p(["<1>one"]), p(["two<a>"])]), p(["three<b>"])]),
        doc([blockquote([blockquote([p(["<1>one"]), p(["two<a>"])]), p(["three<b>"])])]),
        "blockquote"
      )
    end
  end

  # ── split tests (from test-trans.ts) ───────────────────────────────

  describe "split" do
    defp do_split({doc_node, doc_tags}, expect, depth \\ nil, types_after \\ nil) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      depth = depth || 1

      tr = Transform.new(doc_node) |> Transform.split(a_pos, depth, types_after)
      test_transform(tr, expect)
    end

    test "can split a textblock" do
      do_split(
        doc([p(["foo<a>bar"])]),
        doc([p(["foo"]), p(["<a>bar"])])
      )
    end

    test "correctly maps positions" do
      do_split(
        doc([p(["<1>a"]), p(["<2>foo<a>bar<3>"]), p(["<4>b"])]),
        doc([p(["<1>a"]), p(["<2>foo"]), p(["<a>bar<3>"]), p(["<4>b"])])
      )
    end

    test "can split two deep" do
      do_split(
        doc([blockquote([blockquote([p(["foo<a>bar"])])]), p(["after<1>"])]),
        doc([
          blockquote([blockquote([p(["foo"])]), blockquote([p(["<a>bar"])])]),
          p(["after<1>"])
        ]),
        2
      )
    end

    test "can split three deep" do
      do_split(
        doc([blockquote([blockquote([p(["foo<a>bar"])])]), p(["after<1>"])]),
        doc([
          blockquote([blockquote([p(["foo"])])]),
          blockquote([blockquote([p(["<a>bar"])])]),
          p(["after<1>"])
        ]),
        3
      )
    end

    test "can split at end" do
      do_split(
        doc([blockquote([p(["hi<a>"])])]),
        doc([blockquote([p(["hi"]), p(["<a>"])])])
      )
    end

    test "can split at start" do
      do_split(
        doc([blockquote([p(["<a>hi"])])]),
        doc([blockquote([p([]), p(["<a>hi"])])])
      )
    end

    test "can split inside a list item" do
      do_split(
        doc([ol([li([p(["one<1>"])]), li([p(["two<a>three"])]), li([p(["four<2>"])])])]),
        doc([
          ol([li([p(["one<1>"])]), li([p(["two"]), p(["<a>three"])]), li([p(["four<2>"])])])
        ])
      )
    end

    test "can split a list item" do
      do_split(
        doc([ol([li([p(["one<1>"])]), li([p(["two<a>three"])]), li([p(["four<2>"])])])]),
        doc([
          ol([
            li([p(["one<1>"])]),
            li([p(["two"])]),
            li([p(["<a>three"])]),
            li([p(["four<2>"])])
          ])
        ]),
        2
      )
    end

    test "respects the type param" do
      schema = test_schema()

      do_split(
        doc([h1(["hell<a>o!"])]),
        doc([h1(["hell"]), p(["<a>o!"])]),
        nil,
        [%{type: schema.nodes["paragraph"]}]
      )
    end

    test "preserves content constraints before" do
      assert_raise ProsemirrorEx.Transform.TransformError, fn ->
        {doc_node, _doc_tags} = doc([blockquote([p(["x"])])])
        # Position right after blockquote open, before p
        # Tag <a> at start of blockquote content = after blockquote opening
        a_pos = 1
        Transform.new(doc_node) |> Transform.split(a_pos)
      end
    end

    test "preserves content constraints after" do
      assert_raise ProsemirrorEx.Transform.TransformError, fn ->
        {doc_node, _doc_tags} = doc([blockquote([p(["x"])])])
        # Position right before blockquote close, after p
        # blockquote open at 0, p open at 1, x at 2, p close at 3, blockquote close at 4
        a_pos = 4
        Transform.new(doc_node) |> Transform.split(a_pos)
      end
    end
  end

  # ── setBlockType tests (from test-trans.ts) ────────────────────────

  describe "setBlockType" do
    defp do_set_block_type({doc_node, doc_tags}, expect, node_type_name, attrs \\ nil) do
      Process.put(:_pm_test_before_tags, doc_tags)
      schema = doc_node.type.schema

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      tr =
        Transform.new(doc_node)
        |> Transform.set_block_type(a_pos, b_pos, schema.nodes[node_type_name], attrs)

      test_transform(tr, expect)
    end

    test "can change a single textblock" do
      do_set_block_type(
        doc([p(["am<a> i"])]),
        doc([h2(["am i"])]),
        "heading",
        %{"level" => 2}
      )
    end

    test "can change multiple blocks" do
      do_set_block_type(
        doc([h1(["<a>hello"]), p(["there"]), p(["<b>you"]), p(["end"])]),
        doc([pre(["hello"]), pre(["there"]), pre(["you"]), p(["end"])]),
        "code_block"
      )
    end

    test "can change a wrapped block" do
      do_set_block_type(
        doc([blockquote([p(["one<a>"]), p(["two<b>"])])]),
        doc([blockquote([h1(["one<a>"]), h1(["two<b>"])])]),
        "heading",
        %{"level" => 1}
      )
    end

    test "clears markup when necessary" do
      do_set_block_type(
        doc([p(["hello<a> ", em(["world"])])]),
        doc([pre(["hello world"])]),
        "code_block"
      )
    end

    test "removes non-allowed nodes" do
      do_set_block_type(
        doc([p(["<a>one", img(), "two", img(), "three"])]),
        doc([pre(["onetwothree"])]),
        "code_block"
      )
    end

    test "only clears markup when needed" do
      do_set_block_type(
        doc([p(["hello<a> ", em(["world"])])]),
        doc([h1(["hello<a> ", em(["world"])])]),
        "heading",
        %{"level" => 1}
      )
    end

    test "works after another step" do
      {d, tags} = doc([p(["f<x>oob<y>ar"]), p(["baz<a>"])])
      Process.put(:_pm_test_before_tags, tags)

      x_pos = Map.fetch!(tags, "x")
      y_pos = Map.fetch!(tags, "y")

      tr = Transform.new(d) |> Transform.delete(x_pos, y_pos)
      mapped_a = ProsemirrorEx.Transform.Mapping.map(tr.mapping, Map.fetch!(tags, "a"))

      schema = d.type.schema

      tr =
        Transform.set_block_type(tr, mapped_a, mapped_a, schema.nodes["heading"], %{"level" => 1})

      {expected, _} = doc([p(["f<x><y>ar"]), h1(["baz<a>"])])

      assert Node.eq(tr.doc, expected),
             "Transform result doesn't match expected.\n\nGot:\n#{Node.debug_string(tr.doc)}\n\nExpected:\n#{Node.debug_string(expected)}"
    end

    test "skips nodes that can't be changed due to constraints" do
      do_set_block_type(
        doc([p(["<a>hello", img()]), p(["okay"]), ul([li([p(["foo<b>"])])])]),
        doc([pre(["<a>hello"]), pre(["okay"]), ul([li([p(["foo<b>"])])])]),
        "code_block"
      )
    end

    test "can base attributes on previous attributes" do
      {d, tags} = doc(["<a>", h1(["a"]), p(["b"]), "<b>"])
      Process.put(:_pm_test_before_tags, tags)

      a_pos = Map.fetch!(tags, "a")
      b_pos = Map.fetch!(tags, "b")
      schema = d.type.schema

      tr =
        Transform.new(d)
        |> Transform.set_block_type(a_pos, b_pos, schema.nodes["heading"], fn node ->
          level = Map.get(node.attrs || %{}, "level", 0)
          %{"level" => level + 1}
        end)

      {expected, _} = doc([h2(["a"]), h1(["b"])])
      assert Node.eq(tr.doc, expected)
    end
  end

  # ── setNodeMarkup tests (from test-trans.ts) ──────────────────────

  describe "setNodeMarkup" do
    defp do_set_node_markup({doc_node, doc_tags}, expect, type_name, attrs) do
      Process.put(:_pm_test_before_tags, doc_tags)
      schema = doc_node.type.schema

      a_pos = Map.fetch!(doc_tags, "a")

      tr =
        Transform.new(doc_node)
        |> Transform.set_node_markup(a_pos, schema.nodes[type_name], attrs)

      test_transform(tr, expect)
    end

    test "can change a textblock" do
      do_set_node_markup(
        doc(["<a>", p(["foo"])]),
        doc([h1(["foo"])]),
        "heading",
        %{"level" => 1}
      )
    end

    test "can change an inline node" do
      do_set_node_markup(
        doc([p(["foo<a>", img(), "bar"])]),
        doc([p(["foo", img(%{"src" => "bar", "alt" => "y"}), "bar"])]),
        "image",
        %{"src" => "bar", "alt" => "y"}
      )
    end
  end

  # ── join tests (from test-trans.ts) ────────────────────────────────

  describe "join" do
    defp do_join({doc_node, doc_tags}, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      tr = Transform.new(doc_node) |> Transform.join(a_pos)
      test_transform(tr, expect)
    end

    test "can join blocks" do
      do_join(
        doc([blockquote([p(["<before>a"])]), "<a>", blockquote([p(["b"])]), p(["after<after>"])]),
        doc([blockquote([p(["<before>a"]), "<a>", p(["b"])]), p(["after<after>"])])
      )
    end

    test "can join compatible blocks" do
      do_join(
        doc([h1(["foo"]), "<a>", p(["bar"])]),
        doc([h1(["foobar"])])
      )
    end

    test "can join nested blocks" do
      do_join(
        doc([
          blockquote([
            blockquote([p(["a"]), p(["b<before>"])]),
            "<a>",
            blockquote([p(["c"]), p(["d<after>"])])
          ])
        ]),
        doc([
          blockquote([
            blockquote([p(["a"]), p(["b<before>"]), "<a>", p(["c"]), p(["d<after>"])])
          ])
        ])
      )
    end

    test "can join lists" do
      do_join(
        doc([ol([li([p(["one"])]), li([p(["two"])])]), "<a>", ol([li([p(["three"])])])]),
        doc([ol([li([p(["one"])]), li([p(["two"])]), "<a>", li([p(["three"])])])])
      )
    end

    test "can join list items" do
      do_join(
        doc([ol([li([p(["one"])]), li([p(["two"])]), "<a>", li([p(["three"])])])]),
        doc([ol([li([p(["one"])]), li([p(["two"]), "<a>", p(["three"])])])])
      )
    end

    test "can join textblocks" do
      do_join(
        doc([p(["foo"]), "<a>", p(["bar"])]),
        doc([p(["foo<a>bar"])])
      )
    end
  end

  # ── canJoin + joinPoint tests ──────────────────────────────────────

  describe "canJoin" do
    test "returns true for joinable blocks" do
      {doc_node, tags} = doc([p(["foo"]), "<a>", p(["bar"])])
      assert Structure.can_join(doc_node, Map.fetch!(tags, "a"))
    end

    test "returns true for joinable block quotes" do
      {doc_node, tags} =
        doc([blockquote([p(["a"])]), "<a>", blockquote([p(["b"])])])

      assert Structure.can_join(doc_node, Map.fetch!(tags, "a"))
    end
  end

  # ── insertPoint / dropPoint tests ──────────────────────────────────

  describe "insertPoint" do
    test "finds insert point at valid position" do
      {doc_node, _} = doc([p(["hello"])])
      schema = doc_node.type.schema
      # At beginning of doc, a paragraph can be inserted
      result = Structure.insert_point(doc_node, 0, schema.nodes["paragraph"])
      assert result == 0
    end

    test "finds insert point at end of doc" do
      {doc_node, _} = doc([p(["hello"])])
      schema = doc_node.type.schema
      # At end of doc (after paragraph), a paragraph can be inserted
      result = Structure.insert_point(doc_node, doc_node.content.size, schema.nodes["paragraph"])
      assert result == doc_node.content.size
    end
  end

  describe "dropPoint" do
    test "returns pos for empty slice" do
      {doc_node, _} = doc([p(["hello"])])
      result = Structure.drop_point(doc_node, 3, Slice.empty())
      assert result == 3
    end
  end
end
