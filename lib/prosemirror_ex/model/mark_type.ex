defmodule ProsemirrorEx.Model.MarkType do
  @moduledoc "A mark type is a specification for a type of mark in a schema."

  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.Schema

  @type t :: %__MODULE__{
          name: String.t() | nil,
          rank: non_neg_integer() | nil,
          schema: Schema.t() | nil,
          spec: map() | nil,
          excluded: [t()] | :all | nil,
          excluded_names: MapSet.t(String.t()) | :all | nil,
          instance: Mark.t() | nil,
          attrs: map() | nil
        }

  defstruct [:name, :rank, :schema, :spec, :excluded, :excluded_names, :instance, :attrs]

  @doc """
  Create a mark of this type. `attrs` may be nil or a map containing
  only some of the mark's attributes. The others, if they have defaults,
  will be added.
  """
  @spec create(t(), map() | nil) :: Mark.t()
  def create(type, attrs \\ nil)

  def create(%__MODULE__{instance: instance} = _type, attrs)
      when instance != nil and (attrs == %{} or attrs == nil) do
    instance
  end

  def create(%__MODULE__{} = type, attrs) do
    computed = Schema.compute_attrs(type.attrs, attrs)
    %Mark{type: type, attrs: computed}
  end

  @doc "Check whether this mark type excludes another."
  @spec excludes(t(), t()) :: boolean()
  def excludes(%__MODULE__{excluded_names: :all}, _other), do: true

  def excludes(%__MODULE__{excluded_names: %MapSet{} = names}, %__MODULE__{name: other_name}) do
    MapSet.member?(names, other_name)
  end

  # :all means globally excluding (used in manually-constructed types for testing)
  def excludes(%__MODULE__{excluded: :all}, _other), do: true

  def excludes(%__MODULE__{excluded: excluded}, %__MODULE__{name: other_name})
      when is_list(excluded) do
    Enum.any?(excluded, fn ex -> ex.name == other_name end)
  end

  # Fallback: when excluded is nil, marks exclude same-type by default
  def excludes(%__MODULE__{excluded: nil, name: name}, %__MODULE__{name: other_name}) do
    name == other_name
  end

  @doc "When there is a mark of this type in the given set, a new set without it is returned."
  @spec remove_from_set(t(), [Mark.t()]) :: [Mark.t()]
  def remove_from_set(%__MODULE__{} = type, set) when is_list(set) do
    Enum.reject(set, fn mark -> mark.type.name == type.name end)
  end

  @doc "Tests whether there is a mark of this type in the given set. Returns the Mark or nil."
  @spec is_in_set(t(), [Mark.t()]) :: Mark.t() | nil
  def is_in_set(%__MODULE__{} = type, set) when is_list(set) do
    Enum.find(set, fn mark -> mark.type.name == type.name end)
  end

  @doc "Validate attributes against the spec."
  @spec check_attrs(t(), map() | nil) :: :ok
  def check_attrs(%__MODULE__{attrs: attrs}, values) do
    Schema.validate_attrs(attrs || %{}, values, "mark")
  end

  @doc "Validate raw JSON attribute keys against the mark type's attribute spec before defaulting."
  @spec check_attrs_map(t(), term()) :: :ok
  def check_attrs_map(%__MODULE__{name: name, attrs: attrs}, raw_attrs) do
    Schema.check_attrs_map(attrs || %{}, raw_attrs, "mark #{name}")
  end
end
