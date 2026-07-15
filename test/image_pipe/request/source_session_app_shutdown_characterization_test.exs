defmodule ImagePipe.Request.SourceSessionAppShutdownCharacterizationTest do
  @moduledoc """
  D3 topology-gate BASELINE B (spec §D3 in detail): a mechanism-coupled
  CHARACTERIZATION of the supervised topology's app-tree shutdown guarantee —
  that stopping the `ImagePipe.Request.SourceSessionSupervisor` DynamicSupervisor
  (e.g. as part of `Application.stop(:image_plug)`) terminates an in-flight
  prepared delivery, with cleanup firing exactly once.

  This file CANNOT survive the D3 migration unmodified: the guarantee it pins
  is a property of the supervision tree itself (a `DynamicSupervisor` stopping
  its children), not of any topology-neutral request contract. Its fate —
  deleted because the user ruled the app-tree arm out of contract, or kept
  because the user ruled it in contract (which selects the dialects-only
  branch, since the monitor topology structurally cannot preserve the app-tree
  guarantee) — is decided at the Task 1 checkpoint and recorded in the audit
  report (`.superpowers/sdd/d3-audit-report.md`). Task 3 executes that ruling;
  it does not make it.

  Baseline A (owner-death cleanup, immutable, topology-neutral) lives in
  `delivery_owner_cleanup_baseline_test.exs`, deliberately in a separate file
  so Task 3 never has to touch a file containing an immutable baseline while
  acting on this one.

  The request-construction helpers below are copied (in spirit) from
  `test/image_pipe/request/source_session_supervisor_test.exs` — not imported
  across test modules, per that file's own isolation.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Request.SourceSession
  alias ImagePipe.Request.SourceSession.Prepared
  alias ImagePipe.Request.SourceSession.Request
  alias ImagePipe.Request.SourceSessionSupervisor
  alias ImagePipe.Source.Resolved, as: ResolvedSource
  alias ImagePipe.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  # Cache adapter stub. `open_sink`/`write_chunk` are inert (the fixture just
  # needs a non-nil sink so `abort_sink` has something to abort on shutdown);
  # `abort_sink` is the observation point.
  defmodule InertCache do
    @behaviour ImagePipe.Cache

    @impl true
    def validate_options(opts), do: {:ok, opts}
    @impl true
    def get(_key, _opts), do: :miss
    @impl true
    def open_sink(key, _metadata, _opts), do: {:ok, %{key: key}}
    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    @impl true
    def commit_sink(_state, _opts), do: :ok
    @impl true
    def abort_sink(_state, _opts), do: :ok
  end

  # ── Baseline B — mechanism-coupled characterization (fate: checkpoint) ──
  test "app-tree shutdown terminates an in-flight prepared delivery, cache cleanup exactly once" do
    # Characterizes source_session_supervisor_test.exs:134's guarantee
    # ("supervisor shutdown is parent shutdown, not request owner death") under
    # an app-tree-shaped shutdown: this test CANNOT survive the D3 migration;
    # its fate is decided at the Task 1 checkpoint (see moduledoc), never
    # silently at Task 3.
    #
    # NOTE on the observation point: a raw `Supervisor.stop/2` (like a raw
    # owner-kill — see Baseline A's moduledoc) does NOT gracefully halt the
    # producer's output stream; `stop_producer/2` hard-kills it
    # (`Process.exit(producer, :shutdown)`), which does not invoke a
    # `Stream.resource/3` `after` callback (that callback only runs when the
    # reduce is explicitly told to halt — verified empirically, not merely
    # asserted). So the observable "cleanup fired exactly once" signal here is
    # the real `[:cache, :stage]` telemetry event `SourceSession` emits from
    # `abort_cache_sink/2` (`ImagePipe.Cache.Sink.abort/3`) when it tears down
    # the open cache sink — genuine production instrumentation, not a
    # supervisor-internal count.
    infra = start_supervised!({SourceSessionSupervisor, name: nil})

    telemetry_prefix = [:"d3_baseline_b_#{System.unique_integer([:positive])}"]
    stage_event = telemetry_prefix ++ [:cache, :stage]
    test_pid = self()
    handler_id = "d3-baseline-b-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      stage_event,
      fn _event, _measurements, meta, _config -> send(test_pid, {:cache_stage, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, session} =
      SourceSessionSupervisor.start_session(
        infra,
        request(
          cache_key: %Key{hash: "d3-baseline-b", data: []},
          opts:
            opts(
              image_module: MultiChunkImage,
              cache: {InertCache, []},
              telemetry_prefix: telemetry_prefix
            )
        ),
        owner: self()
      )

    session_ref = Process.monitor(session)
    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    ExUnit.CaptureLog.capture_log(fn -> Supervisor.stop(infra, :shutdown) end)

    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}

    # cleanup exactly once: the cache-sink abort telemetry fires exactly one time
    assert_receive {:cache_stage, %{cache: :stage_abandoned, reason: :cancelled}}
    refute_receive {:cache_stage, _}, 100
  end

  defp request(overrides) do
    %Request{
      plan: Keyword.get(overrides, :plan, plan()),
      resolved_source: Keyword.get(overrides, :resolved_source, resolved_source()),
      output_policy: Keyword.get(overrides, :output_policy, output_policy()),
      opts: Keyword.get(overrides, :opts, opts()),
      cache_key: Keyword.get(overrides, :cache_key)
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
      fetch: :fixture
    }
  end

  defp output_policy do
    %Policy{
      mode: {:explicit, :jpeg},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp opts(extra_opts \\ []) do
    Keyword.merge(
      [
        sources: %{path: {ValidAdapter, []}},
        image_module: MultiChunkImage,
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      ],
      extra_opts
    )
  end
end
