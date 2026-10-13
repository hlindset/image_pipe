defmodule ImagePipe.Delivery.TraceParentageTest do
  @moduledoc """
  Checks that `ImagePipe.Delivery.stream/4` carries the caller's request
  trace to its coordinator, producer and cache writer, with their spans
  descending transitively from that request root. The writer's span can end
  after the request's.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.Trace.SpanWalk
  alias ImagePipe.Test.Trace.TestExporter

  # No `telemetry_prefix` (project convention otherwise requires one):
  # `TestExporter`/`Capture` attach via a global `persistent_term` singleton,
  # not a prefix-scoped handler, so a prefix wouldn't isolate anything.
  # `async: false` bounds leakage instead — ExUnit runs sync modules serially.
  @moduletag :tmp_dir

  setup do
    :ok = TestExporter.attach(self())

    :ok
  end

  defp resolved_output do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  # Emits a real `Capture`-subscribed span from INSIDE the producer process,
  # then pumps — so the span is only in the request's trace if the producer
  # hop adopted the caller's context.
  defp build_fun(config) do
    fn pump ->
      Telemetry.span(Telemetry.telemetry_opts(config), [:transform, :execute], %{}, fn ->
        {:ok, %{}}
      end)

      pump.(Stream.map(["a", "b"], & &1), "image/jpeg", resolved_output(), nil)
    end
  end

  defp drain(prepared) do
    case prepared.next.() do
      {:chunk, _chunk} -> drain(prepared)
      :done -> :ok
    end
  end

  test "spans from every delivery hop are semantic descendants of the caller's request span",
       %{tmp_dir: tmp_dir} do
    config = Caches.start!(cache: [root: tmp_dir])

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {:ok, prepared} =
        Delivery.stream(
          build_fun(config),
          %Key{hash: String.duplicate("ab", 32), data: []},
          config
        )

      # Drain to EOF so the coordinator commits its sink. The commit hands the
      # entry to the cache's writer, whose write span adopts the request's
      # trace but may end after the request span.
      :ok = drain(prepared)
      {:ok, %{}}
    end)

    Caches.await_writes(config)

    spans = SpanWalk.collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"

    by_span_id = Map.new(spans, &{&1.span_id, &1})

    for name <- ["image_pipe.transform.execute", "image_pipe.cache.write"] do
      span = Enum.find(spans, &(&1.name == name))
      assert span, "expected a #{name} span"
      assert span.trace_id == root.trace_id, "#{name} must share the caller's trace"

      assert SpanWalk.descendant_of_root?(span, root, by_span_id),
             "#{name} must be a transitive descendant of the caller's request span"
    end
  end
end
