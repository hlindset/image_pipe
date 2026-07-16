defmodule ImagePipe.Dialect.NativeErrorPathsTest do
  @moduledoc """
  Task 20b: the error-path and ownership matrix. One named wire test per
  matrix row, each asserting user-visible status/behavior AND cleanup
  ownership (who opens/aborts/commits the cache sink, who tears the process
  topology down, whether the bracket's `try/after` runs exactly once).

  Rows already covered by `ImagePipe.Dialect.NativeWireTest`'s "delivery
  lifecycle" describe block (Task 15/16: owner-kill during delivery, bracket
  cleanup at EOF, bracket cleanup on an explicit mid-stream cancel, and every
  400-before-fetch parse/validation path) are referenced by name here, not
  duplicated.

  Feeds Task 21.3's error-ownership report section — see
  `.superpowers/sdd/task-20b-report.md`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Dialect.Native
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Delivery.SessionProbe
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Blur, as: ExecutableBlur
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImgproxyWireConformanceTest.OriginImage

  # ── row-specific origin/cache/encoder test doubles ─────────────────────
  #
  # Small, local, single-purpose fixtures (mirrors the convention already
  # used by plug_test.exs and imgproxy_wire_conformance_test.exs of defining
  # a fixture Plug/adapter inline next to the test that exercises it, rather
  # than growing test/support with single-consumer modules).

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
  # existing test-injection point, already threaded transparently through
  # `Native.Dialect`'s `config` since `build_and_pump/6` hands `config`
  # straight to `Encoder.stream_output/3`) that emits one real chunk, then
  # raises — simulating an encoder failure discovered only after the chunked
  # 200 has already gone out on the wire.
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

  # A `ImagePipe.Cache` adapter that announces every callback via message so
  # a test can assert sink OWNERSHIP (opened/written/aborted/committed), not
  # just the resulting HTTP response. `get/2` always misses.
  defmodule ObservingCacheProbe do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts) do
      send(target(), :cache_get)
      :miss
    end

    @impl true
    def open_sink(key, metadata, _opts) do
      send(target(), {:cache_open_sink, key, metadata})
      {:ok, %{chunks: []}}
    end

    @impl true
    def write_chunk(state, chunk, _opts) do
      send(target(), {:cache_write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
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

  # A `get/2` that raises — exercises `ImagePipe.Cache.fetch_entry/3`'s own
  # `rescue`, proving a raising adapter still fails open at the lookup site
  # (unlike a raising `open_sink/3`, see the report's concerns section).
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
  # not a raise) — exercises `ImagePipe.Cache.Sink`'s own fail-open path,
  # which aborts the adapter's sink internally as part of handling the error.
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
  # injection seams that `Native.Config.validate!/1` would reject as unknown
  # options — appended AFTER `Native.init/1`, mirroring
  # `NativeWireTest`'s `opts/1` convention exactly.
  @test_only_seam_keys [:output_capabilities, :on_bracket_exit, :chain, :image_module]

  defp opts(extra) do
    {seams, known} = Keyword.split(extra, @test_only_seam_keys)
    base = Native.init(Keyword.merge([sources: @default_sources], known))

    Keyword.merge(
      base,
      Keyword.merge([output_capabilities: %{avif: true, webp: true, jpeg_xl: true}], seams)
    )
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Native.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

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
        pump.(Stream.map(chunks, & &1), "image/jpeg", fake_resolved_output(), nil)
      after
        send(test_pid, :bracket_cleanup)
      end
    end
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
          cache: {ObservingCacheProbe, []}
        )

      conn = get("/w=64/src/images/cat.jpg", config)

      assert_received :origin_fetch
      assert conn.status == 502
      assert conn.resp_body == "upstream responded 503"
      refute_received {:cache_open_sink, _key, _metadata}
    end

    # A pre-delivery failure (a fetch error, discovered before
    # `Delivery.stream/5` is ever called) must still stamp `:result` on the
    # `[:request]` span's stop metadata — the bug this test guards is
    # `Native.call/2`'s span carrying only `:status`, which renders every
    # failing request as `ok` under the default Logger's `outcome/1`
    # (AGENTS.md, telemetry guidelines).
    test "stamps :source_error as :result on the [:request] stop span" do
      test_pid = self()
      prefix = [:"native_error_paths_#{System.unique_integer([:positive])}"]

      config =
        opts(
          telemetry_prefix: prefix,
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {Origin503, test_pid: test_pid}]}
          ],
          cache: {ObservingCacheProbe, []}
        )

      handler_id = "native-error-paths-#{inspect(prefix)}"

      :telemetry.attach(
        handler_id,
        prefix ++ [:request, :stop],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:request_stop, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn = get("/w=64/src/images/cat.jpg", config)
      assert conn.status == 502

      assert_received {:request_stop, metadata}
      assert metadata[:result] == :source_error
      assert metadata[:error] == :source
      assert metadata[:status] == 502
    end
  end

  # ── row 2: client disconnect during fetch (fetch-phase variant) ─────────
  #
  # `NativeWireTest`'s "owner-kill" test (Task 15) kills the owner AFTER
  # `Coordinator.prepare/1` already has a pending producer reply in flight —
  # i.e. mid/post-fetch. This row exercises the phase T15 does NOT: the
  # owner dying WHILE `build_fun` is still doing its own fetch/decode/encode
  # work, before it has ever reached `pump` (so `Coordinator.prepare/1`
  # itself is still pending). The graceful-halt message queues in the
  # producer's mailbox and is processed once the producer next reaches a
  # receive point — proving bracket cleanup still runs exactly once even for
  # a disconnect this early.

  describe "row 2: client disconnect during fetch (fetch-phase variant of T15's owner-kill test)" do
    test "owner dies mid-fetch: prepare/1 unblocks with owner_down, cleanup still runs once" do
      test_pid = self()

      build_fun = fn pump ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :proceed -> :ok
        end

        try do
          pump.(Stream.map(["a", "b"], & &1), "image/jpeg", fake_resolved_output(), nil)
        after
          send(test_pid, :bracket_cleanup)
        end
      end

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), nil, [])
      coordinator_ref = Process.monitor(coordinator)

      prepare_task = Task.async(fn -> Coordinator.prepare(coordinator) end)
      assert_receive {:fetch_started, producer_pid}
      refute_received :bracket_cleanup

      Process.exit(owner, :kill)

      assert {:error, {:session, {:owner_down, :killed}}} = Task.await(prepare_task)

      # The producer is still "fetching" (blocked in its own receive) at the
      # moment the owner died; only once it reaches its next receive point
      # does the already-queued graceful halt get processed.
      send(producer_pid, :proceed)

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}
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
          cache: {ObservingCacheProbe, []}
        )

      conn = get("/w=64/src/images/cat.jpg", config)

      assert_received :origin_fetch
      assert conn.status == 415
      refute_received {:cache_open_sink, _key, _metadata}
    end
  end

  # ── row 4: transform failure after partial work ─────────────────────────
  #
  # `/w=64/then/blur=5/...` is two groups: the first group's resize runs
  # (real `Chain.execute/3`, proving partial work happened) before the
  # second group's blur is forced to fail via the `:chain` test seam
  # (`ImagePipe.Dialect.Native.Pipeline.run/4`'s own injectable, mirroring
  # `Executor`'s seam — real callers never set it).

  describe "row 4: transform failure after partial work" do
    test "a later group's transform failure surfaces 422 after an earlier group already executed, cleanup runs exactly once" do
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

      conn = get("/w=64/then/blur=5/src/images/cat.jpg", config)

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
          cache: {ObservingCacheProbe, []},
          image_module: RaisingAfterFirstChunkImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      log =
        capture_log(fn ->
          conn = get("/w=64/src/images/cat.jpg", config)

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

  # ── row 6: cache-lookup failure (fail-open) ──────────────────────────────

  describe "row 6: cache-lookup failure (adapter get/2 raises)" do
    test "a raising cache adapter get/2 still fails open: the generated response is delivered" do
      config = opts(cache: {RaisingGetCache, []})

      log =
        capture_log(fn ->
          conn = get("/w=64/src/images/cat.jpg", config)

          assert conn.status == 200
          assert {width, _height} = decoded_dims(conn.resp_body)
          assert width == 64
        end)

      assert log =~ "cache read error"
    end
  end

  # ── row 7: cache-write failure (fail-open) ───────────────────────────────

  describe "row 7: cache-write failure (adapter write_chunk/3 errors)" do
    test "a failing write_chunk/3 still fails open: the response is delivered, the sink aborts, no commit" do
      config = opts(cache: {FailingWriteChunkCache, []})

      conn = get("/w=64/src/images/cat.jpg", config)

      assert conn.status == 200
      assert {width, _height} = decoded_dims(conn.resp_body)
      assert width == 64

      assert_received {:cache_open_sink, _key, _metadata}
      assert_received :cache_write_chunk_failed
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
    end
  end

  # ── row 8: producer cancellation ─────────────────────────────────────────
  #
  # `NativeWireTest`'s "bracket cleanup runs exactly once after an explicit
  # mid-stream cancel" test (Task 15) already proves the process-topology
  # side of this row (producer halts, bracket cleanup runs once, both
  # children terminate) but never configures a real cache, so it cannot
  # prove sink ownership. This row adds that: cancel with a real (observing)
  # cache sink open and asserts the abort, not just the process teardown.

  describe "row 8: producer cancellation (cache-sink ownership, beyond T15's process-only coverage)" do
    test "explicit cancel/0 after the first chunk: sink aborts (never commits), cleanup once, both children terminate" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b", "c"], test_pid)

      config = [cache: {ObservingCacheProbe, []}]

      assert {:ok, prepared} =
               Delivery.stream(self(), build_fun, fake_cache_key(), %PlanResponse{}, config)

      assert prepared.first_chunk == "a"
      assert_received {:cache_open_sink, _key, _metadata}
      assert_received {:cache_write_chunk, "a"}
      refute_received :bracket_cleanup

      assert :ok = prepared.cancel.()

      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup

      # The coordinator is the session's other child. It monitors this process
      # (its owner), which is how the probe finds it; monitoring it back here is
      # what makes its teardown observable.
      for coordinator <- SessionProbe.coordinators() do
        ref = Process.monitor(coordinator)
        assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 2_000
      end

      assert SessionProbe.coordinators() == []
    end
  end

  # ── row 9: response-already-sent ─────────────────────────────────────────

  describe "row 9: response-already-sent (calls after completion are guarded, not a crash)" do
    test "next/1 and cancel/1 after normal completion (:done) return a graceful noproc error, never crash the caller" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b"], test_pid)
      owner = self()

      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), nil, [])
      coordinator_ref = Process.monitor(coordinator)

      assert {:ok, %{first_chunk: "a"}} = Coordinator.prepare(coordinator)
      assert {:chunk, "b"} = Coordinator.next(coordinator)
      assert :done = Coordinator.next(coordinator)

      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
      assert_receive :bracket_cleanup

      assert Coordinator.next(coordinator) == {:error, {:session, :noproc}}
      assert Coordinator.cancel(coordinator) == {:error, {:session, :noproc}}
    end
  end
end
