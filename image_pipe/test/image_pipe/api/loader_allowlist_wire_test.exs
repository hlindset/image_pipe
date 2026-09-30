defmodule ImagePipe.API.LoaderAllowlistWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Foreign
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:loader_allowlist_wire]
  @moduletag :tmp_dir

  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>)

  setup do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        @prefix ++ [:source, :fetch_decode, :stop],
        fn _event, _measurements, metadata, pid -> send(pid, {:fetch_decode, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "sources the detector doesn't recognise are rejected before any libvips call" do
    unrecognised = [
      {"gzip-compressed SVG", :zlib.gzip(@svg)},
      {"SVG with its root past the peek",
       "<!--" <> String.duplicate("x", 40_000) <> "-->" <> @svg},
      {"PPM", "P6\n2 2\n255\n" <> :binary.copy(<<1, 2, 3>>, 4)},
      {"PDF", "%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n"},
      {"arbitrary bytes", :binary.copy(<<0x13, 0x37>>, 64)}
    ]

    for {name, body} <- unrecognised do
      flush_mailbox()
      response = request("format=png", mount(body))

      assert response.status == 415, "#{name}: #{response.status}"
      refute_received {:loader_open, _}, name

      assert_received {:fetch_decode,
                       %{
                         result: :processing_error,
                         error: :unsupported_source_format,
                         detected_source_format: :unknown
                       }}
    end
  end

  test "an AVIF image sequence is rejected as its own family before any libvips call" do
    body = <<0, 0, 0, 0x1C, "ftypavis", 0::32, "avismif1miaf", 0::size(64 * 8)>>
    response = request("format=png", mount(body))

    assert response.status == 415
    refute_received {:loader_open, _}

    assert_received {:fetch_decode,
                     %{
                       result: :processing_error,
                       error: :unsupported_source_format,
                       detected_source_format: :avif_sequence
                     }}
  end

  test "BigTIFF is detected as TIFF" do
    {:ok, body} = VipsImage.write_to_buffer(Image.new!(8, 6, color: :red), ".tif[bigtiff=true]")
    response = request("format=png", mount(body))

    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {8, 6}

    assert_received {:fetch_decode,
                     %{
                       result: :ok,
                       detected_source_format: :tiff,
                       source_format_resolution: :detected
                     }}
  end

  test "a loader outside the detected family is rejected after the header open" do
    png = Image.new!(8, 6) |> Image.write!(:memory, suffix: ".png")
    jpeg = Image.new!(8, 6) |> Image.write!(:memory, suffix: ".jpg")

    # Stands in for libvips picking a competing loader for bytes that carry
    # another family's signature.
    config =
      Keyword.put(mount(jpeg), :buffer_loader, fn _binary, options ->
        VipsImage.new_from_buffer(png, options)
      end)

    assert request("format=png", config).status == 415

    assert_received {:fetch_decode,
                     %{
                       result: :processing_error,
                       error: :unsupported_source_format,
                       detected_source_format: :jpeg,
                       source_loader: "pngload_buffer"
                     }}
  end

  test "a TIFF-signature camera RAW file never reaches a RAW loader", %{tmp_dir: dir} do
    path = Path.join(dir, "source.dng")
    File.write!(path, dng())

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: dir, root_id: "loader-allowlist-test"]
          ]
        ],
        telemetry_prefix: @prefix
      )
      |> Keyword.put(:image_open_module, ImagePipe.Test.HeaderDimensions.RecordingOpen)

    response = conn(:get, "/format=png/src/source.dng") |> ImagePipe.Plug.call(config)

    # libvips offers its RAW loader first only where it was built with one; the
    # request must then fail before any open. Elsewhere tiffload claims the file.
    case Foreign.find_load(path) do
      {:ok, "VipsForeignLoadTiff" <> _} ->
        assert response.status == 200
        assert_received {:loader_open, _}

      {:ok, loader} ->
        assert response.status == 415, loader
        refute_received {:loader_open, _}

        assert_received {:fetch_decode,
                         %{
                           result: :processing_error,
                           error: :unsupported_source_format,
                           detected_source_format: :tiff
                         }}
    end
  end

  # A minimal DNG: a baseline TIFF carrying a DNGVersion tag and CFA pixels.
  defp dng do
    {width, height} = {16, 16}
    pixels = :binary.copy(<<128, 0>>, width * height)
    text = "Cam" <> <<0>>

    entries = [
      {254, 4, 1, <<0::little-32>>},
      {256, 3, 1, <<width::little-16, 0::16>>},
      {257, 3, 1, <<height::little-16, 0::16>>},
      {258, 3, 1, <<16::little-16, 0::16>>},
      {259, 3, 1, <<1::little-16, 0::16>>},
      {262, 3, 1, <<32_803::little-16, 0::16>>},
      {271, 2, 4, text},
      {273, 4, 1, :strip},
      {277, 3, 1, <<1::little-16, 0::16>>},
      {278, 3, 1, <<height::little-16, 0::16>>},
      {279, 4, 1, <<byte_size(pixels)::little-32>>},
      {33_421, 3, 2, <<2::little-16, 2::little-16>>},
      {33_422, 1, 4, <<0, 1, 1, 2>>},
      {50_706, 1, 4, <<1, 4, 0, 0>>},
      {50_708, 2, 4, text}
    ]

    ifd_size = 2 + length(entries) * 12 + 4
    strip_offset = 8 + ifd_size

    ifd =
      for {tag, type, count, value} <- entries, into: <<>> do
        value = if value == :strip, do: <<strip_offset::little-32>>, else: value
        <<tag::little-16, type::little-16, count::little-32, value::binary-size(4)>>
      end

    <<"II", 42::little-16, 8::little-32, length(entries)::little-16, ifd::binary, 0::32,
      pixels::binary>>
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source") |> ImagePipe.Plug.call(config)

  defp mount(body) do
    pid = self()

    origin = fn conn ->
      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
    end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        telemetry_prefix: @prefix
      )

    Keyword.put(config, :buffer_loader, fn binary, options ->
      send(pid, {:loader_open, options})
      VipsImage.new_from_buffer(binary, options)
    end)
  end
end
