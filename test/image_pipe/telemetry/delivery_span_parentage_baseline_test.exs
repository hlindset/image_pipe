defmodule ImagePipe.Telemetry.DeliverySpanParentageBaselineTest do
  @moduledoc """
  D3 topology-gate OTel PARENTAGE BASELINE (immutable): pins that a real
  cache-miss, streamed framework request's stage spans are semantic
  descendants of the `[:request]` root span — the property D3's topology
  change (moving `SourceSession`/`Producer` off a `DynamicSupervisor`-owned
  process onto a monitor-based one) most directly puts at risk, since span
  parentage today is stitched across process hops
  (`ImagePipe.Telemetry.Trace.Stack` adopting a `trace_context` in the
  spawned Producer/SourceSession processes).

  Deliberately asserts SEMANTICS ONLY (trace membership + transitive
  parent-chain descent to the request root), never mechanism: no PIDs, no
  span counts, no process-hop structure. D3 intends to change the process
  topology that produces this parentage; asserting the mechanism instead of
  the semantics would make this baseline a false gate. Task 3 must keep this
  test passing UNMODIFIED; a weakened or edited assertion is a gate failure.

  Prior art: `test/image_pipe/telemetry/trace/cross_process_test.exs` pins
  the same underlying property (hop A/hop B span parentage) at a finer,
  mechanism-adjacent grain; this file is the topology-gate-specific,
  semantics-only baseline.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.OriginImage

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  # Real, exact `@span_stages` names from `ImagePipe.Telemetry.Trace.Capture`
  # (verified against the source, not assumed): the source/transform/encode
  # stage family a cache-miss streamed request exercises, plus `[:deliver]` —
  # itself nested under `[:send]`, not a direct child of `[:request]` — is
  # included deliberately, as proof this test asserts genuine transitive
  # descent, not just direct parentage.
  @descendant_span_names [
    "image_pipe.source.fetch_decode",
    "image_pipe.transform.execute",
    "image_pipe.encode",
    "image_pipe.cache.write",
    "image_pipe.deliver"
  ]

  test "stage spans of a cache-miss streamed request are semantic descendants of the request root" do
    conn = conn(:get, "/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg")

    opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ],
      cache: {CacheProbe, result: :miss}
    ]

    conn = ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
    assert conn.status == 200

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"
    assert root.parent_span_id == nil

    by_span_id = Map.new(spans, &{&1.span_id, &1})

    for name <- @descendant_span_names do
      span = Enum.find(spans, &(&1.name == name))
      assert span, "expected a #{name} span"
      assert span.trace_id == root.trace_id, "#{name} must share the request's trace"

      assert descendant_of_root?(span, root, by_span_id),
             "#{name} must be a transitive descendant of the request root"
    end
  end

  defp collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  # Walks `parent_span_id` links from `span` up to `root`'s span_id — true
  # once the chain reaches root, false if the chain runs out first.
  # Deliberately structural over `parent_span_id` alone (no PID/process
  # assumptions), so it stays valid across a topology change.
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
