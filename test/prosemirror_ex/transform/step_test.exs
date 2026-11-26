defmodule ProsemirrorEx.Transform.StepTest.OverrideStep do
  @behaviour ProsemirrorEx.Transform.Step
  alias ProsemirrorEx.Transform.{StepMap, StepResult}

  defstruct []

  @impl true
  def apply(_step, _doc), do: StepResult.fail("noop")
  @impl true
  def invert(step, _doc), do: step
  @impl true
  def step_map(_step), do: StepMap.empty()
  @impl true
  def to_json(_step), do: %{}
  @impl true
  def merge(_step, _other), do: nil
  @impl true
  def map(_step, _mapping), do: nil
  @impl true
  def from_json(_schema, _json), do: %__MODULE__{}
end

defmodule ProsemirrorEx.Transform.StepTest.ConcurrentStep do
  @behaviour ProsemirrorEx.Transform.Step
  alias ProsemirrorEx.Transform.{StepMap, StepResult}

  defstruct [:id]

  @impl true
  def apply(_step, _doc), do: StepResult.fail("noop")
  @impl true
  def invert(step, _doc), do: step
  @impl true
  def step_map(_step), do: StepMap.empty()
  @impl true
  def to_json(step), do: %{"stepType" => step.id}
  @impl true
  def merge(_step, _other), do: nil
  @impl true
  def map(_step, _mapping), do: nil
  @impl true
  def from_json(_schema, json), do: %__MODULE__{id: json["stepType"]}
end

defmodule ProsemirrorEx.Transform.StepTest.FakeStep do
  @behaviour ProsemirrorEx.Transform.Step
  alias ProsemirrorEx.Transform.{StepMap, StepResult}

  @impl true
  def apply(_step, _doc), do: StepResult.fail("not implemented")
  @impl true
  def invert(_step, _doc), do: nil
  @impl true
  def step_map(_step), do: StepMap.empty()
  @impl true
  def to_json(_step), do: %{}
  @impl true
  def merge(_step, _other), do: nil
  @impl true
  def map(_step, _mapping), do: nil
  @impl true
  def from_json(_schema, _json), do: %{}
end

defmodule ProsemirrorEx.Transform.StepTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Transform.{Step, StepResult, TransformError}
  alias ProsemirrorEx.Transform.StepTest.{ConcurrentStep, FakeStep, OverrideStep}

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

    test "from_replace/4 returns fail on out-of-bounds positions" do
      {doc_node, _tags} = doc([p(["hello"])])
      slice = ProsemirrorEx.Model.Slice.empty()

      assert %StepResult{doc: nil, failed: msg1} = StepResult.from_replace(doc_node, -1, 2, slice)
      assert is_binary(msg1)

      assert %StepResult{doc: nil, failed: msg2} =
               StepResult.from_replace(doc_node, 0, 999, slice)

      assert is_binary(msg2)

      assert %StepResult{doc: nil, failed: msg3} = StepResult.from_replace(doc_node, 4, 2, slice)
      assert is_binary(msg3)
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

    test "Step dispatch wrappers delegate to step struct module" do
      {doc_node, _} = doc([p(["hello"])])
      schema = test_schema()
      text = ProsemirrorEx.Model.Schema.text(schema, "a")
      slice = ProsemirrorEx.Model.Slice.new(ProsemirrorEx.Model.Fragment.from(text), 0, 0)
      step1 = ProsemirrorEx.Transform.ReplaceStep.new(6, 6, slice)
      step2 = ProsemirrorEx.Transform.ReplaceStep.new(7, 7, slice)

      res = Step.apply(step1, doc_node)
      assert res.failed == nil

      inv = Step.invert(step1, doc_node)
      assert Step.apply(inv, res.doc).doc |> ProsemirrorEx.Model.Node.eq(doc_node)

      assert Step.step_map(step1) == ProsemirrorEx.Transform.StepMap.new([6, 0, 1])
      assert Step.to_json(step1)["stepType"] == "replace"
      assert Step.merge(step1, step2) != nil

      mapped = Step.map(step1, ProsemirrorEx.Transform.StepMap.offset(2))
      assert mapped.from == 8
    end
  end

  describe "Step registry" do
    test "built-in steps work without StepRegistry and ensure_registered returns :ok" do
      assert ProsemirrorEx.Transform.StepRegistry.ensure_registered() == :ok
      step = Step.from_json(test_schema(), %{"stepType" => "replace", "from" => 1, "to" => 2})
      assert step.__struct__ == ProsemirrorEx.Transform.ReplaceStep
    end

    test "json_id/2 rejects overriding built-in step IDs" do
      for builtin <-
            ~w(replace replaceAround addMark removeMark addNodeMark removeNodeMark attr docAttr) do
        assert_raise ArgumentError, ~r/Duplicate use of step JSON ID/, fn ->
          Step.json_id(builtin, OverrideStep)
        end
      end
    end

    test "concurrent json_id/2 registrations preserve all distinct IDs" do
      prefix = "concurrent_step_#{System.unique_integer([:positive])}_"

      1..20
      |> Task.async_stream(
        fn i ->
          id = prefix <> Integer.to_string(i)
          Step.json_id(id, ConcurrentStep)
          id
        end,
        max_concurrency: 10
      )
      |> Enum.each(fn {:ok, id} ->
        assert %ConcurrentStep{id: ^id} = Step.from_json(nil, %{"stepType" => id})
      end)
    end

    test "json_id/2 registers a step module" do
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
      Step.json_id("duplicate_test_id", FakeStep)

      assert_raise ArgumentError, ~r/Duplicate use of step JSON ID/, fn ->
        Step.json_id("duplicate_test_id", FakeStep)
      end
    end
  end
end
