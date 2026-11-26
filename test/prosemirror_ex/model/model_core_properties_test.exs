defmodule ProsemirrorEx.Model.ModelCorePropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ProsemirrorEx.Model.{
    CompareDeep,
    ContentMatch,
    Fragment,
    Mark,
    MarkType,
    NodeType,
    Schema
  }

  alias ProsemirrorEx.Schema.{Basic, List}

  defp full_schema do
    Schema.new(%{
      "nodes" => Basic.nodes() |> List.add_list_nodes("paragraph block*", "block"),
      "marks" => Basic.marks()
    })
  end

  defp walk_valid_sequence(_cm, 0, acc) do
    acc |> Enum.reverse() |> Fragment.from_array()
  end

  defp walk_valid_sequence(cm, steps_left, acc) do
    count = ContentMatch.edge_count(cm)

    if count == 0 do
      acc |> Enum.reverse() |> Fragment.from_array()
    else
      # Pick a generatable edge deterministically from steps_left
      {type, next_cm} = ContentMatch.edge(cm, rem(steps_left, count))

      if type.is_text or type.has_required_attrs == true do
        if cm.valid_end do
          acc |> Enum.reverse() |> Fragment.from_array()
        else
          # Try to find a generatable edge
          case Enum.find(0..(count - 1), fn i ->
                 {t, _} = ContentMatch.edge(cm, i)
                 not t.is_text and t.has_required_attrs != true
               end) do
            nil ->
              acc |> Enum.reverse() |> Fragment.from_array()

            idx ->
              {t, n_cm} = ContentMatch.edge(cm, idx)
              node = NodeType.create_and_fill(t)

              if n_cm.valid_end and steps_left <= 1 do
                [node | acc] |> Enum.reverse() |> Fragment.from_array()
              else
                walk_valid_sequence(n_cm, steps_left - 1, [node | acc])
              end
          end
        end
      else
        node = NodeType.create_and_fill(type)

        if next_cm.valid_end and steps_left == 1 do
          [node | acc] |> Enum.reverse() |> Fragment.from_array()
        else
          walk_valid_sequence(next_cm, steps_left - 1, [node | acc])
        end
      end
    end
  end

  property "Mark.add_to_set is idempotent and maintains strictly increasing rank" do
    schema = full_schema()

    mark_gen =
      StreamData.one_of([
        StreamData.constant(Schema.mark(schema, "em")),
        StreamData.constant(Schema.mark(schema, "strong")),
        StreamData.constant(Schema.mark(schema, "code")),
        StreamData.map(StreamData.string(:alphanumeric, min_length: 1, max_length: 12), fn slug ->
          Schema.mark(schema, "link", %{"href" => "https://example.com/" <> slug})
        end)
      ])

    check all(marks <- StreamData.list_of(mark_gen, max_length: 8)) do
      set = Enum.reduce(marks, Mark.none(), &Mark.add_to_set/2)

      ranks = Enum.map(set, & &1.type.rank)
      assert ranks == Enum.sort(ranks)
      assert length(Enum.uniq(ranks)) == length(ranks)

      for m <- marks do
        once = Mark.add_to_set(m, set)
        twice = Mark.add_to_set(m, once)
        assert Mark.same_set(once, twice)
        assert Mark.same_set(once, Enum.reverse(Enum.reverse(once)))
      end

      for m <- set do
        removed = Mark.remove_from_set(m, set)
        refute Mark.is_in_set(m, removed)
        assert Mark.same_set(Mark.remove_from_set(m, removed), removed)
      end
    end
  end

  property "Mark JSON round-trip preserves equality" do
    schema = full_schema()

    mark_gen =
      StreamData.one_of([
        StreamData.constant(Schema.mark(schema, "em")),
        StreamData.constant(Schema.mark(schema, "strong")),
        StreamData.constant(Schema.mark(schema, "code")),
        StreamData.bind(
          StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
          fn href ->
            StreamData.map(
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:printable, max_length: 16)
              ]),
              fn title ->
                Schema.mark(schema, "link", %{"href" => href, "title" => title})
              end
            )
          end
        )
      ])

    check all(mark <- mark_gen) do
      json = Mark.to_json(mark)
      decoded = Mark.from_json(schema, json)
      assert Mark.eq(mark, decoded)
    end
  end

  property "ContentMatch.fill_before produces valid sequences when successful" do
    schema = full_schema()
    expressions = ["paragraph+", "heading paragraph*", "paragraph block*", "list_item+"]

    check all(
            expr <- StreamData.member_of(expressions),
            steps <- StreamData.integer(0..4)
          ) do
      cm = ContentMatch.parse(expr, schema.nodes, Map.keys(schema.nodes))
      frag = walk_valid_sequence(cm, steps, [])

      case ContentMatch.fill_before(cm, frag, true) do
        nil ->
          :ok

        prefix ->
          combined = Fragment.append(prefix, frag)
          res = ContentMatch.match_fragment(cm, combined)
          assert res != nil
          assert res.valid_end == true
      end
    end
  end

  property "CompareDeep.compare is reflexive and symmetric on JSON-like terms" do
    scalar_gen =
      StreamData.one_of([
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.string(:alphanumeric, max_length: 10),
        StreamData.constant(nil)
      ])

    term_gen =
      StreamData.tree(scalar_gen, fn leaf ->
        StreamData.one_of([
          StreamData.list_of(leaf, max_length: 4),
          StreamData.map_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 6), leaf,
            max_length: 4
          )
        ])
      end)

    check all(a <- term_gen, b <- term_gen) do
      assert CompareDeep.compare(a, a)
      assert CompareDeep.compare(a, b) == CompareDeep.compare(b, a)
    end
  end

  property "MarkType.excludes matches between schema-compiled and list-backed lookup" do
    schema = full_schema()
    all_marks = Map.values(schema.marks)

    check all(
            m1 <- StreamData.member_of(all_marks),
            m2 <- StreamData.member_of(all_marks)
          ) do
      list_only = %{m1 | excluded_names: nil}
      assert MarkType.excludes(m1, m2) == MarkType.excludes(list_only, m2)
    end
  end
end
