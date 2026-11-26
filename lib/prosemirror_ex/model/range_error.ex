defmodule ProsemirrorEx.Model.RangeError do
  @moduledoc "Error raised when a position or index is outside valid range."
  defexception [:message]
end
