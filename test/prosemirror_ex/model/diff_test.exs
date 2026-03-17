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

  defp hr_type,
    do: %{
      name: "horizontal_rule",
      is_leaf: true,
      is_text: false,
      is_block: true,
      is_inline: false,
      spec: %{}
    }

  defp bold_mark do
    %Mark{type: %ProsemirrorEx.Model.MarkType{name: "bold", rank: 1}, attrs: %{}}
  end

  # Helper to build a fragment from a list of nodes
  defp frag(nodes), do: Fragment.from_array(nodes)

  defp hr_node do
    %PmNode{type: hr_type(), attrs: %{}, content: Fragment.empty(), marks: []}
  end

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

    test "with explicit pos argument offsets the result" do
      # Calling find_diff_start/3 with an explicit starting pos
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("world")])])
      # Without offset: diff at pos 1 (enter para, then text differs at char 0)
      assert Fragment.find_diff_start(a, b, 0) == 1
      # With offset of 10: result should be 10 + 1 = 11
      assert Fragment.find_diff_start(a, b, 10) == 11
    end

    test "with explicit pos argument and identical fragments returns nil" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_start(a, b, 100) == nil
    end

    test "with explicit pos argument and length mismatch" do
      a = frag([para_node([text_node("a")])])
      b = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      # Without offset: diff at pos 3 (after first para of size 3)
      assert Fragment.find_diff_start(a, b, 0) == 3
      # With offset of 20: result should be 20 + 3 = 23
      assert Fragment.find_diff_start(a, b, 20) == 23
    end

    test "same-markup non-text nodes with identical content followed by differing sibling" do
      # Two fragments where the first child is a blockquote with identical content.
      # Since the blockquotes are eq, the diff is found at the second sibling.
      a = frag([blockquote_node([para_node([text_node("same")])]), para_node([text_node("x")])])
      b = frag([blockquote_node([para_node([text_node("same")])]), para_node([text_node("y")])])
      # blockquote size = 2 + (2 + 4) = 8. Both blockquotes are eq, skip to next.
      # pos after blockquote = 8. Then enter para (pos=9). Text "x" vs "y" differ at 0.
      assert Fragment.find_diff_start(a, b) == 9
    end

    test "empty-content leaf nodes with same markup followed by differing sibling" do
      # Two fragments with an hr (leaf, empty content) followed by differing paras
      a = frag([hr_node(), para_node([text_node("a")])])
      b = frag([hr_node(), para_node([text_node("b")])])
      # hr node_size = 1 (leaf). Both hrs are eq. Skip to next.
      # pos after hr = 1. Enter para (pos=2). Text "a" vs "b" differ at char 0.
      assert Fragment.find_diff_start(a, b) == 2
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

    test "with explicit pos_a and pos_b arguments" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("world")])])
      # a.size = 7, b.size = 7
      # With explicit positions 17 and 27 (offsets of +10 and +20 from default 7):
      # Recurse into para (same markup): find_diff_end(content, content, 16, 26)
      #   Text "hello" vs "world", no common suffix. Return {a: 16, b: 26}.
      assert Fragment.find_diff_end(a, b, 17, 27) == %{a: 16, b: 26}
    end

    test "with explicit pos arguments and identical fragments returns nil" do
      a = frag([para_node([text_node("hello")])])
      b = frag([para_node([text_node("hello")])])
      assert Fragment.find_diff_end(a, b, 100, 200) == nil
    end

    test "with explicit pos arguments and length mismatch" do
      a = frag([para_node([text_node("a")]), para_node([text_node("b")])])
      b = frag([para_node([text_node("b")])])
      # a.size = 6, b.size = 3
      # With pos_a=16, pos_b=13: last children both para("b"), eq. posA=16-3=13, posB=13-3=10.
      # iA=1, iB=0. iB==0, iA!=0. Return {a: 13, b: 10}.
      assert Fragment.find_diff_end(a, b, 16, 13) == %{a: 13, b: 10}
    end

    test "same-markup non-text nodes with identical content followed by differing sibling from end" do
      # Two fragments where the last child (blockquote) has identical content.
      # The diff is found at the preceding sibling.
      a = frag([para_node([text_node("x")]), blockquote_node([para_node([text_node("same")])])])
      b = frag([para_node([text_node("y")]), blockquote_node([para_node([text_node("same")])])])
      # blockquote size = 2 + (2 + 4) = 8. para size = 2 + 1 = 3.
      # a.size = 3 + 8 = 11, b.size = 11.
      # From end: last children are blockquotes, they're eq. posA=11-8=3, posB=11-8=3.
      # Next: iA=1, iB=1. childA=para("x"), childB=para("y"). Same markup.
      # Recurse into content: text "x" vs "y" differ. Return {a: 2, b: 2}.
      assert Fragment.find_diff_end(a, b) == %{a: 2, b: 2}
    end

    test "empty-content leaf nodes with same markup followed by differing sibling from end" do
      # Two fragments with differing paras followed by an hr (leaf, empty content)
      a = frag([para_node([text_node("a")]), hr_node()])
      b = frag([para_node([text_node("b")]), hr_node()])
      # hr node_size = 1 (leaf). Both hrs are eq. posA=4-1=3, posB=4-1=3.
      # Next: childA=para("a"), childB=para("b"). Same markup. Content differs.
      # Recurse into content: text "a" vs "b". Return {a: 2, b: 2}.
      assert Fragment.find_diff_end(a, b) == %{a: 2, b: 2}
    end
  end
end
