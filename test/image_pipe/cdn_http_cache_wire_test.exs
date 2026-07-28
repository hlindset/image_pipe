defmodule ImagePipe.CDNHTTPCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Dialect.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Parser.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Test.AutomaticIIIFParser
  alias ImagePipe.Test.GuidedIIIFParser

  defp iiif_resolver do
    {StaticResolver, map: %{"img" => %SourcePath{segments: ["beach.jpg"]}}}
  end

  defmodule StableSource do
    @behaviour ImagePipe.Source

    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :stable_test)}

    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :path, root: "wire", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{
           byte_identity: {:strong, [kind: :path, root: "wire", path: path]},
           stable?: true
         },
         fetch: [path: path]
       }}
    end

    def fetch(_resolved, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test_pid), :source_fetch_called)
      {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
    end
  end

  defmodule CacheProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      :miss
    end

    def open_sink(%Key{}, metadata, opts),
      do: {:ok, %{metadata: metadata, chunks: [], opts: opts}}

    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = %Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }

      send(Keyword.fetch!(state.opts, :test_pid), {:cache_put, entry})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CacheHitProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def open_sink(_key, _metadata, _opts), do: raise("cache hit should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache hit should not write")
    def commit_sink(_state, _opts), do: raise("cache hit should not write")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule RaisingCommitProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, _metadata, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: raise("commit boom")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule EtaglessCachedSource do
    @behaviour ImagePipe.Source

    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :etagless_test)}

    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :path, root: "wire-etagless", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
         fetch: [path: path]
       }}
    end

    def fetch(_resolved, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test_pid), :source_fetch_called)
      {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
    end
  end

  test "guided IIIF test parser rewrites one real crop to the selected product-neutral guide" do
    opts = GuidedIIIFParser.validate_options!(iiif: [resolver: iiif_resolver()])

    focal_request = conn(:get, "/img/square/max/0/default.jpg?guide=focal")
    face_request = conn(:get, "/img/square/max/0/default.jpg?guide=face_assist")

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = baseline | _]}]}} =
             IIIF.parse(focal_request, opts)

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = focal | _]}]}} =
             GuidedIIIFParser.parse(focal_request, opts)

    assert focal == %CropGuided{
             baseline
             | guide: {:focal, {:ratio, 3, 10}, {:ratio, 7, 10}}
           }

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = face | _]}]}} =
             GuidedIIIFParser.parse(face_request, opts)

    assert face == %CropGuided{baseline | guide: {:smart, :face_assist}}
  end

  test "guided IIIF test parser delegates invalid input unchanged" do
    opts = GuidedIIIFParser.validate_options!(iiif: [resolver: iiif_resolver()])
    request = conn(:get, "/img/full/bad/0/default.jpg?guide=focal")

    assert GuidedIIIFParser.parse(request, opts) == IIIF.parse(request, opts)
  end

  setup do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    automatic_opts =
      ImagePipe.Plug.init(
        parser: AutomaticIIIFParser,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    [opts: opts, automatic_opts: automatic_opts]
  end

  test "stable public route emits cache-control and etag", %{opts: opts} do
    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "matching if-none-match returns before cache lookup and source fetch", %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [etag]
    assert get_resp_header(conn, "content-type") == []
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "HEAD emits the same cache-control and etag as GET", %{opts: opts} do
    get = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)
    flush_messages()

    head = ImagePipe.Plug.call(conn(:head, "/img/full/max/0/default.jpg"), opts)

    assert head.status == 200
    assert get_resp_header(head, "etag") != []
    assert get_resp_header(head, "etag") == get_resp_header(get, "etag")
    assert get_resp_header(head, "cache-control") == get_resp_header(get, "cache-control")
  end

  test "matching if-none-match on a HEAD returns 304 before cache lookup and source fetch",
       %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :head
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert get_resp_header(conn, "etag") == [etag]
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "existing vary is merged in the final response", %{automatic_opts: opts} do
    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("accept", "image/webp")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
  end

  test "request cookie does not change generated headers or source fetch", %{opts: opts} do
    without_cookie = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)
    [etag] = get_resp_header(without_cookie, "etag")

    flush_messages()

    with_cookie =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("cookie", "session=private")
      |> ImagePipe.Plug.call(opts)

    assert get_resp_header(with_cookie, "etag") == [etag]
    refute "cookie" in vary_tokens(with_cookie)
    assert_received :source_fetch_called
  end

  test "response cookies suppress generated public cache headers", %{opts: opts} do
    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_resp_cookie("session", "abc")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
    assert get_resp_header(conn, "etag") == []
    assert get_resp_header(conn, "set-cookie") != []
  end

  test "internal cache hit returns 200 with current prepared etag" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"ip1-")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    refute_received :source_fetch_called
  end

  test "wildcard if-none-match on a cache miss proceeds and returns 200", %{opts: opts} do
    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", "*")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert conn.resp_body != ""
    # The wildcard did not short-circuit pre-fetch: the request proceeded into the
    # cache lookup and the source fetch, exactly as a request with no precondition.
    assert_received {:cache_get, %Key{}}
    assert_received :source_fetch_called
  end

  test "wildcard if-none-match on an internal cache hit returns 304" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", "*")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"ip1-")
    refute_received :source_fetch_called
  end

  test "wildcard if-none-match on a HEAD internal cache hit returns 304" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn =
      :head
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", "*")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    refute_received :source_fetch_called
  end

  test "wildcard if-none-match returns 304 on a cache hit even without a generated etag" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {EtaglessCachedSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", "*")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == []
    refute_received :source_fetch_called
  end

  test "if-none-match mixing an explicit tag with a wildcard collapses to wildcard and 304s on a cache hit" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", ~s("ip1-nonmatching", *))
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    refute_received :source_fetch_called
  end

  test "CORS header lands on a cache-hit response when allow_origin is set" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled],
        allow_origin: "https://cdn.test"
      )

    conn = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
    refute_received :source_fetch_called
  end

  test "CORS header lands on a 304 Not Modified response when allow_origin is set" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled],
        allow_origin: "https://cdn.test"
      )

    first = ImagePipe.Plug.call(conn(:get, "/img/full/max/0/default.jpg"), opts)
    [etag] = get_resp_header(first, "etag")
    flush_messages()

    conn =
      :get
      |> conn("/img/full/max/0/default.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
  end

  test "host-set content-disposition is preserved on both miss and cache-hit responses" do
    probe_opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    miss_conn =
      conn(:get, "/img/full/max/0/default.jpg")
      |> put_resp_header("content-disposition", ~s(attachment; filename="custom.jpg"))
      |> ImagePipe.Plug.call(probe_opts)

    assert miss_conn.status == 200

    assert get_resp_header(miss_conn, "content-disposition") == [
             ~s(attachment; filename="custom.jpg")
           ]

    assert_received {:cache_put, %Entry{} = entry}

    hit_opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.IIIF,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    hit_conn =
      conn(:get, "/img/full/max/0/default.jpg")
      |> put_resp_header("content-disposition", ~s(attachment; filename="custom.jpg"))
      |> ImagePipe.Plug.call(hit_opts)

    assert hit_conn.status == 200

    assert get_resp_header(hit_conn, "content-disposition") == [
             ~s(attachment; filename="custom.jpg")
           ]
  end

  test "detector identity change moves the generated ETag end-to-end (#181 regression)", _ctx do
    etag_for = fn identity ->
      opts =
        ImagePipe.Plug.init(
          parser: GuidedIIIFParser,
          iiif: [resolver: iiif_resolver()],
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled],
          detector: ImagePipe.Test.FakeDetector,
          identity: identity
        )

      conn =
        ImagePipe.Plug.call(
          conn(:get, "/img/square/50,50/0/default.jpg?guide=face_assist"),
          opts
        )

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      etag
    end

    assert etag_for.(:model_v1) != etag_for.(:model_v2)
  end

  test "commit_sink raise still delivers the complete body, byte-identical to a clean cache (#183)" do
    url = "/img/full/50,50/0/default.jpg"

    clean =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.IIIF,
          iiif: [resolver: iiif_resolver()],
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled]
        )
      )

    raising =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.IIIF,
          iiif: [resolver: iiif_resolver()],
          sources: [path: {StableSource, test_pid: self()}],
          cache: {RaisingCommitProbe, []},
          http_cache: [mode: :enabled]
        )
      )

    assert clean.status == 200
    assert raising.status == 200
    assert byte_size(raising.resp_body) > 0
    assert raising.resp_body == clean.resp_body
  end

  # #328: the only guide that reached do_generated_etag under a strong byte
  # identity before this was :center. A gravity-derived guide
  # (focal/smart/detect/anchor) exercises the KeyData.guide_data clauses
  # end-to-end — a missing clause 500s here instead of staying green. Focal needs
  # no detector, so the 200 body path executes too.
  test "guide-bearing focal gravity emits an etag on the strong-identity path" do
    opts =
      ImagePipe.Plug.init(
        parser: GuidedIIIFParser,
        iiif: [resolver: iiif_resolver()],
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    conn =
      ImagePipe.Plug.call(
        conn(:get, "/img/square/200,100/0/default.jpg?guide=focal"),
        opts
      )

    assert conn.status == 200
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp vary_tokens(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end
end
