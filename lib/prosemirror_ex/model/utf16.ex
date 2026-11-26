defmodule ProsemirrorEx.Model.Utf16 do
  @moduledoc """
  UTF-16 code-unit length, slicing, prefix/suffix comparison, and UTF-8 byte
  offset conversion helpers.

  ProseMirror positions inside text nodes count UTF-16 code units (matching
  JavaScript's `String.prototype.length` and `.slice`), whereas Elixir strings
  are UTF-8 binaries. BMP codepoints (`<= 0xFFFF`) count as 1 UTF-16 unit and
  supplementary-plane codepoints (`> 0xFFFF`, such as emojis) count as 2.
  """

  import Bitwise

  @doc """
  Return the number of UTF-16 code units in `str`.
  """
  @spec length(binary()) :: non_neg_integer()
  def length(str) when is_binary(str), do: do_length(str, 0)

  defp do_length(<<>>, acc), do: acc

  defp do_length(<<c::utf8, rest::binary>>, acc) when c <= 0xFFFF,
    do: do_length(rest, acc + 1)

  defp do_length(<<_c::utf8, rest::binary>>, acc), do: do_length(rest, acc + 2)
  defp do_length(<<_byte, rest::binary>>, acc), do: do_length(rest, acc + 1)

  @doc """
  Slice `str` between UTF-16 code-unit offsets `from` (inclusive) and `to`
  (exclusive, or end of string when `nil`).

  Returns `""` when `to <= from` or `from` is past the end of `str`.
  """
  @spec slice(binary(), integer(), integer() | nil) :: binary()
  def slice(str, from, to \\ nil)

  def slice(str, from, nil) when is_binary(str) and is_integer(from) do
    from = max(from, 0)

    if from == 0 do
      str
    else
      total = byte_size(str)
      start_byte = find_start_byte(str, total, from, 0)
      binary_part(str, start_byte, total - start_byte)
    end
  end

  def slice(str, from, to) when is_binary(str) and is_integer(from) and is_integer(to) do
    from = max(from, 0)

    if to <= from do
      ""
    else
      total = byte_size(str)
      {start_byte, u16_pos, rest} = find_start(str, total, from, 0)

      if rest == <<>> do
        ""
      else
        end_byte = find_end_byte(rest, total, to, u16_pos)
        binary_part(str, start_byte, max(0, end_byte - start_byte))
      end
    end
  end

  defp find_start_byte(str, total, target_u16, u16_pos) do
    {byte_pos, _u16, _rest} = find_start(str, total, target_u16, u16_pos)
    byte_pos
  end

  defp find_start(rest, total, target_u16, u16_pos) when u16_pos >= target_u16 do
    {total - byte_size(rest), u16_pos, rest}
  end

  defp find_start(<<>>, total, _target_u16, u16_pos), do: {total, u16_pos, <<>>}

  defp find_start(<<c::utf8, rest::binary>>, total, target_u16, u16_pos) do
    units = if c > 0xFFFF, do: 2, else: 1
    find_start(rest, total, target_u16, u16_pos + units)
  end

  defp find_start(<<_byte, rest::binary>>, total, target_u16, u16_pos) do
    find_start(rest, total, target_u16, u16_pos + 1)
  end

  defp find_end_byte(<<>>, total, _target_u16, _u16_pos), do: total

  defp find_end_byte(rest, total, target_u16, u16_pos) when u16_pos >= target_u16 do
    total - byte_size(rest)
  end

  defp find_end_byte(<<c::utf8, rest::binary>> = bin, total, target_u16, u16_pos) do
    units = if c > 0xFFFF, do: 2, else: 1

    if u16_pos + units > target_u16 do
      total - byte_size(bin)
    else
      find_end_byte(rest, total, target_u16, u16_pos + units)
    end
  end

  defp find_end_byte(<<_byte, rest::binary>>, total, target_u16, u16_pos) do
    find_end_byte(rest, total, target_u16, u16_pos + 1)
  end

  @doc """
  Return the number of matching UTF-16 code units at the start of `a` and `b`.
  """
  @spec common_prefix(binary(), binary()) :: non_neg_integer()
  def common_prefix(a, b) when is_binary(a) and is_binary(b) do
    do_common_prefix(a, b, 0)
  end

  defp do_common_prefix(<<c::utf8, ra::binary>>, <<c::utf8, rb::binary>>, acc) do
    units = if c > 0xFFFF, do: 2, else: 1
    do_common_prefix(ra, rb, acc + units)
  end

  defp do_common_prefix(_, _, acc), do: acc

  @doc """
  Return the number of matching UTF-16 code units at the end of `a` and `b`.
  """
  @spec common_suffix(binary(), binary()) :: non_neg_integer()
  def common_suffix(a, b) when is_binary(a) and is_binary(b) do
    do_common_suffix(a, byte_size(a), b, byte_size(b), 0)
  end

  defp do_common_suffix(_a, 0, _b, _pos_b, acc), do: acc
  defp do_common_suffix(_a, _pos_a, _b, 0, acc), do: acc

  defp do_common_suffix(a, pos_a, b, pos_b, acc) do
    len_a = prev_char_bytes(a, pos_a)
    len_b = prev_char_bytes(b, pos_b)

    if len_a == len_b and
         :binary.part(a, pos_a - len_a, len_a) == :binary.part(b, pos_b - len_b, len_b) do
      units = if len_a == 4, do: 2, else: 1
      do_common_suffix(a, pos_a - len_a, b, pos_b - len_b, acc + units)
    else
      acc
    end
  end

  defp prev_char_bytes(bin, pos) do
    b = :binary.at(bin, pos - 1)

    if b < 0x80 do
      1
    else
      find_lead_byte(bin, pos - 1, 1)
    end
  end

  defp find_lead_byte(_bin, 0, len), do: len

  defp find_lead_byte(bin, idx, len) when len < 4 do
    if (:binary.at(bin, idx) &&& 0xC0) == 0x80 do
      find_lead_byte(bin, idx - 1, len + 1)
    else
      len
    end
  end

  defp find_lead_byte(_bin, _idx, len), do: len

  @doc """
  Convert a UTF-8 byte offset in `str` to a UTF-16 code-unit offset.
  """
  @spec byte_offset_to_utf16(binary(), integer()) :: non_neg_integer()
  def byte_offset_to_utf16(str, byte_offset)
      when is_binary(str) and is_integer(byte_offset) do
    if byte_offset <= 0 do
      0
    else
      do_byte_offset_to_utf16(str, min(byte_offset, byte_size(str)), 0)
    end
  end

  defp do_byte_offset_to_utf16(_str, rem, acc) when rem <= 0, do: acc
  defp do_byte_offset_to_utf16(<<>>, _rem, acc), do: acc

  defp do_byte_offset_to_utf16(<<c::utf8, rest::binary>>, rem, acc) do
    char_bytes = utf8_byte_size(c)

    if char_bytes > rem do
      acc
    else
      units = if c > 0xFFFF, do: 2, else: 1
      do_byte_offset_to_utf16(rest, rem - char_bytes, acc + units)
    end
  end

  defp do_byte_offset_to_utf16(<<_byte, rest::binary>>, rem, acc) do
    do_byte_offset_to_utf16(rest, rem - 1, acc + 1)
  end

  defp utf8_byte_size(c) when c < 0x80, do: 1
  defp utf8_byte_size(c) when c < 0x800, do: 2
  defp utf8_byte_size(c) when c < 0x10000, do: 3
  defp utf8_byte_size(_c), do: 4
end
