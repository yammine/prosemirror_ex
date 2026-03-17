defprotocol ProsemirrorEx.Transform.Mappable do
  @moduledoc """
  Protocol for things that positions can be mapped through.

  Ports the `Mappable` interface from prosemirror-transform/src/map.ts.
  """

  @doc """
  Map a position through this object. `assoc` determines with which side
  the position is associated (-1 or 1, defaults to 1), which determines
  in which direction to move when a chunk of content is inserted at the
  mapped position.
  """
  @spec map(t(), non_neg_integer(), integer()) :: non_neg_integer()
  def map(mappable, pos, assoc)

  @doc """
  Map a position, and return a MapResult containing additional
  information about the mapping.
  """
  @spec map_result(t(), non_neg_integer(), integer()) :: ProsemirrorEx.Transform.MapResult.t()
  def map_result(mappable, pos, assoc)
end
