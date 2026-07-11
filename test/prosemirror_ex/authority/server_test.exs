defmodule ProsemirrorEx.Authority.ServerTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Authority.Server
  alias ProsemirrorEx.Model.{Schema, Node, Fragment, Slice, MarkType}

  alias ProsemirrorEx.Transform.{
    Step,
    ReplaceStep,
    AddMarkStep,
    Mapping
  }

  defp make_schema, do: test_schema()

  defp make_insert_step_json(schema, text_str, pos) do
    text_node = Schema.text(schema, text_str)
    slice = Slice.new(Fragment.from(text_node), 0, 0)
    step = ReplaceStep.new(pos, pos, slice)
    ReplaceStep.to_json(step)
  end

  defp start_server(opts) do
    start_supervised!({Server, opts})
  end

  describe "start and get_doc" do
    test "starts server and returns initial doc as JSON" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      {doc_json, version} = Server.get_doc(server)
      assert version == 0
      assert doc_json["type"] == "doc"
      assert is_list(doc_json["content"])
    end

    test "starts server with default doc when none provided" do
      schema = make_schema()
      server = start_server(schema: schema)

      {doc_json, version} = Server.get_doc(server)
      assert version == 0
      assert doc_json["type"] == "doc"
    end
  end

  describe "receive_steps" do
    test "client A sends steps at version 0 - accepted, returns new version" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      step_json = make_insert_step_json(schema, " world", 6)
      assert {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])

      {doc_json, version} = Server.get_doc(server)
      assert version == 1
      # Verify the doc content was updated
      paragraph = hd(doc_json["content"])
      text_content = Enum.map_join(paragraph["content"], "", & &1["text"])
      assert text_content == "hello world"
    end

    test "client B sends steps at stale version - rejected" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      step_json_a = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json_a])

      step_json_b = make_insert_step_json(schema, "!", 6)

      assert {:error, :version_mismatch} =
               Server.receive_steps(server, "clientB", 0, [step_json_b])
    end

    test "client B fetches steps_since, rebases, retries - accepted" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      # Client A inserts " world" at position 6
      step_json_a = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json_a])

      # Client B had pending step to insert "!" at position 6 (stale version 0)
      pending_step =
        ReplaceStep.new(6, 6, Slice.new(Fragment.from(Schema.text(schema, "!")), 0, 0))

      # Client B is rejected
      pending_json = ReplaceStep.to_json(pending_step)
      {:error, :version_mismatch} = Server.receive_steps(server, "clientB", 0, [pending_json])

      # Client B fetches missed steps
      {:ok, missed_steps_json, _client_ids} = Server.steps_since(server, 0)
      missed_steps = Enum.map(missed_steps_json, &Step.from_json(schema, &1))

      # Client B creates mapping from missed steps and rebases
      mapping =
        Enum.reduce(missed_steps, Mapping.new(), fn step, mapping ->
          Mapping.append_map(mapping, step.__struct__.step_map(step))
        end)

      rebased_steps =
        [pending_step]
        |> Enum.map(fn step -> step.__struct__.map(step, mapping) end)
        |> Enum.reject(&is_nil/1)

      assert length(rebased_steps) == 1

      # Client B retries with rebased steps
      rebased_json = Enum.map(rebased_steps, fn s -> s.__struct__.to_json(s) end)
      assert {:ok, 2} = Server.receive_steps(server, "clientB", 1, rebased_json)

      # Verify final document
      {doc_json, version} = Server.get_doc(server)
      assert version == 2
      paragraph = hd(doc_json["content"])
      text_content = Enum.map_join(paragraph["content"], "", & &1["text"])
      assert text_content == "hello world!"
    end
  end

  describe "steps_since" do
    test "late-joining client gets full doc + steps_since(0)" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      step_json = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])

      # Late joiner can get full step history
      {:ok, steps_json, client_ids} = Server.steps_since(server, 0)
      assert length(steps_json) == 1
      assert client_ids == ["clientA"]

      # Can also get the current doc
      {doc_json, version} = Server.get_doc(server)
      assert version == 1
      assert doc_json["type"] == "doc"
    end

    test "returns error for invalid version" do
      schema = make_schema()
      server = start_server(schema: schema)

      assert {:error, :invalid_version} = Server.steps_since(server, 5)
      assert {:error, :invalid_version} = Server.steps_since(server, -1)
    end
  end

  describe "multi-step batch" do
    test "insert + add mark in one batch" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      # Step 1: Insert " world" at position 6
      text_node = Schema.text(schema, " world")
      insert_slice = Slice.new(Fragment.from(text_node), 0, 0)
      insert_step = ReplaceStep.new(6, 6, insert_slice)

      # Step 2: Add em mark to "world" (positions 7-12 after insert)
      em_mark = MarkType.create(schema.marks["em"])
      mark_step = AddMarkStep.new(7, 12, em_mark)

      steps_json = [
        ReplaceStep.to_json(insert_step),
        AddMarkStep.to_json(mark_step)
      ]

      assert {:ok, 2} = Server.receive_steps(server, "clientA", 0, steps_json)

      {_doc_json, version} = Server.get_doc(server)
      assert version == 2
    end
  end

  describe "JSON round-trip" do
    test "steps sent as JSON, doc retrieved as JSON, verified correct" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      # Send step as JSON
      step_json = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])

      # Get doc as JSON
      {doc_json, _version} = Server.get_doc(server)

      # Reconstruct doc from JSON
      reconstructed = Node.from_json(schema, doc_json)
      paragraph = Node.child(reconstructed, 0)
      assert Node.text_content(paragraph) == "hello world"

      # Get steps as JSON and verify round-trip
      {:ok, steps_json, _client_ids} = Server.steps_since(server, 0)
      assert length(steps_json) == 1
      step = Step.from_json(schema, hd(steps_json))
      assert step.__struct__ == ReplaceStep
    end
  end

  describe "3-client collaboration simulation" do
    test "three clients insert text concurrently, all converge" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      # Client A inserts " A" at position 6 (end of "hello") -- accepted (version 1)
      step_a = ReplaceStep.new(6, 6, Slice.new(Fragment.from(Schema.text(schema, " A")), 0, 0))
      step_a_json = ReplaceStep.to_json(step_a)
      assert {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_a_json])

      # Client B wants to insert " B" at position 6 at stale version 0 -- rejected
      step_b = ReplaceStep.new(6, 6, Slice.new(Fragment.from(Schema.text(schema, " B")), 0, 0))
      step_b_json = ReplaceStep.to_json(step_b)

      assert {:error, :version_mismatch} =
               Server.receive_steps(server, "clientB", 0, [step_b_json])

      # Client C also wants to insert " C" at position 6 at stale version 0 -- rejected
      step_c = ReplaceStep.new(6, 6, Slice.new(Fragment.from(Schema.text(schema, " C")), 0, 0))
      step_c_json = ReplaceStep.to_json(step_c)

      assert {:error, :version_mismatch} =
               Server.receive_steps(server, "clientC", 0, [step_c_json])

      # Client B rebases and retries at version 1 -- accepted (version 2)
      {:ok, missed_b_json, _} = Server.steps_since(server, 0)
      missed_b_steps = Enum.map(missed_b_json, &Step.from_json(schema, &1))

      mapping_b =
        Enum.reduce(missed_b_steps, Mapping.new(), fn step, mapping ->
          Mapping.append_map(mapping, step.__struct__.step_map(step))
        end)

      rebased_b =
        [step_b]
        |> Enum.map(fn s -> s.__struct__.map(s, mapping_b) end)
        |> Enum.reject(&is_nil/1)

      rebased_b_json = Enum.map(rebased_b, fn s -> s.__struct__.to_json(s) end)
      assert {:ok, 2} = Server.receive_steps(server, "clientB", 1, rebased_b_json)

      # Client C rebases and retries at version 2 -- accepted (version 3)
      {:ok, missed_c_json, _} = Server.steps_since(server, 0)
      missed_c_steps = Enum.map(missed_c_json, &Step.from_json(schema, &1))

      mapping_c =
        Enum.reduce(missed_c_steps, Mapping.new(), fn step, mapping ->
          Mapping.append_map(mapping, step.__struct__.step_map(step))
        end)

      rebased_c =
        [step_c]
        |> Enum.map(fn s -> s.__struct__.map(s, mapping_c) end)
        |> Enum.reject(&is_nil/1)

      rebased_c_json = Enum.map(rebased_c, fn s -> s.__struct__.to_json(s) end)
      assert {:ok, 3} = Server.receive_steps(server, "clientC", 2, rebased_c_json)

      # Verify final document contains all three clients' text
      {doc_json, version} = Server.get_doc(server)
      assert version == 3

      reconstructed = Node.from_json(schema, doc_json)
      paragraph = Node.child(reconstructed, 0)
      text = Node.text_content(paragraph)

      assert String.contains?(text, "hello")
      assert String.contains?(text, " A")
      assert String.contains?(text, " B")
      assert String.contains?(text, " C")
    end

    test "step history is complete and ordered" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      # Send three batches
      step1_json = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "c1", 0, [step1_json])

      step2_json = make_insert_step_json(schema, "!", 12)
      {:ok, 2} = Server.receive_steps(server, "c2", 1, [step2_json])

      step3_json = make_insert_step_json(schema, " hi", 13)
      {:ok, 3} = Server.receive_steps(server, "c3", 2, [step3_json])

      # Full history
      {:ok, all_steps, all_ids} = Server.steps_since(server, 0)
      assert length(all_steps) == 3
      assert all_ids == ["c1", "c2", "c3"]

      # Any client can reconstruct the current doc from initial doc + all steps
      steps = Enum.map(all_steps, &Step.from_json(schema, &1))

      reconstructed =
        Enum.reduce(steps, doc_node, fn step, current_doc ->
          result = step.__struct__.apply(step, current_doc)
          assert result.doc != nil, "Step should apply successfully"
          result.doc
        end)

      {final_json, _} = Server.get_doc(server)
      final_doc = Node.from_json(schema, final_json)
      assert Node.eq(reconstructed, final_doc)
    end
  end

  describe "error handling" do
    test "invalid step JSON returns error" do
      schema = make_schema()
      server = start_server(schema: schema)

      assert {:error, :invalid_step, _msg} =
               Server.receive_steps(server, "client1", 0, [%{"invalid" => true}])
    end
  end

  describe "get_version" do
    test "returns the current version" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      assert Server.get_version(server) == 0

      step_json = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])
      assert Server.get_version(server) == 1
    end
  end

  describe "subscribe" do
    test "notifies subscribers when steps are accepted" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      assert :ok = Server.subscribe(server)

      step_json = make_insert_step_json(schema, " world", 6)
      assert {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])

      assert_receive {:authority_update,
                      %{version: 1, steps: [step], client_ids: ["clientA"]}}

      assert step["stepType"] == "replace"
    end

    test "does not notify after unsubscribe" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      :ok = Server.subscribe(server)
      :ok = Server.unsubscribe(server)

      step_json = make_insert_step_json(schema, " world", 6)
      assert {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])

      refute_receive {:authority_update, _}, 50
    end

    test "does not notify on version mismatch" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node)

      :ok = Server.subscribe(server)

      step_json = make_insert_step_json(schema, " world", 6)
      {:ok, 1} = Server.receive_steps(server, "clientA", 0, [step_json])
      assert_receive {:authority_update, %{version: 1}}

      assert {:error, :version_mismatch} =
               Server.receive_steps(server, "clientB", 0, [step_json])

      refute_receive {:authority_update, _}, 50
    end
  end

  describe "max_history" do
    test "returns history_unavailable when version was trimmed" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      server = start_server(schema: schema, doc: doc_node, max_history: 1)

      step1 = make_insert_step_json(schema, " a", 6)
      {:ok, 1} = Server.receive_steps(server, "c1", 0, [step1])

      step2 = make_insert_step_json(schema, " b", 8)
      {:ok, 2} = Server.receive_steps(server, "c2", 1, [step2])

      assert {:error, :history_unavailable} = Server.steps_since(server, 0)
      assert {:ok, steps, ["c2"]} = Server.steps_since(server, 1)
      assert length(steps) == 1
    end
  end
end
