defmodule ImagePipe.Telemetry.Trace.CrossProcessTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImgproxyWireConformanceTest.CacheProbe

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  # A cache-miss request that fetches + decodes a real source and writes to cache.
  # CacheProbe(result: :miss) drives open_sink -> write_chunk -> commit_sink, so the
  # [:cache, :write] span fires from the delivery coordinator process (hop A target).
  defp miss_opts do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver:
          {ImagePipe.Dialect.IIIF.Resolver.Static,
           map: %{"beach" => %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]}}}
      ],
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ],
      cache: {CacheProbe, result: :miss}
    ]
  end

  defp request_path, do: "/beach/full/!120,90/0/default.jpg"

  test "producer-process spans share the request trace_id and parent under it (hop B)" do
    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    fetch = Enum.find(spans, &(&1.name == "image_pipe.source.fetch_decode"))

    assert root && fetch, "expected request + source.fetch_decode spans"
    assert fetch.trace_id == root.trace_id
    refute fetch.parent_span_id == nil
  end

  test "cache write parents under the request (hop A)" do
    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    write = Enum.find(spans, &(&1.name == "image_pipe.cache.write"))

    assert root && write, "expected request + cache.write spans"
    assert write.trace_id == root.trace_id
  end

  test "cache admission is a separate root, not under the request (§8.1)" do
    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    admission = Enum.find(spans, &(&1.name == "image_pipe.cache.admission"))

    assert root, "expected request root span"

    # Admission runs in the shared Admission GenServer with no request context
    # threaded (spec §8.1): it must NOT share the request trace. CacheProbe does
    # not run an admission GenServer, so the span is typically absent here and this
    # guard is effectively a no-op. The real POSITIVE coverage — a [:cache, :admission]
    # span emitted from a live Admission GenServer staying a separate root even with a
    # caller context adopted on the stack — lives in
    # ImagePipe.Telemetry.Trace.AdmissionRootTest.
    if admission do
      assert admission.parent_span_id == nil
      assert admission.trace_id != root.trace_id
    end
  end
end
