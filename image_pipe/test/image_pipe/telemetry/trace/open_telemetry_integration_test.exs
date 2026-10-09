defmodule ImagePipe.Telemetry.Trace.OpenTelemetryIntegrationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Trace.TestExporter

  # Inline plug: serves beach.jpg for any request path (ignores query params).
  # Used by signed_miss_opts so the Req plug-adapter handles the signed fetch URL.
  defmodule SignedOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Inline source adapter that wraps RootHTTPAdapter but appends
  # ?X-Amz-Signature=fake123abcdef to the resolved fetch URL, so the request
  # lifecycle exercises a signed-URL code path end-to-end.
  defmodule SignedRootHTTPAdapter do
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl true
    def identifiers(_options),
      do: [ImagePipe.Plan.Source.Path, ImagePipe.Plan.Source.URL, ImagePipe.Plan.Source.Object]

    alias ImagePipe.Source.Resolved

    @impl true
    def validate_options(opts), do: RootHTTPAdapter.validate_options(opts)

    @impl true
    def resolve(source, opts, runtime_opts) do
      {:ok, %Resolved{fetch: fetch} = resolved} =
        RootHTTPAdapter.resolve(source, opts, runtime_opts)

      url = Keyword.fetch!(fetch, :url)
      signed_url = url <> "?X-Amz-Signature=fake123abcdef"
      {:ok, %{resolved | fetch: Keyword.put(fetch, :url, signed_url)}}
    end

    @impl true
    def fetch(resolved, opts, runtime_opts) do
      RootHTTPAdapter.fetch(resolved, opts, runtime_opts)
    end
  end

  @moduletag :tmp_dir

  setup do
    TestExporter.attach(self(), finch_spans: false)
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  defp miss_opts(cache_root) do
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
      ],
      cache: [root: cache_root]
    ]
  end

  defp signed_miss_opts(cache_root) do
    [
      sources: [
        path: [
          adapter: SignedRootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: SignedOriginImage]]
        ]
      ],
      cache: [root: cache_root]
    ]
  end

  defp request_path, do: "/w=120/h=90/format=jpeg/src/images/beach.jpg"

  test "a real request exports spans that all share one trace_id", %{tmp_dir: tmp_dir} do
    conn = call(request_path(), miss_opts(tmp_dir))
    assert conn.status == 200

    spans = TestExporter.collect()
    assert [_trace_id] = spans |> Enum.map(& &1.trace_id) |> Enum.uniq()

    names = Enum.map(spans, & &1.name)
    assert "image_pipe.request" in names
    assert "image_pipe.source.fetch" in names
    assert "image_pipe.source.fetch_decode" in names
  end

  # Every span but the request root must point at another exported span, or
  # tracing backends report missing parents and render the trace flat.
  test "every non-root span parents onto another exported span", %{tmp_dir: tmp_dir} do
    conn = call(request_path(), miss_opts(tmp_dir))
    assert conn.status == 200

    spans = TestExporter.collect()
    request = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert request, "request root span missing"
    assert length(spans) >= 3

    exported = MapSet.new(spans, & &1.span_id)
    dangling = Enum.reject(spans, &MapSet.member?(exported, &1.parent_span_id))

    assert request.parent_span_id == nil
    assert dangling == [request]
  end

  # SignedRootHTTPAdapter appends ?X-Amz-Signature=fake123abcdef to the
  # resolved fetch URL, so the request runs a signed-URL code path end to end.
  test "no signed source URL leaks into any exported span or event attribute", %{tmp_dir: tmp_dir} do
    conn = call(request_path(), signed_miss_opts(tmp_dir))
    assert conn.status == 200

    values =
      Enum.flat_map(TestExporter.collect(), fn span ->
        Enum.flat_map([span.attributes | Enum.map(span.events, & &1.attributes)], &Map.values/1)
      end)

    assert values != [], "no attribute values collected"
    refute Enum.any?(values, &(is_binary(&1) and String.contains?(&1, "X-Amz-Signature")))
  end
end
