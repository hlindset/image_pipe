defmodule ImagePipe.Telemetry.Trace.OtelReplayTest do
  use ExUnit.Case, async: false

  require Record

  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.Telemetry.Trace.{OtelReplay, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    OtelReplay.reset()

    server =
      start_supervised!({OtelReplay, name: :"otel_replay_#{System.unique_integer([:positive])}"})

    {:ok, server: server}
  end

  @trace "0123456789abcdef0123456789abcdef"

  test "rejects invalid startup options" do
    for invalid <- [
          [unknown: true],
          [name: "replay"],
          [ttl_ms: -1],
          [ttl_ms: :infinity],
          [sweep_interval_ms: 0],
          [sweep_interval_ms: 1.5],
          [max_traces: -1]
        ] do
      assert_raise RuntimeError, ~r/ArgumentError/, fn ->
        start_supervised!({OtelReplay, Keyword.merge([name: nil], invalid)}, id: :invalid_replay)
      end
    end
  end

  test "supports registry names and custom replay limits" do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.Registry})
    name = {:via, Registry, {__MODULE__.Registry, :replay}}

    server =
      start_supervised!(
        {OtelReplay, name: name, ttl_ms: 0, sweep_interval_ms: 60_000, max_traces: 1},
        id: :registry_replay
      )

    assert GenServer.whereis(name) == server
    OtelReplay.add(name, span(root: true))
    assert_receive {:span, _}
  end

  defp span(overrides) do
    Map.merge(
      %Span{
        trace_id: @trace,
        span_id: "89abcdef01234567",
        name: "image_pipe.request",
        start_time: System.system_time(),
        duration_native: 1,
        status: :ok,
        trace_flags: 1
      },
      Map.new(overrides)
    )
  end

  defp drain do
    receive do
      {:span, rec} -> [rec | drain()]
    after
      500 -> []
    end
  end

  test "a root span flushes immediately", %{server: server} do
    OtelReplay.add(server, span(root: true))
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
  end

  test "a nil-parent span without the root flag buffers until swept (no false root)" do
    # The setup instance already occupies the default child id; override it.
    server =
      start_supervised!({OtelReplay, name: :otel_replay_nilparent_test, ttl_ms: 0},
        id: :otel_replay_nilparent_test
      )

    OtelReplay.add(server, span(name: "image_pipe.http.client"))
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    :ok = OtelReplay.sweep(server)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.http.client"
  end

  test "children buffer until the root arrives, then parent onto OTel-minted ids", %{
    server: server
  } do
    # Finish order: deepest first (telemetry semantics).
    grandchild =
      span(
        span_id: "cccccccccccccccc",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.transform.operation"
      )

    child =
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.transform.execute"
      )

    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)

    OtelReplay.add(server, grandchild)
    OtelReplay.add(server, child)
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    OtelReplay.add(server, root)
    recs = drain()
    assert length(recs) == 3

    by_name = Map.new(recs, &{otel_span(&1, :name), &1})
    root_rec = by_name["image_pipe.request"]
    child_rec = by_name["image_pipe.transform.execute"]
    grandchild_rec = by_name["image_pipe.transform.operation"]

    # Real OTel-minted linkage at both levels.
    assert otel_span(child_rec, :parent_span_id) == otel_span(root_rec, :span_id)
    assert otel_span(grandchild_rec, :parent_span_id) == otel_span(child_rec, :span_id)

    # All share OUR forced trace_id.
    for rec <- recs do
      assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    end

    # The root's parent is the synthetic remote parent (its own internal id).
    assert otel_span(root_rec, :parent_span_id) == 0xAAAAAAAAAAAAAAAA
  end

  test "an inbound-continued root uses the real upstream parent", %{server: server} do
    OtelReplay.add(server, span(root: true, parent_span_id: "fedcba9876543210"))
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
  end

  test "a late arrival after the flush parents correctly", %{server: server} do
    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)
    OtelReplay.add(server, root)
    assert_receive {:span, root_rec}, 1_000

    late =
      span(
        span_id: "dddddddddddddddd",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.cache.write"
      )

    OtelReplay.add(server, late)
    assert_receive {:span, late_rec}, 1_000
    assert otel_span(late_rec, :parent_span_id) == otel_span(root_rec, :span_id)
  end

  test "a late child arriving before its late parent dangles (documented degradation)", %{
    server: server
  } do
    OtelReplay.add(server, span(span_id: "aaaaaaaaaaaaaaaa", root: true))
    assert_receive {:span, _root_rec}, 1_000

    # Grandchild arrives post-flush while its parent (bbbb…) has not arrived yet.
    OtelReplay.add(
      server,
      span(
        span_id: "cccccccccccccccc",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.transform.operation"
      )
    )

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :parent_span_id) == 0xBBBBBBBBBBBBBBBB
  end

  test "a buffered span whose parent chain is broken still exports on flush", %{server: server} do
    stray =
      span(
        span_id: "eeeeeeeeeeeeeeee",
        parent_span_id: "1111111111111111",
        name: "image_pipe.cache.lookup"
      )

    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)

    OtelReplay.add(server, stray)
    OtelReplay.add(server, root)

    recs = drain()
    names = Enum.map(recs, &otel_span(&1, :name))
    assert "image_pipe.cache.lookup" in names
    assert "image_pipe.request" in names
  end

  test "traces never interfere across trace_ids", %{server: server} do
    other = "ffffffffffffffffffffffffffffffff"

    OtelReplay.add(
      server,
      span(
        trace_id: other,
        span_id: "9999999999999999",
        parent_span_id: "8888888888888888",
        name: "image_pipe.parse"
      )
    )

    OtelReplay.add(server, span(root: true))
    _ = :sys.get_state(server)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    # The other trace's child stays buffered.
    refute_receive {:span, _}, 100
  end

  test "sweep flushes rootless traces flat, resolving parentage within the set" do
    server =
      start_supervised!({OtelReplay, name: :otel_replay_sweep_test, ttl_ms: 0},
        id: :otel_replay_sweep_test
      )

    t0 = System.system_time()

    parent =
      span(
        span_id: "aaaaaaaaaaaaaaaa",
        parent_span_id: "0000000000000001",
        name: "image_pipe.source.fetch",
        start_time: t0
      )

    child =
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.http.client",
        start_time: t0 + 10
      )

    # Child casts first (finish order); the forest replay must still nest it.
    OtelReplay.add(server, child)
    OtelReplay.add(server, parent)
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    :ok = OtelReplay.sweep(server)
    recs = drain()

    by_name = Map.new(recs, &{otel_span(&1, :name), &1})
    parent_rec = by_name["image_pipe.source.fetch"]
    child_rec = by_name["image_pipe.http.client"]

    # Above the swept set: dangling recorded parent id (degraded, visible).
    assert otel_span(parent_rec, :parent_span_id) == 0x0000000000000001
    # Within the swept set: real minted linkage.
    assert otel_span(child_rec, :parent_span_id) == otel_span(parent_rec, :span_id)
  end

  test "spans for new traces are shed at the max_traces cap" do
    server =
      start_supervised!({OtelReplay, name: :otel_replay_cap_test, ttl_ms: 0, max_traces: 1},
        id: :otel_replay_cap_test
      )

    OtelReplay.add(
      server,
      span(
        trace_id: "11111111111111111111111111111111",
        span_id: "1111111111111111",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.parse"
      )
    )

    OtelReplay.add(
      server,
      span(
        trace_id: "22222222222222222222222222222222",
        span_id: "2222222222222222",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.parse"
      )
    )

    _ = :sys.get_state(server)
    :ok = OtelReplay.sweep(server)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :trace_id) == 0x11111111111111111111111111111111
    # The second trace's span was shed, not buffered.
    refute_receive {:span, _}, 100
  end

  test "reset clears buffered state", %{server: server} do
    OtelReplay.add(
      server,
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.parse"
      )
    )

    :ok = OtelReplay.reset(server)
    OtelReplay.add(server, span(span_id: "aaaaaaaaaaaaaaaa", root: true))

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    refute_receive {:span, _}, 100
  end
end
