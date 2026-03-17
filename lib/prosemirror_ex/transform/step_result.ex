defmodule ProsemirrorEx.Transform.StepResult do
  @moduledoc """
  The result of applying a step. Contains either a new document or a failure value.

  Ports `StepResult` from prosemirror-transform/src/step.ts.
  """

  alias ProsemirrorEx.Model.ReplaceError

  defstruct [:doc, :failed]

  @type t :: %__MODULE__{
          doc: ProsemirrorEx.Model.Node.t() | nil,
          failed: String.t() | nil
        }

  @doc "Create a successful step result."
  def ok(doc) do
    %__MODULE__{doc: doc, failed: nil}
  end

  @doc "Create a failed step result."
  def fail(message) do
    %__MODULE__{doc: nil, failed: message}
  end

  @doc """
  Call `Node.replace` with the given arguments. Create a successful result
  if it succeeds, and a failed one if it throws a `ReplaceError`.
  """
  def from_replace(doc, from, to, slice) do
    try do
      ok(ProsemirrorEx.Model.Node.replace(doc, from, to, slice))
    rescue
      e in ReplaceError ->
        fail(e.message)
    end
  end
end
