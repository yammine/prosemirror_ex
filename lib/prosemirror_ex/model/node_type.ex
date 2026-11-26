defmodule ProsemirrorEx.Model.NodeType do
  @moduledoc "A node type is a specification for a type of node in a schema."

  alias ProsemirrorEx.Model.ContentMatch
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.MarkType
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Schema

  @type t :: %__MODULE__{
          name: String.t() | nil,
          schema: Schema.t() | nil,
          spec: map() | nil,
          groups: [String.t()] | nil,
          content_match: ContentMatch.t() | nil,
          mark_set: [MarkType.t()] | nil,
          mark_set_names: MapSet.t(String.t()) | nil,
          inline_content: boolean() | nil,
          is_block: boolean() | nil,
          is_text: boolean() | nil,
          is_inline: boolean() | nil,
          is_textblock: boolean() | nil,
          is_leaf: boolean() | nil,
          is_atom: boolean() | nil,
          default_attrs: map() | nil,
          attrs: map() | nil,
          has_required_attrs: boolean() | nil
        }

  defstruct [
    :name,
    :schema,
    :spec,
    :groups,
    :content_match,
    :mark_set,
    :mark_set_names,
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
  @spec is_in_group(t(), String.t()) :: boolean()
  def is_in_group(%__MODULE__{groups: groups}, group) when is_list(groups) do
    Enum.member?(groups, group)
  end

  def is_in_group(%__MODULE__{groups: nil}, _group), do: false

  @doc "Check whether this node type has any required attributes."
  @spec has_required_attrs?(t()) :: boolean()
  def has_required_attrs?(%__MODULE__{has_required_attrs: val}), do: val == true

  @doc "Get the whitespace mode for this node type."
  @spec whitespace(t()) :: String.t()
  def whitespace(%__MODULE__{spec: spec}) do
    cond do
      Map.has_key?(spec, "whitespace") -> spec["whitespace"]
      Map.get(spec, "code", false) == true -> "pre"
      true -> "normal"
    end
  end

  @doc "Get the `leafText` function or string configured on this node type's spec, if any."
  @spec leaf_text(t()) :: (PmNode.t() -> String.t()) | String.t() | nil
  def leaf_text(%__MODULE__{spec: nil}), do: nil

  def leaf_text(%__MODULE__{spec: spec}) when is_map(spec) do
    Map.get(spec, "leafText") || Map.get(spec, :leafText)
  end

  @doc "Check whether this node type allows a given mark type."
  @spec allows_mark_type(t(), MarkType.t()) :: boolean()
  def allows_mark_type(%__MODULE__{mark_set: nil}, _mark_type), do: true

  def allows_mark_type(%__MODULE__{mark_set_names: %MapSet{} = names}, %MarkType{name: name}) do
    MapSet.member?(names, name)
  end

  def allows_mark_type(%__MODULE__{mark_set: mark_set}, %MarkType{name: name})
      when is_list(mark_set) do
    Enum.any?(mark_set, fn mt -> mt.name == name end)
  end

  @doc "Test whether the given set of marks are allowed in this node."
  @spec allows_marks(t(), [Mark.t()]) :: boolean()
  def allows_marks(%__MODULE__{mark_set: nil}, _marks), do: true

  def allows_marks(%__MODULE__{} = type, marks) when is_list(marks) do
    Enum.all?(marks, fn mark -> allows_mark_type(type, mark.type) end)
  end

  @doc "Removes the marks that are not allowed in this node from the given set."
  @spec allowed_marks(t(), [Mark.t()]) :: [Mark.t()]
  def allowed_marks(%__MODULE__{mark_set: nil}, marks), do: marks

  def allowed_marks(%__MODULE__{} = type, marks) when is_list(marks) do
    case do_allowed_marks(type, marks) do
      {:unchanged, _} -> marks
      {:changed, filtered} -> filtered
    end
  end

  defp do_allowed_marks(_type, []), do: {:unchanged, []}

  defp do_allowed_marks(type, [mark | rest]) do
    allowed = allows_mark_type(type, mark.type)

    case do_allowed_marks(type, rest) do
      {:unchanged, _} ->
        if allowed, do: {:unchanged, [mark | rest]}, else: {:changed, rest}

      {:changed, tail} ->
        if allowed, do: {:changed, [mark | tail]}, else: {:changed, tail}
    end
  end

  @doc "Indicates whether this node allows some of the same content as the given node type."
  @spec compatible_content(t(), t()) :: boolean()
  def compatible_content(%__MODULE__{name: name}, %__MODULE__{name: name}), do: true

  def compatible_content(%__MODULE__{content_match: cm_a}, %__MODULE__{content_match: cm_b}) do
    ContentMatch.compatible(cm_a, cm_b)
  end

  @doc "Compute attrs, filling in defaults for missing values."
  @spec compute_attrs(t(), map() | nil) :: map()
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
  @spec create(
          t(),
          map() | nil,
          Fragment.t() | PmNode.t() | [PmNode.t()] | nil,
          [Mark.t()] | Mark.t() | nil
        ) ::
          PmNode.t()
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
  @spec create_checked(
          t(),
          map() | nil,
          Fragment.t() | PmNode.t() | [PmNode.t()] | nil,
          [Mark.t()] | Mark.t() | nil
        ) :: PmNode.t()
  def create_checked(type, attrs \\ nil, content \\ nil, marks \\ nil)

  def create_checked(%__MODULE__{is_text: true}, _attrs, _content, _marks) do
    raise "NodeType.create_checked can't construct text nodes"
  end

  def create_checked(%__MODULE__{} = type, attrs, content, marks) do
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
  @spec create_and_fill(
          t(),
          map() | nil,
          Fragment.t() | PmNode.t() | [PmNode.t()] | nil,
          [Mark.t()] | Mark.t() | nil
        ) :: PmNode.t() | nil
  def create_and_fill(type, attrs \\ nil, content \\ nil, marks \\ nil)

  def create_and_fill(%__MODULE__{is_text: true}, _attrs, _content, _marks) do
    raise "NodeType.create_and_fill can't construct text nodes"
  end

  def create_and_fill(%__MODULE__{content_match: nil} = type, attrs, _content, marks) do
    computed_attrs = compute_attrs(type, attrs)
    mark_list = Mark.set_from(marks)

    %PmNode{
      type: type,
      attrs: computed_attrs,
      content: Fragment.empty(),
      marks: mark_list,
      text: nil
    }
  end

  def create_and_fill(%__MODULE__{} = type, attrs, content, marks) do
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

  @doc "Returns true if the given fragment is valid content for this node type."
  @spec valid_content(t(), Fragment.t()) :: boolean()
  def valid_content(%__MODULE__{} = type, %Fragment{} = content) do
    result = ContentMatch.match_fragment(type.content_match, content)

    if result == nil || !result.valid_end do
      false
    else
      valid_marks?(type, content)
    end
  end

  defp valid_marks?(_type, %Fragment{content: []}), do: true

  defp valid_marks?(type, %Fragment{content: content}) do
    Enum.all?(content, fn child ->
      allows_marks(type, child.marks || [])
    end)
  end

  @doc "Raises a RuntimeError if the given fragment is not valid content for this node type."
  @spec check_content(t(), Fragment.t()) :: :ok
  def check_content(%__MODULE__{} = type, %Fragment{} = content) do
    unless valid_content(type, content) do
      preview_frag =
        case content.content do
          [] -> content
          children -> %Fragment{content: Enum.take(children, 50), size: content.size}
        end

      content_str = Fragment.to_string_inner(preview_frag)
      truncated = String.slice(content_str, 0, 50)
      raise "Invalid content for node #{type.name}: #{truncated}"
    end

    :ok
  end

  @doc "Validate attributes against the spec."
  @spec check_attrs(t(), map() | nil) :: :ok
  def check_attrs(%__MODULE__{attrs: attrs}, values) do
    Schema.validate_attrs(attrs || %{}, values, "node")
  end

  @doc "Validate raw JSON attribute keys against the node type's attribute spec before defaulting."
  @spec check_attrs_map(t(), term()) :: :ok
  def check_attrs_map(%__MODULE__{name: name, attrs: attrs}, raw_attrs) do
    Schema.check_attrs_map(attrs || %{}, raw_attrs, "node #{name}")
  end
end
