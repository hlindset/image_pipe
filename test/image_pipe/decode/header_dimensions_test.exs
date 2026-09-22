defmodule ImagePipe.Decode.HeaderDimensionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Decode.HeaderDimensions
  alias Vix.Vips.Image, as: VipsImage

  test "reads PNG, lossy/lossless/extended WebP, and baseline/progressive JPEG headers" do
    for suffix <- [
          ".png",
          ".webp",
          ".webp[lossless]",
          ".jpg",
          ".jpg[interlace]"
        ] do
      {:ok, body} = VipsImage.write_to_buffer(Image.new!(123, 47, color: :red), suffix)
      assert HeaderDimensions.read(peek(body)) == {:ok, {123, 47}}, suffix
    end

    body = Image.new!(123, 47, color: [10, 20, 30, 128]) |> Image.write!(:memory, suffix: ".webp")
    assert <<"RIFF", _::32, "WEBPVP8X", _::binary>> = body
    assert HeaderDimensions.read(peek(body)) == {:ok, {123, 47}}
  end

  test "incomplete dimension headers and zero dimensions are unknown" do
    for header <- [png(123, 47), jpeg(123, 47), webp("VP8X", vp8x(123, 47))] do
      for length <- 0..(byte_size(header) - 1) do
        assert HeaderDimensions.read(binary_part(header, 0, length)) == :unknown
      end
    end

    for header <- [png(0, 47), png(123, 0), jpeg(0, 47), jpeg(123, 0)] do
      assert HeaderDimensions.read(header) == :unknown
    end
  end

  test "malformed PNG IHDR fields and CRC fall back" do
    for header <- [
          png(0x80000000, 47),
          png(123, 47, <<3, 2, 0, 0, 0>>),
          png(123, 47, <<8, 2, 1, 0, 0>>),
          png(123, 47, <<8, 2, 0, 1, 0>>),
          png(123, 47, <<8, 2, 0, 0, 2>>)
        ] do
      assert HeaderDimensions.read(header) == :unknown
    end

    <<prefix::binary-size(32), last>> = png(123, 47)
    assert HeaderDimensions.read(<<prefix::binary, Bitwise.bxor(last, 1)>>) == :unknown
  end

  test "JPEG skips complete segments and marker fill bytes without scanning their payloads" do
    <<0xFF, 0xD8, sof::binary>> = jpeg(123, 47)
    fake_sof = jpeg(60_000, 60_000)
    app = segment(0xE1, fake_sof)

    assert HeaderDimensions.read(<<0xFF, 0xD8, app::binary, 0xFF, sof::binary>>) ==
             {:ok, {123, 47}}

    for prefix <- [
          <<0xFF, 0xE1, 0::16>>,
          <<0xFF, 0xE1, 1::16>>,
          <<0xFF, 0xE1, 65_535::16>>,
          <<0xFF, 0xDA>>,
          <<0xFF, 0xD9>>,
          <<0xFF, 0x00>>,
          <<0xFF, 0xD8>>,
          <<0xFF, 0xC8>>,
          <<0>>
        ] do
      assert HeaderDimensions.read(<<0xFF, 0xD8, prefix::binary, sof::binary>>) == :unknown
    end

    assert HeaderDimensions.read(<<0xFF, 0xD8, 0xFF, 0xC0, 8::16, 8, 47::16, 123::16, 3>>) ==
             :unknown
  end

  test "a JPEG frame beyond the peek remains unknown" do
    <<0xFF, 0xD8, sof::binary>> = jpeg(123, 47)
    space = 32 * 1024 - 2 - 4 - byte_size(sof)
    app = segment(0xE1, :binary.copy(<<0>>, space))

    assert HeaderDimensions.read(peek(<<0xFF, 0xD8, app::binary, sof::binary>>)) ==
             {:ok, {123, 47}}

    for length <- [space + 1, 32 * 1024] do
      app = segment(0xE1, :binary.copy(<<0>>, length))
      assert HeaderDimensions.read(peek(<<0xFF, 0xD8, app::binary, sof::binary>>)) == :unknown
    end

    assert HeaderDimensions.read(<<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 32 * 1024 - 2)) ==
             :unknown
  end

  test "WebP validates chunk bounds, signatures, versions, and reserved fields" do
    for header <- [
          webp("VP8X", <<1, 0::24, 122::little-24, 46::little-24>>),
          webp("VP8X", <<0, 1::24, 122::little-24, 46::little-24>>),
          webp("VP8X", vp8x(123, 47) <> <<0>>),
          webp("VP8X", vp8x(0x1000000, 0x1000000)),
          webp("VP8L", <<0x2F, 0xE0000000::little-32>>),
          webp("VP8L", <<0x00, 0::32>>),
          webp("VP8 ", <<0x11, 0, 0, 0x9D, 0x01, 0x2A, 123::little-16, 47::little-16>>),
          webp("VP8 ", <<0x10, 0, 0, 0, 0, 0, 123::little-16, 47::little-16>>),
          webp("VP8 ", <<0x10, 0, 0, 0x9D, 0x01, 0x2A, 0::16, 47::little-16>>),
          <<"RIFF", 12::little-32, "WEBPVP8X", 10::little-32, vp8x(123, 47)::binary>>,
          <<"RIFF", 22::little-32, "WEBPVP8L", 4::little-32, 0x2F, 0::32>>
        ] do
      assert HeaderDimensions.read(header) == :unknown
    end
  end

  property "complete headers preserve dimensions under arbitrary suffixes" do
    check all width <- integer(1..16_383),
              height <- integer(1..16_383),
              suffix <- binary() do
      packed = Bitwise.bor(width - 1, Bitwise.bsl(height - 1, 14))

      for header <- [
            png(width, height),
            jpeg(width, height),
            webp("VP8X", vp8x(width, height)),
            webp("VP8L", <<0x2F, packed::little-32>>),
            webp("VP8 ", <<0x10, 0, 0, 0x9D, 0x01, 0x2A, width::little-16, height::little-16>>)
          ] do
        assert HeaderDimensions.read(header <> suffix) == {:ok, {width, height}}
      end
    end
  end

  property "arbitrary and signature-prefixed input never raises" do
    check all data <- binary(max_length: 32 * 1024),
              prefix <-
                member_of([
                  <<>>,
                  <<0xFF, 0xD8>>,
                  <<137, "PNG\r\n", 26, 10, 13::32, "IHDR">>,
                  <<"RIFF", 32_768::little-32, "WEBPVP8X", 10::little-32>>,
                  <<"RIFF", 32_768::little-32, "WEBPVP8L", 100::little-32, 0x2F>>,
                  <<"RIFF", 32_768::little-32, "WEBPVP8 ", 100::little-32>>
                ]) do
      case HeaderDimensions.read(peek(prefix <> data)) do
        :unknown -> :ok
        {:ok, {width, height}} -> assert width > 0 and height > 0
      end
    end
  end

  property "JPEG segment lengths bound marker traversal" do
    check all payload <- binary(max_length: 1000),
              marker <- integer(0xE0..0xEF),
              width <- integer(1..65_535),
              height <- integer(1..65_535) do
      <<0xFF, 0xD8, sof::binary>> = jpeg(width, height)
      app = segment(marker, payload)

      assert HeaderDimensions.read(<<0xFF, 0xD8, app::binary, sof::binary>>) ==
               {:ok, {width, height}}
    end
  end

  property "encoded image dimensions agree with libvips" do
    check all width <- integer(1..128),
              height <- integer(1..128),
              suffix <- member_of([".png", ".jpg", ".webp"]),
              max_runs: 20 do
      body = Image.new!(width, height, color: :red) |> Image.write!(:memory, suffix: suffix)
      image = Image.from_binary!(body)
      assert HeaderDimensions.read(peek(body)) == {:ok, {Image.width(image), Image.height(image)}}
    end
  end

  defp png(width, height, fields \\ <<8, 2, 0, 0, 0>>) do
    chunk = <<"IHDR", width::32, height::32, fields::binary>>
    <<137, "PNG\r\n", 26, 10, 13::32, chunk::binary, :erlang.crc32(chunk)::32>>
  end

  defp jpeg(width, height),
    do: <<0xFF, 0xD8, segment(0xC0, <<8, height::16, width::16, 1, 1, 0x11, 0>>)::binary>>

  defp segment(marker, data), do: <<0xFF, marker, byte_size(data) + 2::16, data::binary>>

  defp vp8x(width, height), do: <<0::32, width - 1::little-24, height - 1::little-24>>

  defp webp(chunk, data) do
    padding = :binary.copy(<<0>>, rem(byte_size(data), 2))
    size = 12 + byte_size(data) + byte_size(padding)

    <<"RIFF", size::little-32, "WEBP", chunk::binary, byte_size(data)::little-32, data::binary,
      padding::binary>>
  end

  defp peek(body), do: binary_part(body, 0, min(byte_size(body), 32 * 1024))
end
