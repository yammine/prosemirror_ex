defmodule ProsemirrorEx.Model.CompareDeep do
  @moduledoc false

  @spec compare(term(), term()) :: boolean()
  def compare(a, a), do: true

  def compare(a, b) when is_map(a) and is_map(b) do
    not is_struct(a) and
      not is_struct(b) and
      map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} ->
        case Map.fetch(b, k) do
          {:ok, bv} -> compare(v, bv)
          :error -> false
        end
      end)
  end

  def compare(a, b) when is_list(a) and is_list(b) do
    do_compare_list(a, b)
  end

  def compare(_a, _b), do: false

  defp do_compare_list([], []), do: true

  defp do_compare_list([h1 | t1], [h2 | t2]) do
    compare(h1, h2) and do_compare_list(t1, t2)
  end

  defp do_compare_list(_, _), do: false
end
