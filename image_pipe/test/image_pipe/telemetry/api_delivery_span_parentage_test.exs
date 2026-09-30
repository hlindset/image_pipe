defmodule ImagePipe.Telemetry.APIDeliverySpanParentageTest do
  @moduledoc """
  Checks that a real cache-miss, streamed Plug request's stage spans share
  its trace and descend transitively from the request root, including spans
  emitted by the delivery coordinator and producer.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.TestExporter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias ImagePipe.Test.PlugFixture.OriginImage
  alias ImagePipe.Test.Trace.SpanWalk

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

  @descendant_span_names [
    "image_pipe.source.fetch_decode",
    "image_pipe.transform.execute",
    "image_pipe.transform.operation",
    "image_pipe.encode",
    "image_pipe.cache.write",
    "image_pipe.deliver"
  ]

  test "stage spans of a cache-miss streamed API request are semantic descendants of the request root" do
    config =
      ImagePipe.Plug.init(
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
