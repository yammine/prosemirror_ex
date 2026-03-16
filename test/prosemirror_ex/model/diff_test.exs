defmodule ProsemirrorEx.Model.DiffTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Mark

  # -- Helper functions to build test nodes without a schema --

  defp text_type,
    do: %{name: "text", is_leaf: true, is_text: true, is_block: false, is_inline: true, spec: %{}}

  defp para_type,
    do: %{
      name: "paragraph",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      spec: %{}
    }

  defp blockquote_type,
    do: %{
      name: "blockquote",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      spec: %{}
    }

  defp heading_type,
    do: %{
      name: "heading",
      is_leaf: false,
      is_text: false,
      is_block: true,
      is_inline: false,
      spec: %{}
    }

  defp text_node(text, marks \\ []) do
    %PmNode{type: text_type(), attrs: %{}, content: Fragment.empty(), marks: marks, text: text}
  end

  defp para_node(children) when is_list(children) do
    content = Fragment.from_array(children)
    %PmNode{type: para_type(), attrs: %{}, content: content, marks: []}
  end

  defp blockquote_node(children) when is_list(children) do
    content = Fragment.from_array(children)
    %PmNode{type: blockquote_type(), attrs: %{}, content: content, marks: []}
  end

  defp heading_node(children) when is_list(children) do
    content = Fragment.from_array(children)
    %PmNode{type: heading_type(), attrs: %{}, content: content, marks: []}
  end

  defp bold_mark do
    %Mark{type: %ProsemirrorEx.Model.MarkType{name: "bold", rank: 1}, attrs: %{}}
  end

  # Helper to build a fragment from a list of nodes
  defp frag(nodes), do: Fragment.from_array(nodes)

  describe "find_diff_start/3" do
    test "returns nil for identical fragments" do
      f = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_start(f, f) == nil
    end

    test "returns nil for structurally equal fragments" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_start(a, b) == nil
    end

    test "finds diff when first fragment is longer" do
      # Two paragraphs vs one paragraph
      a = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      b = frag([para_node([text_node("a")])])
      # They share the first child (para("a"), size = 3). Diff starts at pos 3.
      assert Fragment.find_diff_start(a, b) == 3
    end

    test "finds diff when first fragment is shorter" do
      a = frag([para_node([text_node("a")])])
      b = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      # They share the first child. Diff starts at pos 3.
      assert Fragment.find_diff_start(a, b) == 3
    end

    test "finds diff at the start when children differ" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("world")])])
      # Both are paragraphs with same markup, so we recurse inside.
      # pos starts at 0, we add 1 for entering the paragraph.
      # Inside, we compare text "hello" vs "world". They differ at character 0.
      # So the result is 0 + 1 = 1.
      assert Fragment.find_diff_start(a, b) == 1
    end

    test "finds character-level diff in text nodes" do
      a = frag([para_node([text_node("abcde")])])
      b = frag([para_node([text_node("abxyz")])])
      # Enter paragraph (pos + 1 = 1). Text nodes have same markup.
      # Compare characters: a=a, b=b, then c != x. pos = 1 + 2 = 3.
      assert Fragment.find_diff_start(a, b) == 3
    end

    test "finds diff at different markup" do
      a = frag([para_node([text_node("hello")])])
      b = frag([heading_node([text_node("hello")])])
      # First children have different types (paragraph vs heading), so diff is at pos 0.
      assert Fragment.find_diff_start(a, b) == 0
    end

    test "finds diff inside nested content" do
      # blockquote > para("abc") vs blockquote > para("axc")
      a = frag([blockquote_node([para_node([text_node("abc")])])])
      b = frag([blockquote_node([para_node([text_node("axc")])])])
      # Enter blockquote (pos + 1 = 1), enter paragraph (pos + 1 = 2).
      # Text "abc" vs "axc": a=a match (pos=3), b!=x so diff at pos 3.
      assert Fragment.find_diff_start(a, b) == 3
    end

    test "finds diff with text nodes of different lengths" do
      a = frag([para_node([text_node("abc")])])
      b = frag([para_node([text_node("abcdef")])])
      # Enter paragraph (pos=1). Text nodes same markup, different text.
      # Compare chars: a=a, b=b, c=c. Then "abc"[3] doesn't exist but "abcdef"[3] = 'd'.
      # Loop ends after 3 matches, pos = 1 + 3 = 4.
      assert Fragment.find_diff_start(a, b) == 4
    end

    test "returns nil for two empty fragments" do
      a = Fragment.empty()
      b = Fragment.empty()
      assert Fragment.find_diff_start(a, b) == nil
    end

    test "finds diff at pos 0 for empty vs non-empty" do
      a = Fragment.empty()
      b = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_start(a, b) == 0
    end

    test "finds diff with bold markup change mid-text" do
      # para("ab" + bold("cd")) vs para("ab" + "cd")
      a = frag([para_node([text_node("ab"), text_node("cd", [bold_mark()])])])
      b = frag([para_node([text_node("abcd")])])
      # Enter paragraph (pos=1). First text children: "ab" vs "abcd".
      # Same markup (both plain text). Different text.
      # Characters: a=a, b=b, then "ab"[2] doesn't exist but "abcd"[2]='c'.
      # pos = 1 + 2 = 3.
      assert Fragment.find_diff_start(a, b) == 3
    end
  end

  describe "find_diff_end/4" do
    test "returns nil for identical fragments" do
      f = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_end(f, f) == nil
    end

    test "returns nil for structurally equal fragments" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_end(a, b) == nil
    end

    test "finds diff from end when first is longer" do
      a = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      b = frag([para_node([text_node("b")])])
      # a.size = 3 + 3 = 6, b.size = 3
      # Start: iA=2, iB=1, posA=6, posB=3
      # childA = a.child(1) = para("b"), childB = b.child(0) = para("b")
      # They are eq, so posA -= 3 = 3, posB -= 3 = 0
      # Next: iA=1, iB=0. iB==0 and iA!=0, so return {a: 3, b: 0}
      assert Fragment.find_diff_end(a, b) == %{a: 3, b: 0}
    end

    test "finds diff from end when second is longer" do
      a = frag([para_node([text_node("a")])])
      b = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      # a.size = 3, b.size = 6
      # Start: iA=1, iB=2, posA=3, posB=6
      # childA = a.child(0) = para("a"), childB = b.child(1) = para("b")
      # Not eq. same_markup? Both paragraphs, yes. Content differs.
      # Recurse: findDiffEnd(content_a, content_b, posA-1=2, posB-1=5)
      #   content_a = frag(["a"]), content_b = frag(["b"])
      #   iA=1, iB=1, posA=2, posB=5
      #   childA = "a", childB = "b". same_markup? Yes (both text). is_text? Yes.
      #   Different text. same=0, minSize=1.
      #   "a"[0] vs "b"[0]: different. same stays 0. Return {a: 2, b: 5}.
      assert Fragment.find_diff_end(a, b) == %{a: 2, b: 5}
    end

    test "finds character-level diff from end in text" do
      a = frag([para_node([text_node("abcde")])])
      b = frag([para_node([text_node("abxyz")])])
      # a.size = 7, b.size = 7
      # Start: iA=1, iB=1, posA=7, posB=7
      # childA = para("abcde"), childB = para("abxyz"). Same markup.
      # Content differs, recurse: findDiffEnd(content_a, content_b, posA-1=6, posB-1=6)
      #   iA=1, iB=1, posA=6, posB=6
      #   childA = "abcde", childB = "abxyz". Same markup, is_text, different text.
      #   same=0, minSize=5.
      #   "abcde"[4] = 'e', "abxyz"[4] = 'z': different. Return {a: 6, b: 6}.
      # Wait, let me re-check. The loop: same < minSize (5) and
      #   childA.text[5-0-1]=childA.text[4]='e' == childB.text[5-0-1]=childB.text[4]='z'? No.
      # So same=0, return {a: 6, b: 6}.
      assert Fragment.find_diff_end(a, b) == %{a: 6, b: 6}
    end

    test "finds character-level diff from end matching suffix" do
      a = frag([para_node([text_node("abcde")])])
      b = frag([para_node([text_node("xycde")])])
      # Recurse into para, then text comparison from end.
      # childA = "abcde", childB = "xycde". minSize=5.
      # same=0: 'e'=='e' yes, same=1, posA=5, posB=5
      # same=1: 'd'=='d' yes, same=2, posA=4, posB=4
      # same=2: 'c'=='c' yes, same=3, posA=3, posB=3
      # same=3: 'b'=='y' no. Return {a: 3, b: 3}.
      assert Fragment.find_diff_end(a, b) == %{a: 3, b: 3}
    end

    test "finds diff at different markup from end" do
      a = frag([para_node([text_node("hello")])])
      b = frag([heading_node([text_node("hello")])])
      # a.size = 7, b.size = 7
      # childA = para, childB = heading. Different markup. Return {a: 7, b: 7}.
      assert Fragment.find_diff_end(a, b) == %{a: 7, b: 7}
    end

    test "returns nil for two empty fragments" do
      a = Fragment.empty()
      b = Fragment.empty()
      assert Fragment.find_diff_end(a, b) == nil
    end

    test "finds diff for empty vs non-empty" do
      a = Fragment.empty()
      b = frag([para_node([text_node("hello")])])
      # iA=0, iB=1 initially. iA==0, iA != iB, return {a: 0, b: 7}
      assert Fragment.find_diff_end(a, b) == %{a: 0, b: 7}
    end

    test "finds diff inside nested content from end" do
      a = frag([blockquote_node([para_node([text_node("abc")])])])
      b = frag([blockquote_node([para_node([text_node("axc")])])])
      # a.size = 7 (bq: 2 + para: 2 + text: 3), b.size = 7
      # Recurse into blockquote (same markup): findDiffEnd(bq_content_a, bq_content_b, 6, 6)
      #   Recurse into para (same markup): findDiffEnd(para_content_a, para_content_b, 5, 5)
      #     Text "abc" vs "axc", compare from end:
      #     same=0: 'c'=='c', same=1, posA=4, posB=4
      #     same=1: 'b'=='x', no. Return {a: 4, b: 4}
      assert Fragment.find_diff_end(a, b) == %{a: 4, b: 4}
    end
  end
end
