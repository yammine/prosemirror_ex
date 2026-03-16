defmodule ProsemirrorEx.Model.NodeType do
  @moduledoc "A node type is a specification for a type of node in a schema."

  defstruct [
    :name,
    :schema,
    :spec,
    :groups,
    :content_match,
    :mark_set,
    :inline_content,
    :is_block,
    :is_text,
    :is_inline,
    :is_textblock,
    :is_leaf,
    :is_atom,
    :default_attrs,
    :attrs,
    :has_required_attrs
  ]

  @doc "Check whether this node type is in the given group."
  def is_in_group(%__MODULE__{groups: groups}, group) when is_list(groups) do
    Enum.member?(groups, group)
  end

  def is_in_group(%__MODULE__{groups: nil}, _group), do: false

  @doc "Check whether this node type has any required attributes."
  def has_required_attrs?(%__MODULE__{has_required_attrs: val}), do: val == true

  @doc """
  Create a node of this type. The given attributes are checked and
  defaulted. If `content` is given, it must be a Fragment matching
  this type's content expression.

  Creates a simple node with default attributes for use in fillBefore.
  """
  def create_and_fill(%__MODULE__{} = type) do
    alias ProsemirrorEx.Model.Node, as: PmNode
    alias ProsemirrorEx.Model.Fragment

    content =
      if type.content_match do
        fill_content_from_match(type.content_match)
      else
        Fragment.empty()
      end

    %PmNode{
      type: type,
      attrs: type.default_attrs || %{},
      content: content,
      marks: [],
      text: if(type.is_text, do: "", else: nil)
    }
  end

  defp fill_content_from_match(match) do
    alias ProsemirrorEx.Model.Fragment
    alias ProsemirrorEx.Model.Node, as: PmNode

    case match do
      %{valid_end: true} ->
        Fragment.empty()

      %{next: edges} when is_list(edges) and length(edges) > 0 ->
        # Find the first edge with a generatable type
        case Enum.find(edges, fn {type, _next} ->
               not type.is_text and not (type.has_required_attrs == true)
             end) do
          {type, next_match} ->
            child = create_and_fill(type)
            rest = fill_content_from_match(next_match)
            Fragment.new([child | rest.content], PmNode.node_size(child) + rest.size)

          nil ->
            Fragment.empty()
        end

      _ ->
        Fragment.empty()
    end
  end
end
