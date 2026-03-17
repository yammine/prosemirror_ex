defmodule ProsemirrorEx.Transform.TransformError do
  @moduledoc """
  Error raised when a transform operation fails.
  """
  defexception [:message]
end
