defmodule ImagePipe.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.RequestSafetyTest.InvalidPipelinePlanParser
  alias ImagePipe.RequestSafetyTest.InvalidPlanParser
  alias ImagePipe.SourceTest.ValidAdapter

  defmodule DenyingSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts) do
      send(self(), :source_resolve)
      {:error, {:source, :denied_path}}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts) do
      raise "source should not fetch"
    end
  end

  defmodule FetchErrorSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts) do
      {:ok,
       %ImagePipe.Source.Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, root: "test", path: ["missing.jpg"]],
         internal_cache: :enabled,
         http_cache: :inherit,
         cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
         fetch: :missing
       }}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts), do: {:error, {:source, :not_found}}
  end

  defmodule StreamErrorSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts) do
      {:ok,
       %ImagePipe.Source.Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, root: "test", path: ["stream-fails.jpg"]],
         internal_cache: :disabled,
         http_cache: :inherit,
         cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
         fetch: :stream_fails
       }}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts) do
      stream = Stream.map([:raise], fn _ -> raise "stream failed" end)
      {:ok, %ImagePipe.Source.Response{stream: stream}}
    end
  end

  defmodule CacheableStreamErrorSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts) do
      {:ok,
       %ImagePipe.Source.Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, root: "test", path: ["cacheable-stream-fails.jpg"]],
         internal_cache: :enabled,
         http_cache: :inherit,
         cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
         fetch: :stream_fails
       }}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts) do
      stream = Stream.map([:raise], fn _ -> raise "stream failed" end)
      {:ok, %ImagePipe.Source.Response{stream: stream}}
    end
  end

  test "plug validates product-neutral plan shape before source identity resolution" do
    conn =
      ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        sources: [path: {ValidAdapter, []}]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
  end

  test "invalid product-neutral plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []}
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid pipeline plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPipelinePlanParser,
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []}
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "parser validation failures return before source fetch" do
    conn =
      ImagePipe.Plug.call(conn(:get, "/_/raw/plain/images/cat.jpg"),
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {ValidAdapter, []}]
      )

    assert conn.status == 400
  end

  test "invalid composition parser failures return before source identity, cache lookup, and origin" do
    for path <- [
          "/_/pd:-1/plain/images/cat.jpg",
          "/_/bg:256:0:0/plain/images/cat.jpg",
          "/_/bga:1.1/plain/images/cat.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(conn(:get, path),
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {ValidAdapter, []}],
          cache: {CacheProbe, []}
        )

      assert conn.status == 400
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "invalid imgproxy color effect values return before source identity cache lookup and origin" do
    for path <- [
          "/_/br:256/plain/images/cat.jpg",
          "/_/co:0/plain/images/cat.jpg",
          "/_/sa:-1/plain/images/cat.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(conn(:get, path),
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {DenyingSourceAdapter, []}],
          cache: {CacheProbe, []}
        )

      assert conn.status == 400
      refute_received :source_resolve
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "expired imgproxy requests return before source identity and cache work" do
    conn =
      ImagePipe.Plug.call(conn(:get, "/_/exp:100/plain/images/cat.jpg"),
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {ValidAdapter, []}],
        clock: fn -> DateTime.from_unix!(101) end,
        cache: {CacheProbe, []}
      )

    assert conn.status == 400
    assert conn.resp_body =~ "expired_request"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid imgproxy signatures return before source identity, cache lookup, and origin" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {ValidAdapter, []}],
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ],
          cache: {CacheProbe, []}
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid imgproxy signatures return before source fetch with a valid root URL" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {ValidAdapter, []}],
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ]
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
  end

  test "invalid imgproxy signatures return before option parsing at the plug boundary" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/invalid/raw/plain/images/cat.jpg"),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {ValidAdapter, []}],
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ]
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
    refute conn.resp_body =~ "unsupported_option"
  end

  test "invalid pipeline plans return before source resolution" do
    opts =
      ImagePipe.Plug.init(
        parser: InvalidPipelinePlanParser,
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received {:source_resolve, _source}
    refute_received {:source_fetch, _fetch}
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "source resolution failures return before cache lookup and fetch" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {DenyingSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    assert_received :source_resolve
    refute_received {:source_fetch, _fetch}
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "source runtime options pass body limits and runtime metadata without parser or cache config" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []},
        max_body_bytes: 1_000_000,
        receive_timeout: 456,
        connect_timeout: 789,
        request_id: "req-1"
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/cat.jpg"), opts)

    assert conn.status == 200
    assert_received {:source_resolve_runtime_opts, resolve_runtime_opts}
    assert_received {:source_fetch_runtime_opts, fetch_runtime_opts}
    assert resolve_runtime_opts == fetch_runtime_opts

    assert Keyword.fetch!(fetch_runtime_opts, :max_body_bytes) == 1_000_000
    assert Keyword.fetch!(fetch_runtime_opts, :receive_timeout) == 456
    assert Keyword.fetch!(fetch_runtime_opts, :connect_timeout) == 789
    assert Keyword.fetch!(fetch_runtime_opts, :request_id) == "req-1"

    refute Keyword.has_key?(fetch_runtime_opts, :parser)
    refute Keyword.has_key?(fetch_runtime_opts, :cache)
    refute Keyword.has_key?(fetch_runtime_opts, :sources)
  end

  test "source fetch errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {FetchErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/missing.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end

  test "deferred source stream errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/stream-fails.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end

  test "cache miss does not write after deferred source stream errors" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {CacheableStreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/images/cacheable-stream-fails.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    assert_received :cache_lookup
    refute_received :cache_put
  end
end
