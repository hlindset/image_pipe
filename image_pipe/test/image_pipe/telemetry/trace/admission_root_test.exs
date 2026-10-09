defmodule ImagePipe.Telemetry.Trace.AdmissionRootTest do
  # A [:cache, :admission] span emitted from the long-lived Admission GenServer
  # is its own trace root even when the cache writer has a span current: the
  # handler runs in the GenServer process, never the caller's.
  #
  # async: false is required by TestExporter (it routes spans through a global
  # :persistent_term receiver).
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Test.CacheEntry
  alias ImagePipe.Test.Trace.{Span, TestExporter}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "admission_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    alias ImagePipe.Cache.FileSystem

    registry = FileSystem.registry_name(tmp_dir)
    start_supervised!({Registry, keys: :unique, name: registry})

    # The Admission GenServer emits under this custom prefix; the handler
    # subscribes per prefix, so the tracer must be attached with the same one.
    prefix = [:"admission_root_#{System.unique_integer([:positive])}"]
    :ok = TestExporter.attach(self(), prefix: prefix)

    %{registry: registry, tmp_dir: tmp_dir, prefix: prefix}
  end

  defp opts(ctx) do
    [
      registry: ctx.registry,
      root: ctx.tmp_dir,
      node_id: "tel-node",
      state_dir: Path.join(ctx.tmp_dir, ".cache_state"),
      telemetry_prefix: ctx.prefix,
      max_size_bytes: 1_000_000,
      window_ratio: 0.01,
      sketch_depth: 4,
      sketch_width: 256,
      doorkeeper_cardinality: 1024,
      doorkeeper_fpr: 0.01
    ]
  end

  test "cache.admission becomes its own trace root despite the caller's current span", ctx do
    start_supervised!({Admission, opts(ctx)})
    caller = TestExporter.open_span()

    pool = Keyword.drop(opts(ctx), [:registry, :telemetry_prefix])
    assert :ok = CacheEntry.put(pool, String.duplicate("x", 5_000))

    # The handler names the stage under "image_pipe." whatever the prefix.
    assert_receive {:span, %Span{name: "image_pipe.cache.admission"} = span}

    assert span.parent_span_id == nil
    assert span.trace_id != caller.trace_id
  end
end
