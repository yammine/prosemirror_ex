defmodule ProsemirrorEx.Transform.StepRegistry do
  @moduledoc false

  @doc """
  Ensure all built-in step types are registered.

  Built-in step types are dispatched directly by `ProsemirrorEx.Transform.Step.from_json/2`
  without requiring runtime registration. Kept as a no-op for backwards compatibility.
  """
  @spec ensure_registered() :: :ok
  def ensure_registered do
    :ok
  end
end
