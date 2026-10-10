defmodule ImagePipe.API.QualityWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias Vix.Vips.Image, as: VipsImage

  @moduletag timeout: 180_000

  test "host and per-format quality reach encoded bytes with explicit q precedence" do
    configured = response("w=200/format=jpeg", mount(quality: 45))
    explicit = response("w=200/format=jpeg/q=45", mount())
    assert_image(configured, "image/jpeg", {200, 133})
    assert configured.resp_body == explicit.resp_body

    configured = response("w=200/format=webp", mount(format_quality: %{webp: 35}))
    explicit = response("w=200/format=webp/q=35", mount())
    assert configured.status == 200
    assert configured.resp_body == explicit.resp_body

    overrides = response("w=200/format=webp/format-q=webp:35", mount(format_quality: %{webp: 60}))
    assert overrides.resp_body == explicit.resp_body
    format_q_wins = response("w=200/format=webp/format-q=webp:35/q=60", mount())
    assert format_q_wins.resp_body == explicit.resp_body
    q_fallback = response("w=200/format=jpeg/format-q=webp:35/q=60", mount())
    assert q_fallback.resp_body == response("w=200/format=jpeg/q=60", mount()).resp_body
  end

  test "a later layer's q replaces lower layers' per-format qualities" do
    defaults = mount(request_defaults: "format-q=webp:60")
    explicit = response("w=200/format=webp/q=35", mount())
    assert response("w=200/format=webp/q=35", defaults).resp_body == explicit.resp_body

    host = mount(format_quality: %{webp: 60})
    assert response("w=200/format=webp/q=35", host).resp_body == explicit.resp_body
  end

  test "quality controls preserve automatic negotiation and canonical Accept identity" do
    config = mount()
    options = "w=200/format-q=webp:35,avif:40"
    first = response(options, config, "image/webp")
    second = response(options, config, "image/webp;q=1, image/jpeg;q=0.5")
    assert_image(first, "image/webp", {200, 133})
    assert get_resp_header(first, "vary") == ["Accept"]
    assert first.resp_body == second.resp_body
    assert etag(first) == etag(second)

    explicit = response(options <> "/format=webp", config, "image/avif")
    assert explicit.resp_body == first.resp_body
    assert get_resp_header(explicit, "vary") == []
  end

  test "JPEG options merge over host fields and can disable a host flag" do
    config = mount(jpeg_options: [interlace: true, quant_table: 3])
    actual = response("w=200/format=jpeg/jpeg-options=progressive:false", config)
    expected = response("w=200/format=jpeg/jpeg-options=progressive:false,quant-table:3", mount())
    assert_image(actual, "image/jpeg", {200, 133})
    assert actual.resp_body == expected.resp_body
    assert :binary.match(actual.resp_body, <<0xFF, 0xC0>>) != :nomatch

    progressive = response("w=200/format=jpeg/jpeg-options=progressive", mount())
    assert progressive.status == 200
    assert :binary.match(progressive.resp_body, <<0xFF, 0xC2>>) != :nomatch
  end

  test "PNG palette and bit depth reach the file header" do
    response = response("w=200/format=png/png-options=palette,bitdepth:4,filter:none", mount())
    assert_image(response, "image/png", {200, 133})
    assert :binary.at(response.resp_body, 24) == 4
    assert :binary.at(response.resp_body, 25) == 3
  end

  test "lossless WebP preserves the transformed pixels" do
    config = mount()
    png = response("w=128/format=png", config)
    webp = response("w=128/format=webp/webp-options=lossless,effort:0", config)
    assert png.status == 200
    assert webp.status == 200
    assert pixels(png) == pixels(webp)
  end

  test "AVIF exposes its encoder effort control" do
    response = response("w=128/format=avif/avif-options=effort:1", mount())
    assert_image(response, "image/avif", {128, 85})
  end

  test "AVIF encodes full-resolution color unless chroma subsampling is requested" do
    config = mount()
    default = response("w=128/format=avif", config)
    full = response("w=128/format=avif/avif-options=subsample:off", config)
    subsampled = response("w=128/format=avif/avif-options=subsample:on", config)

    assert_image(default, "image/avif", {128, 85})
    assert default.resp_body == full.resp_body
    refute default.resp_body == subsampled.resp_body
  end

  test "lossless WebP rejects explicit search requests before source or cache access" do
    config = mount(CacheObserver.observe(webp_options: [lossless: true]))

    for option <- ["autoquality", "autoquality=75", "max-bytes=1000"] do
      assert response("format=webp/#{option}", config).status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _, _key}
    end
  end

  test "negotiated lossless WebP and inherited search defaults encode without search" do
    config =
      mount(
        allow_debug_headers: true,
        webp_options: [lossless: true, effort: 0],
        autoquality: true
      )

    options = "w=400/autoquality/max-bytes=1/debug"
    negotiated = response(options, config, "image/webp")
    explicit = response("w=400/format=webp/debug", config)
    baseline = response("w=400/format=webp/webp-options=lossless,effort:0", mount())

    assert_image(negotiated, "image/webp", {400, 267})
    assert explicit.status == 200
    assert negotiated.resp_body == baseline.resp_body
    assert explicit.resp_body == baseline.resp_body
    assert get_resp_header(negotiated, "x-imagepipe-aq-target") == []
    assert get_resp_header(explicit, "x-imagepipe-aq-target") == []
  end

  test "max-bytes reduces output and returns the quality floor when it cannot fit" do
    config = mount(allow_debug_headers: true)
    baseline = response("w=400/format=jpeg", config)
    capped = response("w=400/format=jpeg/max-bytes=8000/debug", config)
    assert baseline.status == 200
    assert byte_size(baseline.resp_body) > 8000
    assert_image(capped, "image/jpeg", {400, 267})
    assert byte_size(capped.resp_body) <= 8000

    tiny = response("w=400/format=jpeg/max-bytes=1000/debug", config)
    assert_image(tiny, "image/jpeg", {400, 267})
    assert byte_size(tiny.resp_body) > 1000
    assert get_resp_header(tiny, "x-imagepipe-output-quality") == ["10"]
  end

  test "a byte budget never raises an explicit quality below the usual floor" do
    config = mount(allow_debug_headers: true)
    baseline = response("w=400/format=jpeg/q=5", config)
    capped = response("w=400/format=jpeg/q=5/max-bytes=1/debug", config)

    assert capped.status == 200
    assert capped.resp_body == baseline.resp_body
    assert get_resp_header(capped, "x-imagepipe-output-quality") == ["5"]
  end

  test "SSIMULACRA2 search produces a response near the requested target" do
    config = mount(allow_debug_headers: true)
    png = response("w=400/format=png", config)
    assert png.status == 200
    {:ok, reference} = Ssim2Metric.reference(Image.from_binary!(png.resp_body))

    response =
      response(
        "w=400/format=jpeg/autoquality=80/debug",
        config
      )

    assert_image(response, "image/jpeg", {400, 267})
    assert get_resp_header(response, "x-imagepipe-aq-target") == ["80.0"]
    {:ok, score} = Ssim2Metric.score(reference, Image.from_binary!(response.resp_body))
    assert score >= 77
    assert score <= 86
  end

  test "explicit q and autoquality=false disable inherited quality search" do
    config = mount(allow_debug_headers: true, autoquality: true, autoquality_target: 80)

    explicit = response("w=128/format=jpeg/q=45/debug", config)
    assert explicit.status == 200
    assert explicit.resp_body == response("w=128/format=jpeg/q=45", mount()).resp_body
    assert get_resp_header(explicit, "x-imagepipe-aq-target") == []

    disabled = response("w=128/format=jpeg/autoquality=false/debug", config)
    assert disabled.status == 200
    assert disabled.resp_body == response("w=128/format=jpeg", mount()).resp_body
    assert get_resp_header(disabled, "x-imagepipe-aq-target") == []
  end

  test "format-q turns off quality search for the formats it lists" do
    explicit = response("w=128/format=webp/q=35", mount()).resp_body

    for {options, config} <- [
          {"w=128/format=webp/format-q=webp:35/debug",
           mount(allow_debug_headers: true, autoquality: true)},
          {"w=128/format=webp/autoquality=80/format-q=webp:35/debug",
           mount(allow_debug_headers: true)}
        ] do
      fixed = response(options, config)
      assert fixed.status == 200
      assert fixed.resp_body == explicit
      assert get_resp_header(fixed, "x-imagepipe-aq-target") == []
    end

    unlisted =
      response(
        "w=128/format=jpeg/format-q=webp:35/debug",
        mount(allow_debug_headers: true, autoquality: true)
      )

    assert get_resp_header(unlisted, "x-imagepipe-aq-target") == ["75.0"]

    host_quality =
      response(
        "w=128/format=webp/debug",
        mount(allow_debug_headers: true, autoquality: true, format_quality: %{webp: 35})
      )

    assert get_resp_header(host_quality, "x-imagepipe-aq-target") == ["75.0"]
  end

  test "the auto-quality target changes both cache and ETag identity" do
    config = mount(CacheObserver.observe([]))
    first = response("w=128/format=jpeg/autoquality=70", config)
    assert first.status == 200
    assert_receive {:cache_put, first_hash, _body}
    second = response("w=128/format=jpeg/autoquality=80", config)
    assert second.status == 200
    assert_receive {:cache_put, second_hash, _body}
    refute first_hash == second_hash
    refute etag(first) == etag(second)
  end

  test "invalid and conflicting output controls reject before source or cache access" do
    config = mount(CacheObserver.observe([]))

    for options <- [
          "format-q=webp:0",
          "format-q=webp:40,webp:50",
          "autoquality=ssimulacra2",
          "autoquality=0",
          "autoquality=101",
          "autoquality=-1",
          "autoquality=true",
          "autoquality=target:75",
          "format=jpeg/q=50/autoquality",
          "max-bytes=0",
          "format=png/q=50",
          "format=png/png-options=filter:paeth/q=50",
          "format=png/format-q=png:50",
          "format-q=png:50",
          "jpeg-options=progressive:true",
          "output=blurhash/q=50/autoquality"
        ] do
      assert response(options, config).status == 400, options
      refute_received :origin_fetch
      refute_received {:cache_lookup, _, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  test "PNG quality sets palette quantization and needs palette" do
    config = mount()
    low = response("w=200/format=png/png-options=palette/q=5", config)
    high = response("w=200/format=png/png-options=palette/q=95", config)
    assert low.status == 200 and high.status == 200
    assert byte_size(low.resp_body) < byte_size(high.resp_body)

    format_q = response("w=200/format=png/png-options=palette/format-q=png:5", config)
    assert format_q.resp_body == low.resp_body
  end

  test "BlurHash ignores configured image quality search" do
    config = mount(autoquality: true)
    response = response("output=blurhash", config)
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(response, "vary") == []
  end

  defp response(options, config, accept \\ nil) do
    conn = conn(:get, "/#{options}/src/beach.jpg")
    conn = if accept, do: put_req_header(conn, "accept", accept), else: conn
    ImagePipe.Plug.call(conn, config)
  end

  defp assert_image(response, mime, dimensions) do
    assert response.status == 200
    assert get_resp_header(response, "content-type") == [mime]
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == dimensions
  end

  defp etag(response) do
    assert [etag] = get_resp_header(response, "etag")
    etag
  end

  defp pixels(response),
    do: response.resp_body |> Image.from_binary!() |> VipsImage.write_to_binary()

  defp mount(overrides \\ []) do
    body = File.read!("priv/static/images/beach.jpg")
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            internal_cache: :enabled,
            req_options: [plug: origin]
          ]
        ]
      ],
      http_cache: :auto,
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end
end
