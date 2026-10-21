defmodule ImagePipe.APIResultLimitsTest do
  @moduledoc """
  Request-boundary coverage for `ImagePipe.API`'s `result_limits/2`:
  host-configured `max_result_*` caps reach the post-transform clamp, AND the
  clamp composes the host cap with the format's hard encoder limit via `min/2`
  (`ImagePipe.Output.Encoder.encoder_limit/1`), never exceeding either side.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.OriginImage
  alias Vix.Vips.Image, as: VipsImage

  @default_sources [
    path: [
      adapter: RootHTTPAdapter,
      match: :path,
      options: [
        root_url: "http://origin.test",
        byte_identity: :strong,
        req_options: [plug: OriginImage]
      ]
    ]
  ]

  defp opts(extra),
    do:
      ImagePipe.Plug.init(Keyword.merge([allow_unsigned: true, sources: @default_sources], extra))

  defp get(path, config) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  # The fixed origin fixture (`ImagePipe.Test.PlugFixture.OriginImage`) serves
  # `priv/static/images/beach.jpg`, 4000x2667 — large enough to both downscale
  # past a small host cap and upscale (with `enlarge`) past the WebP encoder
  # limit.

  describe "host-configured max_result_width reaches the clamp" do
    test "a resize past a small host cap is clamped to the cap, not the old hardcoded 8192" do
      config = opts(max_result_width: 64)

      conn = get("/w=200/fit=contain/src/images/beach.jpg", config)

      assert conn.status == 200
      assert {width, _height} = decoded_dims(conn.resp_body)
      assert width == 64
    end
  end

  test "explicit host result limits allow an in-bounds upscale without clamping" do
    body = Image.new!(100, 1, color: :red) |> Image.write!(:memory, suffix: ".png")

    origin = fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    prefix = [:api_result_limits_in_bounds_upscale]
    event = prefix ++ [:output, :clamp]
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn event, _measurements, metadata, pid -> send(pid, {:clamp, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    config =
      opts(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        max_result_width: 7000,
        max_result_height: 100,
        max_result_pixels: 500_000,
        telemetry_prefix: prefix
      )

    conn = get("/w=6000/enlarge/format=png/src/image", config)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert decoded_dims(conn.resp_body) == {6000, 60}
    refute_received {:clamp, ^event, _}
  end

  describe "the clamp's resize" do
    test "keeps semi-transparent colors exact" do
      body =
        Image.new!(900, 100, color: [200, 120, 37, 100], bands: 4)
        |> Image.write!(:memory, suffix: ".png")

      conn = get("/format=png/src/image", served(body, max_result_width: 613))

      assert conn.status == 200
      image = Image.from_binary!(conn.resp_body)
      assert {Image.width(image), Image.height(image)} == {613, 68}
      assert Image.get_pixel!(image, 306, 34) == [200, 120, 37, 100]
    end

    test "uses the request's resize kernel" do
      # Ten-pixel black and white stripes. A nearest-neighbour reduction keeps
      # only black and white, where lanczos3 rings at every edge.
      pixels = for _y <- 1..40, x <- 0..39, into: <<>>, do: <<rem(div(x, 10), 2) * 255>>
      {:ok, stripes} = VipsImage.new_from_binary(pixels, 40, 40, 1, :VIPS_FORMAT_UCHAR)
      body = Image.write!(stripes, :memory, suffix: ".png")

      conn =
        get(
          "/w=400/enlarge/kernel=nearest/format=png/src/image",
          served(body, max_result_width: 200)
        )

      assert conn.status == 200
      image = Image.from_binary!(conn.resp_body)
      assert Image.width(image) == 200
      {:ok, bytes} = VipsImage.write_to_binary(image)
      assert bytes |> :binary.bin_to_list() |> Enum.uniq() |> Enum.sort() == [0, 255]
    end
  end

  defp served(body, extra) do
    origin = fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    opts(
      [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      ] ++ extra
    )
  end

  describe "the clamp composes the host cap with the format's encoder limit (min wins)" do
    test "a host cap above the WebP hard limit still clamps to 16383, not the host cap" do
      config = opts(max_result_width: 20_000)

      conn =
        get(
          "/w=20000/h=100/fit=stretch/enlarge/format=webp/src/images/beach.jpg",
          config
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/webp"]
      assert {width, _height} = decoded_dims(conn.resp_body)
      assert width == 16_383
    end

    test "a host cap above libjpeg's limit still clamps to 65500" do
      config = opts(max_result_width: 70_000)

      conn =
        get("/w=65535/h=1/fit=stretch/enlarge/format=jpeg/src/images/beach.jpg", config)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert {65_500, _height} = decoded_dims(conn.resp_body)
    end
  end

  defp get_resp_header(conn, name), do: Plug.Conn.get_resp_header(conn, name)
end
