defmodule ProsemirrorEx.Transform.StepTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.{Step, StepResult, TransformError}

  describe "TransformError" do
    test "is an exception with a message" do
      error = %TransformError{message: "something went wrong"}
      assert error.message == "something went wrong"
    end

    test "can be raised" do
      assert_raise TransformError, "test error", fn ->
        raise TransformError, "test error"
      end
    end
  end

  describe "StepResult" do
    test "ok/1 creates a successful result" do
      result = StepResult.ok(:fake_doc)
      assert result.doc == :fake_doc
      assert result.failed == nil
    end

    test "fail/1 creates a failed result" do
      result = StepResult.fail("something went wrong")
      assert result.doc == nil
      assert result.failed == "something went wrong"
    end

    test "from_replace/4 returns ok on successful replace" do
      {doc_node, _tags} = doc([p(["hello"])])
      slice = ProsemirrorEx.Model.Slice.empty()
      result = StepResult.from_replace(doc_node, 1, 1, slice)
      assert result.doc != nil
      assert result.failed == nil
    end

    test "from_replace/4 returns fail on invalid replace" do
      {doc_node, _tags} = doc([p(["hello"])])
      # Create a slice that can't be validly inserted (open depth too deep)
      # Use an invalid replacement that will trigger a ReplaceError
      {inner_doc, _} = doc([p(["nested"])])

      bad_slice = %ProsemirrorEx.Model.Slice{
        content: inner_doc.content,
        open_start: 5,
        open_end: 5
      }

      result = StepResult.from_replace(doc_node, 1, 1, bad_slice)
      assert result.failed != nil
      assert result.doc == nil
    end
  end

  describe "Step behaviour" do
    test "Step module defines the expected callbacks" do
      # Verify the behaviour callbacks are defined
      callbacks = ProsemirrorEx.Transform.Step.behaviour_info(:callbacks)
      callback_names = Enum.map(callbacks, fn {name, _arity} -> name end)

      assert :apply in callback_names
      assert :invert in callback_names
      assert :step_map in callback_names
      assert :to_json in callback_names
      assert :merge in callback_names
      assert :map in callback_names
      assert :from_json in callback_names
    end
  end

  describe "Step registry" do
    test "json_id/2 registers a step module" do
      defmodule FakeStep do
        @behaviour ProsemirrorEx.Transform.Step

        @impl true
        def apply(_step, _doc), do: StepResult.fail("not implemented")
        @impl true
        def invert(_step, _doc), do: nil
        @impl true
        def step_map(_step), do: ProsemirrorEx.Transform.StepMap.empty()
        @impl true
        def to_json(_step), do: %{}
        @impl true
        def merge(_step, _other), do: nil
        @impl true
        def map(_step, _mapping), do: nil
        @impl true
        def from_json(_schema, _json), do: %{}
      end

      Step.json_id("fake_step_test", FakeStep)
      assert Step.from_json(nil, %{"stepType" => "fake_step_test"}) == %{}
    end

    test "from_json/2 raises for missing stepType" do
      assert_raise ArgumentError, ~r/Invalid input/, fn ->
        Step.from_json(nil, %{})
      end
    end

    test "from_json/2 raises for unknown stepType" do
      assert_raise ArgumentError, ~r/No step type/, fn ->
        Step.from_json(nil, %{"stepType" => "nonexistent_step_type_xyz"})
      end
    end

    test "json_id/2 raises for duplicate ID" do
      defmodule FakeStep2 do
        @behaviour ProsemirrorEx.Transform.Step

        @impl true
        def apply(_step, _doc), do: StepResult.fail("not implemented")
        @impl true
        def invert(_step, _doc), do: nil
        @impl true
        def step_map(_step), do: ProsemirrorEx.Transform.StepMap.empty()
        @impl true
        def to_json(_step), do: %{}
        @impl true
        def merge(_step, _other), do: nil
        @impl true
        def map(_step, _mapping), do: nil
        @impl true
        def from_json(_schema, _json), do: %{}
      end

      Step.json_id("duplicate_test_id", FakeStep2)

      assert_raise ArgumentError, ~r/Duplicate use of step JSON ID/, fn ->
        Step.json_id("duplicate_test_id", FakeStep2)
      end
    end
  end
end
