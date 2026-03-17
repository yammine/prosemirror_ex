defmodule ProsemirrorEx.Transform.StepRegistry do
  @moduledoc false

  alias ProsemirrorEx.Transform.Step

  @doc """
  Ensure all built-in step types are registered.
  Safe to call multiple times — duplicate registrations are silently ignored.
  """
  def ensure_registered do
    register("replace", ProsemirrorEx.Transform.ReplaceStep)
    register("replaceAround", ProsemirrorEx.Transform.ReplaceAroundStep)
    register("addMark", ProsemirrorEx.Transform.AddMarkStep)
    register("removeMark", ProsemirrorEx.Transform.RemoveMarkStep)
    register("addNodeMark", ProsemirrorEx.Transform.AddNodeMarkStep)
    register("removeNodeMark", ProsemirrorEx.Transform.RemoveNodeMarkStep)
    register("attr", ProsemirrorEx.Transform.AttrStep)
    register("docAttr", ProsemirrorEx.Transform.DocAttrStep)
    :ok
  end

  defp register(id, module) do
    try do
      Step.json_id(id, module)
    rescue
      ArgumentError -> :ok
    end
  end
end
