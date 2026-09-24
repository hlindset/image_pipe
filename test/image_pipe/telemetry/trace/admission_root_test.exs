defmodule ImagePipe.Telemetry.Trace.AdmissionRootTest do
  # Positive coverage for spec §8.1: a [:cache, :admission] span emitted from the
  # long-lived Admission GenServer becomes its OWN trace root (parent_span_id == nil,
  # fresh trace_id) EVEN WHEN the cache writer carries a request trace
  # context on its stack. The GenServer process boundary severs the trace: the Capture
  # handler runs in the GenServer process (empty Stack), never the caller's.
  #
  # async: false is required by TestExporter (it routes spans through a global
  # :persistent_term receiver).
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Context, Span, Stack, TestExporter}
  alias ImagePipe.Test.CacheEntry

  # A request context the CALLER carries on its stack. If admission inherited the
  # caller's context, the emitted span would reuse this trace_id / parent under it.
  @caller_trace_id "deadbeefdeadbeefdeadbeefdeadbeef"
  @caller_span_id "1111111111111111"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "admission_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    alias ImagePipe.Cache.FileSystem

    registry = FileSystem.registry_name(tmp_dir)
    start_supervised!({Registry, keys: :unique, name: registry})

    # The Admission GenServer emits under this custom prefix; the Capture handler
    # subscribes per-prefix, so the tracer must be attached with the SAME prefix.
    prefix = [:"admission_root_#{System.unique_integer([:positive])}"]

    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self(), prefix: prefix)

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
      # Drop the adopted caller frame so it doesn't leak into other tests.
      Stack.clear()
    end)

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

  test "cache.admission becomes its own trace root despite an adopted caller context (§8.1)",
       ctx do
    start_supervised!({Admission, opts(ctx)})

    # The cache writer carries a request context.
    Stack.adopt(%Context{
      trace_id: @caller_trace_id,
      span_id: @caller_span_id,
      trace_flags: 1
    })

    pool = Keyword.drop(opts(ctx), [:registry, :telemetry_prefix])
    assert :ok = CacheEntry.put(pool, String.duplicate("x", 5_000))

    # Capture strips the configured prefix and re-roots the name under "image_pipe.",
    # so the [:cache, :admission] stage always surfaces as this name regardless of the
    # custom telemetry prefix the GenServer uses.
    assert_receive {:span, %Span{name: "image_pipe.cache.admission"} = span}

    # The GenServer process boundary severed the trace: the span did NOT inherit the
    # caller's adopted context.
    assert span.parent_span_id == nil
    assert span.trace_id != @caller_trace_id
  end
end
