defmodule ProsemirrorEx.Model.SliceTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Slice

  describe "Node.slice" do
    # Helper: slice doc from tag "a" (or 0) to tag "b", then check
    # content equality, openStart, and openEnd against expected.
    defp t(doc_with_tags, expected_with_tags, open_start, open_end) do
      {doc_node, doc_tags} = doc_with_tags
      {expected_node, _} = expected_with_tags

      from = Map.get(doc_tags, "a", 0)
      to = Map.get(doc_tags, "b")

      slice = PmNode.slice(doc_node, from, to)

      assert Fragment.eq(slice.content, expected_node.content),
             "Slice content mismatch.\n  Expected: #{Fragment.to_string_inner(expected_node.content)}\n  Got:      #{Fragment.to_string_inner(slice.content)}"

      assert slice.open_start == open_start,
             "openStart mismatch: expected #{open_start}, got #{slice.open_start}"

      assert slice.open_end == open_end,
             "openEnd mismatch: expected #{open_end}, got #{slice.open_end}"
    end

    test "can cut half a paragraph" do
      t(doc([p(["hello<b> world"])]), doc([p(["hello"])]), 0, 1)
    end

    test "can cut to the end of a paragraph" do
      t(doc([p(["hello<b>"])]), doc([p(["hello"])]), 0, 1)
    end

    test "leaves off extra content" do
      t(doc([p(["hello<b> world"]), p(["rest"])]), doc([p(["hello"])]), 0, 1)
    end

    test "preserves styles" do
      t(doc([p(["hello ", em(["WOR<b>LD"])])]), doc([p(["hello ", em(["WOR"])])]), 0, 1)
    end

    test "can cut multiple blocks" do
      t(doc([p(["a"]), p(["b<b>"])]), doc([p(["a"]), p(["b"])]), 0, 1)
    end

    test "can cut to a top-level position" do
      t(doc([p(["a"]), "<b>", p(["b"])]), doc([p(["a"])]), 0, 0)
    end

    test "can cut to a deep position" do
      t(
        doc([blockquote([ul([li([p(["a"])]), li([p(["b<b>"])])])])]),
        doc([blockquote([ul([li([p(["a"])]), li([p(["b"])])])])]),
        0,
        4
      )
    end

    test "can cut everything after a position" do
      t(doc([p(["hello<a> world"])]), doc([p([" world"])]), 1, 0)
    end

    test "can cut from the start of a textblock" do
      t(doc([p(["<a>hello"])]), doc([p(["hello"])]), 1, 0)
    end

    test "leaves off extra content before" do
      t(doc([p(["foo"]), p(["bar<a>baz"])]), doc([p(["baz"])]), 1, 0)
    end

    test "preserves styles after cut" do
      t(
        doc([p(["a sentence with an ", em(["emphasized ", a(["li<a>nk"])]), " in it"])]),
        doc([p([em([a(["nk"])]), " in it"])]),
        1,
        0
      )
    end

    test "preserves styles started after cut" do
      t(
        doc([p(["a ", em(["sentence"]), " wi<a>th ", em(["text"]), " in it"])]),
        doc([p(["th ", em(["text"]), " in it"])]),
        1,
        0
      )
    end

    test "can cut from a top-level position" do
      t(doc([p(["a"]), "<a>", p(["b"])]), doc([p(["b"])]), 0, 0)
    end

    test "can cut from a deep position" do
      t(
        doc([blockquote([ul([li([p(["a"])]), li([p(["<a>b"])])])])]),
        doc([blockquote([ul([li([p(["b"])])])])]),
        4,
        0
      )
    end

    test "can cut part of a text node" do
      t(doc([p(["hell<a>o wo<b>rld"])]), p(["o wo"]), 0, 0)
    end

    test "can cut across paragraphs" do
      t(doc([p(["on<a>e"]), p(["t<b>wo"])]), doc([p(["e"]), p(["t"])]), 1, 1)
    end

    test "can cut part of marked text" do
      t(
        doc([p(["here's noth<a>ing and ", em(["here's e<b>m"])])]),
        p(["ing and ", em(["here's e"])]),
        0,
        0
      )
    end

    test "can cut across different depths" do
      t(
        doc([
          ul([li([p(["hello"])]), li([p(["wo<a>rld"])]), li([p(["x"])])]),
          p([em(["bo<b>o"])])
        ]),
        doc([ul([li([p(["rld"])]), li([p(["x"])])]), p([em(["bo"])])]),
        3,
        1
      )
    end

    test "can cut between deeply nested nodes" do
      t(
        doc([
          blockquote([
            p(["foo<a>bar"]),
            ul([li([p(["a"])]), li([p(["b"]), "<b>", p(["c"])])]),
            p(["d"])
          ])
        ]),
        blockquote([p(["bar"]), ul([li([p(["a"])]), li([p(["b"])])])]),
        1,
        2
      )
    end

    test "can include parents" do
      {d, tags} = doc([blockquote([p(["fo<a>o"]), p(["bar<b>"])])])
      slice = PmNode.slice(d, tags["a"], tags["b"], true)

      assert Slice.to_string(slice) ==
               "<blockquote(paragraph(\"o\"), paragraph(\"bar\"))>(2,2)"
    end
  end
end
