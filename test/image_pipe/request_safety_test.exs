defmodule ImagePipe.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.RequestSafetyTest.CacheProbe
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

  test "parse validation failures return before source fetch" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/rotate=370/format=jpeg/src/images/cat.jpg"),
        ImagePipe.Plug.init(sources: [path: {ValidAdapter, []}])
      )

    assert conn.status == 400
  end

  test "invalid composition parse failures return before source identity, cache lookup, and origin" do
    for path <- [
          "/w=bad/format=jpeg/src/images/cat.jpg",
          "/rotate=370/format=jpeg/src/images/cat.jpg",
          "/region=0,0,0,100/format=jpeg/src/images/cat.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(
          conn(:get, path),
          ImagePipe.Plug.init(
            sources: [path: {ValidAdapter, []}],
            cache: {CacheProbe, []}
          )
        )

      assert conn.status == 400
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "invalid native options return before source identity cache lookup and origin" do
    for path <- [
          "/format=invalid/src/images/cat.jpg",
          "/q=invalid/src/images/cat.jpg",
          "/region=0,0,0,100/format=jpeg/src/images/cat.jpg",
          "/region=0,0,100,-1pct/src/images/cat.jpg",
          "/crop=0,100/src/images/cat.jpg",
          "/crop=100,-1pct/src/images/cat.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(
          conn(:get, path),
          ImagePipe.Plug.init(
            sources: [path: {DenyingSourceAdapter, []}],
            cache: {CacheProbe, []}
          )
        )

      assert conn.status == 400
      refute_received :source_resolve
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "invalid native size requests return before source identity and cache work" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/w=0/format=jpeg/src/images/cat.jpg"),
        ImagePipe.Plug.init(
          sources: [path: {ValidAdapter, []}],
          cache: {CacheProbe, []}
        )
      )

    assert conn.status == 400
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "source resolution failures return before cache lookup and fetch" do
    opts =
      ImagePipe.Plug.init(
        sources: [path: {DenyingSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/format=jpeg/src/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    assert_received :source_resolve
    refute_received {:source_fetch, _fetch}
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "source runtime options pass body limits and runtime metadata without adapter or cache config" do
    opts =
      ImagePipe.Plug.init(
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []},
        max_body_bytes: 1_000_000
      )

    conn = ImagePipe.Plug.call(conn(:get, "/format=jpeg/src/images/cat.jpg"), opts)

    assert conn.status == 200
    assert_received {:source_resolve_runtime_opts, resolve_runtime_opts}
    assert_received {:source_fetch_runtime_opts, fetch_runtime_opts}

    assert resolve_runtime_opts == fetch_runtime_opts

    for runtime_opts <- [resolve_runtime_opts, fetch_runtime_opts] do
      assert Keyword.fetch!(runtime_opts, :max_body_bytes) == 1_000_000
      assert Keyword.fetch!(runtime_opts, :telemetry_prefix) == [:image_pipe]

      refute Keyword.has_key?(runtime_opts, :cache)
      refute Keyword.has_key?(runtime_opts, :sources)
    end
  end

  test "source fetch errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        sources: [path: {FetchErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/format=jpeg/src/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end

  test "deferred source stream errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        sources: [path: {StreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/format=jpeg/src/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "incomplete source response"
    refute_received :cache_put
  end

  test "cache miss does not write after deferred source stream errors" do
    opts =
      ImagePipe.Plug.init(
        sources: [path: {CacheableStreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/format=jpeg/src/images/cat.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "incomplete source response"
    assert_received :cache_lookup
    refute_received :cache_put
  end
end
