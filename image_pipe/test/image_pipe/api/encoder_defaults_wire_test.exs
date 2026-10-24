defmodule ImagePipe.API.EncoderDefaultsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Operation

  # The default luminance DC table from Annex K of the JPEG standard, as the
  # 16 code-length counts a DHT segment starts with.
  @standard_dc_luminance_counts <<0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0>>

  setup_all do
    {:ok, photo} = Image.thumbnail("priv/static/images/dog.jpg", 96)
    %{photo: Image.write!(photo, :memory, suffix: ".jpg")}
  end

  test "a JPEG uses Huffman tables computed for the image", %{photo: photo} do
    response = response("format=jpeg", photo)
    assert response.status == 200

    counts = dc_luminance_counts(response.resp_body)
    assert byte_size(counts) == 16
    refute counts == @standard_dc_luminance_counts
  end

  test "a PNG is deflated at level 3 with the Paeth row filter", %{photo: photo} do
    response = response("format=png", photo)
    assert response.status == 200

    {level, filters} = png_deflate(response.resp_body)
    assert level == 1
    assert Enum.all?(filters, &(&1 == 4))
  end

  test "a PNG keeps the row filter a request sets", %{photo: photo} do
    response = response("format=png/png-options=filter:none", photo)
    assert response.status == 200

    {level, filters} = png_deflate(response.resp_body)
    assert level == 1
    assert Enum.all?(filters, &(&1 == 0))
  end

  test "a palette PNG is deflated at level 6 without row filters", %{photo: photo} do
    response = response("format=png/png-options=palette", photo)
    assert response.status == 200

    {level, filters} = png_deflate(response.resp_body)
    assert level == 2
    assert Enum.all?(filters, &(&1 == 0))
  end

  test "a grayscale PNG below 8 bits has no row filters" do
    gradient =
      64
      |> Operation.xyz!(64)
      |> Operation.extract_band!(0)
      |> Operation.linear!([4.0], [0.0])
      |> Operation.cast!(:VIPS_FORMAT_UCHAR)

    body = Image.write!(gradient, :memory, suffix: ".png")

    response = response("format=png/png-options=bitdepth:4", body)
    assert response.status == 200

    {level, filters} = png_deflate(response.resp_body)
    assert level == 1
    assert Enum.all?(filters, &(&1 == 0))
  end

  # The code-length counts of the first DC table with id 0 in the first DHT
  # segment that defines one.
  defp dc_luminance_counts(<<0xFF, 0xC4, length::16, rest::binary>>) do
    segment_length = length - 2
    <<segment::binary-size(^segment_length), rest::binary>> = rest

    case dc_table(segment) do
      nil -> dc_luminance_counts(rest)
      counts -> counts
    end
  end

  defp dc_luminance_counts(<<0xFF, 0xD8, rest::binary>>), do: dc_luminance_counts(rest)

  defp dc_luminance_counts(<<0xFF, _marker, length::16, rest::binary>>),
    do: dc_luminance_counts(binary_part(rest, length - 2, byte_size(rest) - length + 2))

  defp dc_table(<<0x00, counts::binary-size(16), _rest::binary>>), do: counts

  defp dc_table(<<_class_id, counts::binary-size(16), rest::binary>>) do
    symbols = counts |> :binary.bin_to_list() |> Enum.sum()
    <<_symbols::binary-size(^symbols), rest::binary>> = rest
    dc_table(rest)
  end

  defp dc_table(<<>>), do: nil

  # The zlib FLEVEL of the image data (0 for levels 0-1, 1 for 2-5, 2 for 6,
  # 3 for 7-9) and the filter type that starts each row.
  defp png_deflate(<<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>>) do
    {header, data} = png_chunks(chunks, nil, [])
    <<width::32, _height::32, depth, color_type, _rest::binary>> = header
    <<_cmf, level::2, _check::6, _rest::binary>> = data
    row_bytes = div(width * channels(color_type) * depth + 7, 8)
    {level, row_filters(:zlib.uncompress(data), row_bytes)}
  end

  defp png_chunks(<<length::32, type::binary-4, rest::binary>>, header, idat) do
    <<chunk::binary-size(^length), _crc::32, rest::binary>> = rest

    case type do
      "IHDR" -> png_chunks(rest, chunk, idat)
      "IDAT" -> png_chunks(rest, header, [idat, chunk])
      "IEND" -> {header, IO.iodata_to_binary(idat)}
      _other -> png_chunks(rest, header, idat)
    end
  end

  defp channels(0), do: 1
  defp channels(2), do: 3
  defp channels(3), do: 1
  defp channels(4), do: 2
  defp channels(6), do: 4

  defp row_filters(<<>>, _row_bytes), do: []

  defp row_filters(<<filter, rest::binary>>, row_bytes) do
    <<_row::binary-size(^row_bytes), rest::binary>> = rest
    [filter | row_filters(rest, row_bytes)]
  end

  defp response(options, body) do
    origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        allow_unsigned: true,
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    conn(:get, "/#{options}/src/image") |> ImagePipe.Plug.call(config)
  end
end
