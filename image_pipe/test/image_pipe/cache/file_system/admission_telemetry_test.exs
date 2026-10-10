defmodule ImagePipe.Cache.FileSystem.AdmissionTelemetryTest do
  # async: true is safe because each test boots Admission under a unique
  # telemetry prefix and attaches only to that prefix. Events from other
  # concurrently-running Admission instances (which use the default
  # `[:image_pipe]` prefix) never match these handlers.
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "admission_tel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    alias ImagePipe.Cache.FileSystem

    registry = FileSystem.registry_name(tmp_dir)
    start_supervised!({Registry, keys: :unique, name: registry})

    prefix = [:"admission_tel_#{System.unique_integer([:positive])}"]

    %{registry: registry, tmp_dir: tmp_dir, prefix: prefix}
  end

  # The cache options a bounded pool would use, and the Admission options
  # built from them.
  defp cache_opts(ctx, overrides) do
    Keyword.merge(
      [root: ctx.tmp_dir, pool: :input, max_size_bytes: 1_000_000, sketch_width: 256],
      overrides
    )
  end

  defp opts(ctx, overrides) do
    ctx
    |> cache_opts(overrides)
    |> Keyword.put(:telemetry_prefix, ctx.prefix)
    |> Store.admission_options(ctx.registry)
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

  test "emits an admission span with an admitted result", ctx do
    alias ImagePipe.Test.CacheEntry

    start_supervised!({Admission, opts(ctx, [])})
    attach(ctx.prefix, [[:cache, :admission, :stop]])

    pool = cache_opts(ctx, [])
    assert :ok = CacheEntry.put(pool, String.duplicate("x", 5_000))

    stop_event = ctx.prefix ++ [:cache, :admission, :stop]

    assert_receive {:telemetry, ^stop_event, %{duration: _},
                    %{result: :admitted, victim_count: 0, pool: :input}}
  end

  test "emits an admission span with a rejected result on over-cap", ctx do
    alias ImagePipe.Test.CacheEntry

    start_supervised!({Admission, opts(ctx, max_size_bytes: 4)})
    attach(ctx.prefix, [[:cache, :admission, :stop]])

    pool = cache_opts(ctx, max_size_bytes: 4)
    assert {:ok, :rejected} = CacheEntry.put(pool, String.duplicate("x", 100))

    stop_event = ctx.prefix ++ [:cache, :admission, :stop]

    assert_receive {:telemetry, ^stop_event, _measurements,
                    %{result: :rejected, reason: :over_cap, victim_count: 0, pool: :input}}
  end

  test "emits an eviction stop event when reconciliation evicts", ctx do
    alias ImagePipe.Cache.Entry
    alias ImagePipe.Cache.FileSystem
    alias ImagePipe.Cache.Key

    metadata = %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :png
    }

    for i <- 1..3 do
      key = %Key{hash: String.duplicate(Integer.to_string(i), 64), data: []}
      pool = [root: ctx.tmp_dir]
      {:ok, sink} = FileSystem.open_sink(key, metadata, pool)
      {:ok, sink} = FileSystem.write_chunk(sink, String.duplicate("x", 5_000), pool)
      assert :ok = FileSystem.commit_sink(sink, pool)
    end

    attach(ctx.prefix, [[:cache, :eviction, :stop]])
    pid = start_supervised!({Admission, opts(ctx, max_size_bytes: 10_000, window_ratio: 0.0)})
    Admission.await_scan(pid)

    stop_event = ctx.prefix ++ [:cache, :eviction, :stop]

    assert_receive {:telemetry, ^stop_event, %{count: count, bytes: bytes},
                    %{trigger: :reconcile}}

    assert count >= 1
    assert bytes >= 5_000
  end
end
