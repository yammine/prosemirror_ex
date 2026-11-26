defmodule ProsemirrorEx.Transform.TransformAlgosPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ProsemirrorEx.Model.{Fragment, MarkType, Node, Schema, Slice, Utf16}
  alias ProsemirrorEx.Schema.{Basic, List}
  alias ProsemirrorEx.Transform.{Step, Structure, Transform}

  defp full_schema do
    Schema.new(%{
      "nodes" => Basic.nodes() |> List.add_list_nodes("paragraph block*", "block"),
      "marks" => Basic.marks()
    })
  end

  # Collect all valid character-boundary UTF-16 positions inside a doc
  # (never landing inside a 2-unit surrogate pair).
  defp valid_positions(doc) do
    positions =
      Node.fold_descendants(doc, [0], fn node, pos, _parent, _index, acc ->
        if Node.is_text(node) do
          text_positions =
            node.text
            |> String.codepoints()
            |> Enum.scan(pos, fn cp, cur ->
              cur + Utf16.length(cp)
            end)

          {:skip, Enum.reverse(text_positions) ++ [pos | acc]}
        else
          [pos, pos + Node.node_size(node) | acc]
        end
      end)

    [doc.content.size | positions] |> Enum.uniq() |> Enum.sort()
  end

  defp valid_inline_positions(block_node, base_pos) do
    {positions, _} =
      Enum.reduce(block_node.content.content, {[base_pos], base_pos}, fn child, {acc, cur} ->
        if Node.is_text(child) do
          pts =
            child.text
            |> String.codepoints()
            |> Enum.scan(cur, fn cp, p -> p + Utf16.length(cp) end)

          {Enum.reverse(pts, acc), cur + Node.node_size(child)}
        else
          next = cur + Node.node_size(child)
          {[next | acc], next}
        end
      end)

    positions |> Enum.uniq() |> Enum.sort()
  end

  defp assert_transform_invariants(tr, original_doc) do
    # 1. Valid document according to schema
    Node.check(tr.doc)

    # 2. Invertibility restores original document
    inverted =
      Enum.reduce((length(tr.steps) - 1)..0//-1, Transform.new(tr.doc), fn i, acc ->
        step_struct = Enum.at(tr.steps, i)
        inverted_step = step_struct.__struct__.invert(step_struct, Enum.at(tr.docs, i))
        Transform.step(acc, inverted_step)
      end)

    assert Node.eq(inverted.doc, original_doc)

    # 3. Step JSON round-trip yields identical result document
    schema = original_doc.type.schema

    replayed =
      Enum.reduce(tr.steps, Transform.new(original_doc), fn step_struct, acc ->
        json = step_struct.__struct__.to_json(step_struct)
        restored = Step.from_json(schema, json)
        Transform.step(acc, restored)
      end)

    assert Node.eq(replayed.doc, tr.doc)
  end

  property "add_mark and remove_mark preserve invertibility, JSON round-trip, and schema validity across UTF-8/emoji docs" do
    schema = full_schema()

    text_gen =
      StreamData.map(
        StreamData.list_of(
          StreamData.member_of(["hello", "world", "😀", "🎉", "café", " "]),
          min_length: 1,
          max_length: 6
        ),
        &Enum.join/1
      )

    mark_gen =
      StreamData.member_of([
        MarkType.create(schema.marks["em"]),
        MarkType.create(schema.marks["strong"]),
        MarkType.create(schema.marks["code"])
      ])

    check all(
            paras <- StreamData.list_of(text_gen, min_length: 1, max_length: 3),
            op_list <-
              StreamData.list_of(
                StreamData.tuple({
                  StreamData.member_of([:add, :remove_mark, :remove_type, :remove_all]),
                  StreamData.integer(0..100),
                  StreamData.integer(0..100),
                  mark_gen
                }),
                min_length: 1,
                max_length: 6
              )
          ) do
      doc =
        Schema.node(
          schema,
          "doc",
          nil,
          Enum.map(paras, fn t ->
            Schema.node(schema, "paragraph", nil, [Schema.text(schema, t)])
          end)
        )

      tr =
        Enum.reduce(op_list, Transform.new(doc), fn {kind, raw_a, raw_b, mark}, acc ->
          pts = valid_positions(acc.doc)
          len = length(pts)
          a = Enum.at(pts, rem(raw_a, len))
          b = Enum.at(pts, rem(raw_b, len))
          p1 = min(a, b)
          p2 = max(a, b)

          case kind do
            :add -> Transform.add_mark(acc, p1, p2, mark)
            :remove_mark -> Transform.remove_mark(acc, p1, p2, mark)
            :remove_type -> Transform.remove_mark(acc, p1, p2, mark.type)
            :remove_all -> Transform.remove_mark(acc, p1, p2, nil)
          end
        end)

      assert_transform_invariants(tr, doc)
    end
  end

  property "set_block_type (including linebreak_replacement with \\r\\n and emoji) and split/join preserve invariants" do
    schema = full_schema()

    code_text_gen =
      StreamData.map(
        StreamData.list_of(
          StreamData.member_of(["abc", "😀", "🎉", "\n", "\r\n", "\r", "xy"]),
          min_length: 1,
          max_length: 8
        ),
        &Enum.join/1
      )

    check all(
            text <- code_text_gen,
            target <- StreamData.member_of(["paragraph", "heading"]),
            split_seed <- StreamData.integer(0..50)
          ) do
      doc =
        Schema.node(schema, "doc", nil, [
          Schema.node(schema, "code_block", nil, [Schema.text(schema, text)])
        ])

      attrs = if target == "heading", do: %{"level" => 2}, else: nil

      tr =
        Transform.new(doc)
        |> Transform.set_block_type(1, 1, schema.nodes[target], attrs)

      assert_transform_invariants(tr, doc)

      # Verify no raw \r or \n remains inside the converted non-pre block
      text_only = Node.text_between(tr.doc, 0, tr.doc.content.size)
      refute String.contains?(text_only, "\n")
      refute String.contains?(text_only, "\r")

      first_block = Node.first_child(tr.doc)
      inline_pts = valid_inline_positions(first_block, 1)

      if length(inline_pts) > 0 do
        split_pos = Enum.at(inline_pts, rem(split_seed, length(inline_pts)))

        if Structure.can_split(tr.doc, split_pos) do
          tr2 = Transform.split(tr, split_pos)
          assert_transform_invariants(tr2, doc)

          join_pos = 1 + Node.first_child(tr2.doc).content.size + 1

          if Structure.can_join(tr2.doc, join_pos) do
            tr3 = Transform.join(tr2, join_pos)
            assert_transform_invariants(tr3, doc)
            assert Node.eq(tr3.doc, tr.doc)
          end
        end
      end
    end
  end

  property "replace_range and delete_range preserve schema validity and invertibility" do
    schema = full_schema()

    check all(
            t1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            t2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            raw_from <- StreamData.integer(0..25),
            raw_to <- StreamData.integer(0..25),
            ins <- StreamData.string(:alphanumeric, min_length: 0, max_length: 6)
          ) do
      doc =
        Schema.node(schema, "doc", nil, [
          Schema.node(schema, "paragraph", nil, [Schema.text(schema, t1)]),
          Schema.node(schema, "paragraph", nil, [Schema.text(schema, t2)])
        ])

      size = doc.content.size
      from = min(rem(raw_from, size + 1), rem(raw_to, size + 1))
      to = max(rem(raw_from, size + 1), rem(raw_to, size + 1))

      slice =
        if ins == "" do
          Slice.empty()
        else
          Slice.new(Fragment.from(Schema.text(schema, ins)), 0, 0)
        end

      tr = Transform.new(doc) |> Transform.replace_range(from, to, slice)
      assert_transform_invariants(tr, doc)
    end
  end
end
