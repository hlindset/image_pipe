defmodule ImagePipe.Telemetry.Trace.EncodeSpanTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  # Two distinct spans:
  #
  #   * [:encode] is the forced output encode (Encoder.stream_output + first_chunk),
  #     emitted from the PRODUCER process in
  #     ImagePipe.Request.DeliveryBuild.encode_first_chunk/3. It is the
  #     heaviest stage of most requests and parents to the request root — a sibling
  #     of the delivery-backstop [:transform, :materialize], in the same process.
  #
  #   * [:deliver] is connection streaming of the already-produced chunks, emitted
  #     from the REQUEST process in ImagePipe.Response.Sender.send_prepared_stream/5,
  #     nested under [:send].

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp collect_spans(timeout \\ 200) do
    receive do
      {:span, %Span{} = s} -> [s | collect_spans(timeout)]
    after
      timeout -> []
    end
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  defp parent_of(spans, %Span{parent_span_id: pid}),
    do: Enum.find(spans, &(&1.span_id == pid))

  defp beach_opts do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver:
          {ImagePipe.Parser.IIIF.Resolver.Static,
           map: %{"beach" => %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]}}}
      ],
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ]
    ]
  end

  test "the encode span measures forced encode in the producer, parented to the request root" do
    conn = call("/beach/full/!120,90/0/default.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"

    assert [encode] = Enum.filter(spans, &(&1.name == "image_pipe.encode"))
    assert encode.trace_id == root.trace_id
    assert is_integer(encode.duration_native) and encode.duration_native >= 0

    # The resize-only request streams through the chain without materializing, so the
    # only flush is the delivery backstop — which also parents to the request root.
    # encode runs right after it in the producer process, on the same trace stack, so
    # the two are siblings: same parent (the adopted request root), same pid.
    assert [materialize] =
             Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))

    assert encode.parent_span_id == root.span_id, "encode must parent to the request root"
    assert encode.parent_span_id == materialize.parent_span_id
    assert encode.pid == materialize.pid, "encode runs in the producer process"
  end

  test "the deliver span measures connection streaming, nested under [:send]" do
    conn = call("/beach/full/!120,90/0/default.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root

    assert [deliver] = Enum.filter(spans, &(&1.name == "image_pipe.deliver"))
    assert deliver.trace_id == root.trace_id

    parent = parent_of(spans, deliver)
    assert parent, "deliver span must have a captured parent"
    assert parent.name == "image_pipe.send"
    assert parent.pid == deliver.pid, "deliver and its [:send] parent run in the same process"

    grandparent = parent_of(spans, parent)
    assert grandparent && grandparent.name == "image_pipe.request"
  end

  test "encode runs in a different process than deliver" do
    conn = call("/beach/full/!120,90/0/default.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [encode] = Enum.filter(spans, &(&1.name == "image_pipe.encode"))
    assert [deliver] = Enum.filter(spans, &(&1.name == "image_pipe.deliver"))

    refute encode.pid == deliver.pid,
           "encode (producer) and deliver (request process) run in different processes"
  end
end
