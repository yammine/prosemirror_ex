defmodule ProsemirrorEx.Model.NodeType do
  @moduledoc "A node type is a specification for a type of node in a schema."

  alias ProsemirrorEx.Model.ContentMatch
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Schema

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

  @doc "Get the whitespace mode for this node type."
  def whitespace(%__MODULE__{spec: spec}) do
    cond do
      Map.has_key?(spec, "whitespace") -> spec["whitespace"]
      Map.get(spec, "code", false) == true -> "pre"
      true -> "normal"
    end
  end

  @doc "Check whether this node type allows a given mark type."
  def allows_mark_type(%__MODULE__{mark_set: nil}, _mark_type), do: true

  def allows_mark_type(%__MODULE__{mark_set: mark_set}, mark_type) when is_list(mark_set) do
    Enum.any?(mark_set, fn mt -> mt.name == mark_type.name end)
  end

  @doc "Test whether the given set of marks are allowed in this node."
  def allows_marks(%__MODULE__{mark_set: nil}, _marks), do: true

  def allows_marks(%__MODULE__{} = type, marks) when is_list(marks) do
    Enum.all?(marks, fn mark -> allows_mark_type(type, mark.type) end)
  end

  @doc "Removes the marks that are not allowed in this node from the given set."
  def allowed_marks(%__MODULE__{mark_set: nil}, marks), do: marks

  def allowed_marks(%__MODULE__{} = type, marks) when is_list(marks) do
    filtered = Enum.filter(marks, fn mark -> allows_mark_type(type, mark.type) end)

    if length(filtered) == length(marks) do
      marks
    else
      if filtered == [], do: Mark.none(), else: filtered
    end
  end

  @doc "Indicates whether this node allows some of the same content as the given node type."
  def compatible_content(%__MODULE__{name: name}, %__MODULE__{name: name}), do: true

  def compatible_content(%__MODULE__{content_match: cm_a}, %__MODULE__{content_match: cm_b}) do
    ContentMatch.compatible(cm_a, cm_b)
  end

  @doc "Compute attrs, filling in defaults for missing values."
  def compute_attrs(%__MODULE__{attrs: attrs, default_attrs: default_attrs}, value) do
    cond do
      (value == nil || value == %{}) && default_attrs != nil -> default_attrs
      attrs == %{} -> %{}
      true -> Schema.compute_attrs(attrs, value)
    end
  end

  @doc """
  Create a Node of this type. The given attributes are checked and
  defaulted. `content` may be a Fragment, a node, an array of nodes,
  or nil. Similarly `marks` may be nil to default to the empty set.
  Does NOT check content against the content expression.
  """
  def create(type, attrs \\ nil, content \\ nil, marks \\ nil)

  def create(%__MODULE__{is_text: true}, _attrs, _content, _marks) do
    raise "NodeType.create can't construct text nodes"
  end

  def create(%__MODULE__{} = type, attrs, content, marks) do
    computed_attrs = compute_attrs(type, attrs)
    frag = Fragment.from(content)
    mark_list = Mark.set_from(marks)

    %PmNode{
      type: type,
      attrs: computed_attrs,
      content: frag,
      marks: mark_list,
      text: nil
    }
  end

  @doc """
  Like `create`, but check the given content against the node type's
  content restrictions, and raise an error if it doesn't match.
  """
  def create_checked(%__MODULE__{} = type, attrs, content, marks \\ nil) do
    frag = Fragment.from(content)
    check_content(type, frag)
    computed_attrs = compute_attrs(type, attrs)
    mark_list = Mark.set_from(marks)

    %PmNode{
      type: type,
      attrs: computed_attrs,
      content: frag,
      marks: mark_list,
      text: nil
    }
  end

  @doc """
  Like `create`, but see if it is necessary to add nodes to the start
  or end of the given fragment to make it fit the node. If no fitting
  wrapping can be found, return nil.
  """
  def create_and_fill(%__MODULE__{} = type, attrs \\ nil, content \\ nil, marks \\ nil) do
    # When content_match is nil (type not compiled via schema), use simple fallback
    if type.content_match == nil do
      create_and_fill_simple(type, attrs, marks)
    else
      create_and_fill_full(type, attrs, content, marks)
    end
  end

  defp create_and_fill_simple(type, attrs, marks) do
    computed_attrs = compute_attrs(type, attrs)
    mark_list = Mark.set_from(marks)

    content =
      if type.content_match do
        fill_content_from_match(type.content_match)
      else
        Fragment.empty()
      end

    %PmNode{
      type: type,
      attrs: computed_attrs || %{},
      content: content,
      marks: mark_list,
      text: if(type.is_text, do: "", else: nil)
    }
  end

  defp create_and_fill_full(type, attrs, content, marks) do
    computed_attrs = compute_attrs(type, attrs)
    frag = Fragment.from(content)
    mark_list = Mark.set_from(marks)

    frag =
      if frag.size > 0 do
        case ContentMatch.fill_before(type.content_match, frag) do
          nil -> nil
          before -> Fragment.append(before, frag)
        end
      else
        frag
      end

    if frag == nil do
      nil
    else
      matched = ContentMatch.match_fragment(type.content_match, frag)
      after_frag = matched && ContentMatch.fill_before(matched, Fragment.empty(), true)

      if after_frag == nil do
        nil
      else
        %PmNode{
          type: type,
          attrs: computed_attrs,
          content: Fragment.append(frag, after_frag),
          marks: mark_list,
          text: nil
        }
      end
    end
  end

  defp fill_content_from_match(match) do
    case match do
      %{valid_end: true} ->
        Fragment.empty()

      %{next: edges} when is_list(edges) and length(edges) > 0 ->
        case Enum.find(edges, fn {type, _next} ->
               not type.is_text and not (type.has_required_attrs == true)
             end) do
          {type, _next_match} ->
            child = create_and_fill_simple(type, nil, nil)
            rest = Fragment.empty()
            Fragment.new([child | rest.content], PmNode.node_size(child) + rest.size)

          nil ->
            Fragment.empty()
        end

      _ ->
        Fragment.empty()
    end
  end

  @doc "Returns true if the given fragment is valid content for this node type."
  def valid_content(%__MODULE__{} = type, %Fragment{} = content) do
    result = ContentMatch.match_fragment(type.content_match, content)

    if result == nil || !result.valid_end do
      false
    else
      # Also check that all marks on children are allowed
      valid_marks?(type, content, 0)
    end
  end

  defp valid_marks?(_type, %Fragment{content: []}, _i), do: true

  defp valid_marks?(type, %Fragment{content: content}, _i) do
    Enum.all?(content, fn child ->
      allows_marks(type, child.marks || [])
    end)
  end

  @doc "Raises a RuntimeError if the given fragment is not valid content for this node type."
  def check_content(%__MODULE__{} = type, %Fragment{} = content) do
    unless valid_content(type, content) do
      content_str = Fragment.to_string_inner(content)
      truncated = String.slice(content_str, 0, 50)
      raise "Invalid content for node #{type.name}: #{truncated}"
    end
  end

  @doc "Validate attributes against the spec."
  def check_attrs(%__MODULE__{attrs: attrs}, values) do
    # Check for unsupported attributes
    Enum.each(values, fn {name, _val} ->
      unless Map.has_key?(attrs, name) do
        raise "Unsupported attribute #{name} for node"
      end
    end)

    # Run validators
    Enum.each(attrs, fn {attr_name, attr} ->
      if attr.validate do
        case attr.validate do
          f when is_function(f) -> f.(Map.get(values, attr_name))
          _ -> :ok
        end
      end
    end)
  end
end
