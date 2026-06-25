defmodule ImagePipe.DebugHeadersWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

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

  # ---------------------------------------------------------------------------
  # Harness helpers
  # ---------------------------------------------------------------------------

  # Base mount options using RootHTTPAdapter. Mirrors @default_opts +
  # origin_opts/1 from imgproxy_wire_conformance_test.exs.
  defp base_opts(overrides) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ]
    ]
    |> Keyword.merge(overrides)
  end

  # Mount options using StableOrigin so the HTTP cache generates an ETag
  # (requires byte-identity in the resolved source). Used by G2 tests.
  defp stable_opts(overrides) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [path: {StableOrigin, []}],
      http_cache: [mode: :enabled]
    ]
    |> Keyword.merge(overrides)
  end

  # Mount options pointing at the large SSIM2 origin for G3.
  defp large_ssim2_opts(overrides) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: LargeSsim2OriginImage]}
      ]
    ]
    |> Keyword.merge(overrides)
  end

  # An imgproxy URL that resizes beach.jpg to 400×300. Produces a non-trivial
  # pipeline (rs:fit) so x-imagepipe-pipeline is populated.
  defp request_path, do: "/_/rs:fit:400:300/f:jpeg/plain/images/beach.jpg"

  # An imgproxy URL for the stable source — plain (no resize) so the path
  # works with StableOrigin's path-only fetch.
  defp stable_request_path, do: "/_/rs:fit:400:300/f:jpeg/plain/beach.jpg"

  # An imgproxy URL that triggers an ssim2 quality search (autoquality:ssim2).
  # Mirrors the "autoquality:ssim2 yields a decodable JPEG" test from the
  # conformance suite. No resize so the full >6 MP frame goes to the encoder.
  defp autoquality_path, do: "/_/f:jpeg/autoquality:ssim2:85:50:95/plain/images/large.jpg"

  defp call(path, opts) do
    conn(:get, path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp header(conn, name) do
    conn |> get_resp_header(name) |> List.first()
  end

  # ---------------------------------------------------------------------------
  # G1 — wire-level miss-path gate tests
  # ---------------------------------------------------------------------------

  test "no debug headers without _debug param, even when allow_debug_headers: true" do
    conn = call(request_path(), base_opts(allow_debug_headers: true))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
    assert header(conn, "server-timing") == nil
  end

  test "no debug headers with _debug=1 when allow_debug_headers: false (default)" do
    conn = call(request_path() <> "?_debug=1", base_opts(allow_debug_headers: false))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
  end

  test "debug headers present with _debug=1 when allow_debug_headers: true (cache miss)" do
    conn = call(request_path() <> "?_debug=1", base_opts(allow_debug_headers: true))

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
    test "_debug=1 does not change the generated ETag" do
      opts = stable_opts(allow_debug_headers: true)

      plain = call(stable_request_path(), opts)
      debug = call(stable_request_path() <> "?_debug=1", opts)

      plain_etag = header(plain, "etag")
      debug_etag = header(debug, "etag")

      assert is_binary(plain_etag), "expected plain request to carry an ETag"

      assert plain_etag == debug_etag,
             "expected _debug=1 not to change ETag; got plain=#{inspect(plain_etag)} debug=#{inspect(debug_etag)}"
    end

    test "conditional GET with _debug=1 still 304s against the plain ETag" do
      opts = stable_opts(allow_debug_headers: true)
      plain = call(stable_request_path(), opts)
      etag = header(plain, "etag")

      assert is_binary(etag), "expected initial request to carry an ETag"

      conn =
        conn(:get, stable_request_path() <> "?_debug=1")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))

      assert conn.status == 304,
             "expected conditional GET with _debug=1 to 304; got #{conn.status}"
    end
  end

  # ---------------------------------------------------------------------------
  # G3 — autoquality AQ-* header coverage
  # ---------------------------------------------------------------------------

  test "autoquality ssim2 request emits AQ-* headers with _debug=1" do
    opts =
      large_ssim2_opts(
        allow_debug_headers: true,
        imgproxy: [autoquality_method: :ssimulacra2, autoquality_target: 85]
      )

    conn = call(autoquality_path() <> "?_debug=1", opts)

    assert conn.status == 200

    assert header(conn, "x-imagepipe-aq-metric") == "ssimulacra2"
    assert header(conn, "x-imagepipe-aq-iterations") =~ ~r/^\d+$/
    outcome = header(conn, "x-imagepipe-aq-outcome")
    assert outcome in ["hit", "best_effort", "skipped", "native"]
    assert header(conn, "x-imagepipe-aq-quality-min") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-aq-quality-max") =~ ~r/^\d+$/
  end
end
