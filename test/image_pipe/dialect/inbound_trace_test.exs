defmodule ImagePipe.Dialect.InboundTraceTest do
  @moduledoc """
  Both inverted dialects must continue an inbound W3C trace under
  `extract_inbound: true`, exactly as `ImagePipe.Plug` does — the root
  `[:request]` span adopts the caller's trace id and parent span id instead of
  starting a fresh trace.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy, as: ImgproxyDialect
  alias ImagePipe.Dialect.Native, as: NativeDialect
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  @trace_id "0af7651916cd43dd8448eb211c80319c"
  @parent_span_id "b7ad6b7169203331"

  setup do
    TestExporter.set_receiver(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
    ]
  end

  defp get(init_opts, path, headers) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(init_opts))
  end

  describe "ImagePipe.Dialect.Imgproxy" do
    test "adopts an inbound traceparent when extract_inbound: true" do
      :ok = TestExporter.attach(self(), extract_inbound: true)

      conn =
        get(
          [dialect: ImgproxyDialect, sources: sources()],
          "/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg",
          [
            {"traceparent", @tp}
          ]
        )

      assert conn.status == 200

      assert_receive {:span, %Span{name: "image_pipe.request"} = root}
      assert root.trace_id == @trace_id
      assert root.parent_span_id == @parent_span_id
    end

    test "ignores traceparent by default (opt-in)" do
      :ok = TestExporter.attach(self())

      conn =
        get(
          [dialect: ImgproxyDialect, sources: sources()],
          "/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg",
          [
            {"traceparent", @tp}
          ]
        )

      assert conn.status == 200

      assert_receive {:span, %Span{name: "image_pipe.request"} = root}
      assert root.trace_id != @trace_id
      assert root.parent_span_id == nil
    end
  end

  describe "ImagePipe.Dialect.Native" do
    test "adopts an inbound traceparent when extract_inbound: true" do
      :ok = TestExporter.attach(self(), extract_inbound: true)

      conn =
        get(
          [dialect: NativeDialect, sources: sources()],
          "/w=64/src/images/beach.jpg",
          [{"traceparent", @tp}]
        )

      assert conn.status == 200

      assert_receive {:span, %Span{name: "image_pipe.request"} = root}
      assert root.trace_id == @trace_id
      assert root.parent_span_id == @parent_span_id
    end

    test "ignores traceparent by default (opt-in)" do
      :ok = TestExporter.attach(self())

      conn =
        get(
          [dialect: NativeDialect, sources: sources()],
          "/w=64/src/images/beach.jpg",
          [{"traceparent", @tp}]
        )

      assert conn.status == 200

      assert_receive {:span, %Span{name: "image_pipe.request"} = root}
      assert root.trace_id != @trace_id
      assert root.parent_span_id == nil
    end
  end
end
