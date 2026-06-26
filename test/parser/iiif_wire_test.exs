defmodule ImagePipe.Parser.IIIFWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Parser.IIIF.CORS
  alias ImagePipe.Parser.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  # ---------------------------------------------------------------------------
  # Origin plugs
  # ---------------------------------------------------------------------------

  defmodule OriginImage do
    @moduledoc false

    # Serves a 200×300 opaque PNG — tall enough to exercise width-only resize
    # (100,/ should produce width=100) and large enough to avoid upscale paths.
    def init(opts), do: opts

    def call(conn, _opts) do
      body = Image.new!(200, 300, color: [100, 150, 200]) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule RGBAOriginImage do
    @moduledoc false

    # Serves a 200×300 RGBA PNG (semi-transparent) to exercise gray+JPEG flatten
    # and gray+PNG alpha-preserve contracts.
    def init(opts), do: opts

    def call(conn, _opts) do
      body =
        Image.new!(200, 300, color: [120, 180, 60, 128], bands: 4)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Routes "rgba.png" requests to RGBAOriginImage, all others to OriginImage.
  # Used to cover contracts 3/4 where different identifiers need different source images.
  defmodule MultiOriginImage do
    @moduledoc false

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: path} = conn, _opts) do
      if String.contains?(path, "rgba") do
        RGBAOriginImage.call(conn, [])
      else
        OriginImage.call(conn, [])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mount options
  # ---------------------------------------------------------------------------

  defp static_resolver(extra_map \\ %{}) do
    base_map = %{
      "img" => %SourcePath{segments: ["pic.png"]},
      "imgrgba" => %SourcePath{segments: ["rgba.png"]}
    }

    {StaticResolver, map: Map.merge(base_map, extra_map)}
  end

  defp iiif_opts(origin_plug) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver()],
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  defp iiif_opts_tile(origin_plug, tile_size) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver(), tile_size: tile_size],
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  defp iiif_opts_bounded(origin_plug, bounds) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver()] ++ bounds,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  defp iiif_opts_with_rgba do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver()],
      sources: [
        path:
          {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: MultiOriginImage]}
      ]
    ]
  end

  # ---------------------------------------------------------------------------
  # Call helpers
  # ---------------------------------------------------------------------------

  # Builds a conn for the path UNDER the IIIF mount prefix (script_name: ["iiif"]).
  # The `path` should be "/img/full/max/0/default.jpg" (without "/iiif").
  defp call_iiif(path, opts, req_headers \\ []) do
    initialized = ImagePipe.Plug.init(opts)

    conn =
      :get
      |> conn(path)
      |> put_script_name(["iiif"])
      |> add_req_headers(req_headers)

    cors_conn = CORS.call(conn, CORS.init([]))

    if cors_conn.halted do
      cors_conn
    else
      ImagePipe.Plug.call(cors_conn, initialized)
    end
  end

  defp call_options(path) do
    conn =
      :options
      |> conn(path)
      |> put_script_name(["iiif"])

    CORS.call(conn, CORS.init([]))
  end

  defp put_script_name(conn, script_name), do: %{conn | script_name: script_name}

  defp add_req_headers(conn, []), do: conn

  defp add_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp content_type(conn), do: get_resp_header(conn, "content-type")

  defp decoded_image(conn) do
    Image.open!(conn.resp_body, access: :random, fail_on: :error)
  end

  defp dimensions(conn) do
    img = decoded_image(conn)
    {Image.width(img), Image.height(img)}
  end

  # Assert a decoded image is grayscale: 1-band is luminance-only; a 3-band result
  # must have R≈G≈B at sampled points (so a skipped gray op would be detected).
  defp assert_grayscale!(img) do
    {w, h} = {Image.width(img), Image.height(img)}

    for {x, y} <- [{div(w, 4), div(h, 4)}, {div(w, 2), div(h, 2)}, {div(w * 3, 4), div(h * 3, 4)}] do
      case Image.get_pixel!(img, x, y) do
        [_lum] ->
          :ok

        [r, g, b | _] ->
          assert abs(r - g) <= 2 and abs(g - b) <= 2,
                 "pixel at (#{x},#{y}) not gray: r=#{r} g=#{g} b=#{b}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Contract 1: basic image request — width resize, correct content-type
  # ---------------------------------------------------------------------------

  test "contract 1: image request → 200 PNG, decoded width == 100" do
    conn = call_iiif("/img/full/100,/0/default.png", iiif_opts(OriginImage))

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]
    assert elem(dimensions(conn), 0) == 100
  end

  # ---------------------------------------------------------------------------
  # Contract 2: gray quality on opaque source → desaturated pixels
  # ---------------------------------------------------------------------------

  test "contract 2: gray quality on opaque source → R==G==B at sampled points" do
    conn = call_iiif("/img/full/max/0/gray.jpg", iiif_opts(OriginImage))

    assert conn.status == 200

    img = decoded_image(conn)
    {w, h} = {Image.width(img), Image.height(img)}

    sample_points = [
      {div(w, 4), div(h, 4)},
      {div(w, 2), div(h, 2)},
      {div(w * 3, 4), div(h * 3, 4)}
    ]

    for {x, y} <- sample_points do
      pixel = Image.get_pixel!(img, x, y)

      case pixel do
        # 1-band (gray/grayscale JPEG): single luminance value — inherently desaturated
        [_lum] ->
          :ok

        # 3-band (RGB JPEG): check R≈G≈B
        [r, g, b | _] ->
          assert abs(r - g) <= 2 and abs(g - b) <= 2,
                 "pixel at (#{x},#{y}) not gray: r=#{r} g=#{g} b=#{b}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Contract 2b: bitonal quality (Level 2) → every sampled value is 0 or 255
  # ---------------------------------------------------------------------------

  test "contract 2b: bitonal quality on opaque source → pixels are 0 or 255" do
    conn = call_iiif("/img/full/max/0/bitonal.png", iiif_opts(OriginImage))

    assert conn.status == 200

    img = decoded_image(conn)
    {w, h} = {Image.width(img), Image.height(img)}

    for {x, y} <- [{div(w, 4), div(h, 4)}, {div(w, 2), div(h, 2)}, {w - 1, h - 1}] do
      [v | _] = Image.get_pixel!(img, x, y)
      assert v in [0, 255], "pixel at (#{x},#{y}) not bitonal: #{v}"
    end
  end

  # ---------------------------------------------------------------------------
  # Contract 3: gray + RGBA source + JPG output → valid JPEG (no crash)
  # ---------------------------------------------------------------------------

  test "contract 3: gray on RGBA source + JPG format → 200, valid JPEG response" do
    conn = call_iiif("/imgrgba/full/max/0/gray.jpg", iiif_opts_with_rgba())

    assert conn.status == 200, "status=#{conn.status} body=#{inspect(conn.resp_body)}"

    # Must parse as a valid image — no crash from the RGBA→JPEG alpha-flatten path
    img = decoded_image(conn)
    assert Image.width(img) > 0
    assert Image.height(img) > 0

    # JPEG must not have an alpha channel (may be 1-band gray or 3-band color)
    {:ok, n_bands} = VipsImage.header_value(img, "bands")

    assert n_bands in [1, 3],
           "gray+JPEG from RGBA must produce 1 or 3 bands (no alpha), got #{n_bands}"

    # And gray must actually have RUN: the RGBA source is non-gray ([120,180,60]),
    # so a 3-band result must be desaturated (R≈G≈B); a 1-band result is luminance-only.
    assert_grayscale!(img)
  end

  # ---------------------------------------------------------------------------
  # Contract 4: gray + RGBA source + PNG → keeps alpha channel
  # ---------------------------------------------------------------------------

  test "contract 4: gray on RGBA source + PNG format → 200, decoded image has alpha" do
    conn = call_iiif("/imgrgba/full/max/0/gray.png", iiif_opts_with_rgba())

    assert conn.status == 200

    img = decoded_image(conn)
    {:ok, n_bands} = VipsImage.header_value(img, "bands")

    assert n_bands == 2,
           "expected 2 bands (gray+alpha) for gray PNG from RGBA source, got #{n_bands}"
  end

  # ---------------------------------------------------------------------------
  # Contract 5: info.json without Accept → application/json, correct fields
  # ---------------------------------------------------------------------------

  test "contract 5: info.json no Accept → 200, application/json, expected fields" do
    conn = call_iiif("/img/info.json", iiif_opts(OriginImage))

    assert conn.status == 200

    [ct] = content_type(conn)
    assert String.starts_with?(ct, "application/json")

    json = JSON.decode!(conn.resp_body)
    assert json["type"] == "ImageService3"
    assert json["profile"] == "level2"
    # OriginImage serves a 200×300 source (orientation 1), so info.json reports those.
    assert json["width"] == 200 and json["height"] == 300
  end

  # ---------------------------------------------------------------------------
  # Contract 5b: info.json tiles/sizes derived from source dims
  # ---------------------------------------------------------------------------

  test "contract 5b: info.json emits tiles/sizes from source dims" do
    conn = call_iiif("/img/info.json", iiif_opts(OriginImage))
    json = JSON.decode!(conn.resp_body)

    # 200x300 source, default tile 512: short side 200 -> 100, 50<64 at i=1 -> [1,2]
    assert json["tiles"] == [%{"width" => 200, "height" => 300, "scaleFactors" => [1, 2]}]

    assert json["sizes"] == [
             %{"width" => 100, "height" => 150},
             %{"width" => 200, "height" => 300}
           ]
  end

  test "contract 5c: non-default tile_size flows to tiles[].width" do
    conn = call_iiif("/img/info.json", iiif_opts_tile(OriginImage, 128))
    json = JSON.decode!(conn.resp_body)

    # tile clamps to min(128, dim): width 128, height 128 (both < 200/300)
    assert [%{"width" => 128, "height" => 128, "scaleFactors" => factors}] = json["tiles"]
    # short side 200 -> [1,2] regardless of tile size (ladder is dimension-only)
    assert factors == [1, 2]
  end

  # ---------------------------------------------------------------------------
  # Contract 6: info.json with Accept: application/ld+json → ld+json ct + Vary
  # ---------------------------------------------------------------------------

  test "contract 6: info.json with Accept application/ld+json → ld+json content-type + vary: accept" do
    conn =
      call_iiif("/img/info.json", iiif_opts(OriginImage), [
        {"accept", "application/ld+json"}
      ])

    assert conn.status == 200

    [ct] = content_type(conn)

    assert String.starts_with?(ct, "application/ld+json"),
           "expected application/ld+json content-type, got: #{ct}"

    vary = get_resp_header(conn, "vary")

    assert Enum.any?(vary, &String.contains?(String.downcase(&1), "accept")),
           "expected vary: accept header, got: #{inspect(vary)}"
  end

  # ---------------------------------------------------------------------------
  # Contract 7: bare identifier → 303, location ends with /info.json
  # ---------------------------------------------------------------------------

  test "contract 7: bare identifier → 303, location ends with /iiif/img/info.json" do
    conn = call_iiif("/img", iiif_opts(OriginImage))

    assert conn.status == 303

    [location] = get_resp_header(conn, "location")

    assert String.ends_with?(location, "/iiif/img/info.json"),
           "expected location ending in /iiif/img/info.json, got: #{location}"
  end

  # ---------------------------------------------------------------------------
  # Contract 8: CORS headers on image + info + redirect + OPTIONS
  # ---------------------------------------------------------------------------

  test "contract 8a: image response carries access-control-allow-origin: *" do
    conn = call_iiif("/img/full/max/0/default.jpg", iiif_opts(OriginImage))

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "contract 8b: info.json response carries access-control-allow-origin: *" do
    conn = call_iiif("/img/info.json", iiif_opts(OriginImage))

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "contract 8c: redirect response carries access-control-allow-origin: *" do
    conn = call_iiif("/img", iiif_opts(OriginImage))

    assert conn.status == 303
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "contract 8d: OPTIONS preflight → 200 with access-control-allow-methods" do
    conn = call_options("/img/full/max/0/default.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-methods") != []
  end

  # ---------------------------------------------------------------------------
  # Contract 9: status mapping
  # ---------------------------------------------------------------------------

  test "contract 9a: upscale without ^ → 400" do
    # Source is 200×300; requesting 9999w without ^ upscale flag → reject
    conn = call_iiif("/img/full/9999,/0/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 400
  end

  test "contract 9b: confined upscale !4000,4000 without ^ → 400" do
    # !w,h without ^ upscale flag and image smaller than target → reject
    conn = call_iiif("/img/full/!4000,4000/0/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 400
  end

  test "contract 9b2: percent-encoded ^ upscale (%5E400,) → 200, decoded width == 400" do
    # `^` arrives as %5E; classify must percent-decode the size token so the upscale
    # flag is honored. Without decoding, `%5E400,` is an invalid size → 400. Source is
    # 200×300, so `^400,` upscales width 200 → 400.
    conn = call_iiif("/img/full/%5E400,/0/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 200
    assert elem(dimensions(conn), 0) == 400
  end

  test "contract 9c: out-of-range rotation (370) → 400" do
    conn = call_iiif("/img/full/max/370/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 400
  end

  test "contract 9d: unsupported format .tif → 400" do
    conn = call_iiif("/img/full/max/0/default.tif", iiif_opts(OriginImage))
    assert conn.status == 400
  end

  test "contract 9e: unknown identifier → 404" do
    conn = call_iiif("/nope/full/max/0/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 404
  end

  test "contract 9f: unescaped slash in identifier (a/b) → 404" do
    # An identifier with an unescaped slash produces 6 path segments
    # which IIIF Path.classify/1 cannot match → :not_found → 404
    conn = call_iiif("/a/b/full/max/0/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 404
  end

  # ---------------------------------------------------------------------------
  # rot_non90: arbitrary rotation → grown bounding box + transparent corners (png)
  # ---------------------------------------------------------------------------

  test "rot_non90: 45° on png → larger image with a transparent corner" do
    conn = call_iiif("/img/full/max/45/default.png", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    assert Image.width(img) > 200 and Image.height(img) > 300
    assert Image.has_alpha?(img)
    assert List.last(Image.get_pixel!(img, 0, 0)) == 0
  end

  test "rot_non90: 45° on jpg → opaque (corners flattened onto background)" do
    conn = call_iiif("/img/full/max/45/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    refute Image.has_alpha?(img)
  end

  # ---------------------------------------------------------------------------
  # rot_mirror: !n mirrors before rotating
  # ---------------------------------------------------------------------------

  test "rot_mirror: !90 → 200 quarter-turn (lossless dims swapped)" do
    conn = call_iiif("/img/full/max/!90/default.png", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    # source 200x300 -> 90° turn -> 300x200
    assert Image.width(img) == 300 and Image.height(img) == 200
  end

  test "rot_mirror: percent-encoded ! (%2190) ≡ !90" do
    conn = call_iiif("/img/full/max/%2190/default.png", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    # %21 decodes to ! ; result must match !90 → 200×300 source turned to 300×200
    assert Image.width(img) == 300 and Image.height(img) == 200
  end

  # ---------------------------------------------------------------------------
  # Contract 10: image responses do NOT carry vary: accept (IIIF format is per-URL)
  # ---------------------------------------------------------------------------

  test "contract 10: image response does not carry vary: accept" do
    conn = call_iiif("/img/full/max/0/default.jpg", iiif_opts(OriginImage))

    assert conn.status == 200

    vary = get_resp_header(conn, "vary")

    refute Enum.any?(vary, &String.contains?(String.downcase(&1), "accept")),
           "image response must not carry vary: accept, got: #{inspect(vary)}"
  end

  # ---------------------------------------------------------------------------
  # max bounds (#257)
  # ---------------------------------------------------------------------------

  describe "max bounds (#257)" do
    test "^max upscales the 200x300 source toward a larger ceiling box" do
      # 1000-box on 200x300 (height-binding): scale 1000/300 -> 667x1000.
      conn =
        call_iiif(
          "/img/full/^max/0/default.png",
          iiif_opts_bounded(OriginImage, max_width: 1000, max_height: 1000)
        )

      assert conn.status == 200
      {w, h} = dimensions(conn)
      # grew to the ceiling on the binding axis
      assert h == 1000
      # actually upscaled past native width
      assert w > 200
    end

    test "max clamps the 200x300 source down to a sub-source ceiling" do
      # 100-box on 200x300 (height-binding): scale 100/300 -> 67x100.
      conn =
        call_iiif(
          "/img/full/max/0/default.png",
          iiif_opts_bounded(OriginImage, max_width: 100, max_height: 100)
        )

      {w, h} = dimensions(conn)
      assert w <= 100 and h <= 100
      # fits the box on the binding axis
      assert h == 100
    end

    test "maxHeight inferred from maxWidth bounds the unspecified axis (§5.1)" do
      # ONLY max_width: 100 — maxHeight is inferred = maxWidth = 100 per IIIF §5.1.
      # On the 200×300 portrait source, `max` fits within a 100×100 box, which is
      # height-binding (100/300 < 100/200) -> 67×100. Pinning h == 100 is the key:
      # if image_plan dropped the `|| max_width` inference, height would be
      # unbounded and the result would be 100×150 -> this assertion fails.
      conn =
        call_iiif(
          "/img/full/max/0/default.png",
          iiif_opts_bounded(OriginImage, max_width: 100)
        )

      assert conn.status == 200
      assert {67, 100} = dimensions(conn)
    end

    test "explicit width exceeding maxWidth is clamped down (not 400)" do
      # request width 150 (<= 200, no upscale-400) with maxWidth 100 (maxHeight
      # inferred = 100). The inferred 100×100 cap is height-binding on the 200×300
      # source -> 67×100. Pin both axes (h == 100 is the binding-axis guard).
      conn =
        call_iiif(
          "/img/full/150,/0/default.png",
          iiif_opts_bounded(OriginImage, max_width: 100)
        )

      assert conn.status == 200
      assert {67, 100} = dimensions(conn)
    end

    test "info.json does NOT advertise inferred maxHeight (raw configured only)" do
      # ONLY max_width configured. Advertising is raw-configured-only per spec:
      # info_plan performs NO §5.1 inference, so maxHeight/maxArea must be absent.
      # If info_plan ever grew the `|| max_width` inference, maxHeight would appear.
      conn =
        call_iiif(
          "/img/info.json",
          iiif_opts_bounded(OriginImage, max_width: 1000)
        )

      body = JSON.decode!(conn.resp_body)
      assert body["maxWidth"] == 1000
      refute Map.has_key?(body, "maxHeight")
      refute Map.has_key?(body, "maxArea")
    end

    test "info.json advertises configured bounds" do
      conn =
        call_iiif(
          "/img/info.json",
          iiif_opts_bounded(OriginImage, max_width: 1000, max_height: 800, max_area: 500_000)
        )

      body = JSON.decode!(conn.resp_body)
      assert body["maxWidth"] == 1000
      assert body["maxHeight"] == 800
      assert body["maxArea"] == 500_000
    end

    test "unbounded ^max degrades to the source dimensions" do
      # With no bounds configured, the grow-with-empty-scales branch leaves the
      # source untouched: ^max on 200×300 must yield the source dims, not enlarge.
      conn = call_iiif("/img/full/^max/0/default.png", iiif_opts(OriginImage))

      assert conn.status == 200
      assert {200, 300} = dimensions(conn)
    end

    test "info.json omits bounds when unconfigured" do
      conn = call_iiif("/img/info.json", iiif_opts(OriginImage))
      body = JSON.decode!(conn.resp_body)
      refute Map.has_key?(body, "maxWidth")
      refute Map.has_key?(body, "maxHeight")
      refute Map.has_key?(body, "maxArea")
    end
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp iiif_debug_opts(origin_plug) do
    Keyword.put(iiif_opts(origin_plug), :allow_debug_headers, true)
  end

  describe "debug headers trigger (?debug=1 query param)" do
    test "?debug=1 emits x-imagepipe-* headers when allow_debug_headers: true" do
      conn = call_iiif("/img/full/max/0/default.png?debug=1", iiif_debug_opts(OriginImage))

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") != nil
      assert header(conn, "x-imagepipe-cache") == "miss"
      assert header(conn, "x-imagepipe-source-format") != nil
    end

    test "no debug headers without ?debug=1, even when allow_debug_headers: true" do
      conn = call_iiif("/img/full/max/0/default.png", iiif_debug_opts(OriginImage))

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
      assert header(conn, "x-imagepipe-cache") == nil
    end

    test "no debug headers with ?debug=1 when allow_debug_headers: false (default)" do
      conn = call_iiif("/img/full/max/0/default.png?debug=1", iiif_opts(OriginImage))

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
      assert header(conn, "x-imagepipe-cache") == nil
    end

    test "a garbage debug value is ignored (200, no headers) — not a 400" do
      conn = call_iiif("/img/full/max/0/default.png?debug=maybe", iiif_debug_opts(OriginImage))

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
    end
  end
end
