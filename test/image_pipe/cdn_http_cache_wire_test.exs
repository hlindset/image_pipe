defmodule ImagePipe.CDNHTTPCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Dialect.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Test.AutomaticIIIFDialect
  alias ImagePipe.Test.GuidedIIIFDialect

  @image_path "/img/full/max/0/default.jpg"

  # A quoted, non-empty HTTP strong validator. Deliberately shape-only: the
  # digest scheme is internal, and every value-level property this suite cares
  # about (stability, revalidation, separation) is asserted as a round-trip.
  @strong_validator ~r/^"[^"\s]+"$/

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

  # StableSource with the source-level HTTP-cache decision left to the mount,
  # so `http_cache: [mode: ...]` is the deciding input rather than being
  # overridden by the source's own `:enabled`.
  defmodule InheritingSource do
    @behaviour ImagePipe.Source

    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :inherit_test)}

    def resolve(source, opts, runtime_opts) do
      {:ok, resolved} = StableSource.resolve(source, opts, runtime_opts)
      {:ok, %{resolved | http_cache: :inherit}}
    end

    def fetch(resolved, opts, runtime_opts),
      do: StableSource.fetch(resolved, opts, runtime_opts)
  end

  # `identity` is a detector-adapter option, not a mount option, so the dialect
  # config rejects it as unknown. It is spliced onto the validated config after
  # `ImagePipe.Plug.init/1`, where the detector reads it.
  @post_init_keys [:identity]

  defp init(opts) do
    {post_init, known} = Keyword.split(opts, @post_init_keys)
    Keyword.merge(ImagePipe.Plug.init(known), post_init)
  end

  # The suite's baseline mount: a strong-byte-identity source, a cache probe,
  # and the generated cache-header policy switched on.
  defp mount(overrides \\ []) do
    init(
      Keyword.merge(
        [
          dialect: IIIF,
          resolver: iiif_resolver(),
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled]
        ],
        overrides
      )
    )
  end

  defp get(path, opts, req_headers) do
    :get
    |> conn(path)
    |> put_req_headers(req_headers)
    |> ImagePipe.Plug.call(opts)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  test "the guided IIIF test dialect rewrites one real crop to the selected product-neutral guide" do
    opts = GuidedIIIFDialect.validate_config!(resolver: iiif_resolver())

    focal_request = conn(:get, "/img/square/max/0/default.jpg?guide=focal")
    face_request = conn(:get, "/img/square/max/0/default.jpg?guide=face_assist")

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = baseline | _]}]}} =
             IIIF.parse_plan(focal_request, opts)

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = focal | _]}]}} =
             GuidedIIIFDialect.parse_plan(focal_request, opts)

    assert focal == %CropGuided{
             baseline
             | guide: {:focal, {:ratio, 3, 10}, {:ratio, 7, 10}}
           }

    assert {:ok, %Plan{pipelines: [%{operations: [%CropGuided{} = face | _]}]}} =
             GuidedIIIFDialect.parse_plan(face_request, opts)

    assert face == %CropGuided{baseline | guide: {:smart, :face_assist}}
  end

  test "the guided IIIF test dialect delegates invalid input unchanged" do
    opts = GuidedIIIFDialect.validate_config!(resolver: iiif_resolver())
    request = conn(:get, "/img/full/bad/0/default.jpg?guide=focal")

    assert GuidedIIIFDialect.parse_plan(request, opts) == IIIF.parse_plan(request, opts)
  end

  setup do
    [opts: mount(), automatic_opts: mount(dialect: AutomaticIIIFDialect)]
  end

  test "stable public route emits cache-control and a stable etag", %{opts: opts} do
    conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ @strong_validator

    # The validator is a pure function of the request, so replaying the same
    # request reproduces it byte for byte.
    replay = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    assert get_resp_header(replay, "etag") == [etag]
  end

  test "matching if-none-match returns before cache lookup and source fetch", %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :get
      |> conn(@image_path)
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
    get = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    flush_messages()

    head = ImagePipe.Plug.call(conn(:head, "/img/full/max/0/default.jpg"), opts)

    assert head.status == 200
    assert get_resp_header(head, "etag") != []
    assert get_resp_header(head, "etag") == get_resp_header(get, "etag")
    assert get_resp_header(head, "cache-control") == get_resp_header(get, "cache-control")
  end

  test "matching if-none-match on a HEAD returns 304 before cache lookup and source fetch",
       %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :head
      |> conn(@image_path)
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert get_resp_header(conn, "etag") == [etag]
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "configured storage_inputs header names enter vary, sorted, ahead of Accept" do
    opts =
      mount(
        dialect: AutomaticIIIFDialect,
        storage_inputs: [{:header, "X-Tenant"}, {:cookie, "session"}, {:header, "x-region"}]
      )

    conn = get(@image_path, opts, [{"x-tenant", "a"}, {"x-region", "eu"}])

    assert conn.status == 200
    # Header names normalize to lowercase and sort deterministically, so neither
    # the configured order nor the spelling can move the header; Accept, which
    # the automatic output plan adds, comes last.
    assert get_resp_header(conn, "vary") == ["x-region, x-tenant, Accept"]
    # A configured cookie partitions storage but never enters Vary.
    refute "session" in vary_tokens(conn)
  end

  test "a plain (non-negotiated) mount varies by its storage_inputs headers alone" do
    opts = mount(storage_inputs: [{:header, "x-tenant"}])

    conn = get(@image_path, opts, [{"x-tenant", "a"}])

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["x-tenant"]
  end

  # Delta 14 of the Phase C plan asked whether an automatic output plan can lose
  # `Vary: Accept` by collapsing to an explicit selection. It cannot:
  # `Policy.from_output_plan/3` maps EVERY `%Output{mode: :automatic}` to
  # `policy.mode == :source`, and `Policy.identity_selection/1` only returns
  # `{:explicit, _}` for `policy.mode == {:explicit, _}`. Config can empty
  # `modern_candidates` (disabled auto_* flags, a restricted
  # `output_capabilities`), which yields `:source_negotiated` — still an
  # Accept-varying selection. This pins that invariant at the wire for both
  # levers.
  test "an automatic output plan varies by Accept even with no modern candidates left" do
    for extra <- [
          [auto_avif: false, auto_webp: false, auto_jpeg_xl: false],
          [output_capabilities: %{avif: false, webp: false, jpeg_xl: false}]
        ] do
      opts = mount([dialect: AutomaticIIIFDialect] ++ extra)

      conn = get(@image_path, opts, [{"accept", "image/avif,image/webp,*/*"}])

      assert conn.status == 200

      # Proof the lever bit: the client accepted AVIF and WebP, and the response
      # is neither — so `modern_candidates` really was emptied and the selection
      # deferred to the source format.
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/jpeg", "#{inspect(extra)} did not empty the candidates"

      assert get_resp_header(conn, "vary") == ["Accept"],
             "lost Vary: Accept for #{inspect(extra)}"

      flush_messages()
    end
  end

  test "existing vary is merged in the final response", %{automatic_opts: opts} do
    conn =
      :get
      |> conn(@image_path)
      |> put_req_header("accept", "image/webp")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
  end

  test "request cookie does not change generated headers or source fetch", %{opts: opts} do
    without_cookie = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    [etag] = get_resp_header(without_cookie, "etag")

    flush_messages()

    with_cookie =
      :get
      |> conn(@image_path)
      |> put_req_header("cookie", "session=private")
      |> ImagePipe.Plug.call(opts)

    assert get_resp_header(with_cookie, "etag") == [etag]
    refute "cookie" in vary_tokens(with_cookie)
    assert_received :source_fetch_called
  end

  test "response cookies suppress generated public cache headers", %{opts: opts} do
    conn =
      :get
      |> conn(@image_path)
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

    opts = mount(cache: {CacheHitProbe, test_pid: self(), entry: entry})

    conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ @strong_validator
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    refute_received :source_fetch_called
    flush_messages()

    # "current prepared" means the conditional gate computes the same validator
    # from the request alone: replaying it revalidates before the cache is even
    # consulted.
    revalidated = get(@image_path, opts, [{"if-none-match", etag}])

    assert revalidated.status == 304
    assert get_resp_header(revalidated, "etag") == [etag]
    refute_received {:cache_get, %Key{}}
  end

  test "wildcard if-none-match on a cache miss proceeds and returns 200", %{opts: opts} do
    conn =
      :get
      |> conn(@image_path)
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

    opts = mount(cache: {CacheHitProbe, test_pid: self(), entry: entry})

    # The 200 this mount serves for the same request, for the validator the
    # wildcard 304 must carry.
    unconditional = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    assert [etag] = get_resp_header(unconditional, "etag")
    flush_messages()

    conn =
      :get
      |> conn(@image_path)
      |> put_req_header("if-none-match", "*")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [etag]
    refute_received :source_fetch_called
  end

  test "wildcard if-none-match on a HEAD internal cache hit returns 304" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts = mount(cache: {CacheHitProbe, test_pid: self(), entry: entry})

    conn =
      :head
      |> conn(@image_path)
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
      mount(
        sources: [path: {EtaglessCachedSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry}
      )

    conn =
      :get
      |> conn(@image_path)
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

    opts = mount(cache: {CacheHitProbe, test_pid: self(), entry: entry})

    conn =
      :get
      |> conn(@image_path)
      |> put_req_header("if-none-match", ~s("nonmatching-validator", *))
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
      mount(
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        allow_origin: "https://cdn.test"
      )

    conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
    refute_received :source_fetch_called
  end

  test "CORS header lands on a 304 Not Modified response when allow_origin is set" do
    opts = mount(allow_origin: "https://cdn.test")

    first = ImagePipe.Plug.call(conn(:get, @image_path), opts)
    [etag] = get_resp_header(first, "etag")
    flush_messages()

    conn =
      :get
      |> conn(@image_path)
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
  end

  test "host-set content-disposition is preserved on both miss and cache-hit responses" do
    probe_opts = mount()

    miss_conn =
      conn(:get, @image_path)
      |> put_resp_header("content-disposition", ~s(attachment; filename="custom.jpg"))
      |> ImagePipe.Plug.call(probe_opts)

    assert miss_conn.status == 200

    assert get_resp_header(miss_conn, "content-disposition") == [
             ~s(attachment; filename="custom.jpg")
           ]

    assert_received {:cache_put, %Entry{} = entry}

    hit_opts = mount(cache: {CacheHitProbe, test_pid: self(), entry: entry})

    hit_conn =
      conn(:get, @image_path)
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
        mount(
          dialect: GuidedIIIFDialect,
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
        mount()
      )

    raising =
      ImagePipe.Plug.call(
        conn(:get, url),
        mount(cache: {RaisingCommitProbe, []})
      )

    assert clean.status == 200
    assert raising.status == 200
    assert byte_size(raising.resp_body) > 0
    assert raising.resp_body == clean.resp_body
  end

  # #328: the only guide that reached the generated-ETag path under a strong
  # byte identity before this was :center. A gravity-derived guide
  # (focal/smart/detect/anchor) exercises the KeyData.guide_data clauses
  # end-to-end — a missing clause 500s here instead of staying green. Focal needs
  # no detector, so the 200 body path executes too.
  test "guide-bearing focal gravity emits an etag on the strong-identity path" do
    opts = mount(dialect: GuidedIIIFDialect)

    conn =
      ImagePipe.Plug.call(
        conn(:get, "/img/square/200,100/0/default.jpg?guide=focal"),
        opts
      )

    assert conn.status == 200
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ @strong_validator
  end

  @doc false
  def forward_event(event, _measurements, metadata, test_pid),
    do: send(test_pid, {:http_cache, event, metadata})

  describe "generated-policy telemetry" do
    setup do
      prefix = [:"cdn_http_cache_#{System.unique_integer([:positive])}"]
      handler_id = "cdn-http-cache-#{inspect(prefix)}"
      test_pid = self()

      events =
        for suffix <- [
              [:http_cache, :prepare],
              [:http_cache, :fallback, :no_store],
              [:http_cache, :conditional, :match]
            ],
            do: prefix ++ suffix

      :telemetry.attach_many(handler_id, events, &__MODULE__.forward_event/4, test_pid)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      [prefix: prefix]
    end

    test "a strong-identity request prepares generated headers and emits no no-store fallback",
         %{prefix: prefix} do
      conn = ImagePipe.Plug.call(conn(:get, @image_path), mount(telemetry_prefix: prefix))

      assert conn.status == 200

      assert_received {:http_cache, event, metadata}
      assert event == prefix ++ [:http_cache, :prepare]
      assert metadata == %{effective_mode: :enabled, byte_identity: :strong, etag: true}

      refute_received {:http_cache, _event, %{reason: :missing_byte_identity}}
    end

    test "a byte-identity-less source falls back to no-store", %{prefix: prefix} do
      opts =
        mount(
          sources: [path: {EtaglessCachedSource, test_pid: self()}],
          telemetry_prefix: prefix
        )

      conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "etag") == []

      assert_received {:http_cache, _prepare,
                       %{effective_mode: :enabled, byte_identity: :none, etag: false}}

      assert_received {:http_cache, event, metadata}
      assert event == prefix ++ [:http_cache, :fallback, :no_store]
      assert metadata.reason == :missing_byte_identity
      assert metadata.source_kind == :path
    end

    test "a matching conditional request emits the conditional-match event", %{prefix: prefix} do
      opts = mount(telemetry_prefix: prefix)

      first = ImagePipe.Plug.call(conn(:get, @image_path), opts)
      [etag] = get_resp_header(first, "etag")
      flush_messages()

      conn = get(@image_path, opts, [{"if-none-match", etag}])

      assert conn.status == 304
      assert_received {:http_cache, event, %{method: :get}}
      assert event == prefix ++ [:http_cache, :conditional, :match]
    end

    test "a source that inherits the mount's disabled mode generates no headers",
         %{prefix: prefix} do
      opts =
        mount(
          sources: [path: {InheritingSource, test_pid: self()}],
          http_cache: [mode: :disabled],
          telemetry_prefix: prefix
        )

      conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      # Nothing generated: what remains is Plug's own default directive.
      assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]

      # `[:http_cache, :prepare]` still reports the disabled decision; the
      # no-store fallback must not fire.
      assert_received {:http_cache, _prepare, %{effective_mode: :disabled, etag: false}}
      refute_received {:http_cache, _event, %{reason: _}}
    end

    test "a source that enables the HTTP cache overrides the mount's disabled mode",
         %{prefix: prefix} do
      opts = mount(http_cache: [mode: :disabled], telemetry_prefix: prefix)

      conn = ImagePipe.Plug.call(conn(:get, @image_path), opts)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert [_etag] = get_resp_header(conn, "etag")
      assert_received {:http_cache, _prepare, %{effective_mode: :enabled, etag: true}}
    end
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
