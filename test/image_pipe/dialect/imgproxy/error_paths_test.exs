defmodule ImagePipe.Dialect.Imgproxy.ErrorPathsTest do
  @moduledoc """
  The error-path and ownership matrix for `ImagePipe.Dialect.Imgproxy`, the
  imgproxy-URL twin of `ImagePipe.Dialect.NativeErrorPathsTest`. One named
  wire test per matrix row, each asserting user-visible status/behavior AND
  cleanup ownership (who opens/aborts/commits the cache sink, whether the
  `build_fun` bracket's `try/after` runs exactly once).

  ## Which rows live here, and which deliberately do not

  Rows 1-7 are ported: each one is reached THROUGH `Imgproxy.call/2`, so each
  exercises something this dialect owns — `Errors`'s status mapping, the
  `build_fun` bracket in `Imgproxy.build_fun/4`, and the cache key/sink this
  chain hands `Delivery.stream/5`.

  Rows 8 (producer cancellation) and 9 (response-already-sent) are NOT ported,
  and their absence is a finding rather than an oversight:

    * Their subject is `ImagePipe.Delivery` / `ImagePipe.Delivery.Coordinator`
      — core modules the framework and BOTH dialects now share since the D3
      unification. `NativeErrorPathsTest`'s own rows 8/9 never make a wire
      request: they drive `Delivery.stream/5` and `Coordinator.start/5`
      directly with a synthetic `build_fun`. Copying them here would assert the
      same core contract a second time with an `Imgproxy` module name on the
      file and no imgproxy code in the call stack.
    * Neither is reachable through this dialect at the wire level anyway.
      `Plug.Test`'s chunked adapter drains the whole stream inside
      `Sender.send_result/3`, so a caller never holds a `%PreparedStream{}` it
      could cancel (row 8), and never issues a `next/1` after `:done` (row 9).

  Row 2 IS ported, but not by copying: native's row 2 also drives the
  `Coordinator` directly, because its `build_fun` needs a blocking point and a
  synthetic one is the easy way to get it. This dialect has a real one — the
  `:chain` seam `Pipeline.run/4` already exposes — which sits INSIDE
  `build_fun`'s `try/after`. So the row is driven end to end through
  `Imgproxy.call/2` from a spawned owner, and proves this dialect's own bracket
  runs exactly once when the owner dies mid-work.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Blur, as: ExecutableBlur
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImgproxyWireConformanceTest.OriginImage

  # ── row-specific origin/cache/encoder test doubles ─────────────────────
  #
  # Copied, not imported, from `NativeErrorPathsTest` — per the convention
  # already used by `imgproxy_wire_smoke_test.exs` and
  # `imgproxy_wire_conformance_test.exs` of defining single-consumer fixtures
  # next to the test that exercises them.

  defmodule Origin503 do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)
      Plug.Conn.send_resp(conn, 503, "origin 503")
    end
  end

  defmodule CorruptImageOrigin do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not a valid image \xFF\xFE\x00")
    end
  end

  # A `stream!/2`-shaped `image_module` seam (`ImagePipe.Output.Encoder`'s
  # test-injection point, threaded transparently through this dialect's
  # `config` since `build_and_pump/6` hands `config` straight to
  # `Encoder.stream_output/3`) that emits one real chunk, then raises —
  # simulating an encoder failure discovered only after the chunked 200 has
  # already gone out on the wire.
  defmodule RaisingAfterFirstChunkImage do
    @moduledoc false
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _ -> :ok end
      )
    end
  end

  # A lazy `stream!/2` seam that raises on the FIRST pull, before any chunk is
  # emitted. Because the dialect forces the first chunk inside `build_fun`'s
  # producer (before ever calling `pump`), this surfaces as a pre-header 500
  # ("error encoding image"), not a mid-stream abort of an already-committed
  # 200 — the framework's `FailingStreamBeforeHeaderImage` pin. The lazy
  # `Stream.resource` (rather than a synchronous raise in `stream!`) is what
  # makes the FORCE load-bearing: without it, the raise would land in `pump`
  # after the chunked 200 had already gone out.
  defmodule RaisingBeforeFirstChunkImage do
    @moduledoc false
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      Stream.resource(
        fn -> :start end,
        fn :start -> raise "boom before first chunk" end,
        fn _ -> :ok end
      )
    end
  end

  # A `stream!/2` seam that yields no chunks at all. The forced first-chunk
  # pull sees `:empty`, which `build_and_pump/6` reports as
  # `{:error, {:encode, :empty_stream}}` — a pre-header failure that must
  # render 500 (`EmptyStreamingImage` in the framework's `plug_test.exs`).
  defmodule EmptyStreamingImage do
    @moduledoc false
    def stream!(_image, [{:suffix, ".jpg"} | _]), do: []
  end

  # A `Clamp.clamp/3` `image_module` seam whose `resize/3` raises. Clamp is a
  # shared post-transform stage with no rescue of its own (AGENTS.md: only a
  # dialect's own pipeline run is a trusted-callback boundary the runner must
  # not launder) — the raise is expected to escape the producer process,
  # surface to the coordinator as a `:DOWN`, and render 500-class.
  defmodule RaisingClampImage do
    @moduledoc false
    def resize(_image, _scale, _opts), do: raise("boom during clamp resize")
  end

  # An `ImagePipe.Cache` adapter that announces every callback via message so a
  # test can assert sink OWNERSHIP (opened/written/aborted/committed), not just
  # the resulting HTTP response. `get/2` always misses.
  #
  # The reporting target is the `:test_pid` the adapter is configured with,
  # rather than native's `$callers`-walk: row 2 drives the chain from a
  # `spawn/1`ed owner, which inherits no `$callers` chain, so the walk would
  # silently report to the sink's own process and every assertion would time
  # out. `abort_sink/2` in particular is called from the coordinator after the
  # owner is already dead.
  defmodule ObservingCacheProbe do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, opts) do
      send(target(opts), :cache_get)
      :miss
    end

    @impl true
    def open_sink(key, metadata, opts) do
      send(target(opts), {:cache_open_sink, key, metadata})
      {:ok, %{chunks: []}}
    end

    @impl true
    def write_chunk(state, chunk, opts) do
      send(target(opts), {:cache_write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    @impl true
    def commit_sink(_state, opts) do
      send(target(opts), :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(_state, opts) do
      send(target(opts), :cache_abort_sink)
      :ok
    end

    defp target(opts), do: Keyword.fetch!(opts, :test_pid)
  end

  # A `get/2` that raises — exercises `ImagePipe.Cache.fetch_entry/3`'s own
  # `rescue`, proving a raising adapter still fails open at the lookup site.
  defmodule RaisingGetCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: raise("cache get boom")

    @impl true
    def open_sink(_key, _metadata, _opts), do: {:ok, %{chunks: []}}

    @impl true
    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    @impl true
    def commit_sink(_state, _opts), do: :ok

    @impl true
    def abort_sink(_state, _opts), do: :ok
  end

  # `write_chunk/3` always fails (a real adapter-declared `{:error, _, state}`,
  # not a raise) — exercises `ImagePipe.Cache.Sink`'s own fail-open path, which
  # aborts the adapter's sink internally as part of handling the error.
  defmodule FailingWriteChunkCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(key, metadata, _opts) do
      send(target(), {:cache_open_sink, key, metadata})
      {:ok, %{}}
    end

    @impl true
    def write_chunk(state, _chunk, _opts) do
      send(target(), :cache_write_chunk_failed)
      {:error, :forced_write_failure, state}
    end

    @impl true
    def commit_sink(_state, _opts) do
      send(target(), :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(_state, _opts) do
      send(target(), :cache_abort_sink)
      :ok
    end

    defp target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  @default_sources [
    path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
  ]

  # `output_capabilities`/`on_bracket_exit`/`chain`/`image_module` are test-
  # injection seams that `Imgproxy.Config.validate!/1` would reject as unknown
  # options — appended AFTER `Imgproxy.init/1`, mirroring
  # `ImgproxyWireSmokeTest`'s `opts/1` convention.
  @test_only_seam_keys [:output_capabilities, :on_bracket_exit, :chain, :image_module]

  defp opts(extra) do
    {seams, known} = Keyword.split(extra, @test_only_seam_keys)

    base =
      ImagePipe.Plug.init(
        [dialect: Imgproxy] ++ Keyword.merge([sources: @default_sources], known)
      )

    Keyword.merge(
      base,
      Keyword.merge([output_capabilities: %{avif: true, webp: true, jpeg_xl: true}], seams)
    )
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  # ── row 1: fetch failure (origin 5xx) ───────────────────────────────────

  describe "row 1: fetch failure (origin 5xx)" do
    test "upstream 503 -> 502, no partial 200, sink never opened" do
      test_pid = self()

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {Origin503, test_pid: test_pid}]}
          ],
          cache: {ObservingCacheProbe, test_pid: test_pid}
        )

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert_received :origin_fetch
      assert conn.status == 502
      assert conn.resp_body == "upstream responded 503"
      refute_received {:cache_open_sink, _key, _metadata}
    end

    # A pre-delivery failure (a fetch error, discovered before `Delivery.stream/5`
    # is ever called) must still stamp `:result` on the `[:request]` span's stop
    # metadata — the bug this test guards is `Imgproxy.call/2`'s span carrying
    # only `:status`, which renders every failing request as `ok` under the
    # default Logger's `outcome/1` (AGENTS.md, telemetry guidelines).
    test "stamps :source_error as :result on the [:request] stop span" do
      test_pid = self()
      prefix = [:"imgproxy_error_paths_#{System.unique_integer([:positive])}"]

      config =
        opts(
          telemetry_prefix: prefix,
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {Origin503, test_pid: test_pid}]}
          ],
          cache: {ObservingCacheProbe, test_pid: test_pid}
        )

      handler_id = "imgproxy-error-paths-#{inspect(prefix)}"

      :telemetry.attach(
        handler_id,
        prefix ++ [:request, :stop],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:request_stop, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)
      assert conn.status == 502

      assert_received {:request_stop, metadata}
      assert metadata[:result] == :source_error
      assert metadata[:error] == :source
      assert metadata[:status] == 502
    end
  end

  # ── row 2: client disconnect during the producer's work ─────────────────
  #
  # Driven end to end through `Imgproxy.call/2` from a spawned owner. The
  # `:chain` seam parks the producer INSIDE `build_fun`'s `try/after`, so the
  # owner's death lands while the bracket is open — the phase that decides
  # whether cleanup runs, and runs once.

  describe "row 2: client disconnect while the producer holds the bracket open" do
    # The sink assertions are what make this row discriminating rather than a
    # restatement of "the bracket always runs". A request that completes
    # normally through this same config ALSO ends with one `:bracket_cleanup`
    # (see the positive control below), so cleanup alone proves nothing about
    # the disconnect. The sink does: the producer parked BEFORE it ever reached
    # `pump`, so the coordinator never saw a first chunk and never opened a
    # sink — and once the owner is gone it never will. The positive control
    # sends the identical `:proceed` through the identical config and gets
    # `open_sink` + `commit_sink`, so these refutes are observations, not
    # vacuous silence.
    test "owner dies mid-transform: no sink is ever opened, and the bracket cleanup runs exactly once" do
      test_pid = self()

      chain = fn state, ops, chain_opts ->
        send(test_pid, {:chain_parked, self()})

        receive do
          :proceed -> :ok
        end

        Chain.execute(state, ops, chain_opts)
      end

      config =
        opts(
          chain: chain,
          cache: {ObservingCacheProbe, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      owner = spawn(fn -> get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config) end)
      owner_ref = Process.monitor(owner)

      assert_receive {:chain_parked, producer_pid}
      refute_received :bracket_cleanup

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

      # The graceful halt is already queued in the producer's mailbox; it is
      # only processed once `build_fun` reaches `pump`'s receive.
      send(producer_pid, :proceed)

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup

      assert_received :cache_get
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :cache_commit_sink
    end

    test "positive control: with the owner alive, the same config opens and commits the sink" do
      test_pid = self()

      chain = fn state, ops, chain_opts ->
        send(test_pid, {:chain_parked, self()})

        receive do
          :proceed -> :ok
        end

        Chain.execute(state, ops, chain_opts)
      end

      config =
        opts(
          chain: chain,
          cache: {ObservingCacheProbe, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      owner =
        spawn(fn ->
          conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)
          send(test_pid, {:owner_done, conn.status})
        end)

      assert_receive {:chain_parked, producer_pid}
      send(producer_pid, :proceed)

      assert_receive {:owner_done, 200}
      assert_receive :bracket_cleanup
      assert_received {:cache_open_sink, _key, _metadata}
      assert_receive :cache_commit_sink
      refute_received :cache_abort_sink

      Process.exit(owner, :kill)
    end
  end

  # ── row 3: decode rejection (415) ───────────────────────────────────────

  describe "row 3: decode rejection (415)" do
    test "corrupt body with an image content-type -> 415, no partial 200, sink never opened" do
      test_pid = self()

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {CorruptImageOrigin, test_pid: test_pid}]}
          ],
          cache: {ObservingCacheProbe, test_pid: test_pid}
        )

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert_received :origin_fetch
      assert conn.status == 415
      refute_received {:cache_open_sink, _key, _metadata}
    end
  end

  # ── row 4: transform failure after partial work ─────────────────────────
  #
  # `/rs:fit:64:64/-/bl:5/` is two `-` pipelines: the first pipeline's resize
  # runs (real `Chain.execute/3`, proving partial work happened) before the
  # second pipeline's blur is forced to fail via the `:chain` test seam
  # (`Pipeline.run/4`'s own injectable — real callers never set it).

  describe "row 4: transform failure after partial work" do
    test "a later pipeline's transform failure surfaces 422 after an earlier pipeline already executed, cleanup runs exactly once" do
      test_pid = self()

      chain = fn state, ops, chain_opts ->
        send(test_pid, {:chain_call, Enum.map(ops, & &1.__struct__)})

        if Enum.any?(ops, &match?(%ExecutableBlur{}, &1)) do
          {:error, :forced_blur_failure}
        else
          Chain.execute(state, ops, chain_opts)
        end
      end

      config = opts(chain: chain, on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end)

      conn = get("/unsafe/rs:fit:64:64/-/bl:5/plain/images/beach.jpg", config)

      assert conn.status == 422

      chain_calls = drain_chain_calls()
      assert Enum.any?(chain_calls, &(ExecutableResize in &1))
      assert Enum.any?(chain_calls, &(ExecutableBlur in &1))

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  defp drain_chain_calls(acc \\ []) do
    receive do
      {:chain_call, structs} -> drain_chain_calls([structs | acc])
    after
      0 -> acc
    end
  end

  # ── row 5: encoder failure after the first streamed chunk ───────────────

  describe "row 5: encoder failure after the first streamed chunk" do
    test "chunked 200 already sent when encode fails: stream halts at the delivered prefix, sink aborts, cleanup once" do
      test_pid = self()

      config =
        opts(
          cache: {ObservingCacheProbe, test_pid: test_pid},
          image_module: RaisingAfterFirstChunkImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      log =
        capture_log(fn ->
          conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

          # The response is already committed as a chunked 200 by the time
          # encode fails; a chunked response cannot change its status, so the
          # contract is halt+abort+cleanup, not a 500.
          assert conn.status == 200
          assert conn.state == :chunked
          assert conn.resp_body == "first chunk"
          assert get_resp_header(conn, "content-type") == ["image/jpeg"]
        end)

      assert log =~ "boom after first chunk"

      assert_received {:cache_open_sink, _key, _metadata}
      assert_received {:cache_write_chunk, "first chunk"}
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  # ── row 5b: encoder failure BEFORE the first chunk (pre-header 500) ──────
  #
  # The B3 encode force means a first-chunk encode failure surfaces as a
  # pre-header 500 (never a mid-stream abort of a committed 200). The framework
  # pins both halves (`FailingStreamBeforeHeaderImage` + `EmptyStreamingImage`);
  # row 5 above pins only the unchanged mid-stream half. These two cases pin the
  # pre-header half on this dialect arm: a raising first pull, and an empty
  # stream.

  describe "row 5b: encoder failure before the first chunk (pre-header 500)" do
    test "a raising first pull -> pre-header text 500, conn sent, no chunked commit, sink never opened" do
      test_pid = self()

      config =
        opts(
          cache: {ObservingCacheProbe, test_pid: test_pid},
          image_module: RaisingBeforeFirstChunkImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert conn.status == 500
      assert conn.state == :sent
      assert conn.resp_body == "error encoding image"
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      # The producer failed before ever reaching `pump`, so no chunked response
      # was committed and no cache sink was opened.
      assert_received :cache_get
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :cache_commit_sink

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end

    test "an empty stream -> pre-header text 500, conn sent, sink never opened" do
      test_pid = self()

      config =
        opts(
          cache: {ObservingCacheProbe, test_pid: test_pid},
          image_module: EmptyStreamingImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert conn.status == 500
      assert conn.state == :sent
      assert conn.resp_body == "error encoding image"
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      assert_received :cache_get
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :cache_commit_sink

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  # ── row 6: cache-lookup failure (fail-open) ──────────────────────────────

  describe "row 6: cache-lookup failure (adapter get/2 raises)" do
    test "a raising cache adapter get/2 still fails open: the generated response is delivered" do
      config = opts(cache: {RaisingGetCache, []})

      log =
        capture_log(fn ->
          conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

          assert conn.status == 200
          assert {width, height} = decoded_dims(conn.resp_body)
          assert max(width, height) == 64
        end)

      assert log =~ "cache read error"
    end
  end

  # ── row 7: cache-write failure (fail-open) ───────────────────────────────

  describe "row 7: cache-write failure (adapter write_chunk/3 errors)" do
    test "a failing write_chunk/3 still fails open: the response is delivered, the sink aborts, no commit" do
      config = opts(cache: {FailingWriteChunkCache, []})

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert conn.status == 200
      assert {width, height} = decoded_dims(conn.resp_body)
      assert max(width, height) == 64

      assert_received {:cache_open_sink, _key, _metadata}
      assert_received :cache_write_chunk_failed
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
    end
  end

  # ── row 8: pre-first-chunk post-transform exception (forced clamp) ──────

  describe "row 8: pre-first-chunk post-transform exception (forced clamp)" do
    test "renders 500-class, opens no sink, cleans up once, and reports processing_error" do
      test_pid = self()
      prefix = [:"imgproxy_error_paths_clamp_#{System.unique_integer([:positive])}"]
      handler_id = "imgproxy-error-paths-clamp-#{inspect(prefix)}"

      :telemetry.attach(
        handler_id,
        prefix ++ [:request, :stop],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:request_stop, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      config =
        opts(
          telemetry_prefix: prefix,
          max_result_width: 10,
          max_result_height: 10,
          cache: {ObservingCacheProbe, test_pid: test_pid},
          image_module: RaisingClampImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", config)

      assert conn.status in 500..599
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :cache_commit_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
      assert_receive {:request_stop, %{result: :processing_error}}
    end
  end
end
