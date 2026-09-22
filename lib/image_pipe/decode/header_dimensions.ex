defmodule ImagePipe.Decode.HeaderDimensions do
  @moduledoc false

  import Bitwise

  @sof_markers [0xC0, 0xC1, 0xC2, 0xC3, 0xC9, 0xCA, 0xCB]
  @skip_markers [0xC4, 0xCC, 0xDB, 0xDD, 0xFE] ++ Enum.to_list(0xE0..0xEF)

  # Reads only the bounded prefix supplied by Decode. This is an early-rejection
  # hint, not validation of the image body; libvips still checks stored dimensions.
  @spec read(binary()) :: {:ok, {pos_integer(), pos_integer()}} | :unknown
  def read(<<137, "PNG\r\n", 26, 10, 13::32, chunk::binary-size(17), crc::32, _::binary>>) do
    case :erlang.crc32(chunk) do
      ^crc -> png_dimensions(chunk)
      _ -> :unknown
    end
  end

  def read(<<0xFF, 0xD8, rest::binary>>), do: jpeg_marker(rest)

  def read(
        <<"RIFF", size::little-32, "WEBP", chunk::binary-size(4), length::little-32,
          data::binary>>
      )
      when rem(size, 2) == 0 and size <= 0xFFFFFFF6 and
             size >= 12 + length + rem(length, 2) do
    webp_dimensions(chunk, length, data)
  end

  def read(_peek), do: :unknown

  defp png_dimensions(<<"IHDR", width::32, height::32, depth, color, 0, 0, interlace>>)
       when width in 1..0x7FFFFFFF and height in 1..0x7FFFFFFF and interlace in [0, 1] and
              ((color == 0 and depth in [1, 2, 4, 8, 16]) or
                 (color == 3 and depth in [1, 2, 4, 8]) or
                 (color in [2, 4, 6] and depth in [8, 16])),
       do: {:ok, {width, height}}

  defp png_dimensions(_chunk), do: :unknown

  # Consume declared segment lengths, never search their payload for marker bytes.
  # SOS, EOI, hierarchical/unknown markers and incomplete segments end the probe.
  defp jpeg_marker(<<0xFF, rest::binary>>), do: jpeg_marker_code(rest)
  defp jpeg_marker(_rest), do: :unknown

  defp jpeg_marker_code(<<0xFF, rest::binary>>), do: jpeg_marker_code(rest)
  defp jpeg_marker_code(<<0x01, rest::binary>>), do: jpeg_marker(rest)

  defp jpeg_marker_code(<<marker, length::16, rest::binary>>)
       when length >= 2 and byte_size(rest) >= length - 2 do
    <<segment::binary-size(^length - 2), tail::binary>> = rest
    jpeg_segment(marker, segment, tail)
  end

  defp jpeg_marker_code(_rest), do: :unknown

  defp jpeg_segment(
         marker,
         <<precision, height::16, width::16, count, components::binary>>,
         _tail
       )
       when marker in @sof_markers and width > 0 and height > 0 and count > 0 and
              byte_size(components) == count * 3 do
    jpeg_dimensions(marker, precision, {width, height})
  end

  defp jpeg_segment(marker, _segment, tail) when marker in @skip_markers,
    do: jpeg_marker(tail)

  defp jpeg_segment(_marker, _segment, _tail), do: :unknown

  defp jpeg_dimensions(0xC0, 8, dimensions), do: {:ok, dimensions}

  defp jpeg_dimensions(marker, precision, dimensions)
       when marker in [0xC1, 0xC2, 0xC9, 0xCA] and precision in [8, 12],
       do: {:ok, dimensions}

  defp jpeg_dimensions(marker, precision, dimensions)
       when marker in [0xC3, 0xCB] and precision in 2..16,
       do: {:ok, dimensions}

  defp jpeg_dimensions(_marker, _precision, _dimensions), do: :unknown

  # RIFF sizes include padding. Only the first dimension-bearing chunk is read;
  # unfamiliar layouts fall back to the loader rather than a container traversal.
  # https://developers.google.com/speed/webp/docs/riff_container
  defp webp_dimensions("VP8X", 10, <<flags, 0::24, w::little-24, h::little-24, _::binary>>)
       when band(flags, 0xC1) == 0 and (w + 1) * (h + 1) <= 0xFFFFFFFF,
       do: {:ok, {w + 1, h + 1}}

  defp webp_dimensions("VP8L", length, <<0x2F, bits::little-32, _::binary>>)
       when length >= 5 and bsr(bits, 29) == 0,
       do: {:ok, {band(bits, 0x3FFF) + 1, band(bsr(bits, 14), 0x3FFF) + 1}}

  defp webp_dimensions(
         "VP8 ",
         length,
         <<tag::little-24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>
       )
       when length >= 10 and band(tag, 0x1F) in [0x10, 0x12, 0x14, 0x16] and
              band(w, 0x3FFF) > 0 and band(h, 0x3FFF) > 0,
       do: {:ok, {band(w, 0x3FFF), band(h, 0x3FFF)}}

  defp webp_dimensions(_chunk, _length, _data), do: :unknown
end
