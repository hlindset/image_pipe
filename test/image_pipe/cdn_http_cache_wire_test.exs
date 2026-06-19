defmodule ImagePipe.CDNHTTPCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

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

  setup do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    [opts: opts]
  end

  test "stable public route emits cache-control and etag", %{opts: opts} do
    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "matching if-none-match returns before cache lookup and source fetch", %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :get
      |> conn("/_/plain/beach.jpg")
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
    get = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    flush_messages()

    head = ImagePipe.Plug.call(conn(:head, "/_/plain/beach.jpg"), opts)

    assert head.status == 200
    assert get_resp_header(head, "etag") != []
    assert get_resp_header(head, "etag") == get_resp_header(get, "etag")
    assert get_resp_header(head, "cache-control") == get_resp_header(get, "cache-control")
  end

  test "matching if-none-match on a HEAD returns 304 before cache lookup and source fetch",
       %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :head
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert get_resp_header(conn, "etag") == [etag]
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "existing vary is merged in the final response", %{opts: opts} do
    conn =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("accept", "image/webp")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
  end

  test "request cookie does not change generated headers or source fetch", %{opts: opts} do
    without_cookie = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    [etag] = get_resp_header(without_cookie, "etag")

    flush_messages()

    with_cookie =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("cookie", "session=private")
      |> ImagePipe.Plug.call(opts)

    assert get_resp_header(with_cookie, "etag") == [etag]
    refute "cookie" in vary_tokens(with_cookie)
    assert_received :source_fetch_called
  end

  test "response cookies suppress generated public cache headers", %{opts: opts} do
    conn =
      :get
      |> conn("/_/plain/beach.jpg")
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
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"ip1-")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    refute_received :source_fetch_called
  end

  test "detector identity change moves the generated ETag end-to-end (#181 regression)", _ctx do
    etag_for = fn identity ->
      opts =
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled],
          detector: ImagePipe.Test.FakeDetector,
          identity: identity
        )

      conn =
        ImagePipe.Plug.call(
          conn(:get, "/_/rs:fill:50:50/g:obj:face/f:jpeg/plain/beach.jpg"),
          opts
        )

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      etag
    end

    assert etag_for.(:model_v1) != etag_for.(:model_v2)
  end

  test "commit_sink raise still delivers the complete body, byte-identical to a clean cache (#183)" do
    url = "/_/rs:fill:50:50/f:jpeg/plain/beach.jpg"

    clean =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled]
        )
      )

    raising =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
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
  # identity before this was :center (the order-invariance test below). A
  # gravity-derived guide (focal/smart/detect/anchor/carried) exercises the
  # KeyData.guide_data clauses end-to-end — a missing clause 500s here instead of
  # staying green. Focal needs no detector, so the 200 body path executes too.
  test "guide-bearing focal gravity emits an etag on the strong-identity path", %{opts: opts} do
    conn =
      ImagePipe.Plug.call(
        conn(:get, "/_/rt:fill/w:200/h:100/g:fp:0.3:0.7/plain/beach.jpg"),
        opts
      )

    assert conn.status == 200
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "TwicPics carried-focus cover emits an etag on the strong-identity path" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.TwicPics,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    conn =
      ImagePipe.Plug.call(
        conn(:get, "/beach.jpg?twic=v1/focus=20x10/cover=100x100"),
        opts
      )

    assert conn.status == 200
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "transform option order variants produce the same etag", %{opts: opts} do
    left =
      ImagePipe.Plug.call(
        conn(:get, "/_/rs:fill:0:400:0/c:0.5:0.5/plain/beach.jpg"),
        opts
      )

    right =
      ImagePipe.Plug.call(
        conn(:get, "/_/c:0.5:0.5/rs:fill:0:400:0/plain/beach.jpg"),
        opts
      )

    assert get_resp_header(left, "etag") == get_resp_header(right, "etag")
  end

  test "stricter result limit does not change generated etag", %{
    opts: opts
  } do
    loose =
      ImagePipe.Plug.call(
        conn(:get, "/_/el:1/w:64/f:jpeg/plain/beach.jpg"),
        Keyword.merge(opts,
          max_result_width: 64,
          max_result_height: 8_192,
          max_result_pixels: 40_000_000
        )
      )

    assert loose.status == 200
    assert [etag] = get_resp_header(loose, "etag")
    flush_messages()

    strict_opts =
      Keyword.merge(opts,
        max_result_width: 32,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      )

    strict =
      :get
      |> conn("/_/el:1/w:64/f:jpeg/plain/beach.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(strict_opts)

    assert strict.status == 304
    assert strict.resp_body == ""
    assert get_resp_header(strict, "etag") == [etag]
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  # #124: color_profile participates in the ETag.
  # scp:0 (color_profile: :preserve_source) and scp:1 (color_profile: :strip)
  # produce different output bytes, so they must produce different ETags.
  # The cachebuster changes the storage key but must NOT change the ETag
  # (adding a cachebuster yields identical output bytes → must not force re-download).
  test "scp:0 and scp:1 produce distinct etags", %{opts: opts} do
    scp0_conn = ImagePipe.Plug.call(conn(:get, "/_/scp:0/plain/beach.jpg"), opts)
    assert_received {:cache_get, key_scp0}

    flush_messages()

    scp1_conn = ImagePipe.Plug.call(conn(:get, "/_/scp:1/plain/beach.jpg"), opts)
    assert_received {:cache_get, key_scp1}

    assert scp0_conn.status == 200
    assert scp1_conn.status == 200

    assert [scp0_etag] = get_resp_header(scp0_conn, "etag")
    assert [scp1_etag] = get_resp_header(scp1_conn, "etag")

    refute scp0_etag == scp1_etag,
           "scp:0 and scp:1 must produce different ETags (different output bytes)"

    refute key_scp0 == key_scp1,
           "scp:0 and scp:1 must use different cache keys"
  end

  test "adding a cachebuster changes the cache key but not the etag", %{opts: opts} do
    base_conn = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    assert_received {:cache_get, key1}

    flush_messages()

    busted_conn = ImagePipe.Plug.call(conn(:get, "/_/cb:v2/plain/beach.jpg"), opts)
    assert_received {:cache_get, key2}

    assert base_conn.status == 200
    assert busted_conn.status == 200

    assert [base_etag] = get_resp_header(base_conn, "etag")
    assert [busted_etag] = get_resp_header(busted_conn, "etag")

    assert base_etag == busted_etag,
           "cachebuster must not change the ETag (same bytes, different storage slot)"

    assert key1 != key2,
           "cachebuster must change the cache key (different storage slot)"
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
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
  end
end
