defmodule ProsemirrorEx.Transform.StepResult do
  @moduledoc """
  The result of applying a step. Contains either a new document or a failure value.

  Ports `StepResult` from prosemirror-transform/src/step.ts.
  """

  alias ProsemirrorEx.Model.{Fragment, Node, RangeError, ReplaceError, Slice}

  defstruct [:doc, :failed]

  @type t :: %__MODULE__{
          doc: Node.t() | nil,
          failed: String.t() | nil
        }

  @doc "Create a successful step result."
  @spec ok(Node.t()) :: t()
  def ok(doc) do
    %__MODULE__{doc: doc, failed: nil}
  end

  @doc "Create a failed step result."
  @spec fail(String.t()) :: t()
  def fail(message) do
    %__MODULE__{doc: nil, failed: message}
  end

  @doc """
  Call `Node.replace` with the given arguments. Create a successful result
  if it succeeds, and a failed one if it throws a `ReplaceError`, `RangeError`,
  or the positions are out of bounds.
  """
  @spec from_replace(Node.t(), integer(), integer(), Slice.t()) :: t()
  def from_replace(%Node{} = doc, from, to, %Slice{} = slice)
      when is_integer(from) and is_integer(to) do
    doc_size = (doc.content || Fragment.empty()).size

    if from < 0 or to > doc_size or from > to do
      fail("Position out of range")
    else
      try do
        ok(Node.replace(doc, from, to, slice))
      rescue
        e in [ReplaceError, RangeError] ->
          fail(e.message)
      end
    end
  end
end
