# The telemetry contract for imgproxy requests, run against BOTH stacks: the
# framework arm (`ImagePipe.Plug` + `ImagePipe.Parser.Imgproxy`) and the
# inverted dialect arm (`ImagePipe.Dialect.Imgproxy`). Same dual-run shape as
# `ImagePipe.ImgproxyWireConformanceTest` — every test body is written once and
# compiled twice, and `call_conn/2`'s dispatch on `@stack` is the only
# difference.
#
# ## What this asserts, and what it deliberately does not
#
# Semantics, not mechanism [spec §Telemetry equivalence]: stage names, stage
# ordering, and the `:result` on error stages. NOT pids, process structure, or
# raw span counts — D3's unification *intends* to change process topology, so a
# mechanism-coupled assertion here would report a false blocker.
#
# Every test uses a unique private `telemetry_prefix` and attaches on the
# prefixed names. `:telemetry` handlers are global: an `async: true` test that
# attached on the default `[:image_pipe, …]` names would have another module's
# concurrent emission leak into its mailbox, silently satisfying an assertion
# or flaking a refutation [AGENTS.md, test guidelines].
#
# ## The stage sets are NOT equal across the arms, and that is measured here
#
# The two arms emit DIFFERENT stage sets. `ImgproxyTelemetryStageSetTest` at the
# bottom of this file measures and states the difference rather than leaving it
# to be discovered: the dialect emits a strict subset, byte-identical to what the
# already-shipped `ImagePipe.Dialect.Native` emits. So the shared subset asserted
# by the dual-run tests above is the honest contract — "both arms emit the same
# stages" is not true, and this file does not claim it.
for {stack, suffix} <- [{:framework, Framework}, {:dialect, Dialect}] do
  defmodule Module.concat(ImagePipe.ImgproxyTelemetryContractTest, suffix) do
    use ExUnit.Case, async: true

    import Plug.Conn
    import Plug.Test

    @stack stack

    alias ImagePipe.Source.CacheSemantics
    alias ImagePipe.Source.Resolved
    alias ImagePipe.Source.Response
    alias ImgproxyWireConformanceTest.CacheProbe

    # A source with a STRONG byte identity, so both arms emit an ETag and the
    # 304 scenario is constructible on either. `RootHTTPAdapter` declares
    # `byte_identity: :none`, on which the framework deliberately withholds the
    # ETag entirely — a real divergence, but a wire-surface one, not this
    # file's subject.
    defmodule StableSource do
      @moduledoc false
      @behaviour ImagePipe.Source

      @impl true
      def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :stable_test)}

      @impl true
      def resolve(source, _opts, _runtime_opts) do
        path = source.segments

        {:ok,
         %Resolved{
           adapter: :path,
           source_kind: :path,
           identity: [kind: :path, adapter: :path, root: "telemetry-contract", path: path],
           internal_cache: :enabled,
           http_cache: :enabled,
           cache_semantics: %CacheSemantics{
             byte_identity: {:strong, [kind: :path, root: "telemetry-contract", path: path]},
             stable?: true
           },
           fetch: [path: path]
         }}
      end

      @impl true
      def fetch(_resolved, _opts, _runtime_opts) do
        {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
      end
    end

    # Parks the producer mid-stream, after `[:source, :fetch, :stop]` (the fetch
    # span wraps the adapter call, not the lazy enumeration). The one blocking
    # point that exists on BOTH arms — the `:chain` seam is a dialect-only
    # injectable.
    defmodule ParkingSource do
      @moduledoc false
      @behaviour ImagePipe.Source

      @impl true
      def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :parking_test)}

      @impl true
      def resolve(source, _opts, _runtime_opts) do
        path = source.segments

        {:ok,
         %Resolved{
           adapter: :path,
           source_kind: :path,
           identity: [kind: :path, adapter: :path, root: "parking", path: path],
           internal_cache: :enabled,
           http_cache: :enabled,
           cache_semantics: %CacheSemantics{
             byte_identity: {:strong, [kind: :path, root: "parking", path: path]},
             stable?: true
           },
           fetch: [path: path]
         }}
      end

      @impl true
      def fetch(_resolved, opts, _runtime_opts) do
        test_pid = Keyword.fetch!(opts, :test_pid)

        stream =
          Stream.resource(
            fn ->
              send(test_pid, {:fetch_parked, self()})

              receive do
                :proceed -> :ok
              end
            end,
            fn _ -> {:halt, :ok} end,
            fn _ -> :ok end
          )

        {:ok, %Response{stream: stream}}
      end
    end

    # A source whose `resolve/3` fails BEFORE any fetch — the pre-delivery
    # error scenario below's failure trigger. Distinct from `StableSource`
    # only in `resolve/3`'s return.
    defmodule ResolveFailingSource do
      @moduledoc false
      @behaviour ImagePipe.Source

      @impl true
      def validate_options(opts), do: {:ok, opts}

      @impl true
      def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :connect_error}}

      @impl true
      def fetch(_resolved, _opts, _runtime_opts), do: {:error, {:source, :connect_error}}
    end

    # `image_module` seam: one real chunk, then a raise — an encode failure
    # discovered only after the chunked 200 is already committed.
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

    # The union of every stage either arm can emit. Attaching on the union (not
    # on each arm's own set) is what lets a single assertion say "this stage did
    # NOT fire on this arm" — a per-arm list would make every refutation vacuous.
    @stages [
      [:request],
      [:parse],
      [:send],
      [:deliver],
      [:render],
      [:cache, :lookup],
      [:cache, :write],
      [:source, :resolve],
      [:source, :fetch],
      [:source, :fetch_decode],
      [:transform, :execute],
      [:transform, :operation],
      [:transform, :input_color_management],
      [:transform, :materialize],
      [:output, :negotiate],
      [:encode]
    ]

    # The stages BOTH arms emit for a plain image cache miss. Everything the
    # dual-run scenarios below assert positively is drawn from this set; see
    # `ImgproxyTelemetryStageSetTest` for what is outside it and why.
    @shared_stages [
      [:request],
      [:parse],
      [:source, :resolve],
      [:cache, :lookup],
      [:source, :fetch],
      [:transform, :input_color_management],
      [:transform, :operation],
      [:output, :negotiate],
      [:transform, :materialize],
      [:deliver]
    ]

    @doc false
    def handle_event(name, _measurements, metadata, test_pid) do
      send(test_pid, {:telemetry, name, metadata})
    end

    setup do
      prefix = [:"imgproxy_tel_#{@stack}_#{System.unique_integer([:positive])}"]

      events =
        Enum.flat_map(@stages, fn stage ->
          [
            prefix ++ stage ++ [:start],
            prefix ++ stage ++ [:stop],
            prefix ++ stage ++ [:exception]
          ]
        end)

      handler_id = "imgproxy-telemetry-contract-#{inspect(prefix)}"
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, prefix: prefix}
    end

    # Every span this test observed, in emission order, as
    # `{stage_suffix, phase, metadata}` — the `telemetry_prefix` stripped back
    # off so assertions read in stage vocabulary.
    defp captured(prefix, acc \\ []) do
      receive do
        {:telemetry, name, metadata} ->
          suffix = Enum.drop(name, length(prefix))
          {stage, [phase]} = Enum.split(suffix, -1)
          captured(prefix, [{stage, phase, metadata} | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end

    defp stages(events), do: events |> Enum.map(fn {stage, _phase, _meta} -> stage end)

    defp stage_set(events), do: events |> stages() |> Enum.uniq()

    defp index_of(events, stage, phase) do
      Enum.find_index(events, fn {s, p, _meta} -> s == stage and p == phase end)
    end

    # The LAST occurrence's index. `[:transform, :operation]` spans emit once per
    # operation, so a plain fit-resize produces several; the delivery-backstop
    # position assertion must anchor on the last operation `:stop`, not the first,
    # or it would pass with materialization landing between two operations.
    defp last_index_of(events, stage, phase) do
      events
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {{s, p, _meta}, i}, acc ->
        if s == stage and p == phase, do: i, else: acc
      end)
    end

    defp result_of(events, stage, phase) do
      Enum.find_value(events, fn
        {^stage, ^phase, meta} -> Map.get(meta, :result, :__absent__)
        _other -> nil
      end)
    end

    # Structural invariants that must hold of ANY request on EITHER arm.
    defp assert_well_formed!(events) do
      assert {[:request], :start, _meta} = List.first(events)

      for stage <- stage_set(events), index_of(events, stage, :stop) != nil do
        start_index = index_of(events, stage, :start)
        stop_index = index_of(events, stage, :stop)

        assert start_index != nil, "#{inspect(stage)} emitted :stop with no :start"
        assert start_index < stop_index, "#{inspect(stage)} emitted :stop before :start"
      end
    end

    defp sources(extra \\ []) do
      [path: {StableSource, extra}]
    end

    defp base_opts(extra) do
      Keyword.merge([sources: sources()], extra)
    end

    defp call(path, opts, req_headers \\ []) do
      :get
      |> conn(path)
      |> then(fn conn ->
        Enum.reduce(req_headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      end)
      |> call_conn(opts)
    end

    # `image_module` is `Output.Encoder`'s test-injection seam, which neither
    # arm's `init/1` accepts as a known option — appended after validation, the
    # convention both wire suites already use.
    @test_only_seam_keys [:image_module]

    # The single stack-invocation site: the ONLY difference between the arms.
    case @stack do
      :framework ->
        @image_path "/_/rs:fit:64:64/plain/images/beach.jpg"
        @jpeg_image_path "/_/f:jpeg/rs:fit:64:64/plain/images/beach.jpg"
        @info_path "/info/_/plain/images/beach.jpg"

        defp call_conn(%Plug.Conn{} = conn, opts) do
          {seams, known} = Keyword.split(opts, @test_only_seam_keys)
          known = Keyword.put(known, :parser, ImagePipe.Parser.Imgproxy)

          ImagePipe.Plug.call(conn, Keyword.merge(ImagePipe.Plug.init(known), seams))
        end

      :dialect ->
        @image_path "/unsafe/rs:fit:64:64/plain/images/beach.jpg"
        @jpeg_image_path "/unsafe/f:jpeg/rs:fit:64:64/plain/images/beach.jpg"
        @info_path "/info/unsafe/plain/images/beach.jpg"

        defp call_conn(%Plug.Conn{} = conn, opts) do
          {seams, known} = Keyword.split(opts, @test_only_seam_keys)

          ImagePipe.Dialect.Imgproxy.call(
            conn,
            Keyword.merge(ImagePipe.Dialect.Imgproxy.init(known), seams)
          )
        end
    end

    # ── scenario 1: image cache miss ──────────────────────────────────────

    describe "image cache miss" do
      test "emits the shared stage set, request outermost, in stage order", %{prefix: prefix} do
        opts = base_opts(telemetry_prefix: prefix, cache: {CacheProbe, []})

        assert call(@image_path, opts).status == 200

        events = captured(prefix)
        assert_well_formed!(events)

        for stage <- @shared_stages do
          assert index_of(events, stage, :start) != nil,
                 "expected #{inspect(stage)} :start on the #{@stack} arm"

          assert index_of(events, stage, :stop) != nil,
                 "expected #{inspect(stage)} :stop on the #{@stack} arm"
        end

        # `[:request]` wraps everything: it opens first and closes last.
        assert index_of(events, [:request], :start) == 0
        assert index_of(events, [:request], :stop) == length(events) - 1

        # Parse precedes every side effect — the request-safety ordering.
        assert index_of(events, [:parse], :stop) < index_of(events, [:source, :resolve], :start)

        # The cache is consulted before the source is fetched.
        assert index_of(events, [:cache, :lookup], :stop) <
                 index_of(events, [:source, :fetch], :start)

        # Bytes are fetched before they are transformed, and transformed before
        # they are delivered.
        assert index_of(events, [:source, :fetch], :stop) <
                 index_of(events, [:transform, :operation], :start)

        assert index_of(events, [:transform, :operation], :stop) <
                 index_of(events, [:deliver], :start)

        # The delivery backstop materializes the lazy vips pipeline AFTER the last
        # transform operation closes and BEFORE delivery opens — the same
        # post-clamp, pre-encode position the framework runs it at. A plain
        # fit-resize has no materializing op, so the span can only be the backstop.
        assert last_index_of(events, [:transform, :operation], :stop) <
                 index_of(events, [:transform, :materialize], :start)

        assert index_of(events, [:transform, :materialize], :stop) <
                 index_of(events, [:deliver], :start)
      end
    end

    # ── scenario 2: image cache hit ───────────────────────────────────────

    describe "image cache hit" do
      test "looks the cache up and skips the fetch and the transform entirely", %{prefix: prefix} do
        store = :ets.new(:imgproxy_telemetry_contract_hit, [:set, :public])
        opts = base_opts(telemetry_prefix: prefix, cache: {CacheProbe, store: store})

        assert call(@image_path, opts).status == 200
        # Drop the miss's events; the hit is the subject.
        _miss = captured(prefix)

        assert call(@image_path, opts).status == 200

        events = captured(prefix)
        assert_well_formed!(events)

        assert index_of(events, [:cache, :lookup], :stop) != nil

        refute [:source, :fetch] in stage_set(events)
        refute [:transform, :operation] in stage_set(events)
      end
    end

    # ── scenario 3: 304 ───────────────────────────────────────────────────

    describe "304 not-modified" do
      test "resolves before the cache lookup and before the fetch", %{prefix: prefix} do
        opts = base_opts(telemetry_prefix: prefix, cache: {CacheProbe, []})

        warm = call(@image_path, opts)
        assert warm.status == 200
        assert [etag] = get_resp_header(warm, "etag")
        _warm_events = captured(prefix)

        conn = call(@image_path, opts, [{"if-none-match", etag}])
        assert conn.status == 304

        events = captured(prefix)
        assert_well_formed!(events)

        # The ETag is pre-fetch identity material, so a conditional GET
        # short-circuits before both the cache and the source [AGENTS.md, cache
        # guidelines]. This is the assertion that would fail if either arm
        # regressed the fast path into a content hash.
        assert index_of(events, [:parse], :stop) < index_of(events, [:source, :resolve], :start)
        refute [:cache, :lookup] in stage_set(events)
        refute [:source, :fetch] in stage_set(events)
        refute [:transform, :operation] in stage_set(events)
      end
    end

    # ── scenario 4: /info/ ────────────────────────────────────────────────

    describe "/info/" do
      test "parses, resolves and fetches, and never transforms or delivers an image", %{
        prefix: prefix
      } do
        opts = base_opts(telemetry_prefix: prefix, cache: {CacheProbe, []})

        conn = call(@info_path, opts)
        assert conn.status == 200

        events = captured(prefix)
        assert_well_formed!(events)

        for stage <- [[:request], [:parse], [:source, :resolve], [:source, :fetch]] do
          assert index_of(events, stage, :start) != nil,
                 "expected #{inspect(stage)} on the #{@stack} arm's /info path"
        end

        assert index_of(events, [:parse], :stop) < index_of(events, [:source, :resolve], :start)

        # /info reads the header and renders JSON: no operation runs, and no
        # image body is streamed.
        refute [:transform, :operation] in stage_set(events)
        refute [:encode] in stage_set(events)
      end
    end

    # ── scenario 5: streamed error after preparation ──────────────────────

    describe "streamed error after preparation" do
      test "the delivery stage carries the failure as :result", %{prefix: prefix} do
        opts =
          base_opts(telemetry_prefix: prefix, cache: {CacheProbe, []}) ++
            [image_module: RaisingAfterFirstChunkImage]

        ExUnit.CaptureLog.capture_log(fn ->
          conn = call(@jpeg_image_path, opts)
          # A chunked 200 is already committed by the time encode fails.
          assert conn.status == 200
        end)

        events = captured(prefix)

        # `[:deliver]` is the one error stage BOTH arms emit. It is core-owned
        # (`Response.Sender`), which is exactly why the dialect gets it: see the
        # stage-set test below for the pre-delivery error stages it does not.
        assert result_of(events, [:deliver], :stop) == :processing_error
      end
    end

    # ── scenario 5b: pre-delivery error ─────────────────────────────────────
    #
    # Scenario 5 above pins the POST-delivery half (a failure surfacing through
    # `[:deliver]`, after `Delivery.stream/5` already returned `{:ok, _}`). This
    # pins the PRE-delivery half: a source resolve failure, discovered before
    # `route_image/2`'s `with` ever reaches `serve/7`, so `[:deliver]` never
    # opens at all. Both halves must still stamp `:result` on `[:request,
    # :stop]` — the bug this scenario guards is `call/2`'s span carrying only
    # `:status`, which renders every failing request as `ok` under the default
    # Logger's `outcome/1` (AGENTS.md, telemetry guidelines).

    describe "pre-delivery error" do
      test "the request stage carries the failure as :result", %{prefix: prefix} do
        opts = [
          telemetry_prefix: prefix,
          cache: {CacheProbe, []},
          sources: [path: {ResolveFailingSource, []}]
        ]

        conn = call(@image_path, opts)
        assert conn.status == 404

        events = captured(prefix)

        refute [:deliver] in stage_set(events)
        assert result_of(events, [:request], :stop) == :source_error
      end
    end

    # ── scenario 6: owner cancellation ────────────────────────────────────

    describe "owner cancellation" do
      test "an abandoned request emits no completion telemetry", %{prefix: prefix} do
        test_pid = self()

        opts =
          [
            sources: [path: {ParkingSource, test_pid: test_pid}],
            telemetry_prefix: prefix,
            cache: {CacheProbe, []}
          ]

        owner = spawn(fn -> call(@image_path, opts) end)
        owner_ref = Process.monitor(owner)

        assert_receive {:fetch_parked, producer_pid}

        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

        send(producer_pid, :proceed)

        events = captured(prefix)

        # The request span opened; it must never claim to have closed. A
        # `[:request, :stop]` here would be a phantom completion — a dashboard
        # would count a request the client never received.
        assert index_of(events, [:request], :start) == 0
        refute index_of(events, [:request], :stop)
        refute index_of(events, [:deliver], :stop)
      end
    end
  end
end

defmodule ImagePipe.ImgproxyTelemetryStageSetTest do
  @moduledoc """
  Measures the stage sets the three stacks actually emit for one plain image
  cache miss, and states the difference.

  This exists because the design spec asserts "the dialect emits the same
  standard stage names as native (`[:request]`, `[:parse]`, …), so no Logger or
  `Trace.Capture` list changes are expected — **asserted by the telemetry
  contract test above, not assumed**". That claim is TRUE and this file is where
  it is checked. But the neighbouring claim a reader is likely to infer — that
  the dialect arm and the FRAMEWORK arm are telemetry-equivalent — is FALSE, and
  it would be dishonest to leave the dual-run tests' green to imply it.

  The framework emits seven stages neither dialect does. Six of them are owned by
  framework-only modules (`ImagePipe.Plug`, `Request.Processor`,
  `Request.DeliveryBuild`), which no dialect routes through; the dialects reach
  the core toolkit directly. The observable consequence is recorded in
  `docs/imgproxy_support_matrix.md` and in the phase-1 exit criteria: a request
  that fails BEFORE delivery emits no `:result` on any stage on a dialect arm,
  so `ImagePipe.Telemetry.Logger`'s `outcome/1` renders it `:ok` and
  `level_for/3` never escalates it.

  This is NOT a regression introduced by the imgproxy dialect: it asserts, by
  measurement, that `Dialect.Imgproxy` matches the already-shipped
  `Dialect.Native` exactly.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  # Safe to alias here, unlike inside the dual-run loop above: this module is
  # deliberately NOT parameterized — comparing the two dialects head to head is
  # its whole subject.
  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.Dialect.Native
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage

  @stages [
    [:request],
    [:parse],
    [:send],
    [:deliver],
    [:render],
    [:cache, :lookup],
    [:cache, :write],
    [:source, :resolve],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:transform, :operation],
    [:transform, :input_color_management],
    [:transform, :materialize],
    [:output, :negotiate],
    [:encode]
  ]

  @framework_only [
    [:send],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:encode]
  ]

  @doc false
  def handle_event(name, _measurements, _metadata, test_pid) do
    send(test_pid, {:telemetry, name})
  end

  defp sources do
    [path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}]
  end

  defp attach(prefix) do
    events =
      Enum.flat_map(@stages, fn stage ->
        [prefix ++ stage ++ [:start], prefix ++ stage ++ [:stop], prefix ++ stage ++ [:exception]]
      end)

    handler_id = "imgproxy-telemetry-stage-set-#{inspect(prefix)}"
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain(prefix, acc \\ []) do
    receive do
      {:telemetry, name} ->
        {stage, [_phase]} = name |> Enum.drop(length(prefix)) |> Enum.split(-1)
        drain(prefix, [stage | acc])
    after
      200 -> acc |> Enum.reverse() |> Enum.uniq()
    end
  end

  defp stage_set_for(:framework) do
    prefix = [:"stage_set_fw_#{System.unique_integer([:positive])}"]
    attach(prefix)

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: sources(),
        telemetry_prefix: prefix
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/rs:fit:64:64/plain/images/beach.jpg"), opts)
    assert conn.status == 200
    drain(prefix)
  end

  defp stage_set_for(:imgproxy_dialect) do
    prefix = [:"stage_set_di_#{System.unique_integer([:positive])}"]
    attach(prefix)

    opts = Imgproxy.init(sources: sources(), telemetry_prefix: prefix)

    conn =
      Imgproxy.call(conn(:get, "/unsafe/rs:fit:64:64/plain/images/beach.jpg"), opts)

    assert conn.status == 200
    drain(prefix)
  end

  defp stage_set_for(:native_dialect) do
    prefix = [:"stage_set_nat_#{System.unique_integer([:positive])}"]
    attach(prefix)

    opts = Native.init(sources: sources(), telemetry_prefix: prefix)

    conn = Native.call(conn(:get, "/w=64/src/images/beach.jpg"), opts)
    assert conn.status == 200
    drain(prefix)
  end

  test "Dialect.Imgproxy emits exactly the stage sequence the shipped Dialect.Native does" do
    # Sequence, not set: the dialects must agree on stage ORDER too, and a set
    # comparison would let a reordering through. This is the spec's actual
    # telemetry claim, and it holds.
    assert stage_set_for(:imgproxy_dialect) == stage_set_for(:native_dialect)
  end

  test "the framework emits seven stages no dialect does, and no dialect emits a stage it does not" do
    framework = stage_set_for(:framework)
    dialect = stage_set_for(:imgproxy_dialect)

    # The dialect's stages are a strict subset: it invents nothing.
    assert dialect -- framework == []

    # And the difference is exactly this pinned list. A future change that
    # closes any of these gaps must update this list — which is the point: the
    # gap is a documented contract, not a silent hole.
    assert Enum.sort(framework -- dialect) == Enum.sort(@framework_only)
  end
end
