defmodule ImagePipe.Native.QualityWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.Metric.Ssimulacra2, as: Ssim2Metric
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipe.Plan.Output.WebpOptions
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
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
    q_wins = response("w=200/format=webp/format-q=webp:35/q=60", mount())
    assert q_wins.resp_body == response("w=200/format=webp/q=60", mount()).resp_body
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
    config = mount(jpeg_options: %JpegOptions{interlace: true, quant_table: 3})
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

  test "AVIF and JPEG XL expose their encoder effort controls" do
    for {format, mime} <- [{"avif", "image/avif"}, {"jxl", "image/jxl"}] do
      response = response("w=128/format=#{format}/#{format}-options=effort:1", mount())
      assert_image(response, mime, {128, 85})
    end
  end

  test "lossless WebP rejects explicit search requests before source or cache access" do
    config = mount(webp_options: %WebpOptions{lossless: true}, cache: {CacheProbe, []})

    for option <- ["autoquality=ssimulacra2", "autoquality=size,target:1000", "max-bytes=1000"] do
      assert response("format=webp/#{option}", config).status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end
  end

  test "negotiated lossless WebP and inherited search defaults encode without search" do
    config =
      mount(
        allow_debug_headers: true,
        webp_options: %WebpOptions{lossless: true, effort: 0},
        autoquality_method: :ssimulacra2
      )

    options = "w=400/autoquality=ssimulacra2/max-bytes=1/debug"
    negotiated = response(options, config, "image/webp")
    explicit = response("w=400/format=webp/debug", config)
    baseline = response("w=400/format=webp/webp-options=lossless,effort:0", mount())

    assert_image(negotiated, "image/webp", {400, 267})
    assert explicit.status == 200
    assert negotiated.resp_body == baseline.resp_body
    assert explicit.resp_body == baseline.resp_body
    assert get_resp_header(negotiated, "x-imagepipe-aq-metric") == []
    assert get_resp_header(explicit, "x-imagepipe-aq-metric") == []
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

  test "size search uses its target and URL bounds override host format bounds" do
    config =
      mount(
        allow_debug_headers: true,
        autoquality_format_min_quality: %{jpeg: 70},
        autoquality_format_max_quality: %{jpeg: 75}
      )

    response =
      response("w=400/format=jpeg/autoquality=size,target:15000,min:40,max:95/debug", config)

    assert_image(response, "image/jpeg", {400, 267})
    assert byte_size(response.resp_body) <= 15_000
    assert get_resp_header(response, "x-imagepipe-aq-metric") == ["size"]
    assert get_resp_header(response, "x-imagepipe-aq-quality-min") == ["40"]
    assert get_resp_header(response, "x-imagepipe-aq-quality-max") == ["95"]
  end

  test "SSIMULACRA2 search produces a response near the requested target" do
    config = mount(allow_debug_headers: true)
    png = response("w=400/format=png", config)
    assert png.status == 200
    {:ok, reference} = Ssim2Metric.reference(Image.from_binary!(png.resp_body))

    response =
      response(
        "w=400/format=jpeg/autoquality=ssimulacra2,target:80,min:50,max:95,error:3/debug",
        config
      )

    assert_image(response, "image/jpeg", {400, 267})
    assert get_resp_header(response, "x-imagepipe-aq-metric") == ["ssimulacra2"]
    {:ok, score} = Ssim2Metric.score(reference, Image.from_binary!(response.resp_body))
    assert score >= 77
    assert score <= 86
  end

  test "Butteraugli searches WebP and uses native JPEG XL distance" do
    config = mount(allow_debug_headers: true)

    for {format, encoder, mime} <- [
          {"webp", "webp-options=effort:0", "image/webp"},
          {"jxl", "jxl-options=effort:1", "image/jxl"}
        ] do
      response =
        response(
          "w=128/format=#{format}/#{encoder}/autoquality=butteraugli,target:1,min:1,max:100,error:0.1/debug",
          config
        )

      assert_image(response, mime, {128, 85})
      assert get_resp_header(response, "x-imagepipe-aq-metric") == ["butteraugli"]

      if format == "jxl" do
        assert get_resp_header(response, "x-imagepipe-aq-outcome") == ["native"]
        assert get_resp_header(response, "x-imagepipe-aq-iterations") == ["0"]
      end
    end
  end

  test "explicit q and autoquality none disable inherited quality search" do
    config =
      mount(
        allow_debug_headers: true,
        autoquality_method: :ssimulacra2,
        autoquality_target: %{ssimulacra2: 80}
      )

    explicit = response("w=128/format=jpeg/q=45/debug", config)
    assert explicit.status == 200
    assert explicit.resp_body == response("w=128/format=jpeg/q=45", mount()).resp_body
    assert get_resp_header(explicit, "x-imagepipe-aq-metric") == []

    disabled = response("w=128/format=jpeg/autoquality=none/debug", config)
    assert disabled.status == 200
    assert disabled.resp_body == response("w=128/format=jpeg", mount()).resp_body
    assert get_resp_header(disabled, "x-imagepipe-aq-metric") == []
  end

  test "active iteration settings change both cache and ETag identity" do
    options = "w=128/format=jpeg/autoquality=size,target:2000,min:1,max:95"
    config = [cache: {CacheProbe, []}]
    first = response(options, mount([autoquality_max_iterations: 1] ++ config))
    assert first.status == 200
    assert_receive {:cache_lookup, first_key}
    assert_receive {:cache_put, _key, _body}
    second = response(options, mount([autoquality_max_iterations: 12] ++ config))
    assert second.status == 200
    assert_receive {:cache_lookup, second_key}
    assert_receive {:cache_put, _key, _body}
    refute first_key.hash == second_key.hash
    refute etag(first) == etag(second)
  end

  test "invalid and inert output controls reject before source or cache access" do
    config = mount(cache: {CacheProbe, []})

    for options <- [
          "format-q=webp:0",
          "format-q=webp:40,webp:50",
          "autoquality=ssim2",
          "autoquality=size",
          "autoquality=size,target:1000,error:1",
          "autoquality=ssimulacra2,min:90,max:40",
          "format=jpeg/autoquality=ssimulacra2,min:90",
          "format=jpeg/q=50/autoquality=ssimulacra2",
          "max-bytes=0",
          "format=png/max-bytes=1000",
          "format=png/autoquality=ssimulacra2",
          "format=jpeg/png-options=palette",
          "jpeg-options=progressive:true",
          "jxl-options=effort:0",
          "output=blurhash/format-q=webp:60",
          "output=blurhash/autoquality=none",
          "output=blurhash/max-bytes=1000",
          "output=blurhash/jpeg-options=progressive"
        ] do
      assert response(options, config).status == 400, options
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  test "BlurHash ignores configured image quality search" do
    config = mount(autoquality_method: :size)
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
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      http_cache: [mode: :enabled],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end
end
