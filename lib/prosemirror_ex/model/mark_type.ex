defmodule ProsemirrorEx.Model.MarkType do
  @moduledoc "A mark type is a specification for a type of mark in a schema."

  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.Schema

  @type t :: %__MODULE__{}

  defstruct [:name, :rank, :schema, :spec, :excluded, :instance, :attrs]

  @doc """
  Create a mark of this type. `attrs` may be nil or a map containing
  only some of the mark's attributes. The others, if they have defaults,
  will be added.
  """
  def create(type, attrs \\ nil)

  def create(%__MODULE__{instance: instance} = _type, nil) when instance != nil do
    instance
  end

  def create(%__MODULE__{instance: instance} = _type, attrs)
      when instance != nil and (attrs == %{} or attrs == nil) do
    instance
  end

  def create(%__MODULE__{} = type, attrs) do
    computed = Schema.compute_attrs(type.attrs, attrs)
    %Mark{type: type, attrs: computed}
  end

  @doc "Check whether this mark type excludes another."
  def excludes(%__MODULE__{excluded: excluded}, %__MODULE__{} = other) when is_list(excluded) do
    Enum.any?(excluded, fn ex -> ex.name == other.name end)
  end

  # :all means globally excluding (used in manually-constructed types for testing)
  def excludes(%__MODULE__{excluded: :all}, _other), do: true

  # Fallback: when excluded is nil, marks exclude same-type by default
  def excludes(%__MODULE__{excluded: nil, name: name}, %__MODULE__{name: other_name}) do
    name == other_name
  end

  @doc "When there is a mark of this type in the given set, a new set without it is returned."
  def remove_from_set(%__MODULE__{} = type, set) when is_list(set) do
    Enum.reject(set, fn mark -> mark.type.name == type.name end)
  end

  @doc "Tests whether there is a mark of this type in the given set. Returns the Mark or nil."
  def is_in_set(%__MODULE__{} = type, set) when is_list(set) do
    Enum.find(set, fn mark -> mark.type.name == type.name end)
  end

  @doc "Validate attributes against the spec."
  def check_attrs(%__MODULE__{attrs: attrs}, values) do
    Enum.each(values, fn {name, _val} ->
      unless Map.has_key?(attrs, name) do
        raise "Unsupported attribute #{name} for mark"
      end
    end)

    Enum.each(attrs, fn {attr_name, attr} ->
      if attr[:validate] do
        case attr.validate do
          f when is_function(f) -> f.(Map.get(values, attr_name))
          _ -> :ok
        end
      end
    end)
  end
end
