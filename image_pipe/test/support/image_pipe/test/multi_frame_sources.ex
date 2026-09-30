defmodule ImagePipe.Test.MultiFrameSources do
  @moduledoc false
  # Real multi-frame and multi-page sources, encoded by libvips at test time.
  # Each frame has its own solid colour, so a pixel probe on the output proves
  # which frame was decoded. `frame_color/1` is frame 0's expected colour.

  import Bitwise

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage

  @width 64
  @height 48
  @colors [[220, 30, 30], [30, 200, 40], [40, 60, 210], [230, 200, 20]]

  def frame_size, do: {@width, @height}
  def frame_color(index), do: Enum.at(@colors, index)

  @doc "An `n`-frame source of `family` (`:webp`, `:tiff`, `:avif`, `:jxl`, `:gif`)."
  def encode(family, frames) do
    {:ok, body} = VipsImage.write_to_buffer(strip(frames), saver(family))
    body
  end

  defp saver(:webp), do: ".webp[lossless=true]"
  defp saver(:tiff), do: ".tif"
  defp saver(:avif), do: ".avif[compression=av1]"
  defp saver(:jxl), do: ".jxl[lossless=true]"
  defp saver(:gif), do: ".gif"

  defp strip(frames) do
    images = for index <- 0..(frames - 1), do: solid(frame_color(index))
    {:ok, strip} = Image.join(images, across: 1)

    {:ok, strip} =
      VipsImage.mutate(strip, fn image ->
        :ok = MutableImage.set(image, "page-height", :gint, @height)
        :ok = MutableImage.set(image, "delay", :VipsArrayInt, List.duplicate(100, frames))
        :ok = MutableImage.set(image, "loop", :gint, 0)
      end)

    strip
  end

  defp solid(color), do: Image.new!(@width, @height, color: color)

  @doc """
  An AVIF image collection of `frames` frames whose primary image is frame
  `primary`, made by pointing its `pitm` box at that frame's item.
  """
  def avif_with_primary(frames, primary) do
    body = encode(:avif, frames)
    [{pitm, _length}] = :binary.matches(body, "pitm")

    images =
      for {infe, _length} <- :binary.matches(body, "infe"),
          <<_::binary-size(^infe + 8), item::16, _protection::16, "av01", _::binary>> <- [body],
          do: item

    item = Enum.at(images, primary)
    split = pitm + 8
    <<before::binary-size(^split), _primary::16, rest::binary>> = body
    <<before::binary, item::16, rest::binary>>
  end

  @doc """
  An uncompressed RGB TIFF with one page per `{width, height, color}`. libvips
  writes only equal-sized pages, so this assembles the IFD chain itself.
  """
  def tiff_pages(pages) do
    entry_count = 10
    ifd_size = 2 + entry_count * 12 + 4

    {blocks, _offset} =
      pages
      |> Enum.with_index()
      |> Enum.map_reduce(8, fn {{width, height, [r, g, b]}, index}, offset ->
        bits_offset = offset + ifd_size
        pixels_offset = bits_offset + 6
        pixels = :binary.copy(<<r, g, b>>, width * height)
        next = if index == length(pages) - 1, do: 0, else: pixels_offset + byte_size(pixels)

        entries = [
          {256, 4, 1, <<width::little-32>>},
          {257, 4, 1, <<height::little-32>>},
          {258, 3, 3, <<bits_offset::little-32>>},
          {259, 3, 1, <<1::little-16, 0::16>>},
          {262, 3, 1, <<2::little-16, 0::16>>},
          {273, 4, 1, <<pixels_offset::little-32>>},
          {277, 3, 1, <<3::little-16, 0::16>>},
          {278, 4, 1, <<height::little-32>>},
          {279, 4, 1, <<byte_size(pixels)::little-32>>},
          {284, 3, 1, <<1::little-16, 0::16>>}
        ]

        ifd =
          for {tag, type, count, value} <- entries,
              into: <<entry_count::little-16>>,
              do: <<tag::little-16, type::little-16, count::little-32, value::binary>>

        block =
          ifd <> <<next::little-32>> <> <<8::little-16, 8::little-16, 8::little-16>> <> pixels

        {block, offset + byte_size(block)}
      end)

    <<"II", 42::little-16, 8::little-32>> <> IO.iodata_to_binary(blocks)
  end

  @doc """
  A two-frame APNG  @doc \"""
  A two-frame APNG whose default image is frame 0's colour and whose second
  frame is frame 1's colour. libvips has no APNG saver, so the animation chunks
  are assembled around a PNG it encodes.
  """
  def apng do
    [{"IHDR", header} | _chunks] = first = png_chunks(solid(frame_color(0)))
    first_data = idat(first)
    second_data = idat(png_chunks(solid(frame_color(1))))

    <<137, "PNG\r\n", 26, 10>> <>
      png_chunk("IHDR", header) <>
      png_chunk("acTL", <<2::32, 0::32>>) <>
      png_chunk("fcTL", frame_control(0)) <>
      png_chunk("IDAT", first_data) <>
      png_chunk("fcTL", frame_control(1)) <>
      png_chunk("fdAT", <<2::32, second_data::binary>>) <>
      png_chunk("IEND", "")
  end

  defp png_chunks(image) do
    <<_signature::binary-size(8), chunks::binary>> = Image.write!(image, :memory, suffix: ".png")
    read_png_chunks(chunks)
  end

  defp read_png_chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), _crc::32, rest::binary>>
       ),
       do: [{type, data} | read_png_chunks(rest)]

  defp read_png_chunks(<<>>), do: []

  defp idat(chunks), do: for({"IDAT", data} <- chunks, into: <<>>, do: data)

  defp frame_control(sequence),
    do: <<sequence::32, @width::32, @height::32, 0::32, 0::32, 1::16, 10::16, 0, 0>>

  defp png_chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  @doc """
  An animated WebP of `frames` 1×1 frames that all reuse one lossless bitstream:
  the smallest per-frame container cost, as a hostile source would build it.
  """
  def repeated_frame_webp(frames) do
    {:ok, one} =
      VipsImage.write_to_buffer(Image.new!(1, 1, color: [1, 2, 3]), ".webp[lossless=true]")

    <<"RIFF", _size::little-32, "WEBP", chunks::binary>> = one
    bitstream = riff_chunk_bytes(chunks, "VP8L")

    frame =
      riff_chunk(
        "ANMF",
        <<0::24, 0::24, 0::little-24, 0::little-24, 40::little-24, 0>> <> bitstream
      )

    riff_webp(
      riff_chunk("VP8X", <<0x02, 0::24, 0::little-24, 0::little-24>>) <>
        riff_chunk("ANIM", <<0::32, 0::little-16>>) <> :binary.copy(frame, frames)
    )
  end

  @doc """
  An animated GIF of `frames` 1×1 frames, each a graphic control extension, an
  image descriptor, and a minimal LZW stream: 23 bytes per frame.
  """
  def repeated_frame_gif(frames) do
    header = "GIF89a" <> <<1::little-16, 1::little-16, 0x80, 0, 0, 0, 0, 0, 255, 255, 255>>
    loop = <<0x21, 0xFF, 0x0B, "NETSCAPE2.0", 3, 1, 0::little-16, 0>>
    control = <<0x21, 0xF9, 4, 0, 10::little-16, 0, 0>>
    descriptor = <<0x2C, 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0>>
    pixels = <<2, 2, 0x4C, 0x01, 0>>

    header <> loop <> :binary.copy(control <> descriptor <> pixels, frames) <> <<0x3B>>
  end

  def riff_webp(chunks), do: <<"RIFF", byte_size(chunks) + 4::little-32, "WEBP", chunks::binary>>

  def riff_chunk(id, data) do
    pad = band(byte_size(data), 1)
    <<id::binary, byte_size(data)::little-32, data::binary, 0::size(pad * 8)>>
  end

  # The whole chunk (id, size, payload, padding) with the given id.
  defp riff_chunk_bytes(<<id::binary-size(4), size::little-32, rest::binary>>, wanted) do
    padded = size + band(size, 1)
    <<payload::binary-size(^padded), tail::binary>> = rest

    if id == wanted,
      do: <<id::binary, size::little-32, payload::binary>>,
      else: riff_chunk_bytes(tail, wanted)
  end
end
