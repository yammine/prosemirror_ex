defmodule ProsemirrorEx.Transform.Step do
  @moduledoc """
  A step object represents an atomic change. It generally applies only to the
  document it was created for, since the positions stored in it will only make
  sense for that document.

  This module defines the behaviour that all step types must implement,
  provides dispatch helpers for step operations, and manages the registry
  for custom JSON step types.

  Ports `Step` from prosemirror-transform/src/step.ts.
  """

  alias ProsemirrorEx.Model.{Mark, Node, Schema, Slice}
  alias ProsemirrorEx.Transform.{Mappable, StepMap, StepResult}

  @registry_key {__MODULE__, :registry}

  @builtin_step_types ~w(
    replace
    replaceAround
    addMark
    removeMark
    addNodeMark
    removeNodeMark
    attr
    docAttr
  )

  @type step :: struct()

  @doc "Applies this step to the given document, returning a StepResult."
  @callback apply(step :: step(), doc :: Node.t()) :: StepResult.t()

  @doc "Create an inverted version of this step. Needs the document as it was before the step."
  @callback invert(step :: step(), doc :: Node.t()) :: step()

  @doc "Get the step map that represents the changes made by this step."
  @callback step_map(step :: step()) :: StepMap.t()

  @doc "Create a JSON-serializable representation of this step."
  @callback to_json(step :: step()) :: map()

  @doc "Try to merge this step with another one. Returns the merged step or nil."
  @callback merge(step :: step(), other :: step()) :: step() | nil

  @doc "Map this step through a mappable thing, returning a mapped step or nil."
  @callback map(step :: step(), mappable :: Mappable.t()) :: step() | nil

  @doc "Deserialize a step from its JSON representation."
  @callback from_json(schema :: Schema.t() | nil, json :: map()) :: step()

  # ── Behaviour dispatch helpers ───────────────────────────────────────

  @doc "Apply `step` to `doc`, returning a `StepResult`."
  @spec apply(step(), Node.t()) :: StepResult.t()
  def apply(%{__struct__: mod} = step, doc), do: mod.apply(step, doc)

  @doc "Create an inverted version of `step` relative to pre-step `doc`."
  @spec invert(step(), Node.t()) :: step()
  def invert(%{__struct__: mod} = step, doc), do: mod.invert(step, doc)

  @doc "Get the `StepMap` describing the position changes of `step`."
  @spec step_map(step()) :: StepMap.t()
  def step_map(%{__struct__: mod} = step), do: mod.step_map(step)

  @doc "Serialize `step` to a JSON-compatible map."
  @spec to_json(step()) :: map()
  def to_json(%{__struct__: mod} = step), do: mod.to_json(step)

  @doc "Try to merge `step` with `other`. Returns the merged step or nil."
  @spec merge(step(), step()) :: step() | nil
  def merge(%{__struct__: mod} = step, other), do: mod.merge(step, other)

  @doc "Map `step` through `mappable`. Returns the mapped step or nil."
  @spec map(step(), Mappable.t()) :: step() | nil
  def map(%{__struct__: mod} = step, mappable), do: mod.map(step, mappable)

  # ── Registry & JSON deserialization ──────────────────────────────────

  @doc """
  Register a custom step module under a string ID for JSON serialization.
  Raises `ArgumentError` if the ID is a built-in step type or already registered.
  """
  @spec json_id(String.t(), module()) :: module()
  def json_id(id, module) when is_binary(id) and is_atom(module) do
    if id in @builtin_step_types do
      raise ArgumentError, "Duplicate use of step JSON ID #{id}"
    end

    :global.trans({{__MODULE__, :registry_lock}, self()}, fn ->
      registry = get_registry()

      if Map.has_key?(registry, id) do
        raise ArgumentError, "Duplicate use of step JSON ID #{id}"
      end

      :persistent_term.put(@registry_key, Map.put(registry, id, module))
      module
    end)
  end

  def json_id(id, _module) do
    raise ArgumentError, "Invalid step JSON ID #{inspect(id)}"
  end

  @doc """
  Deserialize a step from its JSON representation.
  Dispatches built-in step types directly and custom step types via the registry.
  """
  @spec from_json(Schema.t() | nil, term()) :: step()
  def from_json(schema, json) when is_map(json) and not is_struct(json) do
    case Map.fetch(json, "stepType") do
      :error ->
        raise ArgumentError, "Invalid input for Step.from_json"

      {:ok, step_type} when not is_binary(step_type) ->
        raise ArgumentError,
              "Invalid input for Step.from_json: invalid stepType #{inspect(step_type)}"

      {:ok, "replace"} ->
        ProsemirrorEx.Transform.ReplaceStep.from_json(schema, json)

      {:ok, "replaceAround"} ->
        ProsemirrorEx.Transform.ReplaceAroundStep.from_json(schema, json)

      {:ok, "addMark"} ->
        ProsemirrorEx.Transform.AddMarkStep.from_json(schema, json)

      {:ok, "removeMark"} ->
        ProsemirrorEx.Transform.RemoveMarkStep.from_json(schema, json)

      {:ok, "addNodeMark"} ->
        ProsemirrorEx.Transform.AddNodeMarkStep.from_json(schema, json)

      {:ok, "removeNodeMark"} ->
        ProsemirrorEx.Transform.RemoveNodeMarkStep.from_json(schema, json)

      {:ok, "attr"} ->
        ProsemirrorEx.Transform.AttrStep.from_json(schema, json)

      {:ok, "docAttr"} ->
        ProsemirrorEx.Transform.DocAttrStep.from_json(schema, json)

      {:ok, step_type} ->
        case Map.get(get_registry(), step_type) do
          nil -> raise ArgumentError, "No step type #{inspect(step_type)} defined"
          module -> module.from_json(schema, json)
        end
    end
  end

  def from_json(_schema, _json) do
    raise ArgumentError, "Invalid input for Step.from_json"
  end

  # ── Shared JSON validation helpers for step implementations ────────────

  @doc false
  @spec validate_json_map!(term(), String.t()) :: :ok
  def validate_json_map!(json, _step_name) when is_map(json) and not is_struct(json), do: :ok

  def validate_json_map!(_json, step_name) do
    raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
  end

  @doc false
  @spec parse_non_neg_int!(map(), String.t(), String.t()) :: non_neg_integer()
  def parse_non_neg_int!(json, key, step_name) do
    case Map.get(json, key) do
      val when is_integer(val) and val >= 0 -> val
      _ -> raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
    end
  end

  @doc false
  @spec parse_boolean!(map(), String.t(), boolean(), String.t()) :: boolean()
  def parse_boolean!(json, key, default, step_name) do
    case Map.get(json, key) do
      nil -> default
      val when is_boolean(val) -> val
      _ -> raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
    end
  end

  @doc false
  @spec parse_slice!(Schema.t() | nil, term(), String.t()) :: Slice.t()
  def parse_slice!(schema, slice_json, step_name) do
    unless is_nil(slice_json) or (is_map(slice_json) and not is_struct(slice_json)) do
      raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
    end

    try do
      Slice.from_json(schema, slice_json)
    rescue
      e in [ArgumentError] ->
        reraise e, __STACKTRACE__

      e in [RuntimeError] ->
        raise ArgumentError, Exception.message(e)
    end
  end

  @doc false
  @spec parse_mark!(Schema.t() | nil, term(), String.t()) :: Mark.t()
  def parse_mark!(schema, mark_json, step_name) do
    unless is_map(mark_json) and not is_struct(mark_json) do
      raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
    end

    try do
      Schema.mark_from_json(schema, mark_json)
    rescue
      e in [ArgumentError] ->
        reraise e, __STACKTRACE__

      e in [RuntimeError] ->
        raise ArgumentError, Exception.message(e)
    end
  end

  defp get_registry do
    :persistent_term.get(@registry_key, %{})
  end
end
