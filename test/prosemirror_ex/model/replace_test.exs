defmodule ProsemirrorEx.Model.ReplaceTest do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.Slice
  alias ProsemirrorEx.Model.ReplaceError

  describe "Node.replace" do
    defp rpl(doc_with_tags, insert_with_tags, expected_with_tags) do
      {doc_node, doc_tags} = doc_with_tags

      slice =
        if insert_with_tags do
          {ins_node, ins_tags} = insert_with_tags
          PmNode.slice(ins_node, ins_tags["a"], ins_tags["b"])
        else
          Slice.empty()
        end

      result = PmNode.replace(doc_node, doc_tags["a"], doc_tags["b"], slice)
      {expected_node, _} = expected_with_tags

      assert PmNode.eq(result, expected_node),
             "Replace result mismatch.\n  Expected: #{PmNode.debug_string(expected_node)}\n  Got:      #{PmNode.debug_string(result)}"
    end

    defp bad(doc_with_tags, insert_with_tags, pattern) do
      {doc_node, doc_tags} = doc_with_tags

      slice =
        if insert_with_tags do
          {ins_node, ins_tags} = insert_with_tags
          PmNode.slice(ins_node, ins_tags["a"], ins_tags["b"])
        else
          Slice.empty()
        end

      assert_raise ReplaceError, ~r/#{pattern}/i, fn ->
        PmNode.replace(doc_node, doc_tags["a"], doc_tags["b"], slice)
      end
    end

    # ── Success cases ──────────────────────────────────────────────────

    test "joins on delete" do
      rpl(
        doc([p(["on<a>e"]), p(["t<b>wo"])]),
        nil,
        doc([p(["onwo"])])
      )
    end

    test "merges matching blocks" do
      rpl(
        doc([p(["on<a>e"]), p(["t<b>wo"])]),
        doc([p(["xx<a>xx"]), p(["yy<b>yy"])]),
        doc([p(["onxx"]), p(["yywo"])])
      )
    end

    test "merges when adding text" do
      rpl(
        doc([p(["on<a>e"]), p(["t<b>wo"])]),
        doc([p(["<a>H<b>"])]),
        doc([p(["onHwo"])])
      )
    end

    test "can insert text" do
      rpl(
        doc([p(["before"]), p(["on<a><b>e"]), p(["after"])]),
        doc([p(["<a>H<b>"])]),
        doc([p(["before"]), p(["onHe"]), p(["after"])])
      )
    end

    test "doesn't merge non-matching blocks" do
      rpl(
        doc([p(["on<a>e"]), p(["t<b>wo"])]),
        doc([h1(["<a>H<b>"])]),
        doc([p(["onHwo"])])
      )
    end

    test "can merge a nested node" do
      rpl(
        doc([blockquote([blockquote([p(["on<a>e"]), p(["t<b>wo"])])])]),
        doc([p(["<a>H<b>"])]),
        doc([blockquote([blockquote([p(["onHwo"])])])])
      )
    end

    test "can replace within a block" do
      rpl(
        doc([blockquote([p(["a<a>bc<b>d"])])]),
        doc([p(["x<a>y<b>z"])]),
        doc([blockquote([p(["ayd"])])])
      )
    end

    test "can insert a lopsided slice" do
      rpl(
        doc([blockquote([blockquote([p(["on<a>e"]), p(["two"]), "<b>", p(["three"])])])]),
        doc([blockquote([p(["aa<a>aa"]), p(["bb"]), p(["cc"]), "<b>", p(["dd"])])]),
        doc([blockquote([blockquote([p(["onaa"]), p(["bb"]), p(["cc"]), p(["three"])])])])
      )
    end

    test "can insert a deep, lopsided slice" do
      rpl(
        doc([
          blockquote([blockquote([p(["on<a>e"]), p(["two"]), p(["three"])]), "<b>", p(["x"])])
        ]),
        doc([blockquote([p(["aa<a>aa"]), p(["bb"]), p(["cc"])]), "<b>", p(["dd"])]),
        doc([blockquote([blockquote([p(["onaa"]), p(["bb"]), p(["cc"])]), p(["x"])])])
      )
    end

    test "can merge multiple levels" do
      rpl(
        doc([
          blockquote([blockquote([p(["hell<a>o"])])]),
          blockquote([blockquote([p(["<b>a"])])])
        ]),
        nil,
        doc([blockquote([blockquote([p(["hella"])])])])
      )
    end

    test "can merge multiple levels while inserting" do
      rpl(
        doc([
          blockquote([blockquote([p(["hell<a>o"])])]),
          blockquote([blockquote([p(["<b>a"])])])
        ]),
        doc([p(["<a>i<b>"])]),
        doc([blockquote([blockquote([p(["hellia"])])])])
      )
    end

    test "can insert a split" do
      rpl(
        doc([p(["foo<a><b>bar"])]),
        doc([p(["<a>x"]), p(["y<b>"])]),
        doc([p(["foox"]), p(["ybar"])])
      )
    end

    test "can insert a deep split" do
      rpl(
        doc([blockquote([p(["foo<a>x<b>bar"])])]),
        doc([blockquote([p(["<a>x"])]), blockquote([p(["y<b>"])])]),
        doc([blockquote([p(["foox"])]), blockquote([p(["ybar"])])])
      )
    end

    test "can add a split one level up" do
      rpl(
        doc([blockquote([p(["foo<a>u"]), p(["v<b>bar"])])]),
        doc([blockquote([p(["<a>x"])]), blockquote([p(["y<b>"])])]),
        doc([blockquote([p(["foox"])]), blockquote([p(["ybar"])])])
      )
    end

    test "keeps the node type of the left node" do
      rpl(
        doc([h1(["foo<a>bar"]), "<b>"]),
        doc([p(["foo<a>baz"]), "<b>"]),
        doc([h1(["foobaz"])])
      )
    end

    test "keeps the node type even when empty" do
      rpl(
        doc([h1(["<a>bar"]), "<b>"]),
        doc([p(["foo<a>baz"]), "<b>"]),
        doc([h1(["baz"])])
      )
    end

    # ── Error cases ────────────────────────────────────────────────────

    test "doesn't allow the left side to be too deep" do
      bad(
        doc([p(["<a><b>"])]),
        doc([blockquote([p(["<a>"])]), "<b>"]),
        "deeper"
      )
    end

    test "doesn't allow a depth mismatch" do
      bad(
        doc([p(["<a><b>"])]),
        doc(["<a>", p(["<b>"])]),
        "inconsistent"
      )
    end

    test "rejects a bad fit" do
      bad(
        doc(["<a><b>"]),
        doc([p(["<a>foo<b>"])]),
        "invalid content"
      )
    end

    test "rejects unjoinable content" do
      bad(
        doc([ul([li([p(["a"])]), "<a>"]), "<b>"]),
        doc([p(["foo", "<a>"]), "<b>"]),
        "cannot join"
      )
    end

    test "rejects an unjoinable delete" do
      bad(
        doc([blockquote([p(["a"]), "<a>"]), ul(["<b>", li([p(["b"])])])]),
        nil,
        "cannot join"
      )
    end

    test "check content validity" do
      bad(
        doc([blockquote(["<a>", p(["hi"])]), "<b>"]),
        doc([blockquote(["hi", "<a>"]), "<b>"]),
        "invalid content"
      )
    end
  end
end
