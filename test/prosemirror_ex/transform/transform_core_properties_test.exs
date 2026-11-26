defmodule ProsemirrorEx.Transform.TransformCorePropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Fragment, MarkType, Node, NodeType, Schema, Slice}

  alias ProsemirrorEx.Transform.{
    AddMarkStep,
    AddNodeMarkStep,
    AttrStep,
    DocAttrStep,
    Mappable,
    MapResult,
    Mapping,
    RemoveMarkStep,
    RemoveNodeMarkStep,
    ReplaceStep,
    Step,
    StepMap,
    Transform
  }

  # ── Generators ────────────────────────────────────────────────────────

  defp non_neg_triples_gen do
    list_of(tuple({integer(0..30), integer(0..10), integer(0..10)}), max_length: 6)
    |> map(fn triples ->
      # Ensure strictly non-overlapping sorted ranges: start_i >= end_{i-1}
      {ranges, _cursor} =
        Enum.map_reduce(triples, 0, fn {gap, old_s, new_s}, cursor ->
          start = cursor + gap
          {[start, old_s, new_s], start + old_s}
        end)

      List.flatten(ranges)
    end)
  end

  defp step_map_gen do
    bind(non_neg_triples_gen(), fn ranges ->
      map(boolean(), fn inverted ->
        StepMap.new(ranges, inverted)
      end)
    end)
  end

  defp mapping_with_mirrors_gen do
    list_of(
      one_of([
        map(non_neg_triples_gen(), fn ranges -> {:single, StepMap.new(ranges)} end),
        map(non_neg_triples_gen(), fn ranges ->
          m = StepMap.new(ranges)
          {:pair, m, StepMap.invert(m)}
        end)
      ]),
      max_length: 8
    )
    |> map(fn entries ->
      Enum.reduce(entries, Mapping.new(), fn
        {:single, m}, acc ->
          Mapping.append_map(acc, m)

        {:pair, m, inv}, acc ->
          idx = length(acc.maps)

          acc
          |> Mapping.append_map(m)
          |> Mapping.append_map(inv, idx)
      end)
    end)
  end

  # ── StepMap properties ────────────────────────────────────────────────

  property "pure insertion StepMaps never set any deleted flags" do
    check all(
            start <- integer(0..50),
            ins_len <- integer(0..20),
            pos <- integer(0..60),
            assoc <- member_of([-1, 1])
          ) do
      smap = StepMap.new([start, 0, ins_len])
      res = StepMap.map_result(smap, pos, assoc)

      assert res.del_info == 0
      assert res.recover == nil
      refute MapResult.deleted?(res)
      refute MapResult.deleted_before?(res)
      refute MapResult.deleted_after?(res)
      refute MapResult.deleted_across?(res)
      assert StepMap.map(smap, pos, assoc) == res.pos
    end
  end

  property "StepMap.fold/3 agrees with StepMap.for_each/2 on all StepMaps" do
    check all(smap <- step_map_gen()) do
      via_for_each = StepMap.for_each(smap, fn os, oe, ns, ne -> {os, oe, ns, ne} end)

      via_fold =
        StepMap.fold(smap, [], fn os, oe, ns, ne, acc -> [{os, oe, ns, ne} | acc] end)
        |> Enum.reverse()

      assert via_fold == via_for_each
    end
  end

  property "StepMap.invert/1 round-trips non-deleted positions" do
    check all(
            smap <- step_map_gen(),
            pos <- integer(0..80),
            assoc <- member_of([-1, 1])
          ) do
      inv = StepMap.invert(smap)
      res = StepMap.map_result(smap, pos, assoc)

      if not MapResult.deleted?(res) and not MapResult.deleted_across?(res) do
        # Boundary positions with non-empty replaced range and matching side recover
        if res.del_info == 0 do
          assert StepMap.map(inv, res.pos, assoc) == pos
        end
      end
    end
  end

  # ── Mapping properties ────────────────────────────────────────────────

  property "Mapping.map/3 equals Mapping.map_result/3 pos and invert round-trips lossless positions" do
    check all(
            mapping <- mapping_with_mirrors_gen(),
            pos <- integer(0..60),
            assoc <- member_of([-1, 1])
          ) do
      res = Mapping.map_result(mapping, pos, assoc)
      assert Mapping.map(mapping, pos, assoc) == res.pos
      assert Mappable.map(mapping, pos, assoc) == res.pos

      inv = Mapping.invert(mapping)
      assert Mapping.map(inv, res.pos, assoc) == Mapping.map_result(inv, res.pos, assoc).pos

      if res.del_info == 0 do
        assert Mapping.map(inv, res.pos, assoc) == pos
      end
    end
  end

  property "Mapping.slice/3 matches standalone Mapping when no mirror crosses slice boundaries" do
    check all(
            maps <-
              list_of(map(non_neg_triples_gen(), &StepMap.new/1), min_length: 1, max_length: 8),
            from <- integer(0..length(maps)),
            to <- integer(from..length(maps)),
            pos <- integer(0..60),
            assoc <- member_of([-1, 1])
          ) do
      full = Mapping.new(maps)
      sliced = Mapping.slice(full, from, to)
      standalone = Mapping.new(Enum.slice(maps, from, to - from))

      assert Mapping.map(sliced, pos, assoc) == Mapping.map(standalone, pos, assoc)
      assert Mapping.map_result(sliced, pos, assoc) == Mapping.map_result(standalone, pos, assoc)
    end
  end

  property "Mapping.append_mapping and append_mapping_inverted preserve mirror recovery" do
    check all(
            m1 <- mapping_with_mirrors_gen(),
            m2 <- mapping_with_mirrors_gen(),
            pos <- integer(0..50),
            assoc <- member_of([-1, 1])
          ) do
      combined = Mapping.append_mapping(m1, m2)

      # Mirror indices are preserved and shifted cleanly in append_mapping
      len1 = length(m1.maps)
      len2 = length(m2.maps)

      for i <- 0..(len2 - 1)//1 do
        case Mapping.get_mirror(m2, i) do
          nil -> assert Mapping.get_mirror(combined, len1 + i) == nil
          mirr -> assert Mapping.get_mirror(combined, len1 + i) == len1 + mirr
        end
      end

      # Mapping through combined and then its inverse matches mapping m1 -> m2 -> inv(m2) -> inv(m1)
      # and mirrors inside append_mapping_inverted are preserved at reversed indices
      inv_combined = Mapping.append_mapping_inverted(Mapping.new(), combined)
      total = length(combined.maps)

      for i <- 0..(total - 1)//1 do
        case Mapping.get_mirror(combined, i) do
          nil ->
            assert Mapping.get_mirror(inv_combined, total - 1 - i) == nil

          mirr ->
            assert Mapping.get_mirror(inv_combined, total - 1 - i) == total - 1 - mirr
        end
      end

      res = Mapping.map_result(combined, pos, assoc)

      if res.del_info == 0 do
        assert Mapping.map(inv_combined, res.pos, assoc) == pos
      end
    end
  end

  # ── Step JSON round-trip & invertibility properties ───────────────────

  property "generated ReplaceStep, MarkSteps, and AttrSteps round-trip JSON and invert" do
    doc_schema =
      Schema.new(%{
        "nodes" => [
          {"doc", %{"content" => "block+", "attrs" => %{"rev" => %{"default" => 0}}}},
          {"paragraph", %{"content" => "inline*", "group" => "block"}},
          {"heading",
           %{
             "content" => "inline*",
             "group" => "block",
             "attrs" => %{"level" => %{"default" => 1}}
           }},
          {"text", %{"group" => "inline"}},
          {"image",
           %{
             "group" => "inline",
             "inline" => true,
             "attrs" => %{"src" => %{"default" => "a.png"}}
           }}
        ],
        "marks" => [
          {"em", %{}},
          {"strong", %{}}
        ]
      })

    check all(
            txt <- string(:alphanumeric, min_length: 3, max_length: 12),
            insert_txt <- string(:alphanumeric, min_length: 1, max_length: 6),
            from_offset <- integer(0..String.length(txt)),
            to_offset <- integer(from_offset..String.length(txt)),
            level <- integer(1..6),
            rev <- integer(1..100),
            mark_name <- member_of(["em", "strong"])
          ) do
      p_type = Schema.node_type(doc_schema, "paragraph")
      h_type = Schema.node_type(doc_schema, "heading")
      doc_type = Schema.node_type(doc_schema, "doc")
      mark = MarkType.create(doc_schema.marks[mark_name])

      img_node = NodeType.create(doc_schema.nodes["image"])
      p_node = NodeType.create(p_type, nil, [Schema.text(doc_schema, txt), img_node])
      h_node = NodeType.create(h_type, %{"level" => 1}, [Schema.text(doc_schema, "head")])
      doc_node = NodeType.create(doc_type, nil, [p_node, h_node])

      marked_img = NodeType.create(doc_schema.nodes["image"], nil, nil, [mark])

      marked_p =
        NodeType.create(p_type, nil, [Schema.text(doc_schema, txt, [mark]), marked_img])

      marked_doc = NodeType.create(doc_type, nil, [marked_p, h_node])

      p_len = String.length(txt)
      from = 1 + from_offset
      to = 1 + to_offset
      img_pos = 1 + p_len
      heading_pos = 1 + p_len + 1 + 1

      ins_slice = Slice.new(Fragment.from(Schema.text(doc_schema, insert_txt)), 0, 0)

      cases = [
        {doc_node, ReplaceStep.new(from, to, ins_slice)},
        {doc_node, AddMarkStep.new(1, 1 + p_len, mark)},
        {marked_doc, RemoveMarkStep.new(1, 1 + p_len, mark)},
        {doc_node, AddNodeMarkStep.new(img_pos, mark)},
        {marked_doc, RemoveNodeMarkStep.new(img_pos, mark)},
        {doc_node, AttrStep.new(heading_pos, "level", level)},
        {doc_node, DocAttrStep.new("rev", rev)}
      ]

      for {target_doc, step} <- cases do
        res = Step.apply(step, target_doc)
        assert res.failed == nil

        json = Step.to_json(step)
        decoded = Step.from_json(doc_schema, json)
        res2 = Step.apply(decoded, target_doc)
        assert Node.eq(res.doc, res2.doc)

        inv = Step.invert(step, target_doc)
        inv_res = Step.apply(inv, res.doc)
        assert inv_res.failed == nil
        assert Node.eq(inv_res.doc, target_doc)
      end

      # Also verify schema-independent Transform.changed_range consistency
      tr =
        Transform.new(doc_node)
        |> Transform.step(ReplaceStep.new(from, to, ins_slice))
        |> Transform.step(
          AddMarkStep.new(1, 1 + p_len + String.length(insert_txt) - (to - from), mark)
        )

      range = Transform.changed_range(tr)
      assert range == %{from: from, to: from + String.length(insert_txt)}
    end
  end

  # ── Untrusted JSON fuzzing property ───────────────────────────────────

  property "Step.from_json/2 raises ArgumentError (never crashes) on arbitrary malformed payloads" do
    schema = test_schema()

    scalar_gen =
      one_of([
        constant(nil),
        boolean(),
        integer(-20..20),
        float(min: -10.0, max: 10.0),
        string(:ascii, max_length: 10)
      ])

    malformed_gen =
      one_of([
        scalar_gen,
        list_of(scalar_gen, max_length: 4),
        map_of(
          member_of([
            "stepType",
            "from",
            "to",
            "gapFrom",
            "gapTo",
            "insert",
            "structure",
            "pos",
            "attr",
            "value",
            "mark",
            "slice"
          ]),
          one_of([
            scalar_gen,
            member_of([
              "replace",
              "replaceAround",
              "addMark",
              "removeMark",
              "addNodeMark",
              "removeNodeMark",
              "attr",
              "docAttr",
              "unknown"
            ]),
            constant(%{"type" => "unknown"}),
            constant(%{"content" => "bad"})
          ]),
          max_length: 6
        )
      ])

    check all(payload <- malformed_gen, max_runs: 150) do
      try do
        _step = Step.from_json(schema, payload)
        :ok
      rescue
        ArgumentError ->
          :ok

        other ->
          flunk(
            "Expected ArgumentError or valid Step, got #{inspect(other)} for #{inspect(payload)}"
          )
      end
    end
  end
end
