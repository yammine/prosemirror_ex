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
  alias ProsemirrorEx.Model.Schema

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
    case do_add_to_set(set, mark, false) do
      :return_original -> set
      new_set -> new_set
    end
  end

  defp do_add_to_set([], _mark, true), do: []
  defp do_add_to_set([], mark, false), do: [mark]

  defp do_add_to_set([other | rest], mark, placed) do
    cond do
      eq(mark, other) ->
        :return_original

      MarkType.excludes(mark.type, other.type) ->
        do_add_to_set(rest, mark, placed)

      MarkType.excludes(other.type, mark.type) ->
        :return_original

      not placed and other.type.rank > mark.type.rank ->
        case do_add_to_set(rest, mark, true) do
          :return_original -> :return_original
          tail -> [mark, other | tail]
        end

      true ->
        case do_add_to_set(rest, mark, placed) do
          :return_original -> :return_original
          tail -> [other | tail]
        end
    end
  end

  @doc """
  Remove this mark from the given set, returning the set itself if it isn't
  found in it.
  """
  @spec remove_from_set(t(), [t()]) :: [t()]
  def remove_from_set(%__MODULE__{} = mark, set) when is_list(set) do
    case do_remove_from_set(set, mark) do
      :not_found -> set
      new_set -> new_set
    end
  end

  defp do_remove_from_set([], _mark), do: :not_found

  defp do_remove_from_set([other | rest], mark) do
    if eq(mark, other) do
      rest
    else
      case do_remove_from_set(rest, mark) do
        :not_found -> :not_found
        tail -> [other | tail]
      end
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
    if a === b do
      true
    else
      do_same_set(a, b)
    end
  end

  defp do_same_set([], []), do: true
  defp do_same_set([m1 | r1], [m2 | r2]), do: eq(m1, m2) and do_same_set(r1, r2)
  defp do_same_set(_, _), do: false

  @doc """
  Create a properly sorted mark set from null, a single mark, or an unsorted
  array of marks.
  """
  @spec set_from([t()] | t() | nil) :: [t()]
  def set_from(nil), do: none()
  def set_from([]), do: none()
  def set_from([_mark] = marks), do: marks

  def set_from(marks) when is_list(marks) do
    Enum.sort_by(marks, fn %__MODULE__{type: type} -> type.rank end)
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
  @spec from_json(Schema.t(), map()) :: t()
  def from_json(schema, json) when is_map(json) and not is_struct(json) do
    type_name = json["type"]

    if not is_binary(type_name) do
      raise "Invalid input for Mark.fromJSON"
    end

    type = Map.get(schema.marks, type_name)

    if !type do
      raise "There is no mark type #{type_name} in this schema"
    end

    raw_attrs = json["attrs"]
    MarkType.check_attrs_map(type, raw_attrs)
    mark = MarkType.create(type, raw_attrs)
    MarkType.check_attrs(type, mark.attrs)
    mark
  end

  def from_json(_schema, _json) do
    raise "Invalid input for Mark.fromJSON"
  end

  @doc """
  The empty set of marks.
  """
  @spec none() :: [t()]
  def none, do: []
end
