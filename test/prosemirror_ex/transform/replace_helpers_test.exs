defmodule ProsemirrorEx.Transform.ReplaceHelpersTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.Transform
  alias ProsemirrorEx.Model.{Node, Slice, Fragment, Schema, NodeType}

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

  # ── replace tests ──────────────────────────────────────────────────

  describe "replace" do
    defp repl({doc_node, doc_tags}, source, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      slice =
        case source do
          nil ->
            Slice.empty()

          %Slice{} = s ->
            s

          {source_node, source_tags} ->
            a_pos = Map.fetch!(source_tags, "a")
            b_pos = Map.fetch!(source_tags, "b")
            Node.slice(source_node, a_pos, b_pos)
        end

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      tr = Transform.new(doc_node)
      tr = Transform.replace(tr, a_pos, b_pos, slice)
      test_transform(tr, expect)
    end

    test "can delete text" do
      repl(
        doc([p(["hell<a>o y<b>ou"])]),
        nil,
        doc([p(["hell<a><b>ou"])])
      )
    end

    test "can join blocks" do
      repl(
        doc([p(["hell<a>o"]), p(["y<b>ou"])]),
        nil,
        doc([p(["hell<a><b>ou"])])
      )
    end

    test "can delete right-leaning lopsided regions" do
      repl(
        doc([blockquote([p(["ab<a>c"])]), "<b>", p(["def"])]),
        nil,
        doc([blockquote([p(["ab<a>"])]), "<b>", p(["def"])])
      )
    end

    test "can delete left-leaning lopsided regions" do
      repl(
        doc([p(["abc"]), "<a>", blockquote([p(["d<b>ef"])])]),
        nil,
        doc([p(["abc"]), "<a>", blockquote([p(["<b>ef"])])])
      )
    end

    test "can overwrite text" do
      repl(
        doc([p(["hell<a>o y<b>ou"])]),
        doc([p(["<a>i k<b>"])]),
        doc([p(["hell<a>i k<b>ou"])])
      )
    end

    test "can insert text" do
      repl(
        doc([p(["hell<a><b>o"])]),
        doc([p(["<a>i k<b>"])]),
        doc([p(["helli k<a><b>o"])])
      )
    end

    test "can add a textblock" do
      repl(
        doc([p(["hello<a>you"])]),
        doc(["<a>", p(["there"]), "<b>"]),
        doc([p(["hello"]), p(["there"]), p(["<a>you"])])
      )
    end

    test "can insert while joining textblocks" do
      repl(
        doc([h1(["he<a>llo"]), p(["arg<b>!"])]),
        doc([p(["1<a>2<b>3"])]),
        doc([h1(["he2!"])])
      )
    end

    test "will match open list items" do
      repl(
        doc([ol([li([p(["one<a>"])]), li([p(["three"])])])]),
        doc([ol([li([p(["<a>half"])]), li([p(["two"])]), "<b>"])]),
        doc([ol([li([p(["onehalf"])]), li([p(["two"])]), li([p(["three"])])])])
      )
    end

    test "merges blocks across deleted content" do
      repl(
        doc([p(["a<a>"]), p(["b"]), p(["<b>c"])]),
        nil,
        doc([p(["a<a><b>c"])])
      )
    end

    test "can merge text down from nested nodes" do
      repl(
        doc([h1(["wo<a>ah"]), blockquote([p(["ah<b>ha"])])]),
        nil,
        doc([h1(["wo<a><b>ha"])])
      )
    end

    test "can merge text up into nested nodes" do
      repl(
        doc([blockquote([p(["foo<a>bar"])]), p(["middle"]), h1(["quux<b>baz"])]),
        nil,
        doc([blockquote([p(["foo<a><b>baz"])])])
      )
    end

    test "will join multiple levels when possible" do
      repl(
        doc([
          blockquote([
            ul([
              li([p(["a"])]),
              li([p(["b<a>"])]),
              li([p(["c"])]),
              li([p(["<b>d"])]),
              li([p(["e"])])
            ])
          ])
        ]),
        nil,
        doc([
          blockquote([
            ul([li([p(["a"])]), li([p(["b<a><b>d"])]), li([p(["e"])])])
          ])
        ])
      )
    end

    test "can replace a piece of text" do
      repl(
        doc([p(["he<before>llo<a> w<after>orld"])]),
        doc([p(["<a> big<b>"])]),
        doc([p(["he<before>llo big w<after>orld"])])
      )
    end

    test "respects open empty nodes at the edges" do
      repl(
        doc([p(["one<a>two"])]),
        doc([p(["a<a>"]), p(["hello"]), p(["<b>b"])]),
        doc([p(["one"]), p(["hello"]), p(["<a>two"])])
      )
    end

    test "can completely overwrite a paragraph" do
      repl(
        doc([p(["one<a>"]), p(["t<inside>wo"]), p(["<b>three<end>"])]),
        doc([p(["a<a>"]), p(["TWO"]), p(["<b>b"])]),
        doc([p(["one<a>"]), p(["TWO"]), p(["<inside>three<end>"])])
      )
    end

    test "joins marks" do
      repl(
        doc([p(["foo ", em(["bar<a>baz"]), "<b> quux"])]),
        doc([p(["foo ", em(["xy<a>zzy"]), " foo<b>"])]),
        doc([p(["foo ", em(["barzzy"]), " foo quux"])])
      )
    end

    test "can replace text with a break" do
      repl(
        doc([p(["foo<a>b<inside>b<b>bar"])]),
        doc([p(["<a>", br(), "<b>"])]),
        doc([p(["foo", br(), "<inside>bar"])])
      )
    end

    test "can join different blocks" do
      repl(
        doc([h1(["hell<a>o"]), p(["by<b>e"])]),
        nil,
        doc([h1(["helle"])])
      )
    end

    test "can delete the whole document" do
      repl(
        doc(["<a>", h1(["hi"]), p(["you"]), "<b>"]),
        nil,
        doc([p([])])
      )
    end

    test "can insert into an empty block" do
      repl(
        doc([p(["a"]), p(["<a>"]), p(["b"])]),
        doc([p(["x<a>y<b>z"])]),
        doc([p(["a"]), p(["y<a>"]), p(["b"])])
      )
    end

    test "doesn't change the nesting of blocks after the selection" do
      repl(
        doc([p(["one<a>"]), p(["two"]), p(["three"])]),
        doc([p(["outside<a>"]), blockquote([p(["inside<b>"])])]),
        doc([p(["one"]), blockquote([p(["inside"])]), p(["two"]), p(["three"])])
      )
    end

    test "can close a parent node" do
      repl(
        doc([blockquote([p(["b<a>c"]), p(["d<b>e"]), p(["f"])])]),
        doc([blockquote([p(["x<a>y"])]), p(["after"]), "<b>"]),
        doc([blockquote([p(["b<a>y"])]), p(["after"]), blockquote([p(["<b>e"]), p(["f"])])])
      )
    end

    test "accepts lopsided regions" do
      repl(
        doc([blockquote([p(["b<a>c"]), p(["d<b>e"]), p(["f"])])]),
        doc([blockquote([p(["x<a>y"])]), p(["z<b>"])]),
        doc([blockquote([p(["b<a>y"])]), p(["z<b>e"]), blockquote([p(["f"])])])
      )
    end

    test "can close nested parent nodes" do
      repl(
        doc([
          blockquote([
            blockquote([p(["one"]), p(["tw<a>o"]), p(["t<b>hree<3>"]), p(["four<4>"])])
          ])
        ]),
        doc([ol([li([p(["hello<a>world"])]), li([p(["bye"])])]), p(["ne<b>xt"])]),
        doc([
          blockquote([
            blockquote([
              p(["one"]),
              p(["tw<a>world"]),
              ol([li([p(["bye"])])]),
              p(["ne<b>hree<3>"]),
              p(["four<4>"])
            ])
          ])
        ])
      )
    end

    test "will close open nodes to the right" do
      repl(
        doc([p(["x"]), "<a>"]),
        doc(["<a>", ul([li([p(["a"])]), li(["<b>", p(["b"])])])]),
        doc([p(["x"]), ul([li([p(["a"])]), li([p([])])]), "<a>"])
      )
    end

    test "preserves an empty parent to the left" do
      repl(
        doc([blockquote(["<a>", p(["hi"])]), p(["b<b>x"])]),
        doc([p(["<a>hi<b>"])]),
        doc([blockquote([p(["hix"])])])
      )
    end

    test "drops an empty parent to the right" do
      repl(
        doc([p(["x<a>hi"]), blockquote([p(["yy"]), "<b>"]), p(["c"])]),
        doc([p(["<a>hi<b>"])]),
        doc([p(["xhi"]), p(["c"])])
      )
    end

    test "can restore a list parent" do
      repl(
        doc([h1(["hell<a>o"]), "<b>"]),
        doc([ol([li([p(["on<a>e"])]), li([p(["tw<b>o"])])])]),
        doc([h1(["helle"]), ol([li([p(["tw"])])])])
      )
    end

    test "can restore a list parent and join text after it" do
      repl(
        doc([h1(["hell<a>o"]), p(["yo<b>u"])]),
        doc([ol([li([p(["on<a>e"])]), li([p(["tw<b>o"])])])]),
        doc([h1(["helle"]), ol([li([p(["twu"])])])])
      )
    end

    test "does nothing when given an unfittable slice" do
      {p_node, _} = p(["<a>x"])
      slice = Slice.new(Fragment.from([elem(blockquote([]), 0), elem(hr(), 0)]), 0, 0)

      Process.put(:_pm_test_before_tags, %{"a" => 1})

      a_pos = 1
      tr = Transform.new(p_node)
      tr = Transform.replace(tr, a_pos, a_pos, slice)
      assert Node.eq(tr.doc, p_node)
    end

    test "doesn't drop content when things only fit at the top level" do
      repl(
        doc([p(["foo"]), "<a>", p(["bar<b>"])]),
        ol([li([p(["<a>a"])]), li([p(["b<b>"])])]),
        doc([p(["foo"]), p(["a"]), ol([li([p(["b"])])])])
      )
    end

    test "preserves openEnd when top isn't placed" do
      {source_node, _} = doc([ul([li([p(["ABCD"])]), li([p(["EFGH"])])])])

      repl(
        doc([ul([li([p(["ab<a>cd"])]), li([p(["ef<b>gh"])])])]),
        Node.slice(source_node, 5, 13, true),
        doc([ul([li([p(["abCD"])]), li([p(["EFgh"])])])])
      )
    end

    test "will auto-close a list item when it fits in a list" do
      repl(
        doc([ul([li([p(["foo"])]), "<a>", li([p(["bar"])])])]),
        ul([li([p(["a<a>bc"])]), li([p(["de<b>f"])])]),
        doc([ul([li([p(["foo"])]), li([p(["bc"])]), li([p(["de"])]), li([p(["bar"])])])])
      )
    end

    test "finds the proper openEnd value when unwrapping a deep slice" do
      {source_node, _} = doc([blockquote([blockquote([blockquote([p(["hi"])])])])])

      repl(
        doc(["<a>", p([]), "<b>"]),
        Node.slice(source_node, 3, 6, true),
        doc([p(["hi"])])
      )
    end
  end

  # ── insert tests ──────────────────────────────────────────────────

  describe "insert" do
    defp ins({doc_node, doc_tags}, nodes, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      tr = Transform.new(doc_node)
      tr = Transform.insert(tr, a_pos, nodes)
      test_transform(tr, expect)
    end

    test "can insert a break" do
      schema = test_schema()

      ins(
        doc([p(["hello<a>there"])]),
        Schema.node(schema, "hard_break"),
        doc([p(["hello", br(), "<a>there"])])
      )
    end

    test "can insert an empty paragraph at the top" do
      schema = test_schema()

      ins(
        doc([p(["one"]), "<a>", p(["two<2>"])]),
        Schema.node(schema, "paragraph"),
        doc([p(["one"]), p([]), "<a>", p(["two<2>"])])
      )
    end

    test "can insert two block nodes" do
      schema = test_schema()

      ins(
        doc([p(["one"]), "<a>", p(["two<2>"])]),
        [
          Schema.node(schema, "paragraph", nil, [Schema.text(schema, "hi")]),
          Schema.node(schema, "horizontal_rule")
        ],
        doc([p(["one"]), p(["hi"]), hr(), "<a>", p(["two<2>"])])
      )
    end

    test "can insert at the end of a blockquote" do
      schema = test_schema()

      ins(
        doc([blockquote([p(["he<before>y"]), "<a>"]), p(["after<after>"])]),
        Schema.node(schema, "paragraph"),
        doc([blockquote([p(["he<before>y"]), p([])]), p(["after<after>"])])
      )
    end

    test "can insert at the start of a blockquote" do
      schema = test_schema()

      ins(
        doc([blockquote(["<a>", p(["he<1>y"])]), p(["after<2>"])]),
        Schema.node(schema, "paragraph"),
        doc([blockquote([p([]), "<a>", p(["he<1>y"])]), p(["after<2>"])])
      )
    end

    test "will wrap a node with the suitable parent" do
      schema = test_schema()
      list_item_type = Schema.node_type(schema, "list_item")
      li_node = NodeType.create_and_fill(list_item_type)

      ins(
        doc([p(["foo<a>bar"])]),
        li_node,
        doc([p(["foo"]), ol([li([p([])])]), p(["bar"])])
      )
    end
  end

  # ── delete tests ──────────────────────────────────────────────────

  describe "delete" do
    defp del({doc_node, doc_tags}, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.fetch!(doc_tags, "b")
      tr = Transform.new(doc_node)
      tr = Transform.delete(tr, a_pos, b_pos)
      test_transform(tr, expect)
    end

    test "can delete a word" do
      del(
        doc([p(["<1>one"]), "<a>", p(["tw<2>o"]), "<b>", p(["<3>three"])]),
        doc([p(["<1>one"]), "<a><2>", p(["<3>three"])])
      )
    end

    test "preserves content constraints" do
      del(
        doc([blockquote(["<a>", p(["hi"]), "<b>"]), p(["x"])]),
        doc([blockquote([p([])]), p(["x"])])
      )
    end

    test "preserves positions after the range" do
      del(
        doc([blockquote([p(["a"]), "<a>", p(["b"]), "<b>"]), p(["c<1>"])]),
        doc([blockquote([p(["a"])]), p(["c<1>"])])
      )
    end

    test "doesn't join incompatible nodes" do
      del(
        doc([pre(["fo<a>o"]), p(["b<b>ar", img()])]),
        doc([pre(["fo"]), p(["ar", img()])])
      )
    end

    test "doesn't join when marks are incompatible" do
      del(
        doc([pre(["fo<a>o"]), p([em(["b<b>ar"])])]),
        doc([pre(["fo"]), p([em(["ar"])])])
      )
    end
  end

  # ── replaceRange tests ──────────────────────────────────────────────

  describe "replaceRange" do
    defp replace_range({doc_node, doc_tags}, source, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      slice =
        case source do
          nil ->
            Slice.empty()

          %Slice{} = s ->
            s

          {source_node, source_tags} ->
            a_pos = Map.fetch!(source_tags, "a")
            b_pos = Map.fetch!(source_tags, "b")
            Node.slice(source_node, a_pos, b_pos, true)
        end

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      tr = Transform.new(doc_node)
      tr = Transform.replace_range(tr, a_pos, b_pos, slice)
      test_transform(tr, expect)
    end

    test "replaces inline content" do
      replace_range(
        doc([p(["foo<a>b<b>ar"])]),
        p(["<a>xx<b>"]),
        doc([p(["foo<a>xx<b>ar"])])
      )
    end

    test "replaces an empty paragraph with a heading" do
      replace_range(
        doc([p(["<a>"])]),
        doc([h1(["<a>text<b>"])]),
        doc([h1(["text"])])
      )
    end

    test "replaces a fully selected paragraph with a heading" do
      replace_range(
        doc([p(["<a>abc<b>"])]),
        doc([h1(["<a>text<b>"])]),
        doc([h1(["text"])])
      )
    end

    test "recreates a list when overwriting a paragraph" do
      replace_range(
        doc([p(["<a>"])]),
        doc([ul([li([p(["<a>foobar<b>"])])])]),
        doc([ul([li([p(["foobar"])])])])
      )
    end

    test "drops context when it doesn't fit" do
      replace_range(
        doc([ul([li([p(["<a>"])]), li([p(["b"])])])]),
        doc([h1(["<a>h<b>"])]),
        doc([ul([li([p(["h<a>"])]), li([p(["b"])])])])
      )
    end

    test "drops defining context when it matches the parent structure" do
      replace_range(
        doc([blockquote([p(["<a>"])])]),
        doc([blockquote([p(["<a>one<b>"])])]),
        doc([blockquote([p(["one"])])])
      )
    end

    test "can replace a node when endpoints are in different children" do
      replace_range(
        doc([
          p(["a"]),
          ul([li([p(["<a>b"])]), li([p(["c"]), blockquote([p(["d<b>"])])])]),
          p(["e"])
        ]),
        doc([h1(["<a>x<b>"])]),
        doc([p(["a"]), h1(["x"]), p(["e"])])
      )
    end

    test "keeps defining context when inserting at the start of a textblock" do
      replace_range(
        doc([p(["<a>foo"])]),
        doc([ul([li([p(["<a>one"])]), li([p(["two<b>"])])])]),
        doc([ul([li([p(["one"])]), li([p(["twofoo"])])])])
      )
    end

    test "drops defining context when it matches the parent structure in a nested context" do
      replace_range(
        doc([ul([li([p(["list1"]), blockquote([p(["<a>"])])])])]),
        doc([blockquote([p(["<a>one<b>"])])]),
        doc([ul([li([p(["list1"]), blockquote([p(["one"])])])])])
      )
    end

    test "closes open nodes at the start" do
      replace_range(
        doc(["<a>", p(["abc"]), "<b>"]),
        doc([ul([li(["<a>"])]), p(["def"]), "<b>"]),
        doc([ul([li([p([])])]), p(["def"])])
      )
    end
  end

  # ── replaceRangeWith tests ──────────────────────────────────────────

  describe "replaceRangeWith" do
    defp replace_range_with({doc_node, doc_tags}, node, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      tr = Transform.new(doc_node)
      tr = Transform.replace_range_with(tr, a_pos, b_pos, node)
      test_transform(tr, expect)
    end

    test "can insert an inline node" do
      {img_node, _} = img()

      replace_range_with(
        doc([p(["fo<a>o"])]),
        img_node,
        doc([p(["fo", img(), "<a>o"])])
      )
    end

    test "can replace content with an inline node" do
      {img_node, _} = img()

      replace_range_with(
        doc([p(["<a>fo<b>o"])]),
        img_node,
        doc([p(["<a>", img(), "o"])])
      )
    end

    test "can insert a block quote in the middle of text" do
      {hr_node, _} = hr()

      replace_range_with(
        doc([p(["foo<a>bar"])]),
        hr_node,
        doc([p(["foo"]), hr(), p(["bar"])])
      )
    end

    test "can replace empty parents with a block node" do
      {hr_node, _} = hr()

      replace_range_with(
        doc([blockquote([p(["<a>"])])]),
        hr_node,
        doc([blockquote([hr()])])
      )
    end

    test "can move an inserted block forward out of parent nodes" do
      {hr_node, _} = hr()

      replace_range_with(
        doc([h1(["foo<a>"])]),
        hr_node,
        doc([h1(["foo"]), hr()])
      )
    end

    test "can replace a block node with a block node" do
      {hr_node, _} = hr()

      replace_range_with(
        doc(["<a>", blockquote([p(["a"])]), "<b>"]),
        hr_node,
        doc([hr()])
      )
    end

    test "can replace a block node with an inline node" do
      {img_node, _} = img()

      replace_range_with(
        doc(["<a>", blockquote([p(["a"])]), "<b>"]),
        img_node,
        doc([p([img()])])
      )
    end

    test "can move an inserted block backward out of parent nodes" do
      {hr_node, _} = hr()

      replace_range_with(
        doc([p(["a"]), blockquote([p(["<a>b"])])]),
        hr_node,
        doc([p(["a"]), blockquote([hr(), p(["b"])])])
      )
    end
  end

  # ── deleteRange tests ──────────────────────────────────────────────

  describe "deleteRange" do
    defp del_range({doc_node, doc_tags}, expect) do
      Process.put(:_pm_test_before_tags, doc_tags)

      a_pos = Map.fetch!(doc_tags, "a")
      b_pos = Map.get(doc_tags, "b", a_pos)

      tr = Transform.new(doc_node)
      tr = Transform.delete_range(tr, a_pos, b_pos)
      test_transform(tr, expect)
    end

    test "deletes the given range" do
      del_range(
        doc([p(["fo<a>o"]), p(["b<b>ar"])]),
        doc([p(["fo<a><b>ar"])])
      )
    end

    test "doesn't delete parent nodes that can be empty" do
      del_range(
        doc([p(["<a>foo<b>"])]),
        doc([p(["<a><b>"])])
      )
    end

    test "is okay with deleting empty ranges" do
      del_range(
        doc([p(["<a><b>"])]),
        doc([p(["<a><b>"])])
      )
    end

    test "leaves wrapping textblock when deleting all text in it" do
      del_range(
        doc([p(["a"]), p(["<a>b<b>"])]),
        doc([p(["a"]), p([])])
      )
    end

    test "deletes empty parent nodes" do
      del_range(
        doc([blockquote([ul([li(["<a>", p(["foo"]), "<b>"])]), p(["x"])])]),
        doc([blockquote(["<a><b>", p(["x"])])])
      )
    end

    test "will delete a whole covered node even if selection ends are in different nodes" do
      del_range(
        doc([ul([li([p(["<a>foo"])]), li([p(["bar<b>"])])]), p(["hi"])]),
        doc([p(["hi"])])
      )
    end

    test "expands to cover the whole parent node" do
      del_range(
        doc([p(["a"]), blockquote([blockquote([p(["<a>foo"])]), p(["bar<b>"])]), p(["b"])]),
        doc([p(["a"]), p(["b"])])
      )
    end

    test "expands to cover the whole document" do
      del_range(
        doc([h1(["<a>foo"]), p(["bar"]), blockquote([p(["baz<b>"])])]),
        doc([p([])])
      )
    end

    test "doesn't expand beyond same-depth textblocks" do
      del_range(
        doc([h1(["<a>foo"]), p(["bar"]), p(["baz<b>"])]),
        doc([h1([])])
      )
    end

    test "deletes the open token when deleting from start to past end of block" do
      del_range(
        doc([h1(["<a>foo"]), p(["b<b>ar"])]),
        doc([p(["ar"])])
      )
    end

    test "doesn't delete the open token when the range end is at end of its own block" do
      del_range(
        doc([p(["one"]), h1(["<a>two"]), blockquote([p(["three<b>"])]), p(["four"])]),
        doc([p(["one"]), h1([]), p(["four"])])
      )
    end
  end
end
