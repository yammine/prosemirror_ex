defmodule ProsemirrorEx.AuthorityTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Authority
  alias ProsemirrorEx.Model.{Schema, Node, Fragment, Slice}
  alias ProsemirrorEx.Transform.ReplaceStep

  defp make_schema, do: test_schema()

  defp make_insert_step(schema, text_str, pos) do
    text_node = Schema.text(schema, text_str)
    slice = Slice.new(Fragment.from(text_node), 0, 0)
    ReplaceStep.new(pos, pos, slice)
  end

  describe "new/2" do
    test "creates authority with initial doc and version 0" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      assert Authority.version(auth) == 0
      assert Node.eq(Authority.doc(auth), doc_node)
      assert auth.steps == []
      assert auth.step_client_ids == []
    end

    test "creates authority with default doc when doc is nil" do
      schema = make_schema()
      auth = Authority.new(schema)

      assert Authority.version(auth) == 0
      assert Authority.doc(auth) != nil
      assert Authority.doc(auth).type.name == "doc"
    end
  end

  describe "receive_steps/4" do
    test "accepts steps at correct version, updates doc and version" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step = make_insert_step(schema, " world", 6)

      assert {:ok, updated_auth} = Authority.receive_steps(auth, "client1", 0, [step])
      assert Authority.version(updated_auth) == 1

      expected_text = "hello world"
      result_doc = Authority.doc(updated_auth)
      first_child = Node.child(result_doc, 0)
      assert Node.text_content(first_child) == expected_text
    end

    test "rejects steps at stale version with :version_mismatch" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step = make_insert_step(schema, " world", 6)
      {:ok, auth} = Authority.receive_steps(auth, "client1", 0, [step])

      step2 = make_insert_step(schema, "!", 6)
      assert {:error, :version_mismatch} = Authority.receive_steps(auth, "client2", 0, [step2])
    end

    test "version accumulates with multiple batches" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step1 = make_insert_step(schema, " world", 6)
      {:ok, auth} = Authority.receive_steps(auth, "client1", 0, [step1])
      assert Authority.version(auth) == 1

      step2 = make_insert_step(schema, "!", 12)
      {:ok, auth} = Authority.receive_steps(auth, "client1", 1, [step2])
      assert Authority.version(auth) == 2

      result_doc = Authority.doc(auth)
      first_child = Node.child(result_doc, 0)
      assert Node.text_content(first_child) == "hello world!"
    end

    test "accepts multiple steps in a single batch" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step1 = make_insert_step(schema, " world", 6)
      step2 = make_insert_step(schema, "!", 12)

      {:ok, auth} = Authority.receive_steps(auth, "client1", 0, [step1, step2])
      assert Authority.version(auth) == 2
    end

    test "returns :step_failed when step fails to apply" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      # Create a step with an invalid position (way beyond document size)
      bad_step = ReplaceStep.new(100, 200, Slice.empty())

      assert {:error, :step_failed, _message} =
               Authority.receive_steps(auth, "client1", 0, [bad_step])
    end

    test "tracks client IDs for each step" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step1 = make_insert_step(schema, " world", 6)
      {:ok, auth} = Authority.receive_steps(auth, "client_a", 0, [step1])

      step2 = make_insert_step(schema, "!", 12)
      {:ok, auth} = Authority.receive_steps(auth, "client_b", 1, [step2])

      assert auth.step_client_ids == ["client_a", "client_b"]
    end

    test "duplicates client_id for multi-step batches" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step1 = make_insert_step(schema, " world", 6)
      step2 = make_insert_step(schema, "!", 12)

      {:ok, auth} = Authority.receive_steps(auth, "client_a", 0, [step1, step2])
      assert auth.step_client_ids == ["client_a", "client_a"]
    end
  end

  describe "steps_since/2" do
    test "returns correct slice of history with client IDs" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      step1 = make_insert_step(schema, " world", 6)
      {:ok, auth} = Authority.receive_steps(auth, "client_a", 0, [step1])

      step2 = make_insert_step(schema, "!", 12)
      {:ok, auth} = Authority.receive_steps(auth, "client_b", 1, [step2])

      {:ok, steps, client_ids} = Authority.steps_since(auth, 0)
      assert length(steps) == 2
      assert client_ids == ["client_a", "client_b"]

      {:ok, steps, client_ids} = Authority.steps_since(auth, 1)
      assert length(steps) == 1
      assert client_ids == ["client_b"]

      {:ok, steps, client_ids} = Authority.steps_since(auth, 2)
      assert steps == []
      assert client_ids == []
    end

    test "returns error for negative version" do
      schema = make_schema()
      auth = Authority.new(schema)

      assert {:error, :invalid_version} = Authority.steps_since(auth, -1)
    end

    test "returns error for version beyond current" do
      schema = make_schema()
      auth = Authority.new(schema)

      assert {:error, :invalid_version} = Authority.steps_since(auth, 1)
    end
  end

  describe "doc/1 and version/1" do
    test "doc returns the current document" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      assert Node.eq(Authority.doc(auth), doc_node)
    end

    test "version returns the current version" do
      schema = make_schema()
      auth = Authority.new(schema)
      assert Authority.version(auth) == 0
    end
  end

  describe "empty step batches" do
    test "accepting an empty batch is a no-op" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node)

      assert {:ok, ^auth} = Authority.receive_steps(auth, "client1", 0, [])
    end
  end

  describe "max_history trimming" do
    test "trims retained steps while keeping version monotonic" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node, max_history: 2)

      {:ok, auth} = Authority.receive_steps(auth, "c1", 0, [make_insert_step(schema, " a", 6)])
      {:ok, auth} = Authority.receive_steps(auth, "c2", 1, [make_insert_step(schema, " b", 8)])
      {:ok, auth} = Authority.receive_steps(auth, "c3", 2, [make_insert_step(schema, " c", 10)])

      assert Authority.version(auth) == 3
      assert length(auth.steps) == 2
      assert Authority.first_version(auth) == 1
      assert auth.step_client_ids == ["c2", "c3"]
    end

    test "steps_since returns :history_unavailable for trimmed versions" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node, max_history: 1)

      {:ok, auth} = Authority.receive_steps(auth, "c1", 0, [make_insert_step(schema, " a", 6)])
      {:ok, auth} = Authority.receive_steps(auth, "c2", 1, [make_insert_step(schema, " b", 8)])

      assert {:error, :history_unavailable} = Authority.steps_since(auth, 0)
      assert {:ok, steps, client_ids} = Authority.steps_since(auth, 1)
      assert length(steps) == 1
      assert client_ids == ["c2"]
    end

    test "steps_since still works for versions inside the retained window" do
      schema = make_schema()
      {doc_node, _} = doc([p(["hello"])])
      auth = Authority.new(schema, doc_node, max_history: 3)

      {:ok, auth} = Authority.receive_steps(auth, "c1", 0, [make_insert_step(schema, " a", 6)])
      {:ok, auth} = Authority.receive_steps(auth, "c2", 1, [make_insert_step(schema, " b", 8)])

      assert {:ok, steps, _} = Authority.steps_since(auth, 0)
      assert length(steps) == 2
      assert Authority.first_version(auth) == 0
    end

    test "rejects invalid max_history" do
      schema = make_schema()

      assert_raise ArgumentError, fn ->
        Authority.new(schema, nil, max_history: 0)
      end
    end
  end
end
