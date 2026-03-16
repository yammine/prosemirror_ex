defmodule ProsemirrorEx.Model.MarkTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.Mark
  alias ProsemirrorEx.Model.MarkType

  # -- Helper mark types mimicking the prosemirror basic schema --

  defp em_type do
    %MarkType{name: "em", rank: 1}
  end

  defp strong_type do
    %MarkType{name: "strong", rank: 2}
  end

  defp link_type do
    %MarkType{name: "link", rank: 3}
  end

  defp code_type do
    %MarkType{name: "code", rank: 4}
  end

  # Custom mark types for exclusion tests

  # excludes: "" means excludes nothing (non-exclusive / allows multiple instances)
  defp remark_type do
    %MarkType{name: "remark", rank: 2, excluded: []}
  end

  # excludes: :all means globally excluding
  defp user_type do
    %MarkType{name: "user", rank: 1, excluded: :all}
  end

  # strong_custom excludes em_custom by name
  defp strong_custom_type do
    %MarkType{name: "strong_custom", rank: 2, excluded: [%MarkType{name: "em_custom"}]}
  end

  defp em_custom_type do
    %MarkType{name: "em_custom", rank: 3}
  end

  # -- Helper constructors --

  defp em, do: %Mark{type: em_type(), attrs: %{}}
  defp strong, do: %Mark{type: strong_type(), attrs: %{}}
  defp code, do: %Mark{type: code_type(), attrs: %{}}

  defp link(href) do
    %Mark{type: link_type(), attrs: %{"href" => href, "title" => nil}}
  end

  defp link(href, title) do
    %Mark{type: link_type(), attrs: %{"href" => href, "title" => title}}
  end

  defp remark(id) do
    %Mark{type: remark_type(), attrs: %{"id" => id}}
  end

  defp user(id) do
    %Mark{type: user_type(), attrs: %{"id" => id}}
  end

  defp strong_custom do
    %Mark{type: strong_custom_type(), attrs: %{}}
  end

  defp em_custom do
    %Mark{type: em_custom_type(), attrs: %{}}
  end

  # ===================== sameSet tests =====================

  describe "sameSet" do
    test "returns true for two empty sets" do
      assert Mark.same_set([], [])
    end

    test "returns true for simple identical sets" do
      assert Mark.same_set([em(), strong()], [em(), strong()])
    end

    test "returns false for different sets" do
      refute Mark.same_set([em(), strong()], [em(), code()])
    end

    test "returns false when set size differs" do
      refute Mark.same_set([em(), strong()], [em(), strong(), code()])
    end

    test "recognizes identical links in set" do
      assert Mark.same_set([link("http://foo")], [link("http://foo")])
    end

    test "recognizes different links in set" do
      refute Mark.same_set([link("http://foo")], [link("http://bar")])
    end
  end

  # ===================== eq tests =====================

  describe "eq" do
    test "considers identical links to be the same" do
      assert Mark.eq(link("http://foo"), link("http://foo"))
    end

    test "considers different links to differ" do
      refute Mark.eq(link("http://foo"), link("http://bar"))
    end

    test "considers links with different titles to differ" do
      refute Mark.eq(link("http://foo", "A"), link("http://foo", "B"))
    end
  end

  # ===================== addToSet tests =====================

  describe "addToSet" do
    test "can add to the empty set" do
      assert Mark.same_set(Mark.add_to_set(em(), []), [em()])
    end

    test "is a no-op when the added thing is in set" do
      set = [em(), strong()]
      assert Mark.add_to_set(em(), set) == set
    end

    test "adds marks with lower rank before others" do
      result = Mark.add_to_set(em(), [strong()])
      assert Mark.same_set(result, [em(), strong()])
    end

    test "adds marks with higher rank after others" do
      result = Mark.add_to_set(strong(), [em()])
      assert Mark.same_set(result, [em(), strong()])
    end

    test "replaces different marks with new attributes" do
      # Same-type marks exclude each other by default (self-exclusion),
      # so link("bar") replaces link("foo")
      result = Mark.add_to_set(link("http://bar"), [em(), link("http://foo")])
      assert Mark.same_set(result, [em(), link("http://bar")])
    end

    test "does nothing when adding an existing link" do
      set = [em(), link("http://foo")]
      assert Mark.add_to_set(link("http://foo"), set) == set
    end

    test "puts code marks at the end" do
      result = Mark.add_to_set(code(), [em(), strong()])
      assert Mark.same_set(result, [em(), strong(), code()])
    end

    test "puts marks with middle rank in the middle" do
      result = Mark.add_to_set(strong(), [em(), code()])
      assert Mark.same_set(result, [em(), strong(), code()])
    end

    test "allows nonexclusive instances of marks with the same type" do
      # remark has excluded: [] meaning it doesn't exclude itself
      result = Mark.add_to_set(remark(2), [remark(1)])
      assert length(result) == 2
      assert Mark.same_set(result, [remark(1), remark(2)])
    end

    test "doesn't duplicate identical instances of nonexclusive marks" do
      set = [remark(1)]
      assert Mark.add_to_set(remark(1), set) == set
    end

    test "clears all others when adding a globally-excluding mark" do
      result = Mark.add_to_set(user(1), [em(), strong()])
      assert Mark.same_set(result, [user(1)])
    end

    test "does not allow adding another mark to a globally-excluding mark" do
      set = [user(1)]
      assert Mark.add_to_set(em(), set) == set
    end

    test "does overwrite a globally-excluding mark when adding another instance" do
      result = Mark.add_to_set(user(2), [user(1)])
      assert Mark.same_set(result, [user(2)])
    end

    test "doesn't add anything when another mark excludes the added mark" do
      # strong_custom excludes em_custom, so if strong_custom is already in set,
      # adding em_custom should be rejected because strong_custom.excludes(em_custom) is true
      # Wait - the logic is: other.type.excludes(this.type) => return set
      # So if strong_custom is in the set, and we add em_custom,
      # we check other(strong_custom).type.excludes(this(em_custom).type) => true => return set
      set = [strong_custom()]
      assert Mark.add_to_set(em_custom(), set) == set
    end

    test "removes excluded marks when adding a mark" do
      # em_custom is in the set, adding strong_custom which excludes em_custom
      # this.type.excludes(other.type) => strong_custom.excludes(em_custom) => true => skip other
      result = Mark.add_to_set(strong_custom(), [em_custom()])
      assert Mark.same_set(result, [strong_custom()])
    end
  end

  # ===================== removeFromSet tests =====================

  describe "removeFromSet" do
    test "is a no-op for the empty set" do
      assert Mark.remove_from_set(em(), []) == []
    end

    test "can remove the last mark from a set" do
      assert Mark.remove_from_set(em(), [em()]) == []
    end

    test "is a no-op when the mark isn't in the set" do
      set = [em(), strong()]
      assert Mark.remove_from_set(code(), set) == set
    end

    test "can remove a mark with attributes" do
      result = Mark.remove_from_set(link("http://foo"), [em(), link("http://foo")])
      assert Mark.same_set(result, [em()])
    end

    test "doesn't remove a mark when its attrs differ" do
      set = [em(), link("http://foo")]
      assert Mark.remove_from_set(link("http://bar"), set) == set
    end
  end
end
