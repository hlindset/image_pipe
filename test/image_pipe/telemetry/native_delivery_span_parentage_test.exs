defmodule ImagePipe.Telemetry.NativeDeliverySpanParentageTest do
  @moduledoc """
  Pins that a real cache-miss, streamed `ImagePipe.Dialect.Native` request's
  stage spans are semantic descendants of the `[:request]` root span — the
  dialect counterpart of
  `ImagePipe.Telemetry.DeliverySpanParentageBaselineTest`, which pins the
  same property for the framework's request runner.

  `ImagePipe.Delivery` spans work across two process hops (the coordinator
  and the producer), neither of which inherits the caller's trace stack, so
  the request's trace context has to be carried as data and adopted on the
  far side. Both spans asserted here are emitted from a hop:
  `transform.operation` from the producer, `cache.write` from the
  coordinator.

  Asserts SEMANTICS ONLY (trace membership + transitive parent-chain descent
  to the request root), never mechanism: no PIDs, no span counts, no
  process-hop structure — the same discipline as the framework baseline.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Dialect.Native
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.TestExporter
  alias ImagePipe.Test.Trace.SpanWalk
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.OriginImage

  # No `telemetry_prefix` here (project convention otherwise requires one for
  # telemetry-asserting tests): `TestExporter`/`Capture` attach via a global
  # `persistent_term` singleton, not a prefix-scoped handler, so a prefix
  # wouldn't isolate anything. Cross-test leakage is bounded instead by
  # `async: false` — ExUnit runs sync modules serially, after all async ones.
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
  # that a cache-miss streamed native request actually exercises across the
  # two `Delivery` process hops:
  #
  #   * `image_pipe.transform.operation` — emitted per plan operation from
  #     INSIDE the producer process (hop B).
  #   * `image_pipe.cache.write` — emitted at sink commit from INSIDE the
  #     coordinator process (hop A).
  @descendant_span_names [
    "image_pipe.transform.operation",
    "image_pipe.cache.write"
  ]

  test "stage spans of a cache-miss streamed native request are semantic descendants of the request root" do
    config =
      ImagePipe.Plug.init(
        dialect: Native,
        sources: [
          path:
            {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn = ImagePipe.Plug.call(conn(:get, "/w=64/src/images/cat.jpg"), config)
    assert conn.status == 200

    spans = SpanWalk.collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"
    assert root.parent_span_id == nil

    by_span_id = Map.new(spans, &{&1.span_id, &1})

    for name <- @descendant_span_names do
      span = Enum.find(spans, &(&1.name == name))
      assert span, "expected a #{name} span"
      assert span.trace_id == root.trace_id, "#{name} must share the request's trace"

      assert SpanWalk.descendant_of_root?(span, root, by_span_id),
             "#{name} must be a transitive descendant of the request root"
    end
  end
end
