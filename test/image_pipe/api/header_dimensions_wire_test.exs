defmodule ImagePipe.API.HeaderDimensionsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:header_dimensions_wire]
  @moduletag :tmp_dir

  test "oversized PNG, JPEG and WebP are rejected before the loader or cache write" do
    handler = {__MODULE__, make_ref()}
    event = @prefix ++ [:source, :fetch_decode, :stop]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, pid ->
          send(pid, {:fetch_decode, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for suffix <- [".png", ".jpg", ".webp"], terminal <- ["format=png", "output=info"] do
      body = encoded(suffix)
      config = mount(body, max_input_pixels: 100, cache: {CacheProbe, []})
      response = request(terminal, config)

      assert response.status == 413
      assert_received :origin_fetch
      refute_received {:loader_open, _}
      refute_received {:cache_put, _, _}
      assert_received {:fetch_decode, %{result: :processing_error, error: :input_limit}}
    end
  end

  test "dimensions at the limit still load and produce the requested image" do
    for suffix <- [".png", ".jpg", ".webp"] do
      response = request("w=12/format=png", mount(encoded(suffix), max_input_pixels: 24 * 16))
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["image/png"]
      output = Image.from_binary!(response.resp_body)
      assert {Image.width(output), Image.height(output)} == {12, 8}
      assert_received {:loader_open, _}
      assert_received {:loader_open, _}
    end
  end

  test "JPEG dimensions beyond the peek use libvips and retain the pixel-limit backstop" do
    <<0xFF, 0xD8, rest::binary>> = encoded(".jpg")
    padding = :binary.copy(<<0>>, 32 * 1024)
    body = <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(padding) + 2::16, padding::binary, rest::binary>>

    assert request("format=png", mount(body, max_input_pixels: 100)).status == 413
    assert_received {:loader_open, _}
    refute_received {:loader_open, _}

    response = request("format=png", mount(body))
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {24, 16}
  end

  test "TIFF retains libvips dimension validation" do
    assert {:ok, body} = VipsImage.write_to_buffer(Image.new!(24, 16), ".tif")
    assert request("format=png", mount(body, max_input_pixels: 100)).status == 413
    assert_received {:loader_open, _}
  end

  test "truncated headers reach the loader and retain decode failure status" do
    body = <<137, "PNG\r\n", 26, 10, 13::32, "IHDR", 100_000::32>>
    assert request("format=png", mount(body, max_input_pixels: 100)).status == 415
    assert_received {:loader_open, _}
  end

  test "body limits still apply before header dimension checks" do
    assert request("format=png", mount(encoded(".png"), max_body_bytes: 10)).status == 422
    refute_received {:loader_open, _}
  end

  test "local file sources use the same early pixel gate", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "source.png"), encoded(".png"))

    config =
      ImagePipe.Plug.init(
        sources: [path: {ImagePipe.Source.File, root: dir, root_id: "header-dimensions-test"}],
        max_input_pixels: 100
      )

    config =
      Keyword.put(config, :image_open_module, ImagePipe.Test.HeaderDimensions.RecordingOpen)

    assert conn(:get, "/format=png/src/source.png")
           |> ImagePipe.Plug.call(config)
           |> Map.fetch!(:status) == 413

    refute_received {:loader_open, _}

    allowed = Keyword.put(config, :max_input_pixels, 24 * 16)
    response = conn(:get, "/format=png/src/source.png") |> ImagePipe.Plug.call(allowed)
    assert response.status == 200
    assert_received {:loader_open, _}
    assert_received {:loader_open, _}
  end

  defp encoded(suffix),
    do: Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: suffix)

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source") |> ImagePipe.Plug.call(config)

  defp mount(body, extra \\ []) do
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    config =
      [
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ],
        telemetry_prefix: @prefix
      ]
      |> Keyword.merge(extra)
      |> ImagePipe.Plug.init()

    Keyword.put(config, :buffer_loader, fn binary, options ->
      send(pid, {:loader_open, options})
      VipsImage.new_from_buffer(binary, options)
    end)
  end
end
