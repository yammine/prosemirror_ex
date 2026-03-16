defmodule ProsemirrorEx.Model.FragmentTest do
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

  defp hr_type,
    do: %{
      name: "horizontal_rule",
      is_leaf: true,
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

  defp hr_node do
    %PmNode{type: hr_type(), attrs: %{}, content: Fragment.empty(), marks: []}
  end

  defp bold_mark do
    %Mark{type: %ProsemirrorEx.Model.MarkType{name: "bold", rank: 1}, attrs: %{}}
  end

  describe "empty/0" do
    test "returns a fragment with no children and size 0" do
      empty = Fragment.empty()
      assert Fragment.child_count(empty) == 0
      assert empty.size == 0
    end

    test "returns the same reference each time" do
      assert Fragment.empty() == Fragment.empty()
    end
  end

  describe "from_array/1" do
    test "empty list returns empty fragment" do
      frag = Fragment.from_array([])
      assert Fragment.child_count(frag) == 0
      assert frag.size == 0
    end

    test "single text node" do
      node = text_node("hello")
      frag = Fragment.from_array([node])
      assert Fragment.child_count(frag) == 1
      assert frag.size == 5
    end

    test "multiple nodes" do
      nodes = [text_node("ab"), text_node("cd")]
      frag = Fragment.from_array(nodes)
      # Different markup (same markup actually - both plain text), so they get joined
      assert Fragment.child_count(frag) == 1
      assert frag.size == 4
    end

    test "joins adjacent text nodes with same markup" do
      nodes = [text_node("hello"), text_node(" world")]
      frag = Fragment.from_array(nodes)
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0).text == "hello world"
      assert frag.size == 11
    end

    test "does not join text nodes with different marks" do
      plain = text_node("hello")
      bold = text_node(" world", [bold_mark()])
      frag = Fragment.from_array([plain, bold])
      assert Fragment.child_count(frag) == 2
      assert Fragment.child(frag, 0).text == "hello"
      assert Fragment.child(frag, 1).text == " world"
    end

    test "does not join non-text nodes" do
      p1 = para_node([text_node("a")])
      p2 = para_node([text_node("b")])
      frag = Fragment.from_array([p1, p2])
      assert Fragment.child_count(frag) == 2
    end
  end

  describe "from/1" do
    test "nil returns empty" do
      assert Fragment.from(nil) == Fragment.empty()
    end

    test "Fragment passthrough" do
      frag = Fragment.from_array([text_node("hi")])
      assert Fragment.from(frag) == frag
    end

    test "single Node wrapping" do
      node = text_node("hi")
      frag = Fragment.from(node)
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0) == node
    end

    test "list wrapping" do
      nodes = [text_node("a"), text_node("b", [bold_mark()])]
      frag = Fragment.from(nodes)
      assert Fragment.child_count(frag) == 2
    end
  end

  describe "child_count/1" do
    test "returns 0 for empty" do
      assert Fragment.child_count(Fragment.empty()) == 0
    end

    test "returns correct count" do
      frag = Fragment.from_array([text_node("a"), text_node("b", [bold_mark()])])
      assert Fragment.child_count(frag) == 2
    end
  end

  describe "child/2" do
    test "returns child at index" do
      node = text_node("hello")
      frag = Fragment.from_array([node])
      assert Fragment.child(frag, 0) == node
    end

    test "raises on out of range index" do
      frag = Fragment.from_array([text_node("hi")])
      assert_raise RuntimeError, fn -> Fragment.child(frag, 5) end
    end

    test "raises on negative index" do
      frag = Fragment.from_array([text_node("hi")])
      assert_raise RuntimeError, fn -> Fragment.child(frag, -1) end
    end
  end

  describe "maybe_child/2" do
    test "returns child at valid index" do
      node = text_node("hello")
      frag = Fragment.from_array([node])
      assert Fragment.maybe_child(frag, 0) == node
    end

    test "returns nil for out of range" do
      frag = Fragment.from_array([text_node("hi")])
      assert Fragment.maybe_child(frag, 5) == nil
    end
  end

  describe "first_child/1" do
    test "returns first child" do
      a = text_node("a")
      b = text_node("b", [bold_mark()])
      frag = Fragment.from_array([a, b])
      assert Fragment.first_child(frag) == a
    end

    test "returns nil for empty" do
      assert Fragment.first_child(Fragment.empty()) == nil
    end
  end

  describe "last_child/1" do
    test "returns last child" do
      a = text_node("a")
      b = text_node("b", [bold_mark()])
      frag = Fragment.from_array([a, b])
      assert Fragment.last_child(frag) == b
    end

    test "returns nil for empty" do
      assert Fragment.last_child(Fragment.empty()) == nil
    end
  end

  describe "eq/2" do
    test "empty == empty" do
      assert Fragment.eq(Fragment.empty(), Fragment.empty())
    end

    test "same content" do
      a = Fragment.from_array([text_node("hello")])
      b = Fragment.from_array([text_node("hello")])
      assert Fragment.eq(a, b)
    end

    test "different content" do
      a = Fragment.from_array([text_node("hello")])
      b = Fragment.from_array([text_node("world")])
      refute Fragment.eq(a, b)
    end

    test "different child count" do
      a = Fragment.from_array([text_node("a")])
      b = Fragment.from_array([text_node("a"), text_node("b", [bold_mark()])])
      refute Fragment.eq(a, b)
    end
  end

  describe "cut/2,3" do
    test "full range returns self" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.cut(frag, 0, frag.size) == frag
      assert Fragment.cut(frag, 0) == frag
    end

    test "cuts text node" do
      frag = Fragment.from_array([text_node("hello")])
      result = Fragment.cut(frag, 1, 4)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "ell"
      assert result.size == 3
    end

    test "cuts from start of text" do
      frag = Fragment.from_array([text_node("hello")])
      result = Fragment.cut(frag, 0, 3)
      assert Fragment.child(result, 0).text == "hel"
    end

    test "cuts to end of text" do
      frag = Fragment.from_array([text_node("hello")])
      result = Fragment.cut(frag, 2)
      assert Fragment.child(result, 0).text == "llo"
    end

    test "cuts across multiple text nodes" do
      frag = Fragment.from_array([text_node("ab"), text_node("cd", [bold_mark()])])
      # positions: "ab" takes 0..2, "cd" takes 2..4
      # cut(1, 3) should give "b" and "c"
      result = Fragment.cut(frag, 1, 3)
      assert Fragment.child_count(result) == 2
      assert Fragment.child(result, 0).text == "b"
      assert Fragment.child(result, 1).text == "c"
    end

    test "cuts into nested (non-text) nodes" do
      # A paragraph node wrapping "hello" has size = 2 + 5 = 7
      # positions: 0 = opening of para, 1..6 = "hello" inside, 6 = closing of para
      p = para_node([text_node("hello")])
      frag = Fragment.from_array([p])
      assert frag.size == 7

      # Cutting from 0 to 7 returns self
      assert Fragment.cut(frag, 0, 7) == frag

      # Cutting into the paragraph: cut(0, 4) should give a para with "hel"
      # from=0, to=4: the para starts at pos 0, end = 0+7 = 7
      # pos(0) < from(0)? No. end(7) > to(4)? Yes. So we cut the child.
      # child is not text: child.cut(max(0, 0-0-1)=0, min(5, 4-0-1)=3) = para with "hel"
      result = Fragment.cut(frag, 0, 4)
      assert Fragment.child_count(result) == 1
      inner = Fragment.child(result, 0)
      assert inner.type.name == "paragraph"
      assert Fragment.child(inner.content, 0).text == "hel"
    end

    test "cuts skipping entire nodes before range" do
      # Two text nodes: "ab" (size 2, pos 0..2) and "cd" (size 2, pos 2..4)
      frag = Fragment.from_array([text_node("ab"), text_node("cd", [bold_mark()])])
      result = Fragment.cut(frag, 2, 4)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "cd"
    end

    test "empty cut returns empty" do
      frag = Fragment.from_array([text_node("hello")])
      result = Fragment.cut(frag, 2, 2)
      assert Fragment.child_count(result) == 0
      assert result.size == 0
    end
  end

  describe "append/2" do
    test "empty + frag = frag" do
      frag = Fragment.from_array([text_node("hi")])
      assert Fragment.append(Fragment.empty(), frag) == frag
    end

    test "frag + empty = frag" do
      frag = Fragment.from_array([text_node("hi")])
      assert Fragment.append(frag, Fragment.empty()) == frag
    end

    test "joins adjacent text nodes with same markup" do
      a = Fragment.from_array([text_node("hello")])
      b = Fragment.from_array([text_node(" world")])
      result = Fragment.append(a, b)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "hello world"
      assert result.size == 11
    end

    test "does not join text nodes with different marks" do
      a = Fragment.from_array([text_node("hello")])
      b = Fragment.from_array([text_node(" world", [bold_mark()])])
      result = Fragment.append(a, b)
      assert Fragment.child_count(result) == 2
    end

    test "does not join non-text nodes" do
      a = Fragment.from_array([para_node([text_node("a")])])
      b = Fragment.from_array([para_node([text_node("b")])])
      result = Fragment.append(a, b)
      assert Fragment.child_count(result) == 2
    end
  end

  describe "find_index/2" do
    test "position 0" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 0) == {0, 0}
    end

    test "position == size" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 5) == {1, 5}
    end

    test "within a text node" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 3) == {0, 0}
    end

    test "at boundary between nodes" do
      frag = Fragment.from_array([text_node("ab"), text_node("cd", [bold_mark()])])
      # pos 2 = end of first node = start of second
      assert Fragment.find_index(frag, 2) == {1, 2}
    end

    test "within second node" do
      frag = Fragment.from_array([text_node("ab"), text_node("cd", [bold_mark()])])
      assert Fragment.find_index(frag, 3) == {1, 2}
    end

    test "raises on negative position" do
      frag = Fragment.from_array([text_node("hello")])
      assert_raise ProsemirrorEx.Model.RangeError, fn -> Fragment.find_index(frag, -1) end
    end

    test "raises on position beyond size" do
      frag = Fragment.from_array([text_node("hello")])
      assert_raise ProsemirrorEx.Model.RangeError, fn -> Fragment.find_index(frag, 6) end
    end
  end

  describe "for_each/2" do
    test "iterates with correct offsets" do
      a = text_node("ab")
      b = text_node("cd", [bold_mark()])
      frag = Fragment.from_array([a, b])

      {:ok, agent} = Agent.start_link(fn -> [] end)

      Fragment.for_each(frag, fn node, offset, index ->
        Agent.update(agent, fn list -> list ++ [{node.text, offset, index}] end)
      end)

      result = Agent.get(agent, & &1)
      Agent.stop(agent)

      assert result == [{"ab", 0, 0}, {"cd", 2, 1}]
    end

    test "empty fragment does not iterate" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Fragment.for_each(Fragment.empty(), fn _node, _offset, _index ->
        Agent.update(agent, &(&1 + 1))
      end)

      assert Agent.get(agent, & &1) == 0
      Agent.stop(agent)
    end
  end

  describe "cut_by_index/3" do
    test "basic slicing" do
      a = text_node("a")
      b = text_node("b", [bold_mark()])
      c = text_node("c")
      frag = Fragment.from_array([a, b, c])

      result = Fragment.cut_by_index(frag, 1, 2)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "b"
    end

    test "full range returns same content" do
      a = text_node("a")
      b = text_node("b", [bold_mark()])
      frag = Fragment.from_array([a, b])

      result = Fragment.cut_by_index(frag, 0, Fragment.child_count(frag))
      assert Fragment.eq(result, frag)
    end

    test "empty range" do
      frag = Fragment.from_array([text_node("a")])
      result = Fragment.cut_by_index(frag, 0, 0)
      assert Fragment.child_count(result) == 0
    end
  end

  describe "replace_child/3" do
    test "replaces child at index" do
      a = text_node("a")
      b = text_node("b", [bold_mark()])
      frag = Fragment.from_array([a, b])

      new_node = text_node("x")
      result = Fragment.replace_child(frag, 0, new_node)
      assert Fragment.child(result, 0).text == "x"
      assert Fragment.child(result, 1) == b
    end

    test "updates size correctly" do
      a = text_node("ab")
      b = text_node("cd", [bold_mark()])
      frag = Fragment.from_array([a, b])
      assert frag.size == 4

      new_node = text_node("xyz")
      result = Fragment.replace_child(frag, 0, new_node)
      assert result.size == 5
    end
  end

  describe "add_to_start/2" do
    test "adds node to beginning" do
      frag = Fragment.from_array([text_node("b", [bold_mark()])])
      node = text_node("a")
      result = Fragment.add_to_start(frag, node)
      assert Fragment.child_count(result) == 2
      assert Fragment.child(result, 0).text == "a"
      assert Fragment.child(result, 1).text == "b"
    end

    test "joins if same markup" do
      frag = Fragment.from_array([text_node("b")])
      node = text_node("a")
      result = Fragment.add_to_start(frag, node)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "ab"
    end
  end

  describe "add_to_end/2" do
    test "adds node to end" do
      frag = Fragment.from_array([text_node("a")])
      node = text_node("b", [bold_mark()])
      result = Fragment.add_to_end(frag, node)
      assert Fragment.child_count(result) == 2
      assert Fragment.child(result, 0).text == "a"
      assert Fragment.child(result, 1).text == "b"
    end

    test "joins if same markup" do
      frag = Fragment.from_array([text_node("a")])
      node = text_node("b")
      result = Fragment.add_to_end(frag, node)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "ab"
    end
  end

  describe "to_json/1" do
    test "nil for empty fragment" do
      assert Fragment.to_json(Fragment.empty()) == nil
    end

    test "array of node JSON for non-empty" do
      frag = Fragment.from_array([text_node("hello")])
      # We just need to verify to_json returns a list (Node.to_json not fully implemented yet,
      # but we can test the structure)
      result = Fragment.to_json(frag)
      assert is_list(result)
      assert length(result) == 1
    end
  end

  describe "node_size integration" do
    test "text node size is string length" do
      node = text_node("hello")
      assert PmNode.node_size(node) == 5
    end

    test "leaf node size is 1" do
      node = hr_node()
      assert PmNode.node_size(node) == 1
    end

    test "paragraph node size includes content + 2" do
      node = para_node([text_node("hi")])
      # content size = 2, plus 2 for open/close = 4
      assert PmNode.node_size(node) == 4
    end
  end

  describe "Node.eq/2" do
    test "equal text nodes" do
      a = text_node("hello")
      b = text_node("hello")
      assert PmNode.eq(a, b)
    end

    test "different text" do
      a = text_node("hello")
      b = text_node("world")
      refute PmNode.eq(a, b)
    end

    test "different marks" do
      a = text_node("hello")
      b = text_node("hello", [bold_mark()])
      refute PmNode.eq(a, b)
    end

    test "equal non-text nodes" do
      a = para_node([text_node("hi")])
      b = para_node([text_node("hi")])
      assert PmNode.eq(a, b)
    end

    test "different non-text nodes" do
      a = para_node([text_node("hi")])
      b = para_node([text_node("bye")])
      refute PmNode.eq(a, b)
    end
  end

  describe "Node.cut/3" do
    test "cuts text node" do
      node = text_node("hello")
      result = PmNode.cut(node, 1, 4)
      assert result.text == "ell"
    end

    test "full range text returns self" do
      node = text_node("hello")
      assert PmNode.cut(node, 0, 5) == node
    end

    test "cuts non-text node" do
      node = para_node([text_node("hello")])
      # content size = 5, cut(1, 4) cuts the fragment content at positions 1..4
      result = PmNode.cut(node, 1, 4)
      assert result.type.name == "paragraph"
      assert Fragment.child(result.content, 0).text == "ell"
    end
  end

  describe "Node.copy/2" do
    test "returns same node if content unchanged" do
      node = para_node([text_node("hello")])
      assert PmNode.copy(node, node.content) == node
    end

    test "returns new node with different content" do
      node = para_node([text_node("hello")])
      new_content = Fragment.from_array([text_node("world")])
      result = PmNode.copy(node, new_content)
      assert result.type == node.type
      assert result.content == new_content
    end
  end

  describe "complex cut scenarios" do
    test "cut across paragraph boundaries" do
      # Two paragraphs: p("ab") p("cd")
      # p("ab") has size 4 (2+2), positions 0..4
      # p("cd") has size 4 (2+2), positions 4..8
      p1 = para_node([text_node("ab")])
      p2 = para_node([text_node("cd")])
      frag = Fragment.from_array([p1, p2])
      assert frag.size == 8

      # Cut(1, 7) should cut into both paragraphs
      # p1: pos=0, end=4. end(4) > from(1), so included.
      #   pos(0) < from(1) => need to cut child
      #   not text: child.cut(max(0, 1-0-1)=0, min(2, 7-0-1)=2) => full content
      #   Actually wait, 7-0-1 = 6, min(2, 6) = 2 — so full content
      # p2: pos=4, end=8. end(8) > from(1), so included.
      #   end(8) > to(7) => need to cut child
      #   not text: child.cut(max(0, 1-4-1)=0, min(2, 7-4-1)=2) => full content
      #   Wait: 1-4-1 = -4, max(0,-4)=0; 7-4-1=2, min(2,2)=2 — so full content
      # So both are included fully
      result = Fragment.cut(frag, 1, 7)
      assert Fragment.child_count(result) == 2

      # First paragraph should be cut: from - pos - 1 = 1-0-1 = 0, to - pos - 1 = 7-0-1 = 6 → min(2, 6) = 2
      # So first para keeps full content "ab"
      assert Fragment.child(result, 0).type.name == "paragraph"

      # Second paragraph: from - pos - 1 = max(0, 1-4-1) = 0, to - pos - 1 = 7-4-1 = 2 → min(2, 2) = 2
      # So second para also keeps full content "cd"
      assert Fragment.child(result, 1).type.name == "paragraph"
    end

    test "cut removing first paragraph entirely" do
      p1 = para_node([text_node("ab")])
      p2 = para_node([text_node("cd")])
      frag = Fragment.from_array([p1, p2])

      # Cut(4, 8) - skip first paragraph entirely
      result = Fragment.cut(frag, 4, 8)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).type.name == "paragraph"
      assert Fragment.child(Fragment.child(result, 0).content, 0).text == "cd"
    end

    test "cut into middle of paragraph" do
      # p("hello") has size 7 (5+2)
      p = para_node([text_node("hello")])
      frag = Fragment.from_array([p])

      # Cut(2, 5) - cuts into the paragraph
      # pos=0, end=7, end > from=2 and pos < from=2 or end > to=5
      # not text: child.cut(max(0, 2-0-1)=1, min(5, 5-0-1)=4) → cut(1, 4) on fragment
      result = Fragment.cut(frag, 2, 5)
      assert Fragment.child_count(result) == 1
      inner = Fragment.child(result, 0)
      assert inner.type.name == "paragraph"
      assert Fragment.child(inner.content, 0).text == "ell"
    end

    test "cut with leaf nodes" do
      # hr_node is a leaf with size 1
      hr = hr_node()
      t = text_node("ab")
      frag = Fragment.from_array([hr, t])
      assert frag.size == 3

      # Cut(0, 1) - just the hr
      result = Fragment.cut(frag, 0, 1)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).type.name == "horizontal_rule"

      # Cut(1, 3) - just the text
      result2 = Fragment.cut(frag, 1, 3)
      assert Fragment.child_count(result2) == 1
      assert Fragment.child(result2, 0).text == "ab"
    end
  end
end
