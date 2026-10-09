defmodule ImagePipe.Telemetry.Trace.InboundPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Trace.{Span, TestExporter}

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  @tp_unsampled "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"

  defp build_opts do
    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            req_options: [plug: ImagePipe.Test.PlugFixture.OriginImage]
          ]
        ]
      ]
    ]
  end

  defp valid_request_path, do: "/w=120/h=90/format=jpeg/src/images/beach.jpg"

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

  test "an inbound unsampled flag (flags=00) leaves the request unsampled" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn = call(valid_request_path(), [{"traceparent", @tp_unsampled}], build_opts())
    assert conn.status == 200

    refute_receive {:span, %Span{name: "image_pipe.request"}}, 300
  end

  test "a span the host opened wins over the inbound header" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    host = TestExporter.open_span()
    conn = call(valid_request_path(), [{"traceparent", @tp}], build_opts())
    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == host.trace_id
    assert root.parent_span_id == host.span_id
  end

  test "the inbound context does not outlive the request" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    assert call(valid_request_path(), [{"traceparent", @tp}], build_opts()).status == 200
    assert :otel_tracer.current_span_ctx() == :undefined
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

  test "non-hexadecimal flags are ignored at the request boundary" do
    prefix = [__MODULE__, :invalid_flags]
    TestExporter.attach(self(), extract_inbound: true, prefix: prefix)
    header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-+1"
    opts = Keyword.put(build_opts(), :telemetry_prefix, prefix)
    assert call(valid_request_path(), [{"traceparent", header}], opts).status == 200

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id != "0af7651916cd43dd8448eb211c80319c"
    assert root.parent_span_id == nil
  end
end
