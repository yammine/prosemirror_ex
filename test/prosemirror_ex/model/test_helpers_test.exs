defmodule ProsemirrorEx.TestHelpersTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.Node, as: PmNode

  describe "test_schema" do
    test "creates a valid schema" do
      schema = test_schema()
      assert schema.nodes["doc"] != nil
      assert schema.nodes["paragraph"] != nil
      assert schema.nodes["text"] != nil
      assert schema.marks["em"] != nil
      assert schema.marks["strong"] != nil
      assert schema.marks["link"] != nil
    end
  end

  describe "basic node builders" do
    test "p creates an empty paragraph" do
      {node, tags} = p()
      assert node.type.name == "paragraph"
      assert PmNode.child_count(node) == 0
      assert tags == %{}
    end

    test "p creates a paragraph with text" do
      {node, tags} = p(["hello"])
      assert node.type.name == "paragraph"
      assert PmNode.child_count(node) == 1
      first = PmNode.first_child(node)
      assert first.text == "hello"
      assert tags == %{}
    end

    test "doc creates a doc with children" do
      {node, _tags} = doc([p(["hello"])])
      assert node.type.name == "doc"
      assert PmNode.child_count(node) == 1
      child = PmNode.child(node, 0)
      assert child.type.name == "paragraph"
    end

    test "blockquote wraps children" do
      {node, _tags} = blockquote([p(["hi"])])
      assert node.type.name == "blockquote"
      assert PmNode.child_count(node) == 1
    end

    test "heading builders" do
      {h, _} = h1(["Title"])
      assert h.type.name == "heading"
      assert h.attrs["level"] == 1

      {h2_node, _} = h2(["Sub"])
      assert h2_node.attrs["level"] == 2

      {h3_node, _} = h3(["Sub Sub"])
      assert h3_node.attrs["level"] == 3
    end

    test "list builders" do
      {node, _} = ul([li([p(["item 1"])])])
      assert node.type.name == "bullet_list"
      child = PmNode.child(node, 0)
      assert child.type.name == "list_item"
    end

    test "ol builder" do
      {node, _} = ol([li([p(["item"])])])
      assert node.type.name == "ordered_list"
      assert node.attrs["order"] == 1
    end
  end

  describe "leaf node builders" do
    test "hr creates a horizontal_rule" do
      {node, tags} = hr()
      assert node.type.name == "horizontal_rule"
      assert tags == %{}
    end

    test "br creates a hard_break" do
      {node, _} = br()
      assert node.type.name == "hard_break"
    end

    test "img creates an image with default src" do
      {node, _} = img()
      assert node.type.name == "image"
      assert node.attrs["src"] == "img.png"
    end

    test "img with custom attrs" do
      {node, _} = img(%{"src" => "custom.png", "alt" => "My image"})
      assert node.attrs["src"] == "custom.png"
      assert node.attrs["alt"] == "My image"
    end
  end

  describe "mark builders" do
    test "em wraps children with em mark" do
      {node, _tags} = p([em(["hello"])])
      child = PmNode.first_child(node)
      assert child.text == "hello"
      assert length(child.marks) == 1
      assert hd(child.marks).type.name == "em"
    end

    test "strong wraps children with strong mark" do
      {node, _tags} = p([strong(["bold"])])
      child = PmNode.first_child(node)
      assert hd(child.marks).type.name == "strong"
    end

    test "nested marks" do
      {node, _tags} = p([em([strong(["both"])])])
      child = PmNode.first_child(node)
      assert child.text == "both"
      mark_names = Enum.map(child.marks, fn m -> m.type.name end)
      assert "em" in mark_names
      assert "strong" in mark_names
    end

    test "a creates a link" do
      {node, _} = p([a(["click me"])])
      child = PmNode.first_child(node)
      assert hd(child.marks).type.name == "link"
      assert hd(child.marks).attrs["href"] == "foo"
    end

    test "a with custom attrs" do
      {node, _} = p([a(%{"href" => "http://example.com"}, ["click"])])
      child = PmNode.first_child(node)
      assert hd(child.marks).attrs["href"] == "http://example.com"
    end

    test "code_mark wraps children" do
      {node, _} = p([code_mark(["x = 1"])])
      child = PmNode.first_child(node)
      assert hd(child.marks).type.name == "code"
    end
  end

  describe "tag tracking" do
    test "tags in text children" do
      {node, tags} = p(["hello<a>world"])
      assert tags["a"] == 6
      # 5 chars for "hello" + 1 for paragraph open token
      child = PmNode.first_child(node)
      assert child.text == "helloworld"
    end

    test "multiple tags" do
      {node, tags} = p(["<a>hello<b>"])
      assert tags["a"] == 1
      assert tags["b"] == 6
      child = PmNode.first_child(node)
      assert child.text == "hello"
    end

    test "tags at start and end" do
      {_node, tags} = p(["<a>text<b>"])
      assert tags["a"] == 1
      assert tags["b"] == 5
    end

    test "tags propagate through nesting" do
      {_node, tags} = doc([p(["<a>hello<b>"])])
      # doc adds 1 for its opening token, p adds 1 for its opening token
      # <a> is at position 0 in text, but +1 for p open, +1 for doc open = 2
      assert tags["a"] == 2
      assert tags["b"] == 7
    end

    test "tags in mark-wrapped children" do
      {_node, tags} = p([em(["<a>hello"])])
      assert tags["a"] == 1
    end

    test "tags after leaf nodes" do
      {_node, tags} = p([em(["hello"]), "<a>world"])
      assert tags["a"] == 6
    end
  end

  describe "eq helper" do
    test "equal nodes" do
      {a, _} = p(["hello"])
      {b, _} = p(["hello"])
      assert eq(a, b)
    end

    test "unequal nodes" do
      {a, _} = p(["hello"])
      {b, _} = p(["world"])
      refute eq(a, b)
    end
  end

  describe "complex document building" do
    test "builds a complex document" do
      {node, _tags} =
        doc([
          h1(["Title"]),
          p(["Some ", em(["emphasized"]), " text"]),
          blockquote([p(["A quote"])]),
          ul([li([p(["Item 1"])]), li([p(["Item 2"])])])
        ])

      assert node.type.name == "doc"
      assert PmNode.child_count(node) == 4
      assert PmNode.child(node, 0).type.name == "heading"
      assert PmNode.child(node, 1).type.name == "paragraph"
      assert PmNode.child(node, 2).type.name == "blockquote"
      assert PmNode.child(node, 3).type.name == "bullet_list"
    end
  end
end
