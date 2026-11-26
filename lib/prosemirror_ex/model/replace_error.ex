defmodule ProsemirrorEx.Model.ReplaceError do
  @moduledoc "Error raised when a document replacement violates structural constraints."
  defexception [:message]
end
