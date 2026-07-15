defmodule ImagePipe.Dialect.NativeWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Dialect.Native
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  @source_key_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @source_key_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  @default_sources [
    path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
  ]

  defp counting_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp should_not_fetch_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
    ]
  end

  # A fresh ETS-backed CacheProbe store: makes lookups/commits stateful
  # (real miss-then-hit round trips) rather than the stateless default (see
  # CacheProbe's module doc).
  defp stateful_cache_probe do
    table = :ets.new(:native_wire_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  # `output_capabilities` and `on_bracket_exit` are internal test-injection
  # seams (the same convention `ImagePipe.Output.Capabilities.supports?/2`
  # already documents) — appended AFTER `Native.init/1`'s validation, which
  # would reject them as unknown options.
  defp opts(extra) do
    base = Native.init(Keyword.merge([sources: @default_sources], extra))
    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp opts, do: opts([])

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Native.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  # Mirrors identity_test.exs's helper: exercises the real parser rather
  # than a hand-built %Request{}.
  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  # ── happy path ──────────────────────────────────────────────────────────

  describe "GET /w=64/src/images/cat.jpg" do
    test "200, image body, decoded width 64, content-type per negotiation" do
      conn = get("/w=64/src/images/cat.jpg", opts())

      assert conn.status == 200
      assert {width, _height} = decoded_dims(conn.resp_body)
      assert width == 64
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    end
  end

  # ── negotiation / representation identity ──────────────────────────────

  describe "output negotiation" do
    test "different Accept selections produce different content-types and ETags, both Vary: Accept" do
      config = opts()

      avif_conn = get("/w=64/src/images/cat.jpg", config, [{"accept", "image/avif"}])
      no_accept_conn = get("/w=64/src/images/cat.jpg", config)

      assert avif_conn.status == 200
      assert no_accept_conn.status == 200

      assert get_resp_header(avif_conn, "content-type") == ["image/avif"]
      assert get_resp_header(no_accept_conn, "content-type") == ["image/jpeg"]

      assert get_resp_header(avif_conn, "vary") == ["Accept"]
      assert get_resp_header(no_accept_conn, "vary") == ["Accept"]

      assert get_resp_header(avif_conn, "etag") != get_resp_header(no_accept_conn, "etag")
    end

    test "same selection under different Accept spellings shares an ETag and cache key" do
      config = opts(cache: {CacheProbe, []})

      conn_a = get("/w=64/src/images/cat.jpg", config, [{"accept", "image/avif"}])
      assert_receive {:cache_lookup, key_a}

      conn_b =
        get("/w=64/src/images/cat.jpg", config, [{"accept", "image/avif,image/webp"}])

      assert_receive {:cache_lookup, key_b}

      assert get_resp_header(conn_a, "content-type") == ["image/avif"]
      assert get_resp_header(conn_b, "content-type") == ["image/avif"]
      assert get_resp_header(conn_a, "etag") == get_resp_header(conn_b, "etag")
      assert key_a.hash == key_b.hash
    end

    test "explicit format=webp selects webp with NO Vary header" do
      conn = get("/format=webp/w=64/src/images/cat.jpg", opts())

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/webp"]
      assert get_resp_header(conn, "vary") == []
    end

    test "format=jpeg/q=42 differs in bytes from format=jpeg/q=90" do
      config = opts()

      conn_low = get("/format=jpeg/q=42/w=64/src/images/cat.jpg", config)
      conn_high = get("/format=jpeg/q=90/w=64/src/images/cat.jpg", config)

      assert conn_low.status == 200
      assert conn_high.status == 200
      assert conn_low.resp_body != conn_high.resp_body
    end

    test "one-%Policy{} continuity: q=42 is the SAME value in negotiation.policy_material and in the %Output.Resolved{} reaching the encoder" do
      config = opts()
      {:ok, request} = Parser.parse(lexed(["format=jpeg", "q=42"]), config)
      conn = conn(:get, "/format=jpeg/q=42/src/images/cat.jpg")

      assert {:ok, negotiation} = Native.negotiate(conn, request, config)
      assert Keyword.fetch!(negotiation.policy_material, :quality) == {:quality, 42}

      assert {:ok, resolved} = Policy.resolve(negotiation.policy, :jpeg)
      assert resolved.quality == {:quality, 42}
    end
  end

  # ── cache write on miss ─────────────────────────────────────────────────

  describe "cache write on miss" do
    test "one request: CacheProbe observes :cache_lookup (miss) then :cache_put" do
      config = opts(cache: {CacheProbe, []})

      conn = get("/w=64/src/images/cat.jpg", config)
      assert conn.status == 200

      assert_received {:source_order, :cache_lookup}
      assert_received {:source_order, :cache_put}
    end

    test "two semantically equivalent (permuted-option) URLs produce the same captured key" do
      config = opts(cache: {CacheProbe, []})

      conn_a = get("/w=64/fit=contain/src/images/cat.jpg", config)
      assert_receive {:cache_lookup, key_a}
      assert conn_a.status == 200

      conn_b = get("/fit=contain/w=64/src/images/cat.jpg", config)
      assert_receive {:cache_lookup, key_b}
      assert conn_b.status == 200

      assert key_a.hash == key_b.hash
    end
  end

  # ── conditional GET: 304 before any cache lookup or source fetch ───────

  describe "conditional GET is evaluated before the cache lookup" do
    test "matching If-None-Match: 304, empty body, no cache lookup, no source fetch" do
      plain_conn = get("/w=64/src/images/cat.jpg", opts())
      [etag] = get_resp_header(plain_conn, "etag")

      config = opts(sources: should_not_fetch_sources(), cache: {CacheProbe, []})
      conn = get("/w=64/src/images/cat.jpg", config, [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end
  end

  # ── cache hit delivery ──────────────────────────────────────────────────

  describe "cache hit delivery" do
    test "second non-conditional request is served from the stored cache entry" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      conn_a = get("/w=64/src/images/cat.jpg", config)
      assert conn_a.status == 200
      assert_received :origin_fetch
      assert_received {:source_order, :cache_put}

      conn_b = get("/w=64/src/images/cat.jpg", config)

      assert conn_b.status == 200
      refute_received :origin_fetch
      assert_received {:source_order, :cache_lookup}
      refute_received {:source_order, :cache_put}

      assert conn_b.resp_body == conn_a.resp_body
      assert get_resp_header(conn_b, "content-type") == get_resp_header(conn_a, "content-type")
      assert get_resp_header(conn_b, "etag") == get_resp_header(conn_a, "etag")
      assert get_resp_header(conn_b, "vary") == get_resp_header(conn_a, "vary")
    end

    test "a semantically permuted URL is served from the SAME cached entry" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      conn_a = get("/w=64/fit=contain/src/images/cat.jpg", config)
      assert conn_a.status == 200
      assert_received :origin_fetch

      conn_b = get("/fit=contain/w=64/src/images/cat.jpg", config)

      assert conn_b.status == 200
      refute_received :origin_fetch
      assert conn_b.resp_body == conn_a.resp_body
      assert get_resp_header(conn_b, "etag") == get_resp_header(conn_a, "etag")
    end

    test "If-None-Match matching etag on a warmed cache: 304, no source fetch" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      first_conn = get("/w=64/src/images/cat.jpg", config)
      assert first_conn.status == 200
      [etag] = get_resp_header(first_conn, "etag")
      assert_received :origin_fetch

      conn = get("/w=64/src/images/cat.jpg", config, [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received :origin_fetch
    end

    test "If-None-Match: * is 200 on a cold cache but 304 once the cache is warmed" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      cold_conn = get("/w=64/src/images/cat.jpg", config, [{"if-none-match", "*"}])
      assert cold_conn.status == 200
      assert_received :origin_fetch

      warm_conn = get("/w=64/src/images/cat.jpg", config, [{"if-none-match", "*"}])

      assert warm_conn.status == 304
      assert warm_conn.resp_body == ""
      refute_received :origin_fetch
    end
  end

  # ── output=blurhash: complete-body terminal delivery ────────────────────

  describe "GET /w=32/output=blurhash/src/images/cat.jpg" do
    test "200, text/plain body, no Vary, ETag present" do
      conn = get("/w=32/output=blurhash/src/images/cat.jpg", opts())

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      assert get_resp_header(conn, "vary") == []
      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
      assert conn.resp_body =~ ~r/^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$/
    end

    test "conditional GET with a matching etag is 304 before any source fetch" do
      plain_conn = get("/output=blurhash/src/images/cat.jpg", opts())
      [etag] = get_resp_header(plain_conn, "etag")

      config = opts(sources: should_not_fetch_sources(), cache: {CacheProbe, []})
      conn = get("/output=blurhash/src/images/cat.jpg", config, [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "second request is served from the stored cache entry (CacheProbe order)" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      conn_a = get("/output=blurhash/src/images/cat.jpg", config)
      assert conn_a.status == 200
      assert_received :origin_fetch
      assert_received {:source_order, :cache_put}

      conn_b = get("/output=blurhash/src/images/cat.jpg", config)

      assert conn_b.status == 200
      refute_received :origin_fetch
      assert_received {:source_order, :cache_lookup}
      refute_received {:source_order, :cache_put}

      assert conn_b.resp_body == conn_a.resp_body
      assert get_resp_header(conn_b, "content-type") == get_resp_header(conn_a, "content-type")
      assert get_resp_header(conn_b, "etag") == get_resp_header(conn_a, "etag")
      assert get_resp_header(conn_b, "vary") == []
    end

    test "a transform earlier in the pipeline (blur) changes the resulting hash" do
      config = opts()

      plain_conn = get("/output=blurhash/src/images/cat.jpg", config)
      blurred_conn = get("/blur=5/output=blurhash/src/images/cat.jpg", config)

      assert plain_conn.status == 200
      assert blurred_conn.status == 200
      assert plain_conn.resp_body != blurred_conn.resp_body
      assert get_resp_header(plain_conn, "etag") != get_resp_header(blurred_conn, "etag")
    end

    test "q=50 combined with output=blurhash is a 400, inert (never reaches source/cache)" do
      config = opts(sources: counting_sources(), cache: {CacheProbe, []})
      conn = get("/q=50/output=blurhash/src/images/cat.jpg", config)

      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "format=webp combined with output=blurhash is a 400, inert (never reaches source/cache)" do
      config = opts(sources: counting_sources(), cache: {CacheProbe, []})
      conn = get("/format=webp/output=blurhash/src/images/cat.jpg", config)

      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end
  end

  # ── 400 paths never touch source or cache ──────────────────────────────

  describe "400 request-validation failures never reach source/cache" do
    setup do
      {:ok, config: opts(sources: counting_sources(), cache: {CacheProbe, []})}
    end

    test "unknown option key", %{config: config} do
      conn = get("/bogus=10/src/images/cat.jpg", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "bad option value", %{config: config} do
      conn = get("/w=invalid/src/images/cat.jpg", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "duplicate option in scope", %{config: config} do
      conn = get("/w=800/w=900/src/images/cat.jpg", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "mutually exclusive pair", %{config: config} do
      conn = get("/crop=100,100/region=0,0,10,10/src/images/cat.jpg", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "empty pipeline group", %{config: config} do
      conn = get("/w=800/then/then/w=900/src/images/cat.jpg", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "non-empty query string", %{config: config} do
      conn = get("/w=64/src/images/cat.jpg?x=1", config)
      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end
  end

  # ── signature matrix ────────────────────────────────────────────────────

  describe "signature matrix" do
    test "keys configured, no sig: 403, no source fetch" do
      config = opts(keys: [@source_key_a], sources: counting_sources())
      conn = get("/w=64/src/images/cat.jpg", config)

      assert conn.status == 403
      refute_received :origin_fetch
    end

    test "keys configured, invalid sig: 403, no source fetch" do
      config = opts(keys: [@source_key_a], sources: counting_sources())
      conn = get("/sig=" <> String.duplicate("A", 43) <> "/w=64/src/images/cat.jpg", config)

      assert conn.status == 403
      refute_received :origin_fetch
    end

    test "keys configured, valid sig with the first key: 200" do
      config = opts(keys: [@source_key_a])
      sig = Native.Signature.sign("/w=64/src/images/cat.jpg", config)
      conn = get("/sig=#{sig}/w=64/src/images/cat.jpg", config)

      assert conn.status == 200
    end

    test "two keys configured, valid sig matching the second key: 200" do
      config = opts(keys: [@source_key_a, @source_key_b])
      second_key_signs = Keyword.put(config, :keys, [@source_key_b, @source_key_a])
      sig = Native.Signature.sign("/w=64/src/images/cat.jpg", second_key_signs)

      conn = get("/sig=#{sig}/w=64/src/images/cat.jpg", config)

      assert conn.status == 200
    end

    test "no keys configured, sig= present: 400, no source fetch" do
      config = opts(sources: counting_sources())
      sig = String.duplicate("A", 43)
      conn = get("/sig=#{sig}/w=64/src/images/cat.jpg", config)

      assert conn.status == 400
      refute_received :origin_fetch
    end
  end

  # ── expires gate ─────────────────────────────────────────────────────────

  describe "expires gate" do
    test "past expires: 404 before any source fetch" do
      config = opts(sources: counting_sources())
      past = System.os_time(:second) - 3600
      conn = get("/expires=#{past}/w=64/src/images/cat.jpg", config)

      assert conn.status == 404
      refute_received :origin_fetch
    end
  end

  # ── delivery lifecycle: monitor direction + bracket containment ────────
  #
  # These exercise ImagePipe.Delivery.Coordinator/Producer
  # directly with a synthetic build_fun, rather than going through the full
  # HTTP call/2 chain — the flagged invariants here are the monitor
  # direction and the bracket-cleanup contract, which are properties of the
  # Coordinator/Producer pair itself, independent of what build_fun actually
  # computes.

  defp fake_resolved_output do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp fake_cache_key, do: %Key{hash: "test-key", data: []}

  defp bracketed_build_fun(chunks, test_pid) do
    fn pump ->
      try do
        pump.(Stream.map(chunks, & &1), "image/jpeg", fake_resolved_output())
      after
        send(test_pid, :bracket_cleanup)
      end
    end
  end

  describe "delivery lifecycle" do
    test "owner-kill: coordinator observes owner :DOWN, halts the producer gracefully, aborts the sink, bracket cleanup runs exactly once, both children terminate" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b", "c"], test_pid)

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), [])
      coordinator_ref = Process.monitor(coordinator)

      assert {:ok, %{first_chunk: "a"}} = Coordinator.prepare(coordinator)
      assert {:chunk, "b"} = Coordinator.next(coordinator)

      refute_received :bracket_cleanup

      Process.exit(owner, :kill)

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup

      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}
    end

    test "bracket cleanup has NOT run after prepare and after the first Coordinator.next/1, and HAS run exactly once at EOF" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b", "c"], test_pid)
      owner = self()

      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), [])

      assert {:ok, %{first_chunk: "a"}} = Coordinator.prepare(coordinator)
      refute_received :bracket_cleanup

      assert {:chunk, "b"} = Coordinator.next(coordinator)
      refute_received :bracket_cleanup

      assert {:chunk, "c"} = Coordinator.next(coordinator)
      refute_received :bracket_cleanup

      assert :done = Coordinator.next(coordinator)
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end

    test "bracket cleanup runs exactly once after an explicit mid-stream cancel" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b", "c"], test_pid)
      owner = self()

      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), [])

      assert {:ok, %{first_chunk: "a"}} = Coordinator.prepare(coordinator)
      refute_received :bracket_cleanup

      assert {:chunk, "b"} = Coordinator.next(coordinator)
      refute_received :bracket_cleanup

      assert :ok = Coordinator.cancel(coordinator)
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end
end
