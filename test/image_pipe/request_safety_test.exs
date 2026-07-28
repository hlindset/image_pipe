defmodule ImagePipe.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Dialect.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.RequestSafetyTest.InvalidPipelinePlanDialect
  alias ImagePipe.RequestSafetyTest.InvalidPlanDialect
  alias ImagePipe.SourceTest.ValidAdapter

  # A static IIIF resolver mapping the opaque identifier "img" to a source path.
  # The mock source adapters below (ValidAdapter, DenyingSourceAdapter, etc.)
  # ignore the resolved source entirely, so the mapped path is a placeholder —
  # only the identifier needs to classify successfully.
  defp iiif_resolver do
    {StaticResolver, map: %{"img" => %SourcePath{segments: ["images", "cat.jpg"]}}}
  end

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
      ImagePipe.Plug.call(
        conn(:get, "/_/plain/images/cat.jpg"),
        ImagePipe.Plug.init(dialect: InvalidPlanDialect, sources: [path: {ValidAdapter, []}])
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
  end

  test "invalid product-neutral plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/_/plain/images/cat.jpg"),
        ImagePipe.Plug.init(
          dialect: InvalidPlanDialect,
          sources: [path: {ValidAdapter, []}],
          cache: {CacheProbe, []}
        )
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid pipeline plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/_/plain/images/cat.jpg"),
        ImagePipe.Plug.init(
          dialect: InvalidPipelinePlanDialect,
          sources: [path: {ValidAdapter, []}],
          cache: {CacheProbe, []}
        )
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "parse validation failures return before source fetch" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/img/full/max/370/default.jpg"),
        ImagePipe.Plug.init(
          dialect: ImagePipe.Dialect.IIIF,
          resolver: iiif_resolver(),
          sources: [path: {ValidAdapter, []}]
        )
      )

    assert conn.status == 400
  end

  test "invalid composition parse failures return before source identity, cache lookup, and origin" do
    for path <- [
          "/img/full/bad/0/default.jpg",
          "/img/full/max/370/default.jpg",
          "/img/0,0,0,100/max/0/default.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(
          conn(:get, path),
          ImagePipe.Plug.init(
            dialect: ImagePipe.Dialect.IIIF,
            resolver: iiif_resolver(),
            sources: [path: {ValidAdapter, []}],
            cache: {CacheProbe, []}
          )
        )

      assert conn.status == 400
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "invalid iiif grammar tokens return before source identity cache lookup and origin" do
    for path <- [
          "/img/full/max/0/default.tif",
          "/img/full/max/0/notaquality.jpg",
          "/img/0,0,0,100/max/0/default.jpg"
        ] do
      conn =
        ImagePipe.Plug.call(
          conn(:get, path),
          ImagePipe.Plug.init(
            dialect: ImagePipe.Dialect.IIIF,
            resolver: iiif_resolver(),
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

  test "invalid iiif size requests return before source identity and cache work" do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/img/full/0,/0/default.jpg"),
        ImagePipe.Plug.init(
          dialect: ImagePipe.Dialect.IIIF,
          resolver: iiif_resolver(),
          sources: [path: {ValidAdapter, []}],
          cache: {CacheProbe, []}
        )
      )

    assert conn.status == 400
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid pipeline plans return before source resolution" do
    opts =
      ImagePipe.Plug.init(
        dialect: InvalidPipelinePlanDialect,
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
        dialect: ImagePipe.Dialect.IIIF,
        resolver: iiif_resolver(),
        sources: [path: {DenyingSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    assert_received :source_resolve
    refute_received {:source_fetch, _fetch}
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "the mount's body limit reaches the source adapter identically on resolve and fetch" do
    opts =
      ImagePipe.Plug.init(
        dialect: ImagePipe.Dialect.IIIF,
        resolver: iiif_resolver(),
        sources: [path: {ValidAdapter, []}],
        cache: {CacheProbe, []},
        max_body_bytes: 1_000_000
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 200
    assert_received {:source_resolve_runtime_opts, resolve_runtime_opts}
    assert_received {:source_fetch_runtime_opts, fetch_runtime_opts}

    for runtime_opts <- [resolve_runtime_opts, fetch_runtime_opts] do
      assert Keyword.fetch!(runtime_opts, :max_body_bytes) == 1_000_000
      assert Keyword.fetch!(runtime_opts, :telemetry_prefix) == [:image_pipe]
    end
  end

  test "source fetch errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        dialect: ImagePipe.Dialect.IIIF,
        resolver: iiif_resolver(),
        sources: [path: {FetchErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end

  test "deferred source stream errors return source response errors" do
    opts =
      ImagePipe.Plug.init(
        dialect: ImagePipe.Dialect.IIIF,
        resolver: iiif_resolver(),
        sources: [path: {StreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "incomplete source response"
    refute_received :cache_put
  end

  test "cache miss does not write after deferred source stream errors" do
    opts =
      ImagePipe.Plug.init(
        dialect: ImagePipe.Dialect.IIIF,
        resolver: iiif_resolver(),
        sources: [path: {CacheableStreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "incomplete source response"
    assert_received :cache_lookup
    refute_received :cache_put
  end
end
