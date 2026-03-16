defmodule ProsemirrorEx.Model.Diff do
  @moduledoc """
  Finds the first and last differing positions between two fragments.

  Ported from prosemirror-model's diff.ts.
  """

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode

  @doc """
  Find the first position at which the content of two fragments diverges.

  Returns the position or nil if they are identical.
  """
  def find_diff_start(%Fragment{} = a, %Fragment{} = b, pos \\ 0) do
    child_count_a = Fragment.child_count(a)
    child_count_b = Fragment.child_count(b)

    do_find_diff_start(a, b, pos, 0, child_count_a, child_count_b)
  end

  defp do_find_diff_start(a, b, pos, i, count_a, count_b) do
    cond do
      i == count_a or i == count_b ->
        if count_a == count_b, do: nil, else: pos

      true ->
        child_a = Fragment.child(a, i)
        child_b = Fragment.child(b, i)

        if PmNode.eq(child_a, child_b) do
          do_find_diff_start(a, b, pos + PmNode.node_size(child_a), i + 1, count_a, count_b)
        else
          if not PmNode.same_markup(child_a, child_b) do
            pos
          else
            if PmNode.is_text(child_a) and child_a.text != child_b.text do
              pos + count_common_prefix(child_a.text, child_b.text)
            else
              if child_a.content.size > 0 or child_b.content.size > 0 do
                inner = find_diff_start(child_a.content, child_b.content, pos + 1)

                if inner != nil do
                  inner
                else
                  do_find_diff_start(
                    a,
                    b,
                    pos + PmNode.node_size(child_a),
                    i + 1,
                    count_a,
                    count_b
                  )
                end
              else
                do_find_diff_start(
                  a,
                  b,
                  pos + PmNode.node_size(child_a),
                  i + 1,
                  count_a,
                  count_b
                )
              end
            end
          end
        end
    end
  end

  defp count_common_prefix(text_a, text_b) do
    graphemes_a = String.graphemes(text_a)
    graphemes_b = String.graphemes(text_b)
    do_count_common_prefix(graphemes_a, graphemes_b, 0)
  end

  defp do_count_common_prefix([ha | ta], [hb | tb], count) when ha == hb do
    do_count_common_prefix(ta, tb, count + 1)
  end

  defp do_count_common_prefix(_, _, count), do: count

  @doc """
  Find the first position counting from the end at which the content of
  two fragments diverges.

  Returns `%{a: pos_a, b: pos_b}` or nil if they are identical.
  """
  def find_diff_end(%Fragment{} = a, %Fragment{} = b, pos_a \\ nil, pos_b \\ nil) do
    pos_a = pos_a || a.size
    pos_b = pos_b || b.size
    i_a = Fragment.child_count(a)
    i_b = Fragment.child_count(b)

    do_find_diff_end(a, b, pos_a, pos_b, i_a, i_b)
  end

  defp do_find_diff_end(_a, _b, pos_a, pos_b, i_a, i_b) when i_a == 0 or i_b == 0 do
    if i_a == i_b, do: nil, else: %{a: pos_a, b: pos_b}
  end

  defp do_find_diff_end(a, b, pos_a, pos_b, i_a, i_b) do
    new_i_a = i_a - 1
    new_i_b = i_b - 1
    child_a = Fragment.child(a, new_i_a)
    child_b = Fragment.child(b, new_i_b)
    size = PmNode.node_size(child_a)

    if PmNode.eq(child_a, child_b) do
      do_find_diff_end(
        a,
        b,
        pos_a - size,
        pos_b - PmNode.node_size(child_b),
        new_i_a,
        new_i_b
      )
    else
      if not PmNode.same_markup(child_a, child_b) do
        %{a: pos_a, b: pos_b}
      else
        if PmNode.is_text(child_a) and child_a.text != child_b.text do
          {new_pos_a, new_pos_b} =
            count_common_suffix(child_a.text, child_b.text, pos_a, pos_b)

          %{a: new_pos_a, b: new_pos_b}
        else
          if child_a.content.size > 0 or child_b.content.size > 0 do
            inner =
              find_diff_end(
                child_a.content,
                child_b.content,
                pos_a - 1,
                pos_b - 1
              )

            if inner do
              inner
            else
              do_find_diff_end(
                a,
                b,
                pos_a - size,
                pos_b - PmNode.node_size(child_b),
                new_i_a,
                new_i_b
              )
            end
          else
            do_find_diff_end(
              a,
              b,
              pos_a - size,
              pos_b - PmNode.node_size(child_b),
              new_i_a,
              new_i_b
            )
          end
        end
      end
    end
  end

  defp count_common_suffix(text_a, text_b, pos_a, pos_b) do
    graphemes_a = String.graphemes(text_a)
    graphemes_b = String.graphemes(text_b)
    rev_a = Enum.reverse(graphemes_a)
    rev_b = Enum.reverse(graphemes_b)
    min_size = min(length(graphemes_a), length(graphemes_b))
    do_count_common_suffix(rev_a, rev_b, pos_a, pos_b, 0, min_size)
  end

  defp do_count_common_suffix([ha | ta], [hb | tb], pos_a, pos_b, same, min_size)
       when same < min_size and ha == hb do
    do_count_common_suffix(ta, tb, pos_a - 1, pos_b - 1, same + 1, min_size)
  end

  defp do_count_common_suffix(_, _, pos_a, pos_b, _, _), do: {pos_a, pos_b}
end
