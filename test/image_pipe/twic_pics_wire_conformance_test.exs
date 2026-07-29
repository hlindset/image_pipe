defmodule TwicPicsWireConformanceTest.DetectorA do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def detect(_image, _opts), do: {:ok, []}

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}
end

defmodule TwicPicsWireConformanceTest.DetectorB do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  defdelegate supported_classes(opts), to: TwicPicsWireConformanceTest.DetectorA

  @impl true
  defdelegate detect(image, opts), to: TwicPicsWireConformanceTest.DetectorA

  @impl true
  defdelegate available?(opts), to: TwicPicsWireConformanceTest.DetectorA

  @impl true
  def identity(_opts), do: {__MODULE__, :v2}
end

defmodule ImagePipe.TwicPicsWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias TwicPicsWireConformanceTest.ExifOrientedOrigin
  alias TwicPicsWireConformanceTest.OriginImage
  alias TwicPicsWireConformanceTest.OriginShouldNotFetch

  @opts [
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  defp call(path, opts \\ @opts, headers \\ []), do: call_method(:get, path, opts, headers)

  defp call_method(method, path, opts, headers \\ []) do
    conn =
      Enum.reduce(headers, conn(method, path), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)

    ImagePipe.Plug.call(conn, ImagePipe.Plug.init([dialect: TwicPics] ++ opts))
  end

  defp strong_opts(extra \\ []) do
    @opts
    |> Keyword.put(:sources, strong_sources())
    |> Keyword.merge(extra)
  end

  defp strong_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
    ]
  end

  defp should_not_fetch_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: OriginShouldNotFetch]}
    ]
  end

  defp counting_sources(internal_cache \\ :enabled) do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         internal_cache: internal_cache,
         req_options: [plug: {OriginImage, test_pid: self()}]}
    ]
  end

  defp cached_opts do
    table = :ets.new(:twicpics_wire_cache, [:set, :public])

    strong_opts(
      sources: counting_sources(),
      cache: {ImgproxyWireConformanceTest.CacheProbe, store: table}
    )
  end

  @doc false
  def handle_wire_telemetry(event, measurements, metadata, owner) do
    send(owner, {:wire_telemetry, event, measurements, metadata})
  end

  defp attach_request_telemetry(prefix) do
    handler_id = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        prefix ++ [:request, :stop],
        &__MODULE__.handle_wire_telemetry/4,
        self()
      )

    handler_id
  end

  defp dimensions(%Plug.Conn{} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(image), Image.height(image)}
  end

  defp exif_opts do
    Keyword.put(@opts, :sources,
      path:
        {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: ExifOrientedOrigin]}
    )
  end

  defp quality_opts(quality), do: Keyword.put(@opts, :quality, quality)

  test "auto-orients an EXIF-tagged source by default, without any geometry" do
    conn = call("/images/oriented.jpg?twic=v1/output=jpeg", exif_opts())
    assert conn.status == 200
    # Stored 40x80 portrait tagged EXIF orientation 6 displays as 80x40. Real
    # TwicPics bakes EXIF orientation into the output by default, so the served
    # frame is the upright 80x40 landscape, not the stored 40x80 portrait.
    assert dimensions(conn) == {80, 40}
  end

  test "a chained resize composes against the auto-oriented (upright) frame" do
    conn = call("/images/oriented.jpg?twic=v1/resize=40/output=jpeg", exif_opts())
    assert conn.status == 200
    # Auto-orient runs first, so resize fits width 40 against the upright 80x40
    # frame -> 40x20 (landscape), not the stored 40x80 portrait.
    assert dimensions(conn) == {40, 20}
  end

  test "single resize reaches the intermediate dimension (not clamped on a large source)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/output=jpeg")
    assert {340, _} = dimensions(conn)
  end

  test "parenthesized arithmetic folds to the same decoded result as its literal (#325)" do
    folded = call("/images/beach.jpg?twic=v1/resize=(700/2)/output=jpeg")
    literal = call("/images/beach.jpg?twic=v1/resize=350/output=jpeg")
    assert {350, h} = dimensions(folded)
    assert {350, ^h} = dimensions(literal)
  end

  test "a fractional bare-pixel resize rounds the decoded width (#325)" do
    # (7/2) = 3.5 -> 4px, matching the live TwicPics round-half-up behavior.
    conn = call("/images/beach.jpg?twic=v1/resize=(7/2)/output=jpeg")
    assert {4, _} = dimensions(conn)
  end

  test "a JSON exponent folds to the same decoded result as its literal" do
    exp = call("/images/beach.jpg?twic=v1/resize=2e2/output=jpeg")
    literal = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg")
    assert {200, h} = dimensions(exp)
    assert {200, ^h} = dimensions(literal)
  end

  test "chained relative resize resolves against running dimensions (340 then 50%)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/output=jpeg")
    assert conn.status == 200
    assert {170, _} = dimensions(conn)
  end

  test "three-hop relative chain compounds against the running width" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/resize=50p/output=jpeg")
    assert {85, _} = dimensions(conn)
  end

  test "bare percent resolves against the source width (4000) -> 2000" do
    conn = call("/images/beach.jpg?twic=v1/resize=50p/output=jpeg")
    assert {2000, _} = dimensions(conn)
  end

  test "malformed chain is rejected before any source fetch" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    # OriginShouldNotFetch raises if the origin is ever reached, so a clean 400
    # (rather than a 500) is itself the proof that the parser rejected the chain
    # before source resolution.
    conn = call("/images/beach.jpg?twic=v1/zoom=2", opts)
    assert conn.status == 400
  end

  defp average(%Plug.Conn{} = conn) do
    conn.resp_body
    |> Image.open!(access: :random, fail_on: :error)
    |> Image.average!()
  end

  test "focus anchor steers the cover crop (decoded pixels differ from centered baseline)" do
    centered = call("/images/beach.jpg?twic=v1/cover=200x200/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=200x200/output=jpeg")

    assert dimensions(centered) == {200, 200}
    assert dimensions(topleft) == {200, 200}
    refute average(centered) == average(topleft)
  end

  test "relative coordinate focus steers the next cover" do
    # focus=50px50p splits on x -> ["50p","50p"] -> x=50%, y=50% (no `px` unit; the
    # `x` is the separator), carried as a 50% focal point. Covering 100x100 from the
    # 4000x2667 source scales to ~150x100, so only the horizontal axis has crop
    # slack; a 50% focal x lands the window mid-range, distinct from the
    # left-clamped corner anchors.
    focal = call("/images/beach.jpg?twic=v1/focus=50px50p/cover=100x100/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")
    bottomright = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=100x100/output=jpeg")

    assert dimensions(focal) == {100, 100}
    # The focal point actually biases the cover crop: a centered focus lands
    # between the two opposing corner anchors, so it differs from both.
    refute average(focal) == average(topleft)
    refute average(focal) == average(bottomright)
  end

  test "bare-pixel coordinate focus steers the next cover (#321)" do
    # The 4000-wide source covers 100x100 with horizontal crop slack only; a
    # mid-source px focus lands the window between the opposing corner anchors, so
    # it differs from both. (Bare-pixel focus is supported, not rejected.)
    focal = call("/images/beach.jpg?twic=v1/focus=2000x1334/cover=100x100/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")
    bottomright = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=100x100/output=jpeg")

    assert dimensions(focal) == {100, 100}
    refute average(focal) == average(topleft)
    refute average(focal) == average(bottomright)
  end

  test "relative focus > 1 clamps to the far edge rather than 4xx'ing (#321)" do
    # focus=150px150p -> both 150%; clamps to the far edge. The cover has only
    # horizontal crop slack, so the clamped focus matches the right/bottom-right
    # anchor exactly (the vertical axis has no slack).
    clamped = call("/images/beach.jpg?twic=v1/focus=150px150p/cover=100x100/output=jpeg")
    corner = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=100x100/output=jpeg")

    assert clamped.status == 200
    assert dimensions(clamped) == {100, 100}
    assert average(clamped) == average(corner)
  end

  test "negative focus is rejected before any source fetch (#321)" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    conn = call("/images/beach.jpg?twic=v1/focus=-50x-50/cover=100x100", opts)
    assert conn.status == 400
  end

  test "focus resolves against the running frame at its chain position (order-sensitive) (#321)" do
    # resize=50p first -> the focus x=1000 is 50% of the 2000-wide resized frame;
    # focus first -> x=1000 is 25% of the 4000-wide source, carried through the
    # resize. Different source content, so the cover crops differ.
    after_resize =
      call("/images/beach.jpg?twic=v1/resize=50p/focus=1000x500/cover=100x100/output=jpeg")

    before_resize =
      call("/images/beach.jpg?twic=v1/focus=1000x500/resize=50p/cover=100x100/output=jpeg")

    assert dimensions(after_resize) == {100, 100}
    assert dimensions(before_resize) == {100, 100}
    refute average(after_resize) == average(before_resize)
  end

  test "a mixed-unit focus resolves each axis in its own unit (#321)" do
    # focus=2000x50p: x=2000px (= 50% of the 4000-wide source), y=50%. Covering
    # 100x100 has horizontal crop slack only, so the px x-axis must resolve to the
    # same fraction as the pure-relative form -> identical crop, and distinct from
    # the corner anchors.
    mixed = call("/images/beach.jpg?twic=v1/focus=2000x50p/cover=100x100/output=jpeg")
    relative = call("/images/beach.jpg?twic=v1/focus=50px50p/cover=100x100/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")

    assert dimensions(mixed) == {100, 100}
    assert average(mixed) == average(relative)
    refute average(mixed) == average(topleft)
  end

  test "a carried focus survives a non-consumer transformer (contain) into a later crop (#321)" do
    # contain only scales (it is not a focus consumer); the carried focus rides the
    # scale and steers the trailing crop, so opposing focus corners still differ.
    topleft =
      call("/images/beach.jpg?twic=v1/focus=top-left/contain=400x400/crop=50x50/output=jpeg")

    bottomright =
      call("/images/beach.jpg?twic=v1/focus=bottom-right/contain=400x400/crop=50x50/output=jpeg")

    assert dimensions(topleft) == {50, 50}
    assert dimensions(bottomright) == {50, 50}
    refute average(topleft) == average(bottomright)
  end

  test "a carried focus steers a SECOND consumer, not only the cover (#321)" do
    # Both steer the cover identically; the carried variant's trailing crop follows
    # the focus into the cover result, while the @-coordinate variant pins a fixed
    # centred region there. They differ only if the focus carries into the 2nd crop.
    carried =
      call("/images/beach.jpg?twic=v1/focus=top-left/cover=200x200/crop=120x120/output=jpeg")

    fixed =
      call(
        "/images/beach.jpg?twic=v1/focus=top-left/cover=200x200/crop=120x120@40x40/output=jpeg"
      )

    assert dimensions(carried) == {120, 120}
    assert dimensions(fixed) == {120, 120}
    refute average(carried) == average(fixed)
  end

  test "crop=WxH@XxY carries the focus through the region crop (no reset) (#331)" do
    # Identical region crop, opposite pre-region focus. The focus is CARRIED through
    # the @-coordinate crop (translated + clamped into the region frame), so it steers
    # the trailing guided crop to opposite ends of the region → different content. A
    # focus *reset* to the crop-result centre (the docs' claim) would center both
    # trailing crops identically; live TwicPics carries (confirmed by differential probe).
    from_tl =
      call("/images/beach.jpg?twic=v1/focus=0x0/crop=2000x2000@1000x500/crop=400x400/output=jpeg")

    from_br =
      call(
        "/images/beach.jpg?twic=v1/focus=3999x2666/crop=2000x2000@1000x500/crop=400x400/output=jpeg"
      )

    assert dimensions(from_tl) == {400, 400}
    assert dimensions(from_br) == {400, 400}
    refute average(from_tl) == average(from_br)
  end

  test "crop=WxH@XxY with an origin past the edge clamps → 200 (not IIIF's OOB 400)" do
    # beach.jpg is 4000×2667; origin x=5000 is wholly past the right edge. IIIF
    # rejects a wholly-outside region (on_out_of_bounds: :reject), but TwicPics keeps
    # the default :clamp — the shared CropRegion→Crop path must stay clamp for TwicPics.
    conn = call("/images/beach.jpg?twic=v1/crop=100x100@5000x100/output=jpeg")

    assert conn.status == 200
    assert dimensions(conn) == {100, 100}
  end

  test "focus=auto steers the cover crop (smart gravity, differs from centered baseline)" do
    # focus=auto -> {:smart, :face_assist} guide, the same attention(+face) engine
    # ImagePipe uses for imgproxy g:sm. With no detector configured (this lane) it
    # falls back to plain libvips attention, so the smart window still differs from a
    # plain centered cover. Face blending is exercised where a detector is live.
    centered = call("/images/beach.jpg?twic=v1/cover=200x200/output=jpeg")
    smart = call("/images/beach.jpg?twic=v1/focus=auto/cover=200x200/output=jpeg")

    assert dimensions(centered) == {200, 200}
    assert dimensions(smart) == {200, 200}
    refute average(centered) == average(smart)
  end

  test "focus=center is accepted and steers to the centre (#321)" do
    # Live TwicPics accepts focus=center (resolves to the centre point); it is a
    # divergence to reject it. The centre focus differs from a corner anchor.
    center = call("/images/beach.jpg?twic=v1/focus=center/cover=100x100/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")

    assert center.status == 200
    assert dimensions(center) == {100, 100}
    refute average(center) == average(topleft)
  end

  test "focus resolves in the display frame of an EXIF-oriented source (#321)" do
    # oriented.jpg: a 40x80 portrait with a red top-left square, EXIF orientation 6
    # (90 CW) -> displays 80x40 with the red block on the RIGHT half. A display-frame
    # focus on the right lands on red; the left lands on white. cover=20x20 leaves
    # horizontal crop slack, so the focus axis is decisive.
    right = call("/images/oriented.jpg?twic=v1/focus=72x20/cover=20x20/output=png", exif_opts())
    left = call("/images/oriented.jpg?twic=v1/focus=8x20/cover=20x20/output=png", exif_opts())

    assert dimensions(right) == {20, 20}
    assert dimensions(left) == {20, 20}
    # White ([255,255,255]) has a high green channel; red ([255,0,0]) a low one, so
    # the right (red) focus is distinctly less green than the left (white) focus.
    [_r1, g_right, _b1 | _] = average(right)
    [_r2, g_left, _b2 | _] = average(left)
    assert g_right < g_left
  end

  test "cover ratio crops to the target ratio without scaling" do
    conn = call("/images/beach.jpg?twic=v1/cover=16:9/output=jpeg")
    {w, h} = dimensions(conn)
    assert_in_delta w / h, 16 / 9, 0.02
  end

  test "contain fits inside; inside letterboxes to exact dims with a transparent border" do
    contain = call("/images/beach.jpg?twic=v1/contain=200x200/output=png")
    inside = call("/images/beach.jpg?twic=v1/inside=200x200/output=png")

    {cw, ch} = dimensions(contain)
    assert cw == 200
    assert ch < 200

    assert dimensions(inside) == {200, 200}
    img = Image.open!(inside.resp_body, access: :random, fail_on: :error)
    assert Image.has_alpha?(img)
  end

  test "inside with a non-alpha output flattens (no error, exact dims)" do
    conn = call("/images/beach.jpg?twic=v1/inside=200x200/output=jpeg")
    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
  end

  test "inside ratio letterboxes (pads, not crops) the source into the ratio box" do
    inside = call("/images/beach.jpg?twic=v1/inside=4:3/output=png")
    assert inside.status == 200

    # The 4000x2667 source (aspect 1.5) padded into a 4:3 (1.333...) box expands
    # the HEIGHT: width stays 4000, height grows to 4000 * 3 / 4 = 3000. The image
    # is centered with transparent bars top and bottom -- taller than the source,
    # never cropped narrower.
    {w, h} = dimensions(inside)
    assert {w, h} == {4000, 3000}
    assert h > 2667
    assert_in_delta w / h, 4 / 3, 0.001

    img = Image.open!(inside.resp_body, access: :random, fail_on: :error)
    assert Image.has_alpha?(img)
  end

  test "crop=WxH@0x0 crops from the top-left" do
    topleft = call("/images/beach.jpg?twic=v1/crop=100x100@0x0/output=png")
    elsewhere = call("/images/beach.jpg?twic=v1/crop=100x100@3900x2567/output=png")

    assert topleft.status == 200
    assert dimensions(topleft) == {100, 100}
    # The zero-based origin is honored: a top-left region differs in pixels from a
    # bottom-right region of the same size.
    refute average(topleft) == average(elsewhere)
  end

  test "relative crop dimensions resolve against the running dimensions" do
    # crop=50px50p is a guided crop of 50% x 50% of the 4000x2667 source.
    conn = call("/images/beach.jpg?twic=v1/crop=50px50p/output=jpeg")
    assert conn.status == 200
    assert dimensions(conn) == {2000, 1334}
  end

  test "relative crop coordinates resolve to the same origin as their pixel equivalent" do
    # @0.25sx0.5s on a 4000x2667 source resolves to origin (1000, 1334):
    # round(4000 × 0.25) = 1000, round(2667 × 0.5) = round(1333.5) = 1334.
    relative = call("/images/beach.jpg?twic=v1/crop=200x200@0.25sx0.5s/output=png")
    pixels = call("/images/beach.jpg?twic=v1/crop=200x200@1000x1334/output=png")

    assert relative.status == 200
    assert dimensions(relative) == {200, 200}
    assert dimensions(pixels) == {200, 200}
    # Same region, so the decoded pixels match (compared via average to tolerate
    # encode-time byte nondeterminism).
    assert average(relative) == average(pixels)
  end

  test "crop dimensions still reject zero before any source fetch" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    conn = call("/images/beach.jpg?twic=v1/crop=0x100", opts)
    assert conn.status == 400
  end

  test "inside still rejects relative units" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    conn = call("/images/beach.jpg?twic=v1/inside=50p", opts)
    assert conn.status == 400
  end

  # Hosted imagepipe.twic.pics output=auto probes (2026-07-19): a Chrome Accept
  # selects WebP; Accept: image/avif alone falls back to the source format (never
  # AVIF); explicit output=avif serves AVIF regardless of Accept; auto emits
  # Vary: Accept. The dialect matches this with WebP-preferred, AVIF-off auto.
  describe "output=auto matches hosted TwicPics format selection" do
    @chrome_accept "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"

    test "a Chrome Accept (avif+webp) selects WebP, not AVIF" do
      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", @opts, [
          {"accept", @chrome_accept}
        ])

      assert conn.status == 200
      assert header(conn, "content-type") == "image/webp"

      vary = conn |> Plug.Conn.get_resp_header("vary") |> Enum.flat_map(&String.split(&1, ", "))
      assert Enum.any?(vary, &(String.downcase(&1) == "accept"))
    end

    test "Accept: image/webp selects WebP" do
      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", @opts, [{"accept", "image/webp"}])

      assert header(conn, "content-type") == "image/webp"
    end

    test "an AVIF-only Accept falls back to the source format (auto never serves AVIF)" do
      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", @opts, [{"accept", "image/avif"}])

      assert conn.status == 200
      # beach.jpg is opaque -> JPEG universal fallback; never AVIF under auto.
      assert header(conn, "content-type") == "image/jpeg"
    end

    test "a legacy Accept falls back to the source format" do
      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", @opts, [
          {"accept", "image/png,*/*;q=0.8"}
        ])

      assert header(conn, "content-type") == "image/jpeg"
    end

    test "explicit output=avif bypasses auto and serves AVIF" do
      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=avif", @opts, [{"accept", "image/webp"}])

      assert header(conn, "content-type") == "image/avif"

      vary = conn |> Plug.Conn.get_resp_header("vary") |> Enum.flat_map(&String.split(&1, ", "))
      refute Enum.any?(vary, &(String.downcase(&1) == "accept"))
    end

    test "disabling WebP capability drops it from auto and falls back to source" do
      opts = Keyword.put(@opts, :output_capabilities, %{webp: false})

      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", opts, [
          {"accept", @chrome_accept}
        ])

      assert conn.status == 200
      assert header(conn, "content-type") == "image/jpeg"
    end

    test "a host may re-enable AVIF auto negotiation" do
      opts = Keyword.put(@opts, :auto_avif, true)

      conn =
        call("/images/beach.jpg?twic=v1/resize=100/output=auto", opts, [
          {"accept", @chrome_accept}
        ])

      assert header(conn, "content-type") == "image/avif"
    end
  end

  test "oversized chained upscale is clamped to the result limit after fetch" do
    opts = Keyword.put(@opts, :max_result_pixels, 1_000_000)
    conn = call("/images/beach.jpg?twic=v1/resize=4s/resize=4s/output=jpeg", opts)
    # The 16x chained upscale of a 4000px source overshoots the host pixel cap.
    # ImagePipe clamps an oversized result down to the host caps (imgproxy
    # limitScale parity, #165) rather than rejecting it — a 200 with the result
    # pinned under the cap proves the request reached the post-fetch result guard.
    assert conn.status == 200
    {w, h} = dimensions(conn)
    assert w * h <= 1_000_000
  end

  test "two semantically-equivalent requests reuse the same cache entry" do
    cache_root =
      Path.join(System.tmp_dir!(), "twicpics_wire_cache_#{System.unique_integer([:positive])}")

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)
    on_exit(fn -> File.rm_rf!(cache_root) end)

    opts =
      @opts
      |> Keyword.put(
        :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {OriginImage, test_pid: self()}]}
      )
      |> Keyword.put(
        :cache,
        {ImagePipe.Cache.FileSystem,
         root: cache_root, path_prefix: "processed", max_body_bytes: 10_000_000}
      )

    first = call("/images/beach.jpg?twic=v1/resize=(400/2)/output=jpeg", opts)
    assert first.status == 200
    assert_received :origin_fetch

    second = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    refute_received :origin_fetch
  end

  describe "shared lifecycle contract" do
    test "HEAD returns the GET metadata without a response body" do
      conn =
        call_method(
          :head,
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          strong_opts()
        )

      assert conn.status == 200
      assert conn.resp_body == ""
      assert header(conn, "content-type") == "image/jpeg"
      assert is_binary(header(conn, "etag"))
    end

    test "OPTIONS and unsupported methods stop before source/cache and carry CORS" do
      opts =
        strong_opts(
          allow_origin: "https://cdn.test",
          sources: should_not_fetch_sources(),
          cache: {ImgproxyWireConformanceTest.CacheProbe, []}
        )

      options = call_method(:options, "/images/beach.jpg?twic=v1/resize=64", opts)
      denied = call_method(:put, "/images/beach.jpg?twic=v1/resize=64", opts)

      assert options.status == 204
      assert header(options, "allow") == "GET, HEAD"
      assert header(options, "access-control-allow-origin") == "https://cdn.test"
      assert header(options, "access-control-allow-methods") == "GET, HEAD, OPTIONS"

      assert denied.status == 405
      assert header(denied, "allow") == "GET, HEAD"
      assert header(denied, "access-control-allow-origin") == "https://cdn.test"
      refute_received {:cache_lookup, _key}
    end

    test "CORS is present on successful and parse-error responses" do
      opts = strong_opts(allow_origin: "https://cdn.test")
      ok = call("/images/beach.jpg?twic=v1/resize=64/output=jpeg", opts)
      invalid = call("/images/beach.jpg?twic=v1/unknown=1", opts)

      assert ok.status == 200
      assert invalid.status == 400
      assert header(ok, "access-control-allow-origin") == "https://cdn.test"
      assert header(invalid, "access-control-allow-origin") == "https://cdn.test"
    end

    test "a strong matching ETag returns 304 before cache lookup and fetch" do
      path = "/images/beach.jpg?twic=v1/resize=64/output=jpeg"
      first = call(path, strong_opts())
      etag = header(first, "etag")

      opts =
        strong_opts(
          sources: should_not_fetch_sources(),
          cache: {ImgproxyWireConformanceTest.CacheProbe, []}
        )

      not_modified = call(path, opts, [{"if-none-match", etag}])

      assert not_modified.status == 304
      assert not_modified.resp_body == ""
      assert header(not_modified, "etag") == etag
      refute_received {:cache_lookup, _key}
    end

    test "a cache miss is committed and the next request is a hit without fetching" do
      path = "/images/beach.jpg?twic=v1/contain=80x80/output=jpeg"
      opts = cached_opts()

      miss = call(path, opts)
      assert miss.status == 200
      assert_received :origin_fetch

      hit = call(path, opts)
      assert hit.status == 200
      refute_received :origin_fetch
      assert hit.resp_body == miss.resp_body
      assert header(hit, "etag") == header(miss, "etag")
    end

    test "a source with internal caching disabled skips cache lookup and write" do
      opts =
        strong_opts(
          sources: counting_sources(:disabled),
          cache: {ImgproxyWireConformanceTest.CacheProbe, []}
        )

      conn = call("/images/beach.jpg?twic=v1/resize=64/output=jpeg", opts)

      assert conn.status == 200
      assert_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end

    test "storage header and cookie values independently move the key, not the strong ETag" do
      opts =
        strong_opts(
          cache: {ImgproxyWireConformanceTest.CacheProbe, []},
          storage_inputs: [{:header, "x-tenant"}, {:cookie, "session"}]
        )

      path = "/images/beach.jpg?twic=v1/resize=64/output=png"

      first =
        call(path, opts, [
          {"x-tenant", "one"},
          {"cookie", "session=alpha"}
        ])

      assert_receive {:cache_lookup, first_key}

      header_changed =
        call(path, opts, [
          {"x-tenant", "two"},
          {"cookie", "session=alpha"}
        ])

      assert_receive {:cache_lookup, header_changed_key}

      cookie_changed =
        call(path, opts, [
          {"x-tenant", "two"},
          {"cookie", "session=beta"}
        ])

      assert_receive {:cache_lookup, cookie_changed_key}

      refute first_key.hash == header_changed_key.hash
      refute header_changed_key.hash == cookie_changed_key.hash
      assert header(first, "etag") == header(header_changed, "etag")
      assert header(header_changed, "etag") == header(cookie_changed, "etag")
    end

    test "active auto-focus detector identity changes the cache key and ETag" do
      path = "/images/beach.jpg?twic=v1/focus=auto/cover=64x64/output=png"
      cache = {ImgproxyWireConformanceTest.CacheProbe, []}

      first =
        call(path, strong_opts(detector: TwicPicsWireConformanceTest.DetectorA, cache: cache))

      assert_receive {:cache_lookup, first_key}

      second =
        call(path, strong_opts(detector: TwicPicsWireConformanceTest.DetectorB, cache: cache))

      assert_receive {:cache_lookup, second_key}

      refute first_key.hash == second_key.hash
      refute header(first, "etag") == header(second, "etag")
    end

    test "max input pixels rejects the decoded source" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/output=jpeg",
          strong_opts(max_input_pixels: 1)
        )

      assert conn.status == 413
    end

    test "a private telemetry prefix receives the shared request span" do
      prefix = [:twicpics_wire_contract, :dialect]
      handler_id = attach_request_telemetry(prefix)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          strong_opts(telemetry_prefix: prefix)
        )

      assert conn.status == 200
      stop_event = prefix ++ [:request, :stop]

      assert_receive {:wire_telemetry, ^stop_event, measurements, %{result: :ok, status: 200}}
      assert is_integer(measurements.duration)
    end
  end

  defp header(%Plug.Conn{} = conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp debug_opts(extra), do: Keyword.merge(@opts, extra)

  describe "debug headers trigger (debug chain segment)" do
    test "the debug=1 segment emits x-imagepipe-* headers when allow_debug_headers: true" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=200/debug=1/output=jpeg",
          debug_opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") != nil
      assert header(conn, "x-imagepipe-cache") == "miss"
      assert header(conn, "x-imagepipe-source-format") != nil
    end

    test "no debug headers without the debug segment, even when allow_debug_headers: true" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=200/output=jpeg",
          debug_opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
      assert header(conn, "x-imagepipe-cache") == nil
    end

    test "no debug headers with debug=1 when allow_debug_headers: false (default)" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=200/debug=1/output=jpeg",
          debug_opts(allow_debug_headers: false)
        )

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
      assert header(conn, "x-imagepipe-cache") == nil
    end

    test "debug=0 is an explicit opt-out (no headers even under allow_debug_headers: true)" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=200/debug=0/output=jpeg",
          debug_opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert header(conn, "x-imagepipe-output-format") == nil
    end

    test "an invalid debug value is a 400 (consistent with other bad chain segments)" do
      conn =
        call(
          "/images/beach.jpg?twic=v1/resize=200/debug=maybe/output=jpeg",
          debug_opts(allow_debug_headers: true)
        )

      assert conn.status == 400
    end
  end

  describe "host-config quality" do
    # Discriminating test: with the URL omitting quality, output depends solely on
    # the configured default — so it fails unless the config is threaded onto Output.
    test "configured quality is honored when the URL omits quality" do
      low = call("/images/beach.jpg?twic=v1/output=jpeg", quality_opts(20))
      high = call("/images/beach.jpg?twic=v1/output=jpeg", quality_opts(90))

      assert low.status == 200 and high.status == 200
      assert byte_size(high.resp_body) > byte_size(low.resp_body)
    end

    test "a URL quality still wins over the configured default" do
      url_q = call("/images/beach.jpg?twic=v1/output=jpeg/quality=90", quality_opts(20))
      config_q = call("/images/beach.jpg?twic=v1/output=jpeg", quality_opts(20))

      assert byte_size(url_q.resp_body) > byte_size(config_q.resp_body)
    end
  end

  describe "cross-dialect encoder option inheritance" do
    test "host jpeg_options config reaches a TwicPics request" do
      # TwicPics has no encoder-option URL surface, but it threads neutral config
      # via apply_to_output/2 — so a host-set jpeg_options must reach the encoder.
      opts =
        Keyword.put(
          @opts,
          :jpeg_options,
          %ImagePipe.Plan.Output.JpegOptions{interlace: true}
        )

      conn = call("/images/beach.jpg?twic=v1/output=jpeg", opts)

      assert conn.status == 200
      # progressive JPEG carries the SOF2 marker (0xFFC2)
      assert :binary.match(conn.resp_body, <<0xFF, 0xC2>>) != :nomatch
    end
  end

  describe "point carry through multi-consumer chains" do
    # oriented.jpg: storage 40x80, red rows 0-39, EXIF 6 -> displays 80x40 with
    # red on the RIGHT half. focus=44x20 (display, just inside the red edge)
    # inverse-maps to storage (20, 36); the cover scales it to (10, 18), crops
    # storage rows 8..27 (mixed red/white), and the flush rotates point and
    # pixels together. focus=20x20 (white left half) maps to storage (20, 60)
    # and crops rows 20..39 (all white). The trailing crop=10x10 reads the
    # carried point AFTER the flush. This pins the seam scale and the crop-top
    # derivation end to end (a dropped scale crops all-white in both chains and
    # flips the relation); the reflect/translate failure modes are pinned by
    # the region-crop test below ([Flush, crop] order) at the wire and by the
    # resolver unit tests ([crop, Flush] order) at exact-integer precision —
    # an unclamped fp crop always centres the carry, so no wire chain on this
    # half/half fixture can isolate the [crop, Flush] reflect by itself.
    test "EXIF-oriented focus carries through cover to a post-flush consumer" do
      red_chain =
        call(
          "/images/oriented.jpg?twic=v1/focus=44x20/cover=20x20/crop=10x10/output=png",
          exif_opts()
        )

      white_chain =
        call(
          "/images/oriented.jpg?twic=v1/focus=20x20/cover=20x20/crop=10x10/output=png",
          exif_opts()
        )

      assert dimensions(red_chain) == {10, 10}
      assert dimensions(white_chain) == {10, 10}

      [_r1, g_red, _b1 | _] = average(red_chain)
      [_r2, g_white, _b2 | _] = average(white_chain)
      assert g_red < g_white
    end

    # Region-crop carry under EXIF: the region crop flushes FIRST ([Flush, Crop]),
    # so the point must reflect at the flush and then translate by the region
    # origin before the trailing consumer reads it (#331 carry semantics). The
    # region @20x0 spans display x in [20, 60) — white in [20, 40), red in
    # [40, 60) — so the two focus variants land the trailing 10x10 window on
    # opposite colors: focus=72x20 translates to (52, 20), past the region's
    # right edge, and to_fp clamps it to the red edge; focus=28x20 translates
    # to (8, 20), deep in the white part.
    test "EXIF-oriented focus carries through a region crop to a later consumer" do
      red_side =
        call(
          "/images/oriented.jpg?twic=v1/focus=72x20/crop=40x40@20x0/crop=10x10/output=png",
          exif_opts()
        )

      white_side =
        call(
          "/images/oriented.jpg?twic=v1/focus=28x20/crop=40x40@20x0/crop=10x10/output=png",
          exif_opts()
        )

      assert dimensions(red_side) == {10, 10}
      assert dimensions(white_side) == {10, 10}

      [_r1, g_red, _b1 | _] = average(red_side)
      [_r2, g_white, _b2 | _] = average(white_side)
      assert g_red < g_white
    end

    # Double-resize seam: two staged covers in a row, each scaling the point by
    # its realized factor before the next consumer reads it. Differential
    # coverage stops at focus -> cover -> crop; this pins the second seam.
    test "focus carries through two chained covers" do
      focal =
        call("/images/beach.jpg?twic=v1/focus=top-left/cover=300x100/cover=100x50/output=jpeg")

      other =
        call(
          "/images/beach.jpg?twic=v1/focus=bottom-right/cover=300x100/cover=100x50/output=jpeg"
        )

      assert dimensions(focal) == {100, 50}
      assert dimensions(other) == {100, 50}
      refute average(focal) == average(other)
    end

    test "implicit centre under EXIF quarter turn places the odd cover pixel" do
      fallback = call("/images/oriented.jpg?twic=v1/cover=15x15/output=png", exif_opts())

      assert dimensions(fallback) == {15, 15}
      image = Image.open!(fallback.resp_body, access: :random, fail_on: :error)

      # The synthetic source displays as an 80×40 frame with white on the left
      # and red on the right. TwicPics' implicit-centre crop gives the odd output
      # column to the red half: seven white columns followed by eight red columns.
      middle_row =
        for x <- 0..14 do
          [_red, green, _blue] = Image.get_pixel!(image, x, 7)
          if green > 128, do: :white, else: :red
        end

      assert middle_row == List.duplicate(:white, 7) ++ List.duplicate(:red, 8)
    end

    # Canvas-embed translate: the focus is set BEFORE an inside letterbox, so
    # the point must translate by the realized embed offset before the trailing
    # cover consumes it. Nothing else gates PointFlow's ExtendCanvas step
    # deterministically (the #441 inside_ratio_focus_* fixtures place the focus
    # AFTER the inside). Opposite-corner focuses land the trailing window on
    # opposite letterbox bands, so the outputs must differ.
    test "focus set before an inside letterbox carries through the canvas embed" do
      top_left =
        call("/images/beach.jpg?twic=v1/focus=0x0/inside=200x200/cover=50x25/output=png")

      bottom_right =
        call("/images/beach.jpg?twic=v1/focus=3999x2666/inside=200x200/cover=50x25/output=png")

      assert dimensions(top_left) == {50, 25}
      assert dimensions(bottom_right) == {50, 25}
      refute average(top_left) == average(bottom_right)
    end
  end
end
