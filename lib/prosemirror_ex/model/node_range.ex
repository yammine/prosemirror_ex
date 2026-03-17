defmodule ProsemirrorEx.Model.NodeRange do
  @moduledoc """
  Represents a flat range of content, i.e. one that starts and ends in the
  same node.

  Ported from ProseMirror's resolvedpos.ts (NodeRange class).
  """

  alias ProsemirrorEx.Model.ResolvedPos

  defstruct [:from, :to, :depth]

  @doc "The position at the start of the range."
  def start(%__MODULE__{from: from, depth: depth}) do
    ResolvedPos.before(from, depth + 1)
  end

  @doc "The position at the end of the range."
  def end_pos(%__MODULE__{to: to, depth: depth}) do
    ResolvedPos.after_pos(to, depth + 1)
  end

  @doc "The parent node that the range points into."
  def parent(%__MODULE__{from: from, depth: depth}) do
    ResolvedPos.node(from, depth)
  end

  @doc "The start index of the range in the parent node."
  def start_index(%__MODULE__{from: from, depth: depth}) do
    ResolvedPos.index(from, depth)
  end

  @doc "The end index of the range in the parent node."
  def end_index(%__MODULE__{to: to, depth: depth}) do
    ResolvedPos.index_after(to, depth)
  end
end
