defmodule ProsemirrorEx.Model.Mark do
  @moduledoc """
  A mark is a piece of information that can be attached to a node, such as
  it being emphasized, in code font, or a link. It has a type and optionally
  a set of attributes that provide further information (such as the target of
  the link). Marks are created through a Schema, which controls which types
  exist and which attributes they have.
  """

  alias ProsemirrorEx.Model.CompareDeep
  alias ProsemirrorEx.Model.MarkType

  defstruct [:type, attrs: %{}]

  @type t :: %__MODULE__{
          type: MarkType.t(),
          attrs: map()
        }

  @doc """
  Test whether this mark has the same type and attributes as another mark.
  """
  @spec eq(t(), t()) :: boolean()
  def eq(%__MODULE__{type: %{name: name}, attrs: attrs_a}, %__MODULE__{
        type: %{name: name},
        attrs: attrs_b
      }) do
    CompareDeep.compare(attrs_a, attrs_b)
  end

  def eq(%__MODULE__{}, %__MODULE__{}), do: false

  @doc """
  Add this mark to the given set, replacing any marks of the same type that
  exist in it, and sorting it to match the order of marks in the schema.
  Returns the input set when this mark is already in it.

  Faithful port of the JS `addToSet` method.
  """
  @spec add_to_set(t(), [t()]) :: [t()]
  def add_to_set(%__MODULE__{} = mark, set) when is_list(set) do
    result =
      Enum.reduce_while(Enum.with_index(set), {nil, false}, fn {other, i}, {copy, placed} ->
        cond do
          eq(mark, other) ->
            {:halt, {:return, set}}

          MarkType.excludes(mark.type, other.type) ->
            new_copy = if copy, do: copy, else: Enum.take(set, i)
            {:cont, {new_copy, placed}}

          MarkType.excludes(other.type, mark.type) ->
            {:halt, {:return, set}}

          true ->
            if !placed and other.type.rank > mark.type.rank do
              c = if copy, do: copy, else: Enum.take(set, i)
              {:cont, {c ++ [mark, other], true}}
            else
              if copy do
                {:cont, {copy ++ [other], placed}}
              else
                {:cont, {nil, placed}}
              end
            end
        end
      end)

    case result do
      {:return, original} ->
        original

      {nil, false} ->
        # No copy, not placed: just append
        set ++ [mark]

      {copy, false} when is_list(copy) ->
        # Copy started but not placed: append mark
        copy ++ [mark]

      {copy, true} when is_list(copy) ->
        # Copy started and placed: need to append remaining elements
        # But wait - reduce_while processes all elements, so remaining
        # non-excluded elements are already in copy. Just return it.
        copy
    end
  end

  @doc """
  Remove this mark from the given set, returning the set itself if it isn't
  found in it.
  """
  @spec remove_from_set(t(), [t()]) :: [t()]
  def remove_from_set(%__MODULE__{} = mark, set) when is_list(set) do
    case Enum.find_index(set, fn other -> eq(mark, other) end) do
      nil -> set
      idx -> List.delete_at(set, idx)
    end
  end

  @doc """
  Test whether this mark is in the given set of marks.
  Returns true/false (matching JS Mark.prototype.isInSet).
  """
  @spec is_in_set(t(), [t()]) :: boolean()
  def is_in_set(%__MODULE__{} = mark, set) when is_list(set) do
    Enum.any?(set, fn other -> eq(mark, other) end)
  end

  @doc """
  Test whether two sets of marks are identical.
  """
  @spec same_set([t()], [t()]) :: boolean()
  def same_set(a, b) when is_list(a) and is_list(b) do
    if a == b do
      true
    else
      length(a) == length(b) and
        Enum.zip(a, b) |> Enum.all?(fn {m1, m2} -> eq(m1, m2) end)
    end
  end

  @doc """
  Create a properly sorted mark set from null, a single mark, or an unsorted
  array of marks.
  """
  @spec set_from([t()] | t() | nil) :: [t()]
  def set_from(nil), do: none()
  def set_from([]), do: none()

  def set_from(marks) when is_list(marks) do
    if length(marks) == 1 do
      marks
    else
      marks
      |> Enum.sort_by(fn %__MODULE__{type: type} -> type.rank end)
      |> then(fn sorted ->
        Enum.reduce(sorted, [], fn mark, acc -> add_to_set(mark, acc) end)
      end)
    end
  end

  def set_from(%__MODULE__{} = mark), do: [mark]

  @doc """
  Serialize this mark to JSON.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{type: %{name: name}, attrs: attrs}) do
    base = %{"type" => name}

    if attrs == nil or attrs == %{} do
      base
    else
      Map.put(base, "attrs", attrs)
    end
  end

  @doc """
  Deserialize a mark from its JSON representation.

  Takes a schema and a JSON map with `"type"` and optionally `"attrs"` keys.
  """
  def from_json(schema, json) do
    if !json, do: raise("Invalid input for Mark.fromJSON")

    type = schema.marks[json["type"]]

    if !type,
      do: raise("There is no mark type #{json["type"]} in this schema")

    mark = MarkType.create(type, json["attrs"])
    MarkType.check_attrs(type, mark.attrs)
    mark
  end

  @doc """
  The empty set of marks.
  """
  @spec none() :: [t()]
  def none, do: []
end
