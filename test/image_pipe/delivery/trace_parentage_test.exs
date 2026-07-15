defmodule ImagePipe.Delivery.TraceParentageTest do
  @moduledoc """
  `ImagePipe.Delivery` spans a session across two processes, neither of which
  inherits the calling process's trace stack. This pins the primitive's half
  of the bargain: a calling dialect opens its request span and calls
  `stream/5` from that process, and both hops' spans land in the same trace,
  descended from it — the dialect passes no trace context and cannot forget
  to.

  Asserts semantics only (trace membership + transitive descent), never
  mechanism — the same discipline as
  `ImagePipe.Telemetry.DeliverySpanParentageBaselineTest`.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  defmodule SilentCacheProbe do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(_key, _metadata, _opts), do: {:ok, %{}}

    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}

    @impl true
    def commit_sink(_state, _opts), do: :ok

    @impl true
    def abort_sink(_state, _opts), do: :ok
  end

  # No `telemetry_prefix` (project convention otherwise requires one):
  # `TestExporter`/`Capture` attach via a global `persistent_term` singleton,
  # not a prefix-scoped handler, so a prefix wouldn't isolate anything.
  # `async: false` bounds leakage instead — ExUnit runs sync modules serially.
  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

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

  test "spans from both delivery hops are semantic descendants of the caller's request span" do
    config = [cache: {SilentCacheProbe, []}]

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {:ok, prepared} =
        Delivery.stream(
          self(),
          build_fun(config),
          %Key{hash: "k", data: []},
          %PlanResponse{},
          config
        )

      # Drain to EOF so the coordinator commits its sink — that commit is the
      # coordinator-hop span this test asserts on.
      :ok = drain(prepared)
      {:ok, %{}}
    end)

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"

    by_span_id = Map.new(spans, &{&1.span_id, &1})

    for name <- ["image_pipe.transform.execute", "image_pipe.cache.write"] do
      span = Enum.find(spans, &(&1.name == name))
      assert span, "expected a #{name} span"
      assert span.trace_id == root.trace_id, "#{name} must share the caller's trace"

      assert descendant_of_root?(span, root, by_span_id),
             "#{name} must be a transitive descendant of the caller's request span"
    end
  end

  defp collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  defp descendant_of_root?(%Span{} = span, %Span{span_id: root_id}, by_span_id),
    do: walk_to_root(span.parent_span_id, root_id, by_span_id)

  defp walk_to_root(nil, _root_id, _by_span_id), do: false
  defp walk_to_root(id, root_id, _by_span_id) when id == root_id, do: true

  defp walk_to_root(id, root_id, by_span_id) do
    case Map.fetch(by_span_id, id) do
      {:ok, %Span{parent_span_id: parent_id}} -> walk_to_root(parent_id, root_id, by_span_id)
      :error -> false
    end
  end
end
