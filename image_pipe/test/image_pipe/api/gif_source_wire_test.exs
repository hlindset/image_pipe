defmodule ImagePipe.API.GifSourceWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.MultiFrameSources
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:gif_source_wire]

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

  test "a GIF is decoded as the gif family" do
    response = request("w=16/format=png", mount(gif(Image.new!(32, 24, color: [200, 40, 40]))))

    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {16, 12}

    assert_received {:fetch_decode,
                     %{
                       result: :ok,
                       detected_source_format: :gif,
                       source_format_resolution: :detected
                     }}
  end

  # libvips decodes every GIF with an alpha band, so the source-format fallback
  # picks PNG for opaque GIFs too.
  test "without an accepted modern format, a GIF is served as PNG" do
    for color <- [[200, 40, 40], [200, 40, 40, 0]] do
      response = request("w=16", mount(gif(Image.new!(32, 24, color: color))))
      assert content_type(response) == "image/png"
    end
  end

  test "output=info reports the gif format" do
    response = request("output=info", mount(gif(Image.new!(32, 24, color: [200, 40, 40]))))

    assert response.status == 200

    assert %{"format" => "gif", "mime_type" => "image/gif", "width" => 32, "height" => 24} =
             JSON.decode!(response.resp_body)
  end

  test "an animated GIF over max_input_frames is rejected after one loader open" do
    body = MultiFrameSources.repeated_frame_gif(6)

    assert request("format=png", mount(body, max_input_frames: 5)).status == 413
    assert_received {:loader_open, _}
    refute_received {:loader_open, _}

    assert_received {:fetch_decode,
                     %{result: :processing_error, error: :input_limit, limit: :frames}}

    assert request("format=png", mount(body, max_input_frames: 6)).status == 200
    assert_received {:fetch_decode, %{result: :ok, source_frames: 6}}
  end

  defp gif(image) do
    {:ok, body} = VipsImage.write_to_buffer(image, ".gif")
    body
  end

  defp content_type(response) do
    [content_type] = get_resp_header(response, "content-type")
    content_type
  end

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source") |> ImagePipe.Plug.call(config)

  defp mount(body, extra \\ []) do
    pid = self()

    origin = fn conn ->
      conn |> put_resp_content_type("image/gif") |> send_resp(200, body)
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
