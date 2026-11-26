defmodule ProsemirrorEx.Model.Diff do
  @moduledoc """
  Finds the first and last differing positions between two fragments.

  Ported from prosemirror-model's diff.ts.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Utf16

  @doc """
  Find the first position at which the content of two fragments diverges.

  Returns the position or nil if they are identical.
  """
  @spec find_diff_start(Fragment.t(), Fragment.t(), integer()) :: integer() | nil
  def find_diff_start(%Fragment{content: content_a}, %Fragment{content: content_b}, pos \\ 0) do
    do_find_diff_start(content_a, content_b, pos)
  end

  defp do_find_diff_start([], [], _pos), do: nil
  defp do_find_diff_start([], _b, pos), do: pos
  defp do_find_diff_start(_a, [], pos), do: pos

  defp do_find_diff_start([child_a | rest_a], [child_b | rest_b], pos) do
    if PmNode.eq(child_a, child_b) do
      do_find_diff_start(rest_a, rest_b, pos + PmNode.node_size(child_a))
    else
      if not PmNode.same_markup(child_a, child_b) do
        pos
      else
        if PmNode.is_text(child_a) and child_a.text != child_b.text do
          pos + Utf16.common_prefix(child_a.text, child_b.text)
        else
          frag_a = child_a.content || Fragment.empty()
          frag_b = child_b.content || Fragment.empty()

          if frag_a.size > 0 or frag_b.size > 0 do
            case do_find_diff_start(frag_a.content, frag_b.content, pos + 1) do
              nil -> do_find_diff_start(rest_a, rest_b, pos + PmNode.node_size(child_a))
              inner -> inner
            end
          else
            do_find_diff_start(rest_a, rest_b, pos + PmNode.node_size(child_a))
          end
        end
      end
    end
  end

  @doc """
  Find the first position counting from the end at which the content of
  two fragments diverges.

  Returns `%{a: pos_a, b: pos_b}` or nil if they are identical.
  """
  @spec find_diff_end(Fragment.t(), Fragment.t(), integer() | nil, integer() | nil) ::
          %{a: integer(), b: integer()} | nil
  def find_diff_end(%Fragment{} = a, %Fragment{} = b, pos_a \\ nil, pos_b \\ nil) do
    pos_a = pos_a || a.size
    pos_b = pos_b || b.size

    do_find_diff_end(Enum.reverse(a.content), Enum.reverse(b.content), pos_a, pos_b)
  end

  defp do_find_diff_end([], [], _pos_a, _pos_b), do: nil
  defp do_find_diff_end([], _b, pos_a, pos_b), do: %{a: pos_a, b: pos_b}
  defp do_find_diff_end(_a, [], pos_a, pos_b), do: %{a: pos_a, b: pos_b}

  defp do_find_diff_end([child_a | rest_a], [child_b | rest_b], pos_a, pos_b) do
    size_a = PmNode.node_size(child_a)

    if PmNode.eq(child_a, child_b) do
      do_find_diff_end(rest_a, rest_b, pos_a - size_a, pos_b - PmNode.node_size(child_b))
    else
      if not PmNode.same_markup(child_a, child_b) do
        %{a: pos_a, b: pos_b}
      else
        if PmNode.is_text(child_a) and child_a.text != child_b.text do
          same = Utf16.common_suffix(child_a.text, child_b.text)
          %{a: pos_a - same, b: pos_b - same}
        else
          frag_a = child_a.content || Fragment.empty()
          frag_b = child_b.content || Fragment.empty()

          if frag_a.size > 0 or frag_b.size > 0 do
            case do_find_diff_end(
                   Enum.reverse(frag_a.content),
                   Enum.reverse(frag_b.content),
                   pos_a - 1,
                   pos_b - 1
                 ) do
              nil ->
                do_find_diff_end(
                  rest_a,
                  rest_b,
                  pos_a - size_a,
                  pos_b - PmNode.node_size(child_b)
                )

              inner ->
                inner
            end
          else
            do_find_diff_end(rest_a, rest_b, pos_a - size_a, pos_b - PmNode.node_size(child_b))
          end
        end
      end
    end
  end
end
