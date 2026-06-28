defmodule ImagePipe.TwicPicsWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias TwicPicsWireConformanceTest.ExifOrientedOrigin
  alias TwicPicsWireConformanceTest.OriginImage
  alias TwicPicsWireConformanceTest.OriginShouldNotFetch

  @opts [
    parser: ImagePipe.Parser.TwicPics,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  defp call(path, opts \\ @opts) do
    :get |> conn(path) |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
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

  defp quality_opts(quality), do: Keyword.put(@opts, :twicpics, quality: quality)

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

  test "explicit output bypasses negotiation; auto sets Vary: Accept" do
    explicit = call("/images/beach.jpg?twic=v1/resize=100/output=avif")
    assert Plug.Conn.get_resp_header(explicit, "content-type") == ["image/avif"]

    auto =
      :get
      |> conn("/images/beach.jpg?twic=v1/resize=100/output=auto")
      |> Plug.Conn.put_req_header("accept", "image/webp")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(@opts))

    vary = auto |> Plug.Conn.get_resp_header("vary") |> Enum.flat_map(&String.split(&1, ", "))
    assert Enum.any?(vary, &(String.downcase(&1) == "accept"))
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
         root: cache_root,
         path_prefix: "processed",
         max_body_bytes: 10_000_000,
         key_headers: [],
         key_cookies: []}
      )

    first = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert first.status == 200
    assert_received :origin_fetch

    second = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    refute_received :origin_fetch
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
end
