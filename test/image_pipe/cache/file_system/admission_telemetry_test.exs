defmodule ImagePipe.Cache.FileSystem.AdmissionTelemetryTest do
  # async: true is safe because each test boots Admission under a unique
  # telemetry prefix and attaches only to that prefix. Events from other
  # concurrently-running Admission instances (which use the default
  # `[:image_pipe]` prefix) never match these handlers.
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Admission

  setup do
    registry = :"#{__MODULE__}.Registry.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    tmp_dir = Path.join(System.tmp_dir!(), "admission_tel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    prefix = [:"admission_tel_#{System.unique_integer([:positive])}"]

    %{registry: registry, tmp_dir: tmp_dir, prefix: prefix}
  end

  defp opts(ctx, overrides) do
    Keyword.merge(
      [
        registry: ctx.registry,
        root: ctx.tmp_dir,
        node_id: "tel-node",
        state_dir: Path.join(ctx.tmp_dir, ".cache_state"),
        telemetry_prefix: ctx.prefix,
        pool: :input,
        max_size_bytes: 1_000_000,
        window_ratio: 0.01,
        sketch_depth: 4,
        sketch_width: 256,
        doorkeeper_cardinality: 1024,
        doorkeeper_fpr: 0.01
      ],
      overrides
    )
  end

  # Attach a forwarding handler for `prefix ++ suffix` events and tear it down
  # on exit. Each delivered event is sent to the test process as
  # `{:telemetry, event, measurements, metadata}`.
  defp attach(prefix, suffixes) do
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    test_pid = self()
    events = Enum.map(suffixes, &(prefix ++ &1))

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits a warm_start span at init", ctx do
    attach(ctx.prefix, [[:cache, :warm_start, :start], [:cache, :warm_start, :stop]])

    start_supervised!({Admission, opts(ctx, [])})

    start_event = ctx.prefix ++ [:cache, :warm_start, :start]
    stop_event = ctx.prefix ++ [:cache, :warm_start, :stop]

    assert_receive {:telemetry, ^start_event, _measurements, _meta}

    assert_receive {:telemetry, ^stop_event, %{duration: _},
                    %{own_state_loaded: false, peer_state_files: 0, pool: :input}}
  end

  test "emits an admission span with an admitted result", ctx do
    pid = start_supervised!({Admission, opts(ctx, [])})
    attach(ctx.prefix, [[:cache, :admission, :stop]])

    descriptor = %{key_hash: "h1", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    assert {:admit, []} = Admission.admit(pid, descriptor)

    stop_event = ctx.prefix ++ [:cache, :admission, :stop]

    assert_receive {:telemetry, ^stop_event, %{duration: _},
                    %{result: :admitted, victim_count: 0, pool: :input}}
  end

  test "emits an admission span with a rejected result on over-cap", ctx do
    pid = start_supervised!({Admission, opts(ctx, max_size_bytes: 4)})
    attach(ctx.prefix, [[:cache, :admission, :stop]])

    descriptor = %{key_hash: "big", size_bytes: 100, body_sha256: "s", cost_us: 1}
    assert {:reject, :over_cap} = Admission.admit(pid, descriptor)

    stop_event = ctx.prefix ++ [:cache, :admission, :stop]

    assert_receive {:telemetry, ^stop_event, _measurements,
                    %{result: :rejected, reason: :over_cap, victim_count: 0, pool: :input}}
  end

  test "emits an eviction stop event when reconciliation evicts", ctx do
    pid = start_supervised!({Admission, opts(ctx, max_size_bytes: 10_000, window_ratio: 0.0)})
    attach(ctx.prefix, [[:cache, :eviction, :stop]])

    # Hit synthesis inserts probationary entries without the admit gate, so
    # three 5_000-byte entries push usage (15_000) past the 10_000 cap.
    for i <- 1..3 do
      Admission.hit(pid, %{key_hash: "ev-#{i}", size_bytes: 5_000, body_sha256: "s", cost_us: 1})
    end

    # Flush the async hit casts, then drive a reconcile tick synchronously.
    _ = :sys.get_state(pid)
    send(pid, :reconcile)
    _ = :sys.get_state(pid)

    stop_event = ctx.prefix ++ [:cache, :eviction, :stop]

    assert_receive {:telemetry, ^stop_event, %{count: count, bytes: bytes},
                    %{trigger: :reconcile}}

    assert count >= 1
    assert bytes >= 5_000
  end

  test "emits a flush stop event when dirty state is flushed", ctx do
    pid = start_supervised!({Admission, opts(ctx, [])})
    attach(ctx.prefix, [[:cache, :flush, :stop]])

    # An admit marks state dirty; the flush tick then persists it.
    Admission.admit(pid, %{key_hash: "f1", size_bytes: 1_000, body_sha256: "s", cost_us: 1})
    send(pid, :flush)
    _ = :sys.get_state(pid)

    stop_event = ctx.prefix ++ [:cache, :flush, :stop]
    assert_receive {:telemetry, ^stop_event, %{bytes: bytes}, %{result: :ok}}
    assert bytes > 0
  end

  test "emits a cleanup stop event", ctx do
    pid = start_supervised!({Admission, opts(ctx, [])})
    attach(ctx.prefix, [[:cache, :cleanup, :stop]])

    send(pid, :cleanup)
    _ = :sys.get_state(pid)

    stop_event = ctx.prefix ++ [:cache, :cleanup, :stop]
    assert_receive {:telemetry, ^stop_event, %{removed: 0}, _meta}
  end
end
