defmodule ProsemirrorEx.Model.Slice do
  @moduledoc """
  A slice represents a piece cut out of a larger document. It stores not only
  a fragment, but also the depth up to which nodes on both sides are 'open'
  (cut through).

  Ported from ProseMirror's replace.ts Slice class.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode

  defstruct [:content, :open_start, :open_end]

  @type t :: %__MODULE__{}

  @doc "Create a new slice."
  def new(%Fragment{} = content, open_start, open_end) do
    %__MODULE__{content: content, open_start: open_start, open_end: open_end}
  end

  @doc "The size this slice would add when inserted into a document."
  def size(%__MODULE__{content: content, open_start: open_start, open_end: open_end}) do
    content.size - open_start - open_end
  end

  @doc "Insert a fragment at the given position in this slice."
  def insert_at(%__MODULE__{} = slice, pos, %Fragment{} = fragment) do
    content = insert_into(slice.content, pos + slice.open_start, fragment)

    if content do
      new(content, slice.open_start, slice.open_end)
    else
      nil
    end
  end

  @doc "Remove content between the given positions in this slice."
  def remove_between(%__MODULE__{} = slice, from, to) do
    content = remove_range(slice.content, from + slice.open_start, to + slice.open_start)
    new(content, slice.open_start, slice.open_end)
  end

  @doc "Test whether this slice is equal to another slice."
  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    Fragment.eq(a.content, b.content) and
      a.open_start == b.open_start and
      a.open_end == b.open_end
  end

  @doc "String representation of this slice."
  def to_string(%__MODULE__{} = slice) do
    content_str = Fragment.to_string_inner(slice.content)

    # Wrap with the outer node type if the content is a single node
    content_repr =
      case slice.content.content do
        [single] ->
          PmNode.debug_string(single)

        _ ->
          content_str
      end

    "<#{content_repr}>(#{slice.open_start},#{slice.open_end})"
  end

  @doc "Convert a slice to a JSON-serializable representation."
  def to_json(%__MODULE__{content: content, open_start: open_start, open_end: open_end}) do
    if content.size == 0 do
      nil
    else
      json = %{"content" => Fragment.to_json(content)}
      json = if open_start > 0, do: Map.put(json, "openStart", open_start), else: json
      json = if open_end > 0, do: Map.put(json, "openEnd", open_end), else: json
      json
    end
  end

  @doc "Deserialize a slice from its JSON representation."
  def from_json(_schema, nil), do: empty()
  def from_json(_schema, json) when json == %{}, do: empty()

  def from_json(schema, json) when is_map(json) do
    open_start = json["openStart"] || 0
    open_end = json["openEnd"] || 0

    unless is_integer(open_start) and is_integer(open_end) do
      raise ArgumentError, "Invalid input for Slice.fromJSON"
    end

    new(Fragment.from_json(schema, json["content"]), open_start, open_end)
  end

  @doc """
  Create a slice from a fragment by taking the maximum possible
  open value on both sides of the fragment.
  """
  def max_open(%Fragment{} = fragment, open_isolating \\ true) do
    open_start = compute_open_start(Fragment.first_child(fragment), open_isolating, 0)
    open_end = compute_open_end(Fragment.last_child(fragment), open_isolating, 0)
    new(fragment, open_start, open_end)
  end

  defp compute_open_start(nil, _open_isolating, depth), do: depth

  defp compute_open_start(%ProsemirrorEx.Model.Node{} = node, open_isolating, depth) do
    if PmNode.is_leaf(node) or (!open_isolating and Map.get(node.type.spec, "isolating", false)) do
      depth
    else
      compute_open_start(PmNode.first_child(node), open_isolating, depth + 1)
    end
  end

  defp compute_open_end(nil, _open_isolating, depth), do: depth

  defp compute_open_end(%ProsemirrorEx.Model.Node{} = node, open_isolating, depth) do
    if PmNode.is_leaf(node) or (!open_isolating and Map.get(node.type.spec, "isolating", false)) do
      depth
    else
      compute_open_end(PmNode.last_child(node), open_isolating, depth + 1)
    end
  end

  @doc "The empty slice."
  def empty do
    %__MODULE__{content: Fragment.empty(), open_start: 0, open_end: 0}
  end

  # ── Helper functions ────────────────────────────────────────────────

  @doc false
  def remove_range(%Fragment{} = content, from, to) do
    {index, offset} = Fragment.find_index(content, from)
    child = Fragment.maybe_child(content, index)
    {index_to, offset_to} = Fragment.find_index(content, to)

    if offset == from or (child && PmNode.is_text(child)) do
      if offset_to != to and !PmNode.is_text(Fragment.child(content, index_to)) do
        raise ProsemirrorEx.Model.RangeError, "Removing non-flat range"
      end

      Fragment.append(Fragment.cut(content, 0, from), Fragment.cut(content, to))
    else
      if index != index_to do
        raise ProsemirrorEx.Model.RangeError, "Removing non-flat range"
      end

      Fragment.replace_child(
        content,
        index,
        PmNode.copy(child, remove_range(child.content, from - offset - 1, to - offset - 1))
      )
    end
  end

  @doc false
  def insert_into(%Fragment{} = content, dist, %Fragment{} = insert, parent \\ nil) do
    {index, offset} = Fragment.find_index(content, dist)
    child = Fragment.maybe_child(content, index)

    if offset == dist or (child && PmNode.is_text(child)) do
      if parent && !PmNode.can_replace(parent, index, index, insert) do
        nil
      else
        content
        |> Fragment.cut(0, dist)
        |> Fragment.append(insert)
        |> Fragment.append(Fragment.cut(content, dist))
      end
    else
      inner = insert_into(child.content, dist - offset - 1, insert)

      if inner do
        Fragment.replace_child(content, index, PmNode.copy(child, inner))
      else
        nil
      end
    end
  end
end
