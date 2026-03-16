defmodule ProsemirrorEx.Model.Node do
  @moduledoc """
  Minimal Node stub. Full implementation comes in Task 7.

  This module represents a ProseMirror document node. It holds a type,
  optional attributes, a content Fragment, marks, and (for text nodes) text.
  """

  alias ProsemirrorEx.Model.{Fragment, Mark, CompareDeep}

  defstruct [:type, :attrs, :content, :marks, :text]

  @doc "The size of this node as counted by the indexing scheme. For text nodes this is the text length, for leaf nodes it is 1, and for non-leaf nodes it is the content size + 2 (for the open and close tokens)."
  def node_size(%__MODULE__{text: text}) when is_binary(text), do: String.length(text)
  def node_size(%__MODULE__{type: %{is_leaf: true}}), do: 1
  def node_size(%__MODULE__{content: nil}), do: 2
  def node_size(%__MODULE__{content: %Fragment{size: size}}), do: 2 + size

  @doc "True when this is a text node."
  def is_text(%__MODULE__{text: text}), do: is_binary(text)

  @doc "Test whether the markup (type, attributes, marks) of this node is the same as that of another."
  def same_markup(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_type(a.type, b.type) and
      CompareDeep.compare(a.attrs || %{}, b.attrs || %{}) and
      Mark.same_set(a.marks || [], b.marks || [])
  end

  # Compare types by name (works with both full NodeType structs and plain maps)
  defp same_type(%{name: name_a}, %{name: name_b}), do: name_a == name_b
  defp same_type(a, b), do: a == b

  @doc "Test whether this node is the same as another node (structurally equal)."
  def eq(%__MODULE__{text: text_a} = a, %__MODULE__{} = b) when is_binary(text_a) do
    same_markup(a, b) and text_a == b.text
  end

  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_markup(a, b) and
      Fragment.eq(a.content || Fragment.empty(), b.content || Fragment.empty())
  end

  @doc "Create a copy of this node with the given content."
  def copy(%__MODULE__{} = node, content) do
    if content == node.content, do: node, else: %{node | content: content}
  end

  @doc "Cut the text or content of this node between the given positions."
  def cut(node, from, to \\ nil)

  def cut(%__MODULE__{text: text} = node, from, to) when is_binary(text) do
    to = to || String.length(text)

    if from == 0 and to == String.length(text) do
      node
    else
      %{node | text: String.slice(text, from, to - from)}
    end
  end

  def cut(%__MODULE__{content: content} = node, from, to) do
    to = to || content.size

    if from == 0 and to == content.size do
      node
    else
      %{node | content: Fragment.cut(content, from, to)}
    end
  end

  @doc "Create a text node with the same type, attributes, and marks but different text."
  def with_text(%__MODULE__{} = node, text) do
    if text == node.text, do: node, else: %{node | text: text}
  end

  @doc "Serialize this node to JSON."
  def to_json(%__MODULE__{} = node) do
    result = %{"type" => node.type.name}

    result =
      if node.attrs != nil and node.attrs != %{} do
        Map.put(result, "attrs", node.attrs)
      else
        result
      end

    result =
      if is_binary(node.text) do
        Map.put(result, "text", node.text)
      else
        case Fragment.to_json(node.content || Fragment.empty()) do
          nil -> result
          content_json -> Map.put(result, "content", content_json)
        end
      end

    result =
      if node.marks != nil and node.marks != [] do
        Map.put(result, "marks", Enum.map(node.marks, &Mark.to_json/1))
      else
        result
      end

    result
  end
end
