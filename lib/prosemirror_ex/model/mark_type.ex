defmodule ProsemirrorEx.Model.MarkType do
  @moduledoc "A mark type is a specification for a type of mark in a schema."

  defstruct [:name, :rank, :schema, :spec, :excluded, :instance, :attrs]

  @doc "Check whether this mark type excludes another."
  # Default: same-type marks exclude each other (self-exclusion)
  def excludes(%__MODULE__{excluded: nil, name: name}, %__MODULE__{name: other_name}),
    do: name == other_name

  # :all means globally excluding
  def excludes(%__MODULE__{excluded: :all}, _other), do: true

  # Explicit exclusion list
  def excludes(%__MODULE__{excluded: excluded}, %__MODULE__{} = other) when is_list(excluded) do
    Enum.any?(excluded, fn ex -> ex.name == other.name end)
  end
end
