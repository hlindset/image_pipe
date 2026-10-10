defmodule ImagePipe.API.MultiFrameWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.DecodeOpens
  alias ImagePipe.Test.MultiFrameSources
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:multi_frame_wire]
  @families [:webp, :tiff, :avif, :jxl, :gif]
  @terminals ["format=png", "output=info"]

  @moduletag :tmp_dir

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
    DecodeOpens.forward(@prefix)
  end

  test "each multi-frame family decodes only its first frame into a single-frame output" do
    for family <- @families do
      flush_mailbox()
      response = request("format=webp", mount(MultiFrameSources.encode(family, 3)))

      assert response.status == 200, "#{family}: #{response.status}"
      assert_single_frame_of(response, 0, family)
      assert_received {:fetch_decode, %{result: :ok, source_frames: 3}}
    end
  end

  test "an APNG decodes its default image and its frames are not counted" do
    response = request("format=webp", mount(MultiFrameSources.apng(), max_input_frames: 1))

    assert response.status == 200
    assert_single_frame_of(response, 0, :apng)
    assert_received {:fetch_decode, %{result: :ok, source_frames: 1}}
  end

  test "sources declaring more frames than max_input_frames are rejected after one loader open" do
    cache = observed_cache()

    for family <- [:tiff, :avif, :jxl, :gif], terminal <- @terminals do
      flush_mailbox()
      body = MultiFrameSources.encode(family, 3)
      response = request(terminal, mount(body, max_input_frames: 2, cache: cache))

      assert response.status == 413, "#{family} #{terminal}: #{response.status}"
      assert_received {:loader_open, _}
      refute_received {:loader_open, _}
      refute_received {:cache_put, _, _}

      assert_received {:fetch_decode,
                       %{result: :processing_error, error: :input_limit, limit: :frames}}

      assert request(terminal, mount(body, max_input_frames: 3)).status == 200
    end
  end

  test "an animated WebP over max_input_frames is rejected before any libvips open" do
    body = MultiFrameSources.repeated_frame_webp(6)
    cache = observed_cache()

    for terminal <- @terminals do
      flush_mailbox()
      response = request(terminal, mount(body, max_input_frames: 5, cache: cache))

      assert response.status == 413, "#{terminal}: #{response.status}"
      refute_received {:loader_open, _}
      refute_received {:cache_put, _, _}

      assert_received {:fetch_decode,
                       %{result: :processing_error, error: :input_limit, limit: :frames}}

      assert request(terminal, mount(body, max_input_frames: 6)).status == 200
      assert_received {:fetch_decode, %{result: :ok, source_frames: 6}}
    end
  end

  test "a local file source counts animated WebP frames before any libvips open", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "source.webp"), MultiFrameSources.repeated_frame_webp(6))

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: dir, root_id: "multi-frame-test"]
          ]
        ],
        max_input_frames: 5,
        telemetry_prefix: @prefix
      )

    assert request_path("/format=png/src/source.webp", config).status == 413
    refute_received {:loader_open, _}

    assert_received {:fetch_decode,
                     %{result: :processing_error, error: :input_limit, limit: :frames}}

    allowed = Keyword.put(config, :max_input_frames, 6)
    assert request_path("/format=png/src/source.webp", allowed).status == 200
    assert_received {:loader_open, _}
  end

  test "the body limit applies to multi-frame sources before any libvips open" do
    body = MultiFrameSources.encode(:webp, 3)
    response = request("format=png", mount(body, max_body_bytes: byte_size(body) - 1))

    assert response.status == 413
    refute_received {:loader_open, _}
    assert_received {:fetch_decode, %{result: :source_error, error: :body_too_large}}
  end

  test "result limits downscale the decoded first frame" do
    {width, height} = MultiFrameSources.frame_size()
    body = MultiFrameSources.encode(:tiff, 3)
    response = request("format=webp", mount(body, max_result_width: div(width, 2)))

    assert response.status == 200
    {:ok, output} = VipsImage.new_from_buffer(response.resp_body, n: -1)
    assert {Image.width(output), Image.height(output)} == {div(width, 2), div(height, 2)}
    assert {:error, _} = VipsImage.header_value(output, "n-pages")
  end

  test "max_input_pixels limits each frame, not the frames together" do
    {width, height} = MultiFrameSources.frame_size()

    for family <- @families do
      flush_mailbox()
      body = MultiFrameSources.encode(family, 3)
      assert request("format=png", mount(body, max_input_pixels: width * height)).status == 200

      response = request("format=png", mount(body, max_input_pixels: width * height - 1))
      assert response.status == 413

      assert_received {:fetch_decode,
                       %{result: :processing_error, error: :input_limit, limit: :pixels}}
    end
  end

  test "a response cached under a higher frame limit is served under a lower one" do
    body = MultiFrameSources.encode(:tiff, 3)
    cache = observed_cache()

    assert request("format=png", mount(body, max_input_frames: 3, cache: cache)).status == 200
    assert_received :origin_fetch

    response = request("format=png", mount(body, max_input_frames: 1, cache: cache))
    assert response.status == 200
    refute_received :origin_fetch
  end

  defp assert_single_frame_of(response, frame, family) do
    {:ok, output} = VipsImage.new_from_buffer(response.resp_body, n: -1)

    assert {Image.width(output), Image.height(output)} == MultiFrameSources.frame_size(),
           "#{family}"

    assert {:error, _} = VipsImage.header_value(output, "n-pages")

    [r, g, b | _] = Image.get_pixel!(output, 10, 10)
    [er, eg, eb] = MultiFrameSources.frame_color(frame)

    assert abs(r - er) <= 12 and abs(g - eg) <= 12 and abs(b - eb) <= 12,
           "#{family}: pixel #{inspect([r, g, b])}, expected frame #{frame}"
  end

  defp observed_cache do
    [telemetry_prefix: @prefix] |> CacheObserver.observe() |> Keyword.fetch!(:cache)
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp request_path(path, config), do: conn(:get, path) |> ImagePipe.Plug.call(config)

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source") |> ImagePipe.Plug.call(config)

  defp mount(body, extra \\ []) do
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
    end

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
  end
end
