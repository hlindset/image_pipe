defmodule ImagePipe.Telemetry.Trace.AdmissionRootTest do
  # A [:cache, :admission] span emitted from the long-lived Admission GenServer
  # is its own trace root even when the cache writer has a span current: the
  # handler runs in the GenServer process, never the caller's.
  #
  # async: false is required by TestExporter (it routes spans through a global
  # :persistent_term receiver).
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
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

  defp cache_opts(ctx), do: [root: ctx.tmp_dir, max_size_bytes: 1_000_000]

  defp opts(ctx) do
    ctx
    |> cache_opts()
    |> Keyword.put(:telemetry_prefix, ctx.prefix)
    |> Store.admission_options(ctx.registry)
  end

  test "cache.admission becomes its own trace root despite the caller's current span", ctx do
    start_supervised!({Admission, opts(ctx)})
    caller = TestExporter.open_span()

    pool = cache_opts(ctx)
    assert :ok = CacheEntry.put(pool, String.duplicate("x", 5_000))

    # The handler names the stage under "image_pipe." whatever the prefix.
    assert_receive {:span, %Span{name: "image_pipe.cache.admission"} = span}

    assert span.parent_span_id == nil
    assert span.trace_id != caller.trace_id
  end
end
