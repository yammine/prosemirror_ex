defmodule ProsemirrorEx.Model.CompareDeep do
  @moduledoc false

  @spec compare(any(), any()) :: boolean()
  def compare(a, a), do: true

  def compare(a, b) when is_map(a) and is_map(b) do
    not Map.has_key?(a, :__struct__) and
      not Map.has_key?(b, :__struct__) and
      map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} ->
        Map.has_key?(b, k) and compare(v, Map.get(b, k))
      end)
  end

  def compare(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> compare(x, y) end)
  end

  def compare(_a, _b), do: false
end
