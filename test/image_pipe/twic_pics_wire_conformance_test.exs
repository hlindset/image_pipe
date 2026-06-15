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
    # `x` is the separator), a {:focal, {:ratio,1,2}, {:ratio,1,2}} guide. Covering
    # 100x100 from the 4000x2667 source scales to ~150x100, so only the horizontal
    # axis has crop slack; a 50% focal x lands the window mid-range (left=25),
    # distinct from the left-clamped corner anchors.
    focal = call("/images/beach.jpg?twic=v1/focus=50px50p/cover=100x100/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")
    bottomright = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=100x100/output=jpeg")

    assert dimensions(focal) == {100, 100}
    # The focal point actually biases the cover crop: a centered focus lands
    # between the two opposing corner anchors, so it differs from both.
    refute average(focal) == average(topleft)
    refute average(focal) == average(bottomright)
  end

  test "out-of-range relative focus is rejected before source fetch" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    # focus=150px50p -> ["150p","50p"] -> x ratio 3/2 (>100%) is an out-of-image
    # focal point; the parser rejects it before any source resolution.
    conn = call("/images/beach.jpg?twic=v1/focus=150px50p", opts)
    assert conn.status == 400
  end

  test "bare-pixel coordinate focus is rejected (deferred)" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    # focus=20x10 -> ["20","10"] -> both bare px; bare-pixel focus needs
    # running-dim-at-focus-position resolution and is deferred -> rejected.
    conn = call("/images/beach.jpg?twic=v1/focus=20x10", opts)
    assert conn.status == 400
  end

  test "focus=auto and focus=center are rejected" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    assert call("/images/beach.jpg?twic=v1/focus=auto", opts).status == 400
    assert call("/images/beach.jpg?twic=v1/focus=center", opts).status == 400
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
end
