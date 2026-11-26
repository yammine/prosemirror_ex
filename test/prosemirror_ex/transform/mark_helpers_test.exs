defmodule ProsemirrorEx.Transform.MarkHelpersTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.Transform
  alias ProsemirrorEx.Model.{Node, Schema, MarkType}

  # ── Test helper: testTransform equivalent ──────────────────────────

  defp test_transform(tr, {expect_node, expect_tags}) do
    # 1. The result doc should match the expected doc
    assert Node.eq(tr.doc, expect_node),
           "Transform result doesn't match expected.\n\nGot:\n#{inspect(tr.doc, pretty: true, limit: :infinity)}\n\nExpected:\n#{inspect(expect_node, pretty: true, limit: :infinity)}"

    # 2. Inverting the transform should produce the original doc
    inverted = invert_transform(tr)

    assert Node.eq(inverted.doc, Transform.before(tr)),
           "Inverted transform doesn't produce original doc"

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
      before_doc_tags = get_before_tags(tr)

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

  # Get tags from the before doc (stored via process dict during building)
  # Since we build the docs with tag helpers, we need to track them
  defp get_before_tags(_tr) do
    # Tags are embedded in the test flow; we pass them through the add/rem helpers
    Process.get(:_pm_test_before_tags, %{})
  end

  # ── addMark helpers ────────────────────────────────────────────────

  defp add({doc_node, doc_tags}, mark, expect) do
    Process.put(:_pm_test_before_tags, doc_tags)

    a_pos = Map.fetch!(doc_tags, "a")
    b_pos = Map.fetch!(doc_tags, "b")

    tr = Transform.new(doc_node)
    tr = Transform.add_mark(tr, a_pos, b_pos, mark)
    test_transform(tr, expect)
  end

  # ── removeMark helpers ─────────────────────────────────────────────

  defp rem_mark({doc_node, doc_tags}, mark, expect) do
    Process.put(:_pm_test_before_tags, doc_tags)

    a_pos = Map.fetch!(doc_tags, "a")
    b_pos = Map.fetch!(doc_tags, "b")

    tr = Transform.new(doc_node)
    tr = Transform.remove_mark(tr, a_pos, b_pos, mark)
    test_transform(tr, expect)
  end

  # ── addMark tests ──────────────────────────────────────────────────

  describe "addMark" do
    test "should add a mark" do
      add(
        doc([p(["hello <a>there<b>!"])]),
        MarkType.create(test_schema().marks["strong"]),
        doc([p(["hello ", strong(["there"]), "!"])])
      )
    end

    test "should only add a mark once" do
      add(
        doc([p(["hello ", strong(["<a>there"]), "!<b>"])]),
        MarkType.create(test_schema().marks["strong"]),
        doc([p(["hello ", strong(["there!"])])])
      )
    end

    test "should join overlapping marks" do
      add(
        doc([p(["one <a>two ", em(["three<b> four"])])]),
        MarkType.create(test_schema().marks["strong"]),
        doc([p(["one ", strong(["two ", em(["three"])]), em([" four"])])])
      )
    end

    test "should overwrite marks with different attributes" do
      schema = test_schema()
      new_link_mark = MarkType.create(schema.marks["link"], %{"href" => "bar"})

      add(
        doc([p(["this is a ", a(["<a>link<b>"])])]),
        new_link_mark,
        doc([p(["this is a ", a(%{"href" => "bar"}, ["link"])])])
      )
    end

    test "can add a mark in a nested node" do
      add(
        doc([
          p(["before"]),
          blockquote([p(["the variable is called <a>i<b>"])]),
          p(["after"])
        ]),
        MarkType.create(test_schema().marks["code"]),
        doc([
          p(["before"]),
          blockquote([p(["the variable is called ", code_mark(["i"])])]),
          p(["after"])
        ])
      )
    end

    test "can add a mark across blocks" do
      add(
        doc([
          p(["hi <a>this"]),
          blockquote([p(["is"])]),
          p(["a docu<b>ment"]),
          p(["!"])
        ]),
        MarkType.create(test_schema().marks["em"]),
        doc([
          p(["hi ", em(["this"])]),
          blockquote([p([em(["is"])])]),
          p([em(["a docu"]), "ment"]),
          p(["!"])
        ])
      )
    end

    test "does not remove non-excluded marks of the same type" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{}}
          ],
          "marks" => [
            {"comment", %{"excludes" => "", "attrs" => %{"id" => %{}}}}
          ]
        })

      text_node =
        Schema.text(schema, "hi", [MarkType.create(schema.marks["comment"], %{"id" => 10})])

      document = Schema.node(schema, "doc", nil, [text_node])

      tr = Transform.new(document)
      tr = Transform.add_mark(tr, 0, 2, MarkType.create(schema.marks["comment"], %{"id" => 20}))

      first_child = Node.first_child(tr.doc)
      assert length(first_child.marks) == 2
    end

    test "can remove multiple excluded marks" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{}}
          ],
          "marks" => [
            {"big", %{"excludes" => "small1 small2"}},
            {"small1", %{}},
            {"small2", %{}}
          ]
        })

      text_node =
        Schema.text(schema, "hi", [
          MarkType.create(schema.marks["small1"]),
          MarkType.create(schema.marks["small2"])
        ])

      document = Schema.node(schema, "doc", nil, [text_node])

      first_child = Node.first_child(document)
      assert length(first_child.marks) == 2

      tr = Transform.new(document)
      tr = Transform.add_mark(tr, 0, 2, MarkType.create(schema.marks["big"]))

      first_child = Node.first_child(tr.doc)
      assert length(first_child.marks) == 1
      assert hd(first_child.marks).type.name == "big"
    end
  end

  # ── removeMark tests ───────────────────────────────────────────────

  describe "removeMark" do
    test "can cut a gap" do
      rem_mark(
        doc([p([em(["hello <a>world<b>!"])])]),
        MarkType.create(test_schema().marks["em"]),
        doc([p([em(["hello "]), "world", em(["!"])])])
      )
    end

    test "doesn't do anything when there's no mark" do
      rem_mark(
        doc([p([em(["hello"]), " <a>world<b>!"])]),
        MarkType.create(test_schema().marks["em"]),
        doc([p([em(["hello"]), " <a>world<b>!"])])
      )
    end

    test "can remove marks from nested nodes" do
      rem_mark(
        doc([p([em(["one ", strong(["<a>two<b>"]), " three"])])]),
        MarkType.create(test_schema().marks["strong"]),
        doc([p([em(["one two three"])])])
      )
    end

    test "can remove a link" do
      schema = test_schema()

      rem_mark(
        doc([p(["<a>hello ", a(["link<b>"])])]),
        MarkType.create(schema.marks["link"], %{"href" => "foo"}),
        doc([p(["hello link"])])
      )
    end

    test "doesn't remove a non-matching link" do
      schema = test_schema()

      rem_mark(
        doc([p(["<a>hello ", a(["link<b>"])])]),
        MarkType.create(schema.marks["link"], %{"href" => "bar"}),
        doc([p(["hello ", a(["link"])])])
      )
    end

    test "can remove across blocks" do
      rem_mark(
        doc([
          blockquote([p([em(["much <a>em"])]), p([em(["here too"])])]),
          p(["between", em(["..."])]),
          p([em(["end<b>"])])
        ]),
        MarkType.create(test_schema().marks["em"]),
        doc([
          blockquote([p([em(["much "]), "em"]), p(["here too"])]),
          p(["between..."]),
          p(["end"])
        ])
      )
    end

    test "can remove everything" do
      rem_mark(
        doc([p(["<a>hello, ", em(["this is ", strong(["much"]), " ", a(["markup<b>"])])])]),
        nil,
        doc([p(["<a>hello, this is much markup"])])
      )
    end

    test "can remove more than one mark of the same type from a block" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "text*"}},
            {"text", %{}}
          ],
          "marks" => [
            {"comment", %{"excludes" => "", "attrs" => %{"id" => %{}}}}
          ]
        })

      text_node =
        Schema.text(schema, "hi", [
          MarkType.create(schema.marks["comment"], %{"id" => 1}),
          MarkType.create(schema.marks["comment"], %{"id" => 2})
        ])

      document = Schema.node(schema, "doc", nil, [text_node])

      first_child = Node.first_child(document)
      assert length(first_child.marks) == 2

      tr = Transform.new(document)
      # Use the MarkType to remove all marks of that type
      tr = Transform.remove_mark(tr, 0, 2, schema.marks["comment"])

      first_child = Node.first_child(tr.doc)
      assert length(first_child.marks) == 0
    end

    test "raises ArgumentError on unexpected mark value" do
      {doc_node, _} = doc([p([em(["hello"])])])

      assert_raise ArgumentError, fn ->
        Transform.new(doc_node) |> Transform.remove_mark(1, 6, "em")
      end
    end
  end

  # ── clearIncompatible tests ─────────────────────────────────────────

  describe "clearIncompatible" do
    test "removes disallowed nodes and marks when changing to code_block" do
      schema = test_schema()
      {doc_node, _} = doc([p(["one ", em(["two"]), img(), " three"])])

      tr =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["code_block"])

      {expected, _} = doc([p(["one two three"])])
      assert Node.eq(tr.doc, expected)
    end

    test "preserves allowed marks and nodes" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello ", strong([em(["world"])])])])

      tr =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["heading"])

      assert Node.eq(tr.doc, doc_node)
    end

    test "replaces \\n, \\r, and \\r\\n with spaces for non-pre parent" do
      schema = test_schema()
      {doc_node, _} = doc([pre(["a\nb\rc\r\nd"])])

      tr =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["paragraph"])

      {expected, _} = doc([pre(["a b c d"])])
      assert Node.eq(tr.doc, expected)
    end

    test "handles multi-byte UTF-8 and emoji before \\r\\n and \\n without offset corruption" do
      schema = test_schema()
      {doc_node, _} = doc([pre(["😀a\r\n🎉b\nc"])])

      tr =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["paragraph"])

      {expected, _} = doc([pre(["😀a 🎉b c"])])
      assert Node.eq(tr.doc, expected)
    end

    test "preserves allowed marks on spaces replacing newlines" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])

      doc_node =
        Schema.node(schema, "doc", nil, [
          Schema.node(schema, "paragraph", nil, [
            Schema.text(schema, "hi\nthere", [em_mark])
          ])
        ])

      tr =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["heading"])

      {expected, _} = doc([p([em(["hi there"])])])
      assert Node.eq(tr.doc, expected)
    end

    test "skips newline clearing when clear_newlines is false or parent is pre" do
      schema = test_schema()
      {doc_node, _} = doc([pre(["line1\nline2\r\nline3"])])

      tr_flag =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["paragraph"], nil, false)

      assert Node.eq(tr_flag.doc, doc_node)

      tr_pre =
        Transform.new(doc_node)
        |> Transform.clear_incompatible(0, schema.nodes["code_block"])

      assert Node.eq(tr_pre.doc, doc_node)
    end

    test "fills required trailing content when final_match is not valid_end" do
      schema =
        Schema.new(%{
          "nodes" => [
            {"doc", %{"content" => "box+"}},
            {"box", %{"content" => "heading paragraph+"}},
            {"heading", %{"content" => "text*"}},
            {"paragraph", %{"content" => "text*"}},
            {"text", %{}}
          ],
          "marks" => []
        })

      doc_node =
        Schema.node(schema, "doc", nil, [
          Schema.node(schema, "box", nil, [
            Schema.node(schema, "heading", nil, [Schema.text(schema, "Title")]),
            Schema.node(schema, "paragraph", nil, [Schema.text(schema, "Body")])
          ])
        ])

      # Use clear_incompatible with a content match that only matched heading,
      # forcing fill_before to add the required paragraph.
      heading_only_match =
        ProsemirrorEx.Model.ContentMatch.match_type(
          schema.nodes["box"].content_match,
          schema.nodes["heading"]
        )

      small_doc =
        ProsemirrorEx.Model.NodeType.create(schema.nodes["doc"], nil, [
          ProsemirrorEx.Model.NodeType.create(schema.nodes["box"], nil, [
            Schema.node(schema, "heading", nil, [Schema.text(schema, "Title")])
          ])
        ])

      tr =
        Transform.new(small_doc)
        |> Transform.clear_incompatible(0, schema.nodes["box"])

      assert Node.child_count(Node.first_child(tr.doc)) == 2
      assert Node.child(Node.first_child(tr.doc), 1).type.name == "paragraph"

      # Custom starting match (post-heading) keeps paragraph without needing heading
      para_only_box =
        ProsemirrorEx.Model.NodeType.create(schema.nodes["doc"], nil, [
          ProsemirrorEx.Model.NodeType.create(schema.nodes["box"], nil, [
            Schema.node(schema, "paragraph", nil, [Schema.text(schema, "Body")])
          ])
        ])

      tr_custom =
        Transform.new(para_only_box)
        |> Transform.clear_incompatible(0, schema.nodes["box"], heading_only_match)

      assert Node.eq(tr_custom.doc, para_only_box)
      assert doc_node != nil
    end

    test "raises ArgumentError when no node exists at pos" do
      schema = test_schema()
      {doc_node, _} = doc([p(["hello"])])

      assert_raise ArgumentError, fn ->
        Transform.new(doc_node)
        |> Transform.clear_incompatible(100, schema.nodes["paragraph"])
      end
    end
  end
end
