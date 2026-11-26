defmodule ProsemirrorEx.Model.ModelPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Fragment, NodeType, ResolvedPos, Schema, Slice, Utf16}
  alias ProsemirrorEx.Model.Node, as: PmNode

  # ── Generators ────────────────────────────────────────────────────────

  defp utf16_text_gen do
    one_of([
      string(:printable, min_length: 1, max_length: 12),
      member_of(["😀", "😁", "👨‍👩‍👧‍👦", "e\u0301", "\r\n", "café", "日本語", "a😀b", "x\r\ny"])
    ])
    |> list_of(min_length: 1, max_length: 4)
    |> map(&Enum.join/1)
    |> filter(&(&1 != ""))
  end

  defp inline_node_gen(schema) do
    mark_gen =
      one_of([
        constant([]),
        constant([Schema.mark(schema, "em")]),
        constant([Schema.mark(schema, "strong")]),
        constant([Schema.mark(schema, "em"), Schema.mark(schema, "strong")])
      ])

    one_of([
      bind(utf16_text_gen(), fn txt ->
        map(mark_gen, fn marks ->
          Schema.text(schema, txt, marks)
        end)
      end),
      constant(NodeType.create(schema.nodes["hard_break"])),
      constant(NodeType.create(schema.nodes["image"], %{"src" => "pic.png"}))
    ])
  end

  defp block_node_gen(schema) do
    p_gen =
      map(list_of(inline_node_gen(schema), min_length: 0, max_length: 4), fn inlines ->
        NodeType.create(schema.nodes["paragraph"], nil, inlines)
      end)

    h_gen =
      bind(integer(1..3), fn level ->
        map(list_of(inline_node_gen(schema), min_length: 0, max_length: 3), fn inlines ->
          NodeType.create(schema.nodes["heading"], %{"level" => level}, inlines)
        end)
      end)

    code_gen =
      map(list_of(utf16_text_gen(), min_length: 0, max_length: 2), fn texts ->
        children = Enum.map(texts, &Schema.text(schema, &1))
        NodeType.create(schema.nodes["code_block"], nil, children)
      end)

    hr_gen = constant(NodeType.create(schema.nodes["horizontal_rule"]))

    one_of([p_gen, h_gen, code_gen, hr_gen])
  end

  defp doc_gen(schema) do
    leaf_or_block =
      one_of([
        block_node_gen(schema),
        map(list_of(block_node_gen(schema), min_length: 1, max_length: 3), fn blocks ->
          NodeType.create(schema.nodes["blockquote"], nil, blocks)
        end)
      ])

    map(list_of(leaf_or_block, min_length: 1, max_length: 5), fn blocks ->
      NodeType.create(schema.nodes["doc"], nil, blocks)
    end)
  end

  # ── Utf16 properties ──────────────────────────────────────────────────

  property "Utf16.length is additive under concatenation" do
    check all(a <- string(:utf8, max_length: 30), b <- string(:utf8, max_length: 30)) do
      assert Utf16.length(a <> b) == Utf16.length(a) + Utf16.length(b)
    end
  end

  property "Utf16.slice(s, 0, Utf16.length(s)) == s" do
    check all(s <- string(:utf8, max_length: 40)) do
      assert Utf16.slice(s, 0, Utf16.length(s)) == s
      assert Utf16.slice(s, 0) == s
    end
  end

  property "Utf16.byte_offset_to_utf16 aligns with Utf16.length at codepoint boundaries" do
    check all(a <- string(:utf8, max_length: 25), b <- string(:utf8, max_length: 25)) do
      assert Utf16.byte_offset_to_utf16(a <> b, byte_size(a)) == Utf16.length(a)
    end
  end

  # ── Fragment properties ───────────────────────────────────────────────

  property "Fragment.append preserves total size and merges adjacent matching text nodes" do
    schema = test_schema()

    check all(
            left <- list_of(inline_node_gen(schema), max_length: 5),
            right <- list_of(inline_node_gen(schema), max_length: 5)
          ) do
      frag_a = Fragment.from_array(left)
      frag_b = Fragment.from_array(right)
      joined = Fragment.append(frag_a, frag_b)

      assert joined.size == frag_a.size + frag_b.size

      # No two adjacent children in a normalized Fragment may be text nodes with same_markup
      Enum.chunk_every(joined.content, 2, 1, :discard)
      |> Enum.each(fn [n1, n2] ->
        refute PmNode.is_text(n1) and PmNode.is_text(n2) and PmNode.same_markup(n1, n2)
      end)
    end
  end

  # ── Document JSON, Resolve, and Slice/Replace properties ──────────────

  property "Node.to_json/from_json round-trips valid documents and passes Node.check" do
    schema = test_schema()

    check all(d <- doc_gen(schema)) do
      assert PmNode.check(d) == :ok
      json = PmNode.to_json(d)
      restored = PmNode.from_json(schema, json)
      assert PmNode.eq(d, restored)
      assert PmNode.check(restored) == :ok
    end
  end

  property "ResolvedPos invariants hold for all valid positions in generated documents" do
    schema = test_schema()

    check all(d <- doc_gen(schema)) do
      max_pos = d.content.size

      for pos <- 0..max_pos do
        rpos = PmNode.resolve(d, pos)
        assert rpos.pos == pos
        assert PmNode.eq(ResolvedPos.doc(rpos), d)

        for depth <- 0..rpos.depth do
          assert ResolvedPos.start(rpos, depth) <= pos
          assert pos <= ResolvedPos.end_pos(rpos, depth)
        end
      end
    end
  end

  property "Node.slice and Node.replace round-trip whole documents" do
    schema = test_schema()

    check all(d <- doc_gen(schema)) do
      size = d.content.size
      slice = PmNode.slice(d, 0, size)
      assert Slice.size(slice) == size

      {target, _} = doc([p([])])
      replaced = PmNode.replace(target, 0, target.content.size, slice)
      assert PmNode.eq(replaced, d)
    end
  end
end
