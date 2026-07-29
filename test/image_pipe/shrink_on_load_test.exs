defmodule ImagePipe.ShrinkOnLoadTest do
  # Real file I/O — don't run async
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage

  # ──────────────────────────────────────────────────────────────────────────────
  # Origin plugs
  # ──────────────────────────────────────────────────────────────────────────────

  defmodule BeachJpegOrigin do
    @moduledoc false
    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule OrientedJpegOrigin do
    @moduledoc false
    # Serves a 4000×3000 JPEG tagged EXIF orientation 6 (90° turn), so the
    # *displayed* image is 3000×4000 (portrait). Built lazily in call/2. Used to
    # exercise shrink-on-load + deferred orientation together: libvips does not
    # auto-apply orientation on a shrink-load (verified), so the decode comes back
    # stored (landscape) and OrientationFlush rotates it after resize — the residual
    # resize must still land on the displayed-orientation target.
    def call(conn, _opts) do
      {:ok, base} = Image.new(4000, 3000, color: [120, 130, 140])
      body = base |> Image.set_orientation!(6) |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule PngOrigin do
    @moduledoc false
    # Serves a 400×300 RGBA solid-colour PNG generated in the module attribute
    # so the body is built once per test run.
    @png_body (fn ->
                 {:ok, img} = Image.new(400, 300, color: [0, 200, 100, 255], bands: 4)
                 Image.write!(img, :memory, suffix: ".png")
               end).()

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @png_body)
    end
  end

  defmodule WebpOrigin do
    @moduledoc false
    # Serves a 1600×1200 solid-colour WebP. The body is generated lazily inside
    # call/2 — never at compile time — so a host without a WebP saver does not crash
    # the module before the runtime webp_supported? gate can skip the test.
    def call(conn, _opts) do
      {:ok, img} = Image.new(1600, 1200, color: [200, 150, 100])
      body = Image.write!(img, :memory, suffix: ".webp")

      conn
      |> Plug.Conn.put_resp_content_type("image/webp")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule AnimatedWebpOrigin do
    @moduledoc false
    # Serves a 2-page animated WebP whose pages are 120×90 (stored as a 120×180
    # strip with page-height 90). Loaded single-page, the input is 120×90 = 10_800
    # pixels; if all pages were decoded it would be 120×180 = 21_600. Generated
    # lazily (see WebpOrigin) so it can't crash the module at compile time.
    def call(conn, _opts) do
      {:ok, f1} = Image.new(120, 90, color: [255, 0, 0])
      {:ok, f2} = Image.new(120, 90, color: [0, 255, 0])
      {:ok, strip} = Image.join([f1, f2])

      {:ok, strip} =
        VipsImage.mutate(strip, fn m ->
          MutableImage.set(m, "page-height", :gint, 90)
        end)

      body = Image.write!(strip, :memory, suffix: ".webp")

      conn
      |> Plug.Conn.put_resp_content_type("image/webp")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────────

  # The WebP tests both encode a fixture and request WebP output, so they need the
  # saver as well as the loader. Gate on both.
  defp webp_supported? do
    suffix_supported?(&VipsImage.supported_loader_suffixes/0, ".webp") and
      suffix_supported?(&VipsImage.supported_saver_suffixes/0, ".webp")
  end

  defp suffix_supported?(query, suffix) do
    case query.() do
      {:ok, suffixes} -> suffix in suffixes
      {:error, _reason} -> false
    end
  end

  defp iiif_resolver do
    {ImagePipe.Dialect.IIIF.Resolver.Static,
     map: %{
       "beach" => %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]},
       "png" => %ImagePipe.Plan.Source.Path{segments: ["images", "png"]},
       "webp" => %ImagePipe.Plan.Source.Path{segments: ["images", "webp"]},
       "animated" => %ImagePipe.Plan.Source.Path{segments: ["images", "animated"]},
       "oriented" => %ImagePipe.Plan.Source.Path{segments: ["images", "oriented"]}
     }}
  end

  defp file_source_opts do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: iiif_resolver(),
      sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}]
    ]
  end

  defp http_source_opts(origin_plug) do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: iiif_resolver(),
      sources: [
        path:
          {ImagePipe.SourceTest.RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  defp call_pipe(path, opts) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp decoded_image(conn) do
    Image.open!(conn.resp_body, access: :random, fail_on: :error)
  end

  # Mean absolute error across all pixels/bands between two equally-sized images,
  # after downsampling both to ~32px wide (coarse comparison that is insensitive
  # to minor sub-pixel differences between decode kernels).
  defp coarse_mae(img_a, img_b) do
    target_w = 32
    scale_a = target_w / Image.width(img_a)
    scale_b = target_w / Image.width(img_b)

    {:ok, ds_a} = Image.resize(img_a, scale_a)
    {:ok, ds_b} = Image.resize(img_b, scale_b)

    w = Image.width(ds_a)
    h = Image.height(ds_a)
    bands = length(Image.get_pixel!(ds_a, 0, 0))

    total =
      for x <- 0..(w - 1), y <- 0..(h - 1) do
        pa = Image.get_pixel!(ds_a, x, y)
        pb = Image.get_pixel!(ds_b, x, y)
        Enum.zip(pa, pb) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.sum()
      end
      |> Enum.sum()

    total / (w * h * bands)
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Tests
  # ──────────────────────────────────────────────────────────────────────────────

  # beach.jpg is 4000×2667.  Requesting w:444 → load_shrink = 4000/444 ≈ 9.0
  # → largest power-of-2 ≤ 9 is 8, so the JPEG is shrunk to 500×333 at decode
  # and subsequently resized by vips to exactly 444×296.  Output dimensions are
  # part of the contract (dimension-exact), so we pin both axes exactly rather
  # than with a tolerance.
  test "JPEG shrink-on-load produces correct output dimensions" do
    conn = call_pipe("/beach/full/444,/0/default.jpg", file_source_opts())

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "image/jpeg")

    img = decoded_image(conn)
    assert {Image.width(img), Image.height(img)} == {444, 296}
  end

  # Coarse MAE between the shrink-on-load pipeline and a direct
  # Image.thumbnail/2 baseline, downsampled to 32px wide.
  #
  # Observed MAE ~0.336 measured against libvips 8.18.2.
  # Threshold is set to 2.0 (≈ 6× observed) to absorb minor libvips/libjpeg
  # version and platform kernel variation while still catching gross decode errors.
  test "JPEG shrink-on-load MAE versus thumbnail baseline is within tolerance" do
    conn = call_pipe("/beach/full/444,/0/default.jpg", file_source_opts())
    assert conn.status == 200

    result_img = decoded_image(conn)

    # Direct thumbnail as a reference; both should be 444×296
    {:ok, baseline} = Image.thumbnail("priv/static/images/beach.jpg", 444)

    mae = coarse_mae(result_img, baseline)

    # Observed ~0.336; threshold 2.0 (≈ 6× observed)
    assert mae < 2.0,
           "coarse MAE #{mae} exceeds 2.0 — shrink-on-load result drifted too far from thumbnail baseline"
  end

  # PNG is not JPEG-shrink-eligible; the decode planner must NOT inject a shrink
  # option.  We use a synthesized 400×300 RGBA PNG and request a 50px-wide
  # result.  Because there is no shrink, the decoded image goes through a normal
  # vips resize, so the output should have alpha and be pixel-exact to a direct
  # resize baseline.
  test "PNG decode is not shrunk; output preserves alpha" do
    conn = call_pipe("/png/full/50,/0/default.png", http_source_opts(PngOrigin))

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "image/")

    img = decoded_image(conn)

    assert Image.width(img) == 50
    assert Image.has_alpha?(img)
  end

  # PNG MAE vs direct resize baseline should be effectively zero (same kernel,
  # no shrink path involved).
  test "PNG pixel values match direct resize baseline" do
    conn = call_pipe("/png/full/50,/0/default.png", http_source_opts(PngOrigin))

    assert conn.status == 200
    result_img = decoded_image(conn)

    {:ok, src} = Image.new(400, 300, color: [0, 200, 100, 255], bands: 4)
    {:ok, baseline} = Image.resize(src, 50 / 400)

    mae = coarse_mae(result_img, baseline)

    assert mae < 1.0,
           "PNG MAE #{mae} unexpectedly high — shrink may have been applied to a PNG"
  end

  # max_input_pixels is checked against the *original* JPEG header dimensions,
  # not the shrunk-decode result.  Setting the limit 1 pixel below the beach.jpg
  # pixel count must return 413 before any encoding.
  test "oversized JPEG is rejected when max_input_pixels < source pixel count" do
    orig_pixels = 4000 * 2667

    opts =
      Keyword.merge(
        http_source_opts(BeachJpegOrigin),
        max_input_pixels: orig_pixels - 1
      )

    conn = call_pipe("/beach/full/444,/0/default.jpg", opts)

    assert conn.status == 413
    assert conn.resp_body =~ "too large"
  end

  # WebP uses fractional scale-on-load (not JPEG block shrink). A 1600×1200 source
  # to w:200 → scale 0.125 → decoded ≈ 200×150, with no residual resize needed.
  # Output must be dimension-exact and perceptually equivalent to a direct
  # thumbnail of the same source. Gated on WebP support in the host libvips.
  test "WebP scale-on-load is dimension-exact and within MAE tolerance" do
    if webp_supported?() do
      conn = call_pipe("/webp/full/200,/0/default.webp", http_source_opts(WebpOrigin))

      assert conn.status == 200

      img = decoded_image(conn)
      assert {Image.width(img), Image.height(img)} == {200, 150}

      {:ok, src} = Image.new(1600, 1200, color: [200, 150, 100])
      {:ok, baseline} = Image.thumbnail(src, 200)

      mae = coarse_mae(img, baseline)
      assert mae < 2.0, "WebP scale-on-load coarse MAE #{mae} exceeds 2.0"
    else
      # The host libvips has no WebP loader; the scale-on-load path can't be
      # exercised here. Don't silently pass — make the skip visible.
      IO.puts(:stderr, "[shrink_on_load] skipping WebP test: libvips has no .webp loader")
    end
  end

  # Safety: an animated input must be decoded single-page so the input-pixel limit
  # cannot be bypassed by frame count. The animated WebP has 2 pages of 120×90;
  # single-page decode counts 10_800 input pixels, all-pages would count 21_600.
  # With the limit set between those, the request succeeds iff only one page was
  # decoded. (Animation is out of scope for output; inputs decode their first frame.)
  test "animated WebP is decoded single-page so the input-pixel limit holds per frame" do
    if webp_supported?() do
      opts =
        Keyword.merge(
          http_source_opts(AnimatedWebpOrigin),
          max_input_pixels: 15_000
        )

      conn = call_pipe("/animated/full/60,/0/default.webp", opts)

      # 10_800 (one page) ≤ 15_000 < 21_600 (two pages): success proves single-page.
      assert conn.status == 200
      img = decoded_image(conn)
      assert Image.width(img) == 60
    else
      IO.puts(
        :stderr,
        "[shrink_on_load] skipping animated-WebP test: libvips has no .webp loader"
      )
    end
  end

  # Regression: crop runs BEFORE resize in the fixed pipeline order. The resize
  # must compute its target from the *cropped* image, not the original source.
  # After the crop runs, `clear_source_frame` drops the stored original dims so
  # `effective_source_dims` reads the live (post-crop) image — correct regardless
  # of the decode prescale.
  #
  # Shrink-on-load now proceeds *through* a preceding crop (#151): the shrink is
  # sized against the cropped extent and the crop's pixel coords are rescaled by the
  # realized shrink. beach.jpg is 4000×2667. The region crops a 2000×2000 square,
  # size !500,500 → shrink 4 (crop 2000 / target 500), crop rescaled to 500×500 on the
  # 1000×667 shrunk decode, then the residual resize lands the square. Because the
  # residual resize scales by a fractional factor, the result may sit ±1px off the
  # requested square (the resampling floor the shrink_on_load property test pins);
  # the original absolute-`source_dimensions` bug produced 500×333 here, which this
  # still guards against.
  test "crop-before-resize computes the residual resize from the cropped square" do
    conn =
      call_pipe("/beach/0,0,2000,2000/!500,500/0/default.jpg", file_source_opts())

    assert conn.status == 200

    img = decoded_image(conn)
    {w, h} = {Image.width(img), Image.height(img)}
    assert abs(w - 500) <= 1 and abs(h - 500) <= 1, "expected ~500×500, got #{w}×#{h}"
  end

  # A second crop+resize geometry, to guard the dimension contract independent of
  # the square-crop coincidence above: a 2000×2000 crop fit to 1500×1500 → 1500×1500.
  test "crop-before-resize is dimensionally exact for a larger target" do
    conn =
      call_pipe(
        "/beach/0,0,2000,2000/!1500,1500/0/default.jpg",
        file_source_opts()
      )

    assert conn.status == 200

    img = decoded_image(conn)
    assert {Image.width(img), Image.height(img)} == {1500, 1500}
  end

  # Shrink-on-load composed with deferred orientation (the retina-photo case). The
  # source is a 4000×3000 JPEG tagged EXIF orientation 6, so the displayed image is
  # 3000×4000 (portrait). IIIF auto-rotation is on by default; size 375, against the
  # displayed width (3000) gives load_shrink 8. libvips returns the shrink-load
  # stored-oriented (landscape); OrientationFlush rotates it after the residual
  # resize, which must land on the displayed-orientation target 375×500.
  #
  # Pinning both dims (and that the result is portrait) guards the orientation
  # axis-swap: a stored-vs-displayed mismatch would transpose the output (500×375).
  test "shrink-on-load with auto-orient lands on the displayed-orientation target" do
    conn =
      call_pipe(
        "/oriented/full/375,/0/default.jpg",
        http_source_opts(OrientedJpegOrigin)
      )

    assert conn.status == 200

    img = decoded_image(conn)
    assert {Image.width(img), Image.height(img)} == {375, 500}
    assert Image.height(img) > Image.width(img), "auto-oriented output must be portrait"
  end
end
