defmodule ProsemirrorEx.Model.Slice do
  @moduledoc """
  A slice represents a piece cut out of a larger document. It stores not only
  a fragment, but also the depth up to which nodes on both sides are 'open'
  (cut through).

  Ported from ProseMirror's replace.ts Slice class.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.RangeError, as: PmRangeError

  defstruct [:content, :open_start, :open_end]

  @type t :: %__MODULE__{
          content: Fragment.t(),
          open_start: non_neg_integer(),
          open_end: non_neg_integer()
        }

  @doc "Create a new slice."
  @spec new(Fragment.t(), non_neg_integer(), non_neg_integer()) :: t()
  def new(%Fragment{} = content, open_start, open_end) do
    %__MODULE__{content: content, open_start: open_start, open_end: open_end}
  end

  @doc "The size this slice would add when inserted into a document."
  @spec size(t()) :: integer()
  def size(%__MODULE__{content: content, open_start: open_start, open_end: open_end}) do
    content.size - open_start - open_end
  end

  @doc "Insert a fragment at the given position in this slice."
  @spec insert_at(t(), integer(), Fragment.t()) :: t() | nil
  def insert_at(%__MODULE__{} = slice, pos, %Fragment{} = fragment) do
    content = insert_into(slice.content, pos + slice.open_start, fragment, nil)

    if content do
      new(content, slice.open_start, slice.open_end)
    else
      nil
    end
  end

  @doc "Remove content between the given positions in this slice."
  @spec remove_between(t(), integer(), integer()) :: t()
  def remove_between(%__MODULE__{} = slice, from, to) do
    if to <= from do
      slice
    else
      content = remove_range(slice.content, from + slice.open_start, to + slice.open_start)
      new(content, slice.open_start, slice.open_end)
    end
  end

  @doc "Test whether this slice is equal to another slice."
  @spec eq(t(), t()) :: boolean()
  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    Fragment.eq(a.content, b.content) and
      a.open_start == b.open_start and
      a.open_end == b.open_end
  end

  @doc "String representation of this slice."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = slice) do
    "<#{Fragment.to_string_inner(slice.content)}>(#{slice.open_start},#{slice.open_end})"
  end

  @doc "Convert a slice to a JSON-serializable representation."
  @spec to_json(t()) :: map() | nil
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
  @spec from_json(term(), term()) :: t()
  def from_json(_schema, nil), do: empty()
  def from_json(_schema, json) when json == %{}, do: empty()

  def from_json(schema, json) when is_map(json) and not is_struct(json) do
    open_start = parse_open_depth(json, "openStart")
    open_end = parse_open_depth(json, "openEnd")

    content = Fragment.from_json_for_slice(schema, Map.get(json, "content"))
    slice = new(content, open_start, open_end)

    if size(slice) < 0 do
      raise ArgumentError, "Invalid input for Slice.fromJSON"
    end

    slice
  end

  def from_json(_schema, _json) do
    raise ArgumentError, "Invalid input for Slice.fromJSON"
  end

  defp parse_open_depth(json, key) do
    case Map.get(json, key) do
      nil -> 0
      val when is_integer(val) and val >= 0 -> val
      _ -> raise ArgumentError, "Invalid input for Slice.fromJSON"
    end
  end

  @doc """
  Create a slice from a fragment by taking the maximum possible
  open value on both sides of the fragment.
  """
  @spec max_open(Fragment.t(), boolean()) :: t()
  def max_open(%Fragment{} = fragment, open_isolating \\ true) do
    open_start = compute_open_start(Fragment.first_child(fragment), open_isolating, 0)
    open_end = compute_open_end(Fragment.last_child(fragment), open_isolating, 0)
    new(fragment, open_start, open_end)
  end

  defp compute_open_start(nil, _open_isolating, depth), do: depth

  defp compute_open_start(%PmNode{} = node, open_isolating, depth) do
    spec = Map.get(node.type, :spec) || %{}

    if PmNode.is_leaf(node) or (!open_isolating and Map.get(spec, "isolating", false)) do
      depth
    else
      compute_open_start(PmNode.first_child(node), open_isolating, depth + 1)
    end
  end

  defp compute_open_end(nil, _open_isolating, depth), do: depth

  defp compute_open_end(%PmNode{} = node, open_isolating, depth) do
    spec = Map.get(node.type, :spec) || %{}

    if PmNode.is_leaf(node) or (!open_isolating and Map.get(spec, "isolating", false)) do
      depth
    else
      compute_open_end(PmNode.last_child(node), open_isolating, depth + 1)
    end
  end

  @doc "The empty slice."
  @spec empty() :: t()
  def empty do
    %__MODULE__{content: Fragment.empty(), open_start: 0, open_end: 0}
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp remove_range(%Fragment{} = content, from, to) do
    {index, offset} = Fragment.find_index(content, from)
    child = Fragment.maybe_child(content, index)
    {index_to, offset_to} = Fragment.find_index(content, to)

    if offset == from or (child && PmNode.is_text(child)) do
      if offset_to != to and !PmNode.is_text(Fragment.child(content, index_to)) do
        raise PmRangeError, "Removing non-flat range"
      end

      Fragment.append(Fragment.cut(content, 0, from), Fragment.cut(content, to))
    else
      if index != index_to do
        raise PmRangeError, "Removing non-flat range"
      end

      child_content = child.content || Fragment.empty()

      Fragment.replace_child(
        content,
        index,
        PmNode.copy(child, remove_range(child_content, from - offset - 1, to - offset - 1))
      )
    end
  end

  defp insert_into(%Fragment{} = content, dist, %Fragment{} = insert, parent) do
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
      child_content = child.content || Fragment.empty()
      inner = insert_into(child_content, dist - offset - 1, insert, child)

      if inner do
        Fragment.replace_child(content, index, PmNode.copy(child, inner))
      else
        nil
      end
    end
  end
end
