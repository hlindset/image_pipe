defmodule ImagePipe.DebugHeadersWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Parser.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter

  # ---------------------------------------------------------------------------
  # Source stubs
  # ---------------------------------------------------------------------------

  # Mimics ImgproxyWireConformanceTest.OriginImage — serves beach.jpg from priv.
  defmodule OriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # A "stable" source adapter — has known byte-identity so the HTTP cache
  # generates an ETag. Mirrors the StableSource pattern from cdn_http_cache_wire_test.exs.
  defmodule StableOrigin do
    @moduledoc false

    @behaviour ImagePipe.Source

    alias ImagePipe.Source.CacheSemantics
    alias ImagePipe.Source.Resolved
    alias ImagePipe.Source.Response

    @impl ImagePipe.Source
    def validate_options(opts),
      do: {:ok, Keyword.put_new(opts, :telemetry_kind, :debug_wire_test)}

    @impl ImagePipe.Source
    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :debug_wire_test, root: "wire", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{
           byte_identity: {:strong, [kind: :path, root: "wire", path: path]},
           stable?: true
         },
         fetch: [path: path]
       }}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts) do
      {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
    end
  end

  # A >6 MP source for autoquality — zone-plate JPEG. Mirrors
  # LargeSsim2OriginImage from imgproxy_wire_conformance_test.exs.
  defmodule LargeSsim2OriginImage do
    @moduledoc false

    alias Vix.Vips.Operation

    def call(conn, _opts) do
      side = 2800
      {:ok, z} = Operation.zone(side, side)
      {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
      {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
      {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
      {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
      {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
      body = Image.write!(srgb, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Serves beach.jpg and signals the test pid on each fetch, so a cache hit
  # (no re-fetch) is provable. Mirrors CountingOriginImage from the conformance suite.
  defmodule CountingDebugOrigin do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :origin_fetch)
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Harness helpers
  # ---------------------------------------------------------------------------

  # Every id this file's IIIF requests resolve, shared across the opts builders
  # below (a single static map keeps each builder's iiif: base minimal).
  defp iiif_resolver do
    {StaticResolver,
     map: %{
       "beach" => %SourcePath{segments: ["images", "beach.jpg"]},
       "stable" => %SourcePath{segments: ["beach.jpg"]},
       "large" => %SourcePath{segments: ["images", "large.jpg"]}
     }}
  end

  # Merges `overrides` into `base`, deep-merging the `:iiif` key so a caller
  # can override an individual iiif: sub-option (e.g. autoquality_method)
  # without having to restate the resolver.
  defp merge_opts(base, overrides) do
    {iiif_override, overrides} = Keyword.pop(overrides, :iiif, [])

    base
    |> Keyword.update(:iiif, iiif_override, &Keyword.merge(&1, iiif_override))
    |> Keyword.merge(overrides)
  end

  # Base mount options using RootHTTPAdapter. Mirrors @default_opts +
  # origin_opts/1 from imgproxy_wire_conformance_test.exs.
  defp base_opts(overrides) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: iiif_resolver()],
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ]
    ]
    |> merge_opts(overrides)
  end

  # Mount options using StableOrigin so the HTTP cache generates an ETag
  # (requires byte-identity in the resolved source). Used by G2 tests.
  defp stable_opts(overrides) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: iiif_resolver()],
      sources: [path: {StableOrigin, []}],
      http_cache: [mode: :enabled]
    ]
    |> merge_opts(overrides)
  end

  # Mount options pointing at the large SSIM2 origin for G3.
  defp large_ssim2_opts(overrides) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: iiif_resolver()],
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: LargeSsim2OriginImage]}
      ]
    ]
    |> merge_opts(overrides)
  end

  # An IIIF path that resizes beach.jpg to fit within 400×300 (confined size
  # `!400,300`). Produces a non-trivial pipeline so x-imagepipe-pipeline is
  # populated.
  defp request_path, do: "/beach/full/!400,300/0/default.jpg"

  # An IIIF path for the stable source — resized to fit within 400×300 (confined
  # size `!400,300`) so the request works with StableOrigin's path-only fetch.
  defp stable_request_path, do: "/stable/full/!400,300/0/default.jpg"

  # An IIIF path over the large >6 MP origin. autoquality is entirely
  # config-driven (autoquality_method/autoquality_target on the iiif: mount
  # opts) — the IIIF grammar has no URL-level autoquality slot, unlike
  # imgproxy's autoquality: processing option. No resize so the full frame
  # goes to the encoder, mirroring the "autoquality:ssim2 yields a decodable
  # JPEG" test from the conformance suite.
  defp autoquality_path, do: "/large/full/max/0/default.jpg"

  # Mount options with a filesystem cache + a counting origin, so a second
  # request hits the stored entry. Returns {opts, cache_root} for cleanup.
  defp cached_opts(overrides) do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_pipe_debug_hit_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    opts =
      [
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingDebugOrigin, test_pid: self()}]}
        ],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: []}
      ]
      |> merge_opts(overrides)

    {opts, cache_root}
  end

  defp call(path, opts) do
    conn(:get, path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp header(conn, name) do
    conn |> get_resp_header(name) |> List.first()
  end

  # Appends IIIF's `?debug=1` trigger. Unlike imgproxy's debug:1 (which rides
  # in the signed processing-options segment), this is an out-of-band query
  # param — IIIF has no request signing, so it is unprotected by design (see
  # docs/iiif_3_support_matrix.md).
  defp with_debug(path), do: path <> "?debug=1"

  # Any non-"1"/"true" value is read leniently as "off" (never a 400) — see
  # debug_requested?/1 in lib/image_pipe/parser/iiif.ex.
  defp with_non_triggering_debug(path), do: path <> "?debug=0"

  # ---------------------------------------------------------------------------
  # G1 — wire-level miss-path gate tests
  # ---------------------------------------------------------------------------

  test "no debug headers without the debug option, even when allow_debug_headers: true" do
    conn = call(request_path(), base_opts(allow_debug_headers: true))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
    assert header(conn, "server-timing") == nil
  end

  test "debug=0 is not a trigger (only 1/true enable it)" do
    conn = call(with_non_triggering_debug(request_path()), base_opts(allow_debug_headers: true))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
    assert header(conn, "server-timing") == nil
  end

  test "no debug headers with ?debug=1 when allow_debug_headers: false (default)" do
    conn = call(with_debug(request_path()), base_opts(allow_debug_headers: false))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
  end

  test "debug headers present with ?debug=1 when allow_debug_headers: true (cache miss)" do
    conn = call(with_debug(request_path()), base_opts(allow_debug_headers: true))

    assert conn.status == 200

    # Cache status
    assert header(conn, "x-imagepipe-cache") == "miss"

    # Source facts — beach.jpg is a 4000×2667 JPEG
    assert header(conn, "x-imagepipe-source-format") == "jpeg"
    assert header(conn, "x-imagepipe-source-width") == "4000"
    assert header(conn, "x-imagepipe-source-height") == "2667"
    assert header(conn, "x-imagepipe-source-size") =~ ~r/^\d+$/

    # Output facts
    assert header(conn, "x-imagepipe-output-format") != nil
    assert header(conn, "x-imagepipe-output-width") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-output-height") =~ ~r/^\d+$/

    # Pipeline is non-empty for a resize request
    assert header(conn, "x-imagepipe-pipeline") != nil

    # Server-Timing includes total and encode durations
    server_timing = header(conn, "server-timing")
    assert server_timing != nil
    assert server_timing =~ "total;dur="
    assert server_timing =~ "encode;dur="
  end

  # ---------------------------------------------------------------------------
  # G2 — ETag / cache-key invariance
  # Uses StableOrigin so the HTTP cache issues an ETag on the miss path.
  # ---------------------------------------------------------------------------

  describe "cache identity invariance" do
    test "?debug=1 does not change the generated ETag" do
      opts = stable_opts(allow_debug_headers: true)

      plain = call(stable_request_path(), opts)
      debug = call(with_debug(stable_request_path()), opts)

      plain_etag = header(plain, "etag")
      debug_etag = header(debug, "etag")

      assert is_binary(plain_etag), "expected plain request to carry an ETag"

      assert plain_etag == debug_etag,
             "expected ?debug=1 not to change ETag; got plain=#{inspect(plain_etag)} debug=#{inspect(debug_etag)}"
    end

    test "conditional GET with ?debug=1 still 304s against the plain ETag" do
      opts = stable_opts(allow_debug_headers: true)
      plain = call(stable_request_path(), opts)
      etag = header(plain, "etag")

      assert is_binary(etag), "expected initial request to carry an ETag"

      conn =
        conn(:get, with_debug(stable_request_path()))
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))

      assert conn.status == 304,
             "expected conditional GET with ?debug=1 to 304; got #{conn.status}"
    end
  end

  # ---------------------------------------------------------------------------
  # G3 — autoquality AQ-* header coverage
  # ---------------------------------------------------------------------------

  # Real ssim2 autoquality over a large origin image through the full request
  # path; on oversubscribed CI cores it can approach the source-session backstop,
  # so give ExUnit headroom above the default 60s.
  @tag timeout: 180_000
  test "autoquality ssim2 request emits AQ-* headers with ?debug=1" do
    opts =
      large_ssim2_opts(
        allow_debug_headers: true,
        iiif: [autoquality_method: :ssimulacra2, autoquality_target: %{ssimulacra2: 85}]
      )

    conn = call(with_debug(autoquality_path()), opts)

    assert conn.status == 200

    assert header(conn, "x-imagepipe-aq-metric") == "ssimulacra2"
    assert header(conn, "x-imagepipe-aq-iterations") =~ ~r/^\d+$/
    outcome = header(conn, "x-imagepipe-aq-outcome")
    assert outcome in ["hit", "best_effort", "skipped", "native"]
    assert header(conn, "x-imagepipe-aq-quality-min") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-aq-quality-max") =~ ~r/^\d+$/
  end

  # ---------------------------------------------------------------------------
  # Plan 2 — cache hybrid (hit-path replay)
  # ---------------------------------------------------------------------------

  describe "cache hybrid (hit-path replay)" do
    test "a hit replays stored facts, tags hit, and merges a live cache;dur" do
      {opts, cache_root} = cached_opts(allow_debug_headers: true)

      try do
        miss = call(with_debug(request_path()), opts)
        assert miss.status == 200
        assert header(miss, "x-imagepipe-cache") == "miss"
        assert_received :origin_fetch
        miss_source_format = header(miss, "x-imagepipe-source-format")
        miss_output_width = header(miss, "x-imagepipe-output-width")
        assert is_binary(miss_source_format)

        hit = call(with_debug(request_path()), opts)
        assert hit.status == 200
        assert hit.resp_body == miss.resp_body
        refute_received :origin_fetch

        # status flips to hit; the stored facts replay identically
        assert header(hit, "x-imagepipe-cache") == "hit"
        assert header(hit, "x-imagepipe-source-format") == miss_source_format
        assert header(hit, "x-imagepipe-output-width") == miss_output_width
        assert header(hit, "x-imagepipe-cache-key") =~ ~r/^[0-9a-f]{64}$/

        # origin per-stage timings replay; a live cache entry is appended
        server_timing = header(hit, "server-timing")
        assert server_timing =~ "total;dur="
        assert server_timing =~ "cache;dur="
      after
        File.rm_rf!(cache_root)
      end
    end

    test "flipping allow_debug_headers on renders debug headers for an already-cached entry" do
      {base, cache_root} = cached_opts([])

      try do
        # Generated while debug output was OFF — no debug headers, but facts are
        # collected and stored unconditionally.
        off = call(with_debug(request_path()), Keyword.put(base, :allow_debug_headers, false))
        assert off.status == 200
        assert header(off, "x-imagepipe-cache") == nil
        assert header(off, "x-imagepipe-source-format") == nil
        assert_received :origin_fetch

        # Same path, now with the mount flag ON. Reuses the cached entry (flag is
        # not in the key) and replays the stored facts — no origin re-fetch.
        on = call(with_debug(request_path()), Keyword.put(base, :allow_debug_headers, true))
        assert on.status == 200
        assert on.resp_body == off.resp_body
        refute_received :origin_fetch

        assert header(on, "x-imagepipe-cache") == "hit"
        assert header(on, "x-imagepipe-source-format") != nil
        assert header(on, "x-imagepipe-output-width") =~ ~r/^\d+$/
        assert header(on, "server-timing") =~ "cache;dur="
      after
        File.rm_rf!(cache_root)
      end
    end

    test "?debug=1 and a plain request share one cache entry; a plain hit emits no debug headers" do
      {opts, cache_root} = cached_opts(allow_debug_headers: true)

      try do
        first = call(with_debug(request_path()), opts)
        assert first.status == 200
        assert_received :origin_fetch

        # Plain request (no ?debug=1): hits the same entry, identical bytes, and
        # renders NO debug headers despite the stored facts. (A different cache
        # key would miss and re-fetch — so this also proves key invariance.)
        plain = call(request_path(), opts)
        assert plain.status == 200
        assert plain.resp_body == first.resp_body
        refute_received :origin_fetch
        assert header(plain, "x-imagepipe-cache") == nil
        assert header(plain, "x-imagepipe-source-format") == nil
      after
        File.rm_rf!(cache_root)
      end
    end
  end
end
