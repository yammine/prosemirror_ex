defmodule ProsemirrorEx.Transform.MapResult do
  @moduledoc """
  An object representing a mapped position with extra information.

  Ports `MapResult` from prosemirror-transform/src/map.ts.
  """

  import Bitwise

  @del_before 1
  @del_after 2
  @del_across 4
  @del_side 8

  defstruct [:pos, :del_info, :recover]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          del_info: non_neg_integer(),
          recover: non_neg_integer() | nil
        }

  @doc "Bitmask constant for deletion before."
  def del_before, do: @del_before

  @doc "Bitmask constant for deletion after."
  def del_after, do: @del_after

  @doc "Bitmask constant for deletion across."
  def del_across, do: @del_across

  @doc "Bitmask constant for deletion on the queried side."
  def del_side, do: @del_side

  @doc """
  Tells you whether the position was deleted, that is, whether the
  step removed the token on the side queried (via the `assoc` argument)
  from the document.
  """
  @spec deleted?(t()) :: boolean()
  def deleted?(%__MODULE__{del_info: del_info}) do
    (del_info &&& @del_side) > 0
  end

  @doc """
  Tells you whether the token before the mapped position was deleted.
  """
  @spec deleted_before?(t()) :: boolean()
  def deleted_before?(%__MODULE__{del_info: del_info}) do
    (del_info &&& (@del_before ||| @del_across)) > 0
  end

  @doc """
  True when the token after the mapped position was deleted.
  """
  @spec deleted_after?(t()) :: boolean()
  def deleted_after?(%__MODULE__{del_info: del_info}) do
    (del_info &&& (@del_after ||| @del_across)) > 0
  end

  @doc """
  Tells whether any of the steps mapped through deletes across the
  position (including both the token before and after the position).
  """
  @spec deleted_across?(t()) :: boolean()
  def deleted_across?(%__MODULE__{del_info: del_info}) do
    (del_info &&& @del_across) > 0
  end
end
