defmodule ProsemirrorEx.Transform.Step do
  @moduledoc """
  A step object represents an atomic change. It generally applies only to the
  document it was created for, since the positions stored in it will only make
  sense for that document.

  This module defines the behaviour that all step types must implement,
  and provides a registry for JSON serialization/deserialization.

  Ports `Step` from prosemirror-transform/src/step.ts.
  """

  alias ProsemirrorEx.Transform.{StepMap, StepResult}

  @registry_key {__MODULE__, :registry}

  @doc "Applies this step to the given document, returning a StepResult."
  @callback apply(step :: term(), doc :: term()) :: StepResult.t()

  @doc "Create an inverted version of this step. Needs the document as it was before the step."
  @callback invert(step :: term(), doc :: term()) :: term()

  @doc "Get the step map that represents the changes made by this step."
  @callback step_map(step :: term()) :: StepMap.t()

  @doc "Create a JSON-serializable representation of this step."
  @callback to_json(step :: term()) :: map()

  @doc "Try to merge this step with another one. Returns the merged step or nil."
  @callback merge(step :: term(), other :: term()) :: term() | nil

  @doc "Map this step through a mappable thing, returning a mapped step or nil."
  @callback map(step :: term(), mappable :: term()) :: term() | nil

  @doc "Deserialize a step from its JSON representation."
  @callback from_json(schema :: term(), json :: map()) :: term()

  @doc """
  Register a step module under a string ID for JSON serialization.
  Raises if the ID is already registered.
  """
  def json_id(id, module) do
    registry = get_registry()

    if Map.has_key?(registry, id) do
      raise ArgumentError, "Duplicate use of step JSON ID #{id}"
    end

    :persistent_term.put(@registry_key, Map.put(registry, id, module))
    module
  end

  @doc """
  Deserialize a step from its JSON representation.
  Dispatches to the registered module based on the `stepType` field.
  """
  def from_json(schema, json) do
    unless is_map(json) and Map.has_key?(json, "stepType") do
      raise ArgumentError, "Invalid input for Step.from_json"
    end

    step_type = json["stepType"]
    registry = get_registry()

    case Map.get(registry, step_type) do
      nil -> raise ArgumentError, "No step type #{step_type} defined"
      module -> module.from_json(schema, json)
    end
  end

  defp get_registry do
    try do
      :persistent_term.get(@registry_key)
    rescue
      ArgumentError -> %{}
    end
  end
end
