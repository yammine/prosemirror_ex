defmodule ProsemirrorEx.AuthorityPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ProsemirrorEx.Authority
  alias ProsemirrorEx.Model.{Fragment, Node, Schema, Slice}
  alias ProsemirrorEx.Schema.Basic
  alias ProsemirrorEx.Transform.ReplaceStep

  defp make_doc_and_schema do
    schema = Basic.schema()

    doc =
      Schema.node(schema, "doc", nil, [
        Schema.node(schema, "paragraph", nil, [Schema.text(schema, "init")])
      ])

    {schema, doc}
  end

  defp apply_random_edit(schema, auth, client_id, text_chunk) do
    doc = Authority.doc(auth)
    p_node = Node.first_child(doc)
    max_offset = p_node.content.size
    insert_pos = 1 + :erlang.phash2({client_id, text_chunk, auth.version}, max_offset + 1)

    step =
      ReplaceStep.new(
        insert_pos,
        insert_pos,
        Slice.new(Fragment.from(Schema.text(schema, text_chunk)), 0, 0)
      )

    {step, Authority.receive_steps(auth, client_id, Authority.version(auth), [step])}
  end

  property "Authority maintains monotonic versions, history window invariants, and replay equivalence" do
    {schema, initial_doc} = make_doc_and_schema()

    batch_op_gen =
      StreamData.tuple({
        StreamData.member_of(["c1", "c2", "c3"]),
        StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 4),
          min_length: 1,
          max_length: 3
        )
      })

    check all(
            initial_version <- StreamData.integer(0..20),
            max_history <- StreamData.one_of([StreamData.constant(nil), StreamData.integer(3..8)]),
            ops <- StreamData.list_of(batch_op_gen, min_length: 1, max_length: 15)
          ) do
      auth0 =
        Authority.new(schema, initial_doc, version: initial_version, max_history: max_history)

      {final_auth, accepted_steps} =
        Enum.reduce(ops, {auth0, []}, fn {client_id, chunks}, {auth_acc, hist_acc} ->
          {steps, _doc} =
            Enum.map_reduce(chunks, Authority.doc(auth_acc), fn chunk, cur_doc ->
              p_node = Node.first_child(cur_doc)

              pos =
                1 +
                  :erlang.phash2(
                    {client_id, chunk, cur_doc.content.size},
                    p_node.content.size + 1
                  )

              s =
                ReplaceStep.new(
                  pos,
                  pos,
                  Slice.new(Fragment.from(Schema.text(schema, chunk)), 0, 0)
                )

              res = s.__struct__.apply(s, cur_doc)
              {s, res.doc}
            end)

          v = Authority.version(auth_acc)

          # Stale version must always be rejected
          if v > 0 do
            assert {:error, :version_mismatch} =
                     Authority.receive_steps(auth_acc, client_id, v - 1, steps)
          end

          case Authority.receive_steps(auth_acc, client_id, v, steps) do
            {:ok, next_auth} ->
              assert Authority.version(next_auth) == v + length(steps)
              {next_auth, hist_acc ++ steps}

            {:error, :batch_too_large} ->
              assert max_history != nil and length(steps) > max_history
              {auth_acc, hist_acc}
          end
        end)

      v = Authority.version(final_auth)
      fv = Authority.first_version(final_auth)

      assert fv >= initial_version
      assert fv <= v
      assert v == initial_version + length(accepted_steps)

      if max_history != nil do
        assert v - fv <= max_history
      else
        assert fv == initial_version
      end

      # Every version in [fv, v] succeeds and returns exact step count
      for since <- fv..v do
        assert {:ok, steps, ids} = Authority.steps_since(final_auth, since)
        assert length(steps) == v - since
        assert length(ids) == v - since
      end

      # Versions before fv return :history_unavailable
      if fv > 0 do
        assert {:error, :history_unavailable} = Authority.steps_since(final_auth, fv - 1)
      end

      # Out-of-bounds versions return :invalid_version
      assert {:error, :invalid_version} = Authority.steps_since(final_auth, -1)
      assert {:error, :invalid_version} = Authority.steps_since(final_auth, v + 1)

      # Replaying retained steps from the doc at fv? When unlimited, replay from initial_doc == final doc
      if max_history == nil do
        {:ok, all_steps, _} = Authority.steps_since(final_auth, initial_version)

        replayed_doc =
          Enum.reduce(all_steps, initial_doc, fn s, d ->
            s.__struct__.apply(s, d).doc
          end)

        assert Node.eq(replayed_doc, Authority.doc(final_auth))
      end

      # Also check single-step helper works
      {_s, res} = apply_random_edit(schema, final_auth, "c1", "x")
      assert match?({:ok, _}, res) or match?({:error, :batch_too_large}, res)
    end
  end
end
