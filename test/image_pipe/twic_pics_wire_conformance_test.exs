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

defmodule ImagePipe.TwicPicsWireConformanceTest.CrossArm do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias TwicPicsWireConformanceTest.Arm
  alias TwicPicsWireConformanceTest.OriginImage
  alias TwicPicsWireConformanceTest.OriginShouldNotFetch
  alias Vix.Vips.Image, as: VipsImage

  @opts [
    parser: ImagePipe.Parser.TwicPics,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  @stable_debug_headers [
    "x-imagepipe-source-format",
    "x-imagepipe-source-width",
    "x-imagepipe-source-height",
    "x-imagepipe-output-format",
    "x-imagepipe-output-negotiated",
    "x-imagepipe-output-width",
    "x-imagepipe-output-height",
    "x-imagepipe-output-quality",
    "x-imagepipe-pipeline",
    "x-imagepipe-cache"
  ]

  @host_cache_control "public, max-age=60"

  defp call_both(path, opts, headers \\ []), do: call_both(:get, path, opts, headers)

  defp call_both(method, path, opts, headers) do
    {
      call_arm(:framework, method, path, opts, headers),
      call_arm(:dialect, method, path, opts, headers)
    }
  end

  defp call_arm(arm, method, path, opts, headers) do
    conn =
      headers
      |> Enum.reduce(conn(method, path), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)
      |> Plug.Conn.put_resp_header("cache-control", @host_cache_control)

    Arm.call(arm, conn, opts)
  end

  defp strong_opts(extra \\ []) do
    @opts
    |> Keyword.put(:sources, strong_sources())
    |> Keyword.put(:http_cache, mode: :enabled)
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

  defp counting_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {OriginImage, test_pid: self()}]}
    ]
  end

  defp conditional_pair do
    path = "/images/beach.jpg?twic=v1/resize=64/output=jpeg"

    [:framework, :dialect]
    |> Enum.map(fn arm ->
      first = call_arm(arm, :get, path, strong_opts(), [])
      etag = header(first, "etag")

      opts =
        strong_opts(
          sources: should_not_fetch_sources(),
          cache: {ImgproxyWireConformanceTest.CacheProbe, []}
        )

      call_arm(arm, :get, path, opts, [{"if-none-match", etag}])
    end)
    |> List.to_tuple()
  end

  defp cache_hit_pair do
    path = "/images/beach.jpg?twic=v1/contain=80x80/output=jpeg"

    [:framework, :dialect]
    |> Enum.map(fn arm ->
      table = :ets.new(:twicpics_cross_arm_cache, [:set, :public])

      opts =
        strong_opts(
          sources: counting_sources(),
          cache: {ImgproxyWireConformanceTest.CacheProbe, store: table}
        )

      miss = call_arm(arm, :get, path, opts, [])
      assert miss.status == 200
      assert_receive :origin_fetch

      hit = call_arm(arm, :get, path, opts, [])
      refute_receive :origin_fetch
      hit
    end)
    |> List.to_tuple()
  end

  defp assert_observable_parity(framework, dialect) do
    assert framework.status == dialect.status

    for name <- ["content-type", "vary"] do
      assert header(framework, name) == header(dialect, name)
    end

    assert header(framework, "cache-control") == @host_cache_control
    assert header(dialect, "cache-control") == @host_cache_control
    assert etag_kind(framework) == etag_kind(dialect)
  end

  defp etag_kind(conn) do
    case header(conn, "etag") do
      nil ->
        :absent

      etag when is_binary(etag) ->
        {:strong, String.starts_with?(etag, "\"") and String.ends_with?(etag, "\"")}
    end
  end

  defp assert_decoded_parity(framework, dialect) do
    assert decoded_material(framework) == decoded_material(dialect)
  end

  defp decoded_material(conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {:ok, pixels} = VipsImage.write_to_binary(image)

    {
      Image.width(image),
      Image.height(image),
      Image.bands(image),
      VipsImage.header_value(image, "format"),
      pixels
    }
  end

  defp vary_names(conn) do
    conn
    |> Plug.Conn.get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  defp header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  test "explicit PNG has exact cross-arm bytes, decoded pixels, and stable headers" do
    {framework, dialect} =
      call_both("/images/beach.jpg?twic=v1/resize=64/output=png", strong_opts())

    assert_observable_parity(framework, dialect)
    assert_decoded_parity(framework, dialect)
    assert framework.resp_body == dialect.resp_body
  end

  test "explicit JPEG has cross-arm decoded pixels and stable headers" do
    {framework, dialect} =
      call_both("/images/beach.jpg?twic=v1/cover=80x60/output=jpeg", strong_opts())

    assert_observable_parity(framework, dialect)
    assert_decoded_parity(framework, dialect)
  end

  test "automatic negotiation has cross-arm pixels and Accept representation headers" do
    {framework, dialect} =
      call_both(
        "/images/beach.jpg?twic=v1/resize=64/output=auto",
        strong_opts(),
        [{"accept", "image/webp"}]
      )

    assert_observable_parity(framework, dialect)
    assert_decoded_parity(framework, dialect)
    assert header(framework, "content-type") == "image/webp"
    assert "accept" in vary_names(framework)
  end

  test "parse errors have cross-arm status and stable response headers" do
    {framework, dialect} =
      call_both("/images/beach.jpg?twic=v1/unknown=1", strong_opts())

    assert framework.status == 400
    assert_observable_parity(framework, dialect)
  end

  test "strong conditional requests have cross-arm 304 observables" do
    {framework, dialect} = conditional_pair()

    assert framework.status == 304
    assert framework.resp_body == ""
    assert dialect.resp_body == ""
    assert_observable_parity(framework, dialect)
  end

  test "HEAD has cross-arm GET metadata and no body" do
    {framework, dialect} =
      call_both(
        :head,
        "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
        strong_opts(),
        []
      )

    assert framework.status == 200
    assert framework.resp_body == ""
    assert dialect.resp_body == ""
    assert_observable_parity(framework, dialect)
  end

  test "cache hits have cross-arm decoded pixels and stable headers" do
    {framework, dialect} = cache_hit_pair()

    assert_observable_parity(framework, dialect)
    assert_decoded_parity(framework, dialect)
  end

  test "debug responses compare stable facts without comparing timing values" do
    {framework, dialect} =
      call_both(
        "/images/beach.jpg?twic=v1/resize=64/output=jpeg/debug=1",
        strong_opts(allow_debug_headers: true)
      )

    assert_observable_parity(framework, dialect)
    assert_decoded_parity(framework, dialect)

    for name <- @stable_debug_headers do
      assert header(framework, name) == header(dialect, name)
    end

    assert is_binary(header(framework, "server-timing"))
    assert is_binary(header(dialect, "server-timing"))
  end
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

defmodule TwicPicsWireConformanceTest.Arm do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics

  @dialect_keys ImagePipe.Dialect.SharedConfig.keys() ++
                  [:detector, :detector_required, :allow_debug_headers]

  def call(:framework, conn, opts) do
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  def call(:dialect, conn, opts) do
    TwicPics.call(
      conn,
      TwicPics.init(translate_opts(opts))
    )
  end

  defp translate_opts(opts) do
    {twicpics, rest} = Keyword.pop(opts, :twicpics, [])

    rest
    |> Keyword.take(@dialect_keys)
    |> Keyword.merge(twicpics)
    |> put_storage_inputs(cache_storage_inputs(rest))
  end

  defp cache_storage_inputs(opts) do
    case Keyword.get(opts, :cache) do
      {_adapter, cache_opts} when is_list(cache_opts) ->
        headers = Enum.map(Keyword.get(cache_opts, :key_headers, []), &{:header, &1})
        cookies = Enum.map(Keyword.get(cache_opts, :key_cookies, []), &{:cookie, &1})
        headers ++ cookies

      _disabled_or_invalid ->
        []
    end
  end

  defp put_storage_inputs(opts, []), do: opts

  defp put_storage_inputs(opts, storage_inputs),
    do: Keyword.put(opts, :storage_inputs, storage_inputs)
end

for {arm, suffix} <- [{:framework, Framework}, {:dialect, Dialect}] do
  defmodule Module.concat(ImagePipe.TwicPicsWireConformanceTest, suffix) do
    use ExUnit.Case, async: true

    import Plug.Test

    alias ImagePipe.SourceTest.RootHTTPAdapter
    alias TwicPicsWireConformanceTest.Arm
    alias TwicPicsWireConformanceTest.ExifOrientedOrigin
    alias TwicPicsWireConformanceTest.OriginImage
    alias TwicPicsWireConformanceTest.OriginShouldNotFetch

    @arm arm

    @opts [
      parser: ImagePipe.Parser.TwicPics,
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

      Arm.call(@arm, conn, opts)
    end

    defp strong_opts(extra \\ []) do
      @opts
      |> Keyword.put(:sources, strong_sources())
      |> Keyword.put(:http_cache, mode: :enabled)
      |> Keyword.merge(extra)
    end

    defp strong_sources do
      [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           req_options: [plug: OriginImage]}
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
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: ExifOrientedOrigin]}
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
        call(
          "/images/beach.jpg?twic=v1/focus=bottom-right/contain=400x400/crop=50x50/output=jpeg"
        )

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
        call(
          "/images/beach.jpg?twic=v1/focus=0x0/crop=2000x2000@1000x500/crop=400x400/output=jpeg"
        )

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

    test "explicit output bypasses negotiation; auto sets Vary: Accept" do
      explicit = call("/images/beach.jpg?twic=v1/resize=100/output=avif")
      assert Plug.Conn.get_resp_header(explicit, "content-type") == ["image/avif"]

      auto =
        call(
          "/images/beach.jpg?twic=v1/resize=100/output=auto",
          @opts,
          [{"accept", "image/webp"}]
        )

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
            cache:
              {ImgproxyWireConformanceTest.CacheProbe,
               key_headers: ["x-tenant"], key_cookies: ["session"]}
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
        prefix = [:twicpics_wire_contract, @arm]
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
          Keyword.put(@opts, :twicpics,
            jpeg_options: %ImagePipe.Plan.Output.JpegOptions{interlace: true}
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

      # The nil-point centred fallback under EXIF with an odd extent difference:
      # compensate_crop's :deferred clause sets center_bias so the discarded pixel
      # lands on the intended display side (#146 Bug 2). Pin the current decoded-
      # pixel relation between the no-focus fallback and an explicit centre focus
      # (the fp path ignores center_bias, so these may legitimately differ by one
      # pixel row/column — record whichever relation currently holds and pin it).
      test "nil-point centred fallback under EXIF quarter turn (odd cover box)" do
        fallback = call("/images/oriented.jpg?twic=v1/cover=15x15/output=png", exif_opts())

        explicit =
          call("/images/oriented.jpg?twic=v1/focus=center/cover=15x15/output=png", exif_opts())

        assert dimensions(fallback) == {15, 15}
        assert dimensions(explicit) == {15, 15}
        # Observed relation (current code): the decoded pixels differ by one pixel
        # row/column — the legitimate center_bias divergence called out above (the
        # fp path taken by an explicit focus=center ignores center_bias, while the
        # nil-point :deferred fallback sets it). Pin that divergence via decoded
        # pixels, not encoded bytes (encode-time byte nondeterminism makes raw body
        # comparison unreliable, as noted elsewhere in this file).
        refute average(fallback) == average(explicit)
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
end
