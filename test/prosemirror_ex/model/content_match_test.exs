defmodule ProsemirrorEx.Model.ContentMatchTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.ContentMatch
  alias ProsemirrorEx.Model.Fragment
  alias ProsemirrorEx.Model.Node, as: PmNode
  alias ProsemirrorEx.Model.NodeType

  # ── Test node types (mimics prosemirror-test-builder schema) ──────

  defp make_node_types do
    %{
      "doc" => %NodeType{
        name: "doc",
        groups: [],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "paragraph" => %NodeType{
        name: "paragraph",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: true
      },
      "heading" => %NodeType{
        name: "heading",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{"level" => 1},
        inline_content: true
      },
      "blockquote" => %NodeType{
        name: "blockquote",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "horizontal_rule" => %NodeType{
        name: "horizontal_rule",
        groups: ["block"],
        is_block: true,
        is_leaf: true,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "code_block" => %NodeType{
        name: "code_block",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "text" => %NodeType{
        name: "text",
        groups: ["inline"],
        is_block: false,
        is_leaf: true,
        is_text: true,
        is_inline: true,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "image" => %NodeType{
        name: "image",
        groups: ["inline"],
        is_block: false,
        is_leaf: true,
        is_text: false,
        is_inline: true,
        has_required_attrs: false,
        default_attrs: %{"src" => "img.png", "alt" => nil, "title" => nil},
        inline_content: false
      },
      "hard_break" => %NodeType{
        name: "hard_break",
        groups: ["inline"],
        is_block: false,
        is_leaf: true,
        is_text: false,
        is_inline: true,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "ordered_list" => %NodeType{
        name: "ordered_list",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{"order" => 1},
        inline_content: false
      },
      "bullet_list" => %NodeType{
        name: "bullet_list",
        groups: ["block"],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      },
      "list_item" => %NodeType{
        name: "list_item",
        groups: [],
        is_block: true,
        is_leaf: false,
        is_text: false,
        is_inline: false,
        has_required_attrs: false,
        default_attrs: %{},
        inline_content: false
      }
    }
  end

  defp get(expr) do
    ContentMatch.parse(expr, make_node_types())
  end

  defp match_expr(expr, types_str) do
    m = get(expr)
    node_types = make_node_types()

    types =
      if types_str == "",
        do: [],
        else: String.split(types_str) |> Enum.map(&Map.fetch!(node_types, &1))

    result =
      Enum.reduce_while(types, m, fn type, acc ->
        case ContentMatch.match_type(acc, type) do
          nil -> {:halt, nil}
          next -> {:cont, next}
        end
      end)

    result != nil and result.valid_end
  end

  defp valid(expr, types), do: assert(match_expr(expr, types))
  defp invalid(expr, types), do: refute(match_expr(expr, types))

  # ── Node builder helpers ──────────────────────────────────────────

  defp node_types, do: make_node_types()

  defp make_node(type_name, children \\ []) do
    type = Map.fetch!(node_types(), type_name)
    content = Fragment.from_array(children)
    %PmNode{type: type, attrs: type.default_attrs || %{}, content: content, marks: []}
  end

  defp doc(children \\ []), do: make_node("doc", children)
  defp p(children \\ []), do: make_node("paragraph", children)
  defp h1(children \\ []), do: make_node("heading", children)
  defp pre(children \\ []), do: make_node("code_block", children)
  defp hr, do: make_node("horizontal_rule")

  defp br do
    type = Map.fetch!(node_types(), "hard_break")
    %PmNode{type: type, attrs: %{}, content: nil, marks: []}
  end

  defp img do
    type = Map.fetch!(node_types(), "image")

    %PmNode{
      type: type,
      attrs: %{"src" => "img.png", "alt" => nil, "title" => nil},
      content: nil,
      marks: []
    }
  end

  defp fill(expr, before_node, after_node, expected_result) do
    cm = get(expr)
    matched = ContentMatch.match_fragment(cm, before_node.content)

    filled =
      case matched do
        nil -> nil
        m -> ContentMatch.fill_before(m, after_node.content, true)
      end

    if expected_result do
      assert filled != nil, "fillBefore returned nil, expected a fragment"
      assert Fragment.eq(filled, expected_result.content)
    else
      assert filled == nil
    end
  end

  defp fill3(expr, before, mid, after_node, left, right \\ nil) do
    cm = get(expr)

    a =
      case ContentMatch.match_fragment(cm, before.content) do
        nil -> nil
        m -> ContentMatch.fill_before(m, mid.content)
      end

    b =
      if a do
        combined = Fragment.append(Fragment.append(before.content, a), mid.content)

        case ContentMatch.match_fragment(cm, combined) do
          nil -> nil
          m -> ContentMatch.fill_before(m, after_node.content, true)
        end
      else
        nil
      end

    if left do
      assert a != nil, "fill3: first fillBefore returned nil"
      assert b != nil, "fill3: second fillBefore returned nil"
      assert Fragment.eq(a, left.content)
      assert Fragment.eq(b, right.content)
    else
      assert b == nil
    end
  end

  # ── matchType tests ──────────────────────────────────────────────

  describe "matchType" do
    test "accepts empty content for the empty expr" do
      valid("", "")
    end

    test "doesn't accept content in the empty expr" do
      invalid("", "image")
    end

    test "matches nothing to an asterisk" do
      valid("image*", "")
    end

    test "matches one element to an asterisk" do
      valid("image*", "image")
    end

    test "matches multiple elements to an asterisk" do
      valid("image*", "image image image image")
    end

    test "only matches appropriate elements to an asterisk" do
      invalid("image*", "image text")
    end

    test "matches group members to a group" do
      valid("inline*", "image text")
    end

    test "doesn't match non-members to a group" do
      invalid("inline*", "paragraph")
    end

    test "matches an element to a choice expression" do
      valid("(paragraph | heading)", "paragraph")
    end

    test "doesn't match unmentioned elements to a choice expr" do
      invalid("(paragraph | heading)", "image")
    end

    test "matches a simple sequence" do
      valid("paragraph horizontal_rule paragraph", "paragraph horizontal_rule paragraph")
    end

    test "fails when a sequence is too long" do
      invalid("paragraph horizontal_rule", "paragraph horizontal_rule paragraph")
    end

    test "fails when a sequence is too short" do
      invalid("paragraph horizontal_rule paragraph", "paragraph horizontal_rule")
    end

    test "fails when a sequence starts incorrectly" do
      invalid("paragraph horizontal_rule", "horizontal_rule paragraph horizontal_rule")
    end

    test "accepts a sequence asterisk matching zero elements" do
      valid("heading paragraph*", "heading")
    end

    test "accepts a sequence asterisk matching multiple elts" do
      valid("heading paragraph*", "heading paragraph paragraph")
    end

    test "accepts a sequence plus matching one element" do
      valid("heading paragraph+", "heading paragraph")
    end

    test "accepts a sequence plus matching multiple elts" do
      valid("heading paragraph+", "heading paragraph paragraph")
    end

    test "fails when a sequence plus has no elements" do
      invalid("heading paragraph+", "heading")
    end

    test "fails when a sequence plus misses its start" do
      invalid("heading paragraph+", "paragraph paragraph")
    end

    test "accepts an optional element being present" do
      valid("image?", "image")
    end

    test "accepts an optional element being missing" do
      valid("image?", "")
    end

    test "fails when an optional element is present twice" do
      invalid("image?", "image image")
    end

    test "accepts a nested repeat" do
      valid("(heading paragraph+)+", "heading paragraph heading paragraph paragraph")
    end

    test "fails on extra input after a nested repeat" do
      invalid(
        "(heading paragraph+)+",
        "heading paragraph heading paragraph paragraph horizontal_rule"
      )
    end

    test "accepts a matching count" do
      valid("hard_break{2}", "hard_break hard_break")
    end

    test "rejects a count that comes up short" do
      invalid("hard_break{2}", "hard_break")
    end

    test "rejects a count that has too many elements" do
      invalid("hard_break{2}", "hard_break hard_break hard_break")
    end

    test "accepts a count on the lower bound" do
      valid("hard_break{2, 4}", "hard_break hard_break")
    end

    test "accepts a count on the upper bound" do
      valid("hard_break{2, 4}", "hard_break hard_break hard_break hard_break")
    end

    test "accepts a count between the bounds" do
      valid("hard_break{2, 4}", "hard_break hard_break hard_break")
    end

    test "rejects a sequence with too few elements" do
      invalid("hard_break{2, 4}", "hard_break")
    end

    test "rejects a sequence with too many elements" do
      invalid(
        "hard_break{2, 4}",
        "hard_break hard_break hard_break hard_break hard_break"
      )
    end

    test "rejects a sequence with a bad element after it" do
      invalid("hard_break{2, 4} text*", "hard_break hard_break image")
    end

    test "accepts a sequence with a matching element after it" do
      valid("hard_break{2, 4} image?", "hard_break hard_break image")
    end

    test "accepts an open range" do
      valid("hard_break{2,}", "hard_break hard_break")
    end

    test "accepts an open range matching many" do
      valid("hard_break{2,}", "hard_break hard_break hard_break hard_break")
    end

    test "rejects an open range with too few elements" do
      invalid("hard_break{2,}", "hard_break")
    end
  end

  # ── fillBefore tests ──────────────────────────────────────────────

  describe "fillBefore" do
    test "returns the empty fragment when things match" do
      fill("paragraph horizontal_rule paragraph", doc([p(), hr()]), doc([p()]), doc())
    end

    test "adds a node when necessary" do
      fill("paragraph horizontal_rule paragraph", doc([p()]), doc([p()]), doc([hr()]))
    end

    test "accepts an asterisk across the bound" do
      fill("hard_break*", p([br()]), p([br()]), p())
    end

    test "accepts an asterisk only on the left" do
      fill("hard_break*", p([br()]), p(), p())
    end

    test "accepts an asterisk only on the right" do
      fill("hard_break*", p(), p([br()]), p())
    end

    test "accepts an asterisk with no elements" do
      fill("hard_break*", p(), p(), p())
    end

    test "accepts a plus across the bound" do
      fill("hard_break+", p([br()]), p([br()]), p())
    end

    test "adds an element for a content-less plus" do
      fill("hard_break+", p(), p(), p([br()]))
    end

    test "fails for a mismatched plus" do
      fill("hard_break+", p(), p([img()]), nil)
    end

    test "accepts asterisk with content on both sides" do
      fill("heading* paragraph*", doc([h1()]), doc([p()]), doc())
    end

    test "accepts asterisk with no content after" do
      fill("heading* paragraph*", doc([h1()]), doc(), doc())
    end

    test "accepts plus with content on both sides" do
      fill("heading+ paragraph+", doc([h1()]), doc([p()]), doc())
    end

    test "accepts plus with no content after" do
      fill("heading+ paragraph+", doc([h1()]), doc(), doc([p()]))
    end

    test "adds elements to match a count" do
      fill("hard_break{3}", p([br()]), p([br()]), p([br()]))
    end

    test "fails when there are too many elements" do
      fill("hard_break{3}", p([br(), br()]), p([br(), br()]), nil)
    end

    test "adds elements for two counted groups" do
      fill("code_block{2} paragraph{2}", doc([pre()]), doc([p()]), doc([pre(), p()]))
    end

    test "doesn't include optional elements" do
      fill("heading paragraph? horizontal_rule", doc([h1()]), doc(), doc([hr()]))
    end

    test "completes a sequence (fill3)" do
      fill3(
        "paragraph horizontal_rule paragraph horizontal_rule paragraph",
        doc([p()]),
        doc([p()]),
        doc([p()]),
        doc([hr()]),
        doc([hr()])
      )
    end

    test "accepts plus across two bounds (fill3)" do
      fill3(
        "code_block+ paragraph+",
        doc([pre()]),
        doc([pre()]),
        doc([p()]),
        doc(),
        doc()
      )
    end

    test "fills a plus from empty input (fill3)" do
      fill3(
        "code_block+ paragraph+",
        doc(),
        doc(),
        doc(),
        doc(),
        doc([pre(), p()])
      )
    end

    test "completes a count (fill3)" do
      fill3(
        "code_block{3} paragraph{3}",
        doc([pre()]),
        doc([p()]),
        doc(),
        doc([pre(), pre()]),
        doc([p(), p()])
      )
    end

    test "fails on non-matching elements (fill3)" do
      fill3(
        "paragraph*",
        doc([p()]),
        doc([pre()]),
        doc([p()]),
        nil
      )
    end

    test "completes a plus across two bounds (fill3)" do
      fill3(
        "paragraph{4}",
        doc([p()]),
        doc([p()]),
        doc([p()]),
        doc(),
        doc([p()])
      )
    end

    test "refuses to complete an overflown count across two bounds (fill3)" do
      fill3(
        "paragraph{2}",
        doc([p()]),
        doc([p()]),
        doc([p()]),
        nil
      )
    end
  end
end
