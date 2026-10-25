defmodule ImagePipe.API.SVGSourceWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Caches
  alias Vix.Vips.Operation

  # The sibling image_pipe_svg project's test font.
  @font_dir Path.expand("../../../../image_pipe_svg/test/support/fonts", __DIR__)

  # Red left half, blue right half, at an intrinsic 40×20.
  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20">) <>
         ~s(<rect width="20" height="20" fill="#ff0000"/>) <>
         ~s(<rect x="20" width="20" height="20" fill="#0000ff"/></svg>)

  @transparent ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">) <>
                 ~s(<rect width="20" height="20" fill="#ff0000"/></svg>)

  # The render always has an alpha band, so without a format or a negotiated
  # one every SVG falls back to PNG.
  test "renders to PNG, keeping transparency" do
    response = request("w=40", mount(@transparent))

    assert content_type(response) == "image/png"
    assert dimensions(response) == {40, 20}
    assert pixel(response, 10, 10) == [255, 0, 0, 255]
    assert pixel(response, 30, 10) == [0, 0, 0, 0]
  end

  test "negotiates a modern format from Accept" do
    response =
      conn(:get, "/w=40/src/source.svg")
      |> put_req_header("accept", "image/webp")
      |> ImagePipe.Plug.call(mount(@svg))

    assert content_type(response) == "image/webp"
    assert get_resp_header(response, "vary") == ["Accept"]
  end

  test "renders past its intrinsic size with sharp edges, without enlarge" do
    response = request("w=400/format=png", mount(@svg))

    assert dimensions(response) == {400, 200}
    # A raster upscale blends the colours across several pixels at the edge.
    assert pixel(response, 198, 100) == [255, 0, 0]
    assert pixel(response, 201, 100) == [0, 0, 255]
  end

  test "renders a fractional size straight at the requested size" do
    fractional =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40.4" height="20" ) <>
        ~s(viewBox="0 0 40 20" preserveAspectRatio="none">) <>
        ~s(<rect width="20" height="20" fill="#ff0000"/>) <>
        ~s(<rect x="20" width="20" height="20" fill="#0000ff"/></svg>)

    response = request("w=400/format=png", mount(fractional))

    assert dimensions(response) == {400, 200}
    assert pixel(response, 199, 100) == [255, 0, 0]
    assert pixel(response, 200, 100) == [0, 0, 255]
  end

  test "renders a one-axis stretch and a minimum past the intrinsic size" do
    for {options, expected} <- [
          {"w=400/fit=stretch/format=png", {400, 20}},
          {"h=200/fit=stretch/format=png", {40, 200}},
          {"min-w=400/format=png", {400, 200}},
          {"min-h=200/format=png", {400, 200}}
        ] do
      response = request(options, mount(@svg))
      assert dimensions(response) == expected, options

      info = JSON.decode!(request(options <> "/output=info", mount(@svg)).resp_body)
      assert {info["result"]["width"], info["result"]["height"]} == expected, options
    end

    # Rendered at the requested width, not enlarged from the 40-pixel raster.
    response = request("w=400/fit=stretch/format=png", mount(@svg))
    assert pixel(response, 198, 10) == [255, 0, 0]
    assert pixel(response, 201, 10) == [0, 0, 255]
  end

  test "applies DPR past the intrinsic size" do
    assert dimensions(request("w=40/dpr=2/format=png", mount(@svg))) == {80, 40}
  end

  test "measures regions in intrinsic pixels whatever size it renders at" do
    response = request("region=20,0,20,20/w=100/format=png", mount(@svg))

    assert dimensions(response) == {100, 100}
    assert pixel(response, 2, 50) == [0, 0, 255]
    assert pixel(response, 97, 50) == [0, 0, 255]
  end

  test "rotates before resizing past the intrinsic size" do
    turned = request("rotate=90/w=40/format=png", mount(@svg))

    assert dimensions(turned) == {40, 80}
    assert pixel(turned, 20, 10) == [255, 0, 0]
    assert pixel(turned, 20, 70) == [0, 0, 255]

    assert {width, _height} = dimensions(request("rotate=30/w=200/format=png", mount(@svg)))
    assert width == 200
  end

  test "keeps the enlargement clamp in later groups, which resize the rendered raster" do
    assert dimensions(request("w=10/-/w=100/format=png", mount(@svg))) == {10, 5}
  end

  test "reports its intrinsic size and format in info" do
    response = request("w=400/output=info", mount(@svg))
    info = JSON.decode!(response.resp_body)

    assert %{"format" => "svg", "width" => 40, "height" => 20} = info["source"]
    assert %{"width" => 400, "height" => 200} = info["result"]
  end

  test "has one page, so a later page is out of range" do
    config = mount(@svg)
    assert request("page=0", config).status == 200

    for options <- ["page=1", "page=5/output=info"] do
      assert request(options, config).status == 422, options
    end
  end

  test "fails an SVG over max_input_pixels at both its own and its requested size" do
    config = mount(@svg, max_input_pixels: 799)

    assert dimensions(request("w=20/format=png", config)) == {20, 10}
    assert request("w=400/format=png", config).status == 413
  end

  test "renders at most max_input_pixels, then enlarges the rendered image" do
    config = mount(@svg, max_input_pixels: 4_000)

    assert dimensions(request("w=400/format=png", config)) == {400, 200}
    # A crop then zoom renders the whole SVG at the zoomed scale.
    assert dimensions(request("region=20,0,20,20/w=100/format=png", config)) == {100, 100}
  end

  test "keeps the enlargement clamp when the first group trims" do
    assert dimensions(request("trim=auto/w=400/format=png", mount(@transparent))) == {20, 20}
  end

  describe "fonts" do
    @text ~s(<svg xmlns="http://www.w3.org/2000/svg" width="50" height="50">) <>
            ~s(<text x="0" y="40" font-family="Helvetica, sans-serif" font-size="40">M</text></svg>)

    test "draw text only with configured fonts" do
      with_fonts = mount(@text, svg: [font_dirs: [@font_dir], fallback_family: "Geist Mono"])

      refute drawn?(request("format=png", mount(@text)))
      assert drawn?(request("format=png", with_fonts))
    end

    test "change the ETag, since they change how the same SVG renders" do
      etag = fn config -> request("w=50", config) |> get_resp_header("etag") end

      refute etag.(mount(@text)) ==
               etag.(mount(@text, svg: [font_dirs: [@font_dir], fallback_family: "Geist Mono"]))
    end

    # A configuration built at compile time may see other fonts than the
    # server that renders with it.
    @tag :tmp_dir
    test "key the ETag by the fonts that render", %{tmp_dir: dir} do
      options = [font_dirs: [dir], fallback_family: "Geist Mono"]
      File.cp!(Path.join(@font_dir, "GeistMono-Regular.ttf"), Path.join(dir, "font.ttf"))
      config = mount(@text, svg: options)
      # As if the configuration was built in another VM.
      :persistent_term.erase({ImagePipe.Decode.SVG, :fonts, [dir], "Geist Mono"})
      File.rm!(Path.join(dir, "font.ttf"))
      File.cp!(Path.join(@font_dir, "GeistMono-Regular.ttf"), Path.join(dir, "renamed.ttf"))
      etag = fn config -> request("w=50", config) |> get_resp_header("etag") end

      assert drawn?(request("format=png", config))
      assert etag.(config) == etag.(mount(@text, svg: options))
    end

    test "change the ETag with the fallback family" do
      etag = fn config -> request("w=50", config) |> get_resp_header("etag") end
      fonts = [font_dirs: [@font_dir]]

      refute etag.(mount(@text, svg: fonts)) ==
               etag.(mount(@text, svg: fonts ++ [fallback_family: "Geist Mono"]))
    end

    test "fail configuration when the fallback family isn't loaded" do
      assert_raise ArgumentError, ~r/Comic Sans MS/, fn ->
        mount(@svg, svg: [font_dirs: [@font_dir], fallback_family: "Comic Sans MS"])
      end
    end
  end

  test "fails an SVG larger than svg.max_bytes" do
    assert request("w=40", mount(@svg, svg: [max_bytes: byte_size(@svg)])).status == 200
    assert request("w=40", mount(@svg, svg: [max_bytes: byte_size(@svg) - 1])).status == 413
  end

  @tag :tmp_dir
  test "serves a repeat from the output cache, keyed by the fonts", %{tmp_dir: dir, test: name} do
    prefix = [:svg_cache_wire, name]
    event = prefix ++ [:source, :svg_render, :stop]
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, event, &__MODULE__.forward_render/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    options = [telemetry_prefix: prefix, cache: [root: dir]]
    plain = cached_mount(@svg, options)

    assert request("w=40/format=png", plain).status == 200
    assert_received :rendered
    assert request("w=40/format=png", plain).status == 200
    refute_received :rendered

    stop_supervised!(Caches.instance(options))
    with_fonts = cached_mount(@svg, options ++ [svg: [font_dirs: [@font_dir]]])

    assert request("w=40/format=png", with_fonts).status == 200
    assert_received :rendered
  end

  test "fails a render whose geometry reaches too far past the canvas" do
    far =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="4">) <>
        ~s(<path d="M4,0S4,578888888 6,0 6 3,6 9"/></svg>)

    assert request("format=png", mount(far)).status == 413
  end

  test "fails a render over svg.max_render_work" do
    assert request("w=40", mount(@svg, svg: [max_render_work: 1_000])).status == 413
  end

  describe "SVG watermarks" do
    # A 4×4 logo, red on its left half and transparent on its right.
    @logo ~s(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">) <>
            ~s(<rect width="2" height="4" fill="#ff0000"/></svg>)

    setup do
      photo = Image.new!(400, 200, color: [0, 0, 255]) |> Image.write!(:memory, suffix: ".png")
      {:ok, photo: photo}
    end

    test "render sharp at the size they're drawn", %{photo: photo} do
      config =
        mount(%{"/photo.png" => photo, "/logo.svg" => @logo},
          watermarks: %{logo: [source: "logo.svg"]}
        )

      response =
        conn(:get, "/wm=logo/wm-scale=0.5/format=png/src/photo.png")
        |> ImagePipe.Plug.call(config)

      # The 100×100 logo is centred, so its edge falls at x = 200. A raster
      # upscale from 4 px blends the colours across many pixels there.
      assert dimensions(response) == {400, 200}
      assert pixel(response, 198, 100) == [255, 0, 0]
      assert pixel(response, 201, 100) == [0, 0, 255]
    end

    test "fail when rendering at the drawn size is over the render budget", %{photo: photo} do
      # 80×80 at wm-scale=0.4, 100×100 at 0.5.
      config =
        mount(%{"/photo.png" => photo, "/logo.svg" => @logo},
          watermarks: %{logo: [source: "logo.svg"]},
          svg: [max_render_pixels: 9_000]
        )

      status = fn scale ->
        conn(:get, "/wm=logo/wm-scale=#{scale}/format=png/src/photo.png")
        |> ImagePipe.Plug.call(config)
        |> Map.fetch!(:status)
      end

      assert status.(0.4) == 200
      assert status.(0.5) == 413
    end

    test "report their parse in its own span", %{photo: photo} do
      prefix = [:svg_watermark_parse_test]
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          prefix ++ [:source, :svg_parse, :stop],
          fn _event, _measurements, metadata, pid -> send(pid, {:svg_parse, metadata}) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      bodies = %{"/photo.png" => photo, "/logo.svg" => @logo}
      watermarks = %{logo: [source: "logo.svg"]}
      path = "/wm=logo/wm-scale=0.5/format=png/src/photo.png"

      config = mount(bodies, watermarks: watermarks, telemetry_prefix: prefix)
      assert ImagePipe.Plug.call(conn(:get, path), config).status == 200
      assert_received {:svg_parse, %{result: :ok, asset: :watermark, intrinsic_dims: {4, 4}}}

      config =
        mount(bodies, watermarks: watermarks, telemetry_prefix: prefix, svg: [max_bytes: 10])

      assert ImagePipe.Plug.call(conn(:get, path), config).status == 413

      assert_received {:svg_parse,
                       %{
                         result: :processing_error,
                         asset: :watermark,
                         error: :input_limit,
                         limit: :svg_bytes
                       }}
    end
  end

  describe "the svg_render span" do
    setup do
      prefix = [:svg_source_wire_test]
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          prefix ++ [:source, :svg_render, :stop],
          fn _event, _measurements, metadata, pid -> send(pid, {:svg_render, metadata}) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, prefix: prefix}
    end

    test "reports the render's sizes and cost", %{prefix: prefix} do
      request("w=400/format=png", mount(@svg, telemetry_prefix: prefix))

      assert_received {:svg_render,
                       %{result: :ok, intrinsic_dims: {40, 20}, rendered_dims: {400, 200}} = meta}

      assert meta.work > 0 and meta.peak >= 400 * 200
      assert %{images: 0, image_pixels: 0} = meta
    end

    test "names the limit that rejected a render", %{prefix: prefix} do
      config = mount(@svg, telemetry_prefix: prefix, svg: [max_render_work: 1_000])
      request("w=40", config)

      assert_received {:svg_render,
                       %{result: :processing_error, error: :input_limit, limit: :svg_render_work}}
    end
  end

  test "fails a render over the render budget" do
    blurs =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">) <>
        ~s[<filter id="f"><feGaussianBlur stdDeviation="5"/></filter>] <>
        String.duplicate(~s[<rect width="100" height="100" filter="url(#f)"/>], 200) <>
        "</svg>"

    assert request("w=1000/format=png", mount(blurs)).status == 413
  end

  test "fails an SVG whose entities expand too far, before parsing it" do
    x = String.duplicate("a", 2000)
    y = String.duplicate("&x;", 250)

    bomb =
      ~s(<!DOCTYPE svg [<!ENTITY x "#{x}"><!ENTITY y "#{y}">]>) <>
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><text>) <>
        String.duplicate("&y;", 1000) <> "</text></svg>"

    assert request("w=8", mount(bomb)).status == 413
  end

  test "fails an SVG with too much text in one element, before laying it out" do
    text =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><text>) <>
        String.duplicate("a", 10_001) <> "</text></svg>"

    assert request("w=8", mount(text)).status == 413
  end

  test "rejects a malformed SVG as an unsupported source" do
    malformed = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8"><rect)
    assert request("w=8", mount(malformed)).status == 415
  end

  def forward_render(_event, _measurements, _metadata, pid), do: send(pid, :rendered)

  defp drawn?(response) do
    {_color, alpha} = response.resp_body |> Image.from_binary!() |> Image.split_alpha()
    {:ok, mean} = Operation.avg(alpha)
    mean > 0
  end

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source.svg") |> ImagePipe.Plug.call(config)

  defp mount(body, options \\ []),
    do: ImagePipe.Plug.init(Keyword.put_new(options(body, options), :allow_unsigned, true))

  defp cached_mount(body, options),
    do: body |> options(options) |> Caches.start!() |> Caches.plug()

  defp options(bodies, options) when is_map(bodies) do
    origin(
      fn conn ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, Map.fetch!(bodies, conn.request_path))
      end,
      options
    )
  end

  defp options(body, options) do
    origin(
      fn conn -> conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, body) end,
      options
    )
  end

  defp origin(origin, options) do
    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ]
    ] ++ options
  end

  defp content_type(response) do
    [value] = get_resp_header(response, "content-type")
    value |> String.split(";") |> hd()
  end

  defp dimensions(response) do
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    {Image.width(image), Image.height(image)}
  end

  defp pixel(response, x, y) do
    response.resp_body |> Image.from_binary!() |> Image.get_pixel!(x, y)
  end
end
