defmodule ProsemirrorEx.Model.Utf16Test do
  use ExUnit.Case, async: true

  import ProsemirrorEx.TestHelpers

  alias ProsemirrorEx.Model.{Fragment, ResolvedPos, Utf16}
  alias ProsemirrorEx.Model.Node, as: PmNode

  describe "Utf16.length/1" do
    test "counts ASCII as 1 unit per char" do
      assert Utf16.length("") == 0
      assert Utf16.length("hello") == 5
    end

    test "counts BMP non-ASCII as 1 unit per codepoint" do
      assert Utf16.length("café") == 4
      assert Utf16.length("日本語") == 3
    end

    test "counts combining marks as separate UTF-16 code units" do
      # "e" + U+0301 combining acute accent = 1 grapheme, 2 UTF-16 units
      assert Utf16.length("e\u0301") == 2
    end

    test "counts CRLF as 2 UTF-16 code units" do
      assert Utf16.length("\r\n") == 2
      assert Utf16.length("a\r\nb") == 4
    end

    test "counts supplementary-plane emojis (surrogate pairs) as 2 UTF-16 units" do
      assert Utf16.length("😀") == 2
      assert Utf16.length("a😀b") == 4
      # ZWJ family emoji: 4 emojis (8) + 3 ZWJs (3) = 11 UTF-16 units
      assert Utf16.length("👨‍👩‍👧‍👦") == 11
    end
  end

  describe "Utf16.slice/3" do
    test "slices ASCII and handles nil/inverted bounds" do
      assert Utf16.slice("hello", 1, 4) == "ell"
      assert Utf16.slice("hello", 2) == "llo"
      assert Utf16.slice("hello", 4, 2) == ""
      assert Utf16.slice("hello", 3, 3) == ""
      assert Utf16.slice("hello", -2, 2) == "he"
      assert Utf16.slice("hello", 10, 12) == ""
    end

    test "slices across surrogate pairs, combining marks, and CRLF" do
      assert Utf16.slice("a😀b", 0, 1) == "a"
      assert Utf16.slice("a😀b", 1, 3) == "😀"
      assert Utf16.slice("a😀b", 3, 4) == "b"
      assert Utf16.slice("a😀b", 1) == "😀b"

      assert Utf16.slice("e\u0301x", 0, 1) == "e"
      assert Utf16.slice("e\u0301x", 1, 2) == "\u0301"
      assert Utf16.slice("e\u0301x", 2, 3) == "x"

      assert Utf16.slice("\r\nx", 0, 1) == "\r"
      assert Utf16.slice("\r\nx", 1, 2) == "\n"
      assert Utf16.slice("\r\nx", 2, 3) == "x"
    end

    test "handles mid-surrogate offsets safely without producing invalid UTF-8" do
      assert String.valid?(Utf16.slice("a😀b", 0, 2))
      assert Utf16.slice("a😀b", 0, 2) == "a"
      assert Utf16.slice("a😀b", 2, 4) == "b"
    end
  end

  describe "Utf16.common_prefix/2 and common_suffix/2" do
    test "common_prefix counts UTF-16 units" do
      assert Utf16.common_prefix("😀ab", "😀ac") == 3
      assert Utf16.common_prefix("ea", "e\u0301a") == 1
      assert Utf16.common_prefix("e\u0301a", "e\u0301b") == 2
      assert Utf16.common_prefix("\ra", "\r\nb") == 1
      assert Utf16.common_prefix("\r\na", "\r\nb") == 2
      assert Utf16.common_prefix("😀", "😁") == 0
    end

    test "common_suffix counts UTF-16 units" do
      assert Utf16.common_suffix("a😀", "b😀") == 2
      assert Utf16.common_suffix("ae\u0301", "ao\u0301") == 1
      assert Utf16.common_suffix("a\r\n", "b\r\n") == 2
      assert Utf16.common_suffix("a\n", "b\r\n") == 1
      assert Utf16.common_suffix("😀", "😁") == 0
      # Different leading UTF-8 bytes sharing trailing continuation byte 0xA9
      assert Utf16.common_suffix(<<0xC3, 0xA9>>, <<0xC4, 0xA9>>) == 0
    end
  end

  describe "Utf16.byte_offset_to_utf16/2" do
    test "converts UTF-8 byte offsets to UTF-16 code-unit offsets" do
      str = "a😀e\u0301\r\nb"
      assert Utf16.byte_offset_to_utf16(str, 0) == 0
      # "a" = 1 byte, 1 utf16 unit
      assert Utf16.byte_offset_to_utf16(str, 1) == 1
      # "a😀" = 5 bytes, 3 utf16 units
      assert Utf16.byte_offset_to_utf16(str, 5) == 3
      # "a😀e" = 6 bytes, 4 utf16 units
      assert Utf16.byte_offset_to_utf16(str, 6) == 4
      # "a😀e\u0301" = 8 bytes, 5 utf16 units
      assert Utf16.byte_offset_to_utf16(str, 8) == 5
      assert Utf16.byte_offset_to_utf16(str, 100) == Utf16.length(str)
      assert Utf16.byte_offset_to_utf16(str, -1) == 0
    end
  end

  describe "model tree UTF-16 integration" do
    test "Node, Fragment, Diff, ResolvedPos, and TestHelpers use UTF-16 positions" do
      {d, tags} = doc([p(["a😀<a>e\u0301<b>\r\nc"])])
      # "a" (1) + "😀" (2) = 3 inside p => 1 + 3 = 4
      assert tags["a"] == 4
      # "e\u0301" (2) => 4 + 2 = 6
      assert tags["b"] == 6

      p_node = PmNode.child(d, 0)
      # "a"(1) + "😀"(2) + "e\u0301"(2) + "\r\n"(2) + "c"(1) = 8
      assert PmNode.node_size(PmNode.first_child(p_node)) == 8
      assert PmNode.node_size(p_node) == 10

      # ResolvedPos around emoji
      r = PmNode.resolve(d, 4)
      assert ResolvedPos.text_offset(r) == 3
      assert ResolvedPos.node_before(r).text == "a😀"
      assert ResolvedPos.node_after(r).text == "e\u0301\r\nc"

      # Fragment.cut and Node.text_between
      cut_p = PmNode.cut(p_node, 1, 5)
      assert PmNode.text_content(cut_p) == "😀e\u0301"
      assert PmNode.text_between(d, 2, 6) == "😀e\u0301"

      # Diff.find_diff_start and find_diff_end
      {d2, _} = doc([p(["a😀x\u0301\r\nc"])])
      # Diverges after "a😀" (pos 1 + 3 = 4)
      assert Fragment.find_diff_start(d.content, d2.content) == 4
      # Suffix "\u0301\r\nc" = 4 UTF-16 units; doc end is 9 (1 + 8), 9 - 4 = 5
      assert Fragment.find_diff_end(d.content, d2.content) == %{a: 5, b: 5}
    end
  end
end
