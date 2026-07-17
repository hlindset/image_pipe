defmodule ImagePipe.Telemetry.Trace.InboundPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  @tp_unsampled "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"

  setup do
    TestExporter.set_receiver(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp build_opts do
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

  defp valid_request_path, do: "/beach/full/!120,90/0/default.jpg"

  defp call(path, headers, opts) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  test "adopts inbound traceparent when extract_inbound: true" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn = call(valid_request_path(), [{"traceparent", @tp}], build_opts())
    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == "0af7651916cd43dd8448eb211c80319c"
    assert root.parent_span_id == "b7ad6b7169203331"
  end

  test "propagates an inbound unsampled flag (flags=00) onto the root span" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn = call(valid_request_path(), [{"traceparent", @tp_unsampled}], build_opts())
    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == "0af7651916cd43dd8448eb211c80319c"
    assert root.trace_flags == 0
  end

  test "ignores traceparent by default (opt-in)" do
    :ok = TestExporter.attach(self())
    conn = call(valid_request_path(), [{"traceparent", @tp}], build_opts())
    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id != "0af7651916cd43dd8448eb211c80319c"
    assert root.parent_span_id == nil
  end

  test "malformed traceparent falls back to a fresh root" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn = call(valid_request_path(), [{"traceparent", "garbage"}], build_opts())
    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id =~ ~r/\A[0-9a-f]{32}\z/
    assert root.parent_span_id == nil
  end
end
