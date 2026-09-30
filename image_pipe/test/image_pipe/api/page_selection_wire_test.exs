defmodule ImagePipe.API.PageSelectionWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.MultiFrameSources
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:page_selection_wire]
  @families [:webp, :gif, :jxl, :tiff, :avif]

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

  test "page=N decodes that page or frame of every multi-frame family" do
    for family <- @families do
      flush_mailbox()
      response = request("page=2/format=png", mount(MultiFrameSources.encode(family, 3)))

      assert response.status == 200, "#{family}: #{response.status}"
      assert_color(response, MultiFrameSources.frame_color(2), family)
      assert_received {:fetch_decode, %{result: :ok, page: 2, source_frames: 3}}
    end
  end

  test "a page past the last is rejected with 422 before the decoding open" do
    for family <- @families do
      flush_mailbox()
      response = request("page=3/format=png", mount(MultiFrameSources.encode(family, 3)))

      assert response.status == 422, "#{family}: #{response.status}"
      assert_received {:loader_open, _}
      refute_received {:loader_open, _}

      assert_received {:fetch_decode,
                       %{
                         result: :processing_error,
                         error: :page_out_of_range,
                         page: 3,
                         source_frames: 3
                       }}
    end
  end

  test "a still image has one page" do
    body = Image.new!(8, 8, color: [10, 20, 30]) |> Image.write!(:memory, suffix: ".png")

    assert request("page=0/format=png", mount(body)).status == 200
    assert request("page=1/format=png", mount(body)).status == 422
  end

  test "without page a HEIF collection decodes its primary image; page=0 is the first" do
    body = MultiFrameSources.avif_with_primary(3, 2)

    assert_color(request("format=png", mount(body)), MultiFrameSources.frame_color(2), :primary)

    assert_color(
      request("page=0/format=png", mount(body)),
      MultiFrameSources.frame_color(0),
      :page0
    )
  end

  test "the pixel limit applies to the selected page's own dimensions" do
    body = MultiFrameSources.tiff_pages([{8, 8, [200, 0, 0]}, {64, 64, [0, 0, 200]}])
    config = mount(body, max_input_pixels: 64 * 64 - 1)

    assert request("page=0/format=png", config).status == 200
    assert request("page=1/format=png", config).status == 413

    assert_received {:fetch_decode,
                     %{result: :processing_error, error: :input_limit, limit: :pixels}}

    response = request("page=1/format=png", mount(body))
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {64, 64}
  end

  test "selecting a timed frame counts every frame composited to reach it" do
    {width, height} = MultiFrameSources.frame_size()
    canvas = width * height
    body = MultiFrameSources.encode(:webp, 3)

    assert request("page=2/format=png", mount(body, max_input_pixels: 3 * canvas)).status == 200

    assert request("page=2/format=png", mount(body, max_input_pixels: 3 * canvas - 1)).status ==
             413

    assert request("page=0/format=png", mount(body, max_input_pixels: canvas)).status == 200
    assert request("format=png", mount(body, max_input_pixels: canvas)).status == 200
  end

  test "info reports the page count and describes the selected page" do
    info = fn options, body -> request(options, mount(body)).resp_body |> JSON.decode!() end

    assert %{"pages" => 3} = info.("output=info", MultiFrameSources.encode(:webp, 3))

    still = Image.new!(8, 8) |> Image.write!(:memory, suffix: ".png")
    assert %{"pages" => 1} = info.("output=info", still)

    mixed = MultiFrameSources.tiff_pages([{8, 8, [200, 0, 0]}, {64, 48, [0, 0, 200]}])

    assert %{"pages" => 2, "width" => 64, "height" => 48} =
             info.("output=info/page=1", mixed)
  end

  defp assert_color(response, [er, eg, eb], label) do
    assert response.status == 200, "#{label}: #{response.status}"
    [r, g, b | _] = response.resp_body |> Image.from_binary!() |> Image.get_pixel!(4, 4)

    assert abs(r - er) <= 12 and abs(g - eg) <= 12 and abs(b - eb) <= 12,
           "#{label}: pixel #{inspect([r, g, b])}, expected #{inspect([er, eg, eb])}"
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

  defp mount(body, extra \\ []) do
    pid = self()

    origin = fn conn ->
      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
    end

    config =
      [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
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
