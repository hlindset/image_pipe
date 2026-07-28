defmodule ImagePipe.Telemetry.Trace.OpenTelemetryIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  require Record

  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :otel_event,
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{LogExporter, OpenTelemetryExporter, OtelReplay, Span}
  alias ImgproxyWireConformanceTest.CacheProbe

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

  # Route OTel spans to the test process; next test's setup re-points the exporter.
  # Resetting the replay buffer also fences pending casts from a prior test.
  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    OtelReplay.reset()
    :ok
  end

  # Attach the OTel span tracer; must be called from within a test (not setup)
  # so the on_exit runs before the module-level OTel teardown.
  defp attach_otel_tracer do
    Telemetry.attach_tracer(exporter: OpenTelemetryExporter, finch_spans: false)
    on_exit(fn -> Telemetry.detach_tracer() end)
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  defp iiif_beach_resolver do
    {ImagePipe.Dialect.IIIF.Resolver.Static,
     map: %{"beach" => %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]}}}
  end

  defp miss_opts do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: iiif_beach_resolver(),
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ],
      cache: {CacheProbe, result: :miss}
    ]
  end

  defp signed_miss_opts do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: iiif_beach_resolver(),
      sources: [
        path:
          {SignedRootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: SignedOriginImage]}
      ],
      cache: {CacheProbe, result: :miss}
    ]
  end

  defp request_path, do: "/beach/full/!120,90/0/default.jpg"

  # Drain all {:span, rec} OTel records delivered to this process.
  defp drain_spans(timeout \\ 500) do
    receive do
      {:span, rec} -> [rec | drain_spans(timeout)]
    after
      timeout -> []
    end
  end

  # Collect every binary attribute value from span attrs + event attrs.
  defp all_string_attr_values(recs) do
    Enum.flat_map(recs, fn rec ->
      span_attr_strings(rec) ++ event_attr_strings(rec)
    end)
  end

  defp span_attr_strings(rec) do
    rec
    |> otel_span(:attributes)
    |> elem(4)
    |> Map.values()
    |> Enum.flat_map(&flatten_value/1)
    |> Enum.filter(&is_binary/1)
  end

  defp event_attr_strings(rec) do
    rec
    |> otel_span(:events)
    |> :otel_events.list()
    |> Enum.flat_map(fn ev ->
      ev
      |> otel_event(:attributes)
      |> elem(4)
      |> Map.values()
      |> Enum.flat_map(&flatten_value/1)
      |> Enum.filter(&is_binary/1)
    end)
  end

  defp flatten_value(v) when is_list(v), do: v
  defp flatten_value(v), do: [v]

  # ── test 1: correlation — no real request required ────────────────────────────

  test "LogExporter and OTel share the trace_id; span_ids DIFFER (trace-level trade)" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1,
      root: true
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    log = capture_log(fn -> LogExporter.export(span) end)

    # Both consumers see the same trace_id …
    assert log =~ "trace=#{span.trace_id}"
    assert String.to_integer(span.trace_id, 16) == otel_span(rec, :trace_id)

    # … but span_ids differ: LogExporter logs ours; OTel mints its own.
    assert log =~ "span=#{span.span_id}"
    assert String.to_integer(span.span_id, 16) != otel_span(rec, :span_id)
  end

  # ── test 2: E2E — a real request; all exported OTel spans share one trace_id ───

  test "a real request exports spans that all share one trace_id" do
    attach_otel_tracer()

    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    recs = drain_spans()
    assert recs != [], "no spans exported — request/drain not wired"

    trace_ids = recs |> Enum.map(&otel_span(&1, :trace_id)) |> Enum.uniq()
    assert length(trace_ids) == 1

    names = Enum.map(recs, &otel_span(&1, :name))
    # Root span is always present; a full request produces many children.
    assert "image_pipe.request" in names
    assert length(recs) >= 2
    # Source-fetch spans are reliably present on a cache-miss request.
    assert "image_pipe.source.fetch" in names
    assert "image_pipe.source.fetch_decode" in names
  end

  # ── test 3: hierarchy — the Jaeger "missing parent spans" regression ──────────
  #
  # Pre-fix, every exported span referenced an internal (never-exported) parent id,
  # so Jaeger flagged all spans as missing their parent and rendered the trace flat.
  # Post-fix, every non-root span must point at another exported span's OTel-minted
  # id; only the request root keeps a synthetic out-of-trace parent (it forces
  # ImagePipe's trace_id).

  test "every non-root span parents onto another exported span" do
    attach_otel_tracer()

    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    # A synchronous call fences every add cast enqueued before it — and the
    # cross-process spans (cache.write, source.fetch_decode) are all cast
    # before the 200 response returns, so they are covered by the fence. The
    # drain window below covers any stragglers.
    :ok = OtelReplay.sweep()

    recs = drain_spans()
    assert recs != [], "no spans exported — request/drain not wired"

    req = Enum.find(recs, &(otel_span(&1, :name) == "image_pipe.request"))
    assert req, "request root span missing"

    trace_id = otel_span(req, :trace_id)
    trace_recs = Enum.filter(recs, &(otel_span(&1, :trace_id) == trace_id))
    assert length(trace_recs) >= 3

    minted = MapSet.new(trace_recs, &otel_span(&1, :span_id))

    dangling =
      Enum.reject(trace_recs, fn rec ->
        MapSet.member?(minted, otel_span(rec, :parent_span_id))
      end)

    assert dangling == [req]
  end

  # ── test 4: URL safety — signed source URL must not leak into OTel attrs ───────
  #
  # SignedRootHTTPAdapter appends ?X-Amz-Signature=fake123abcdef to the resolved
  # fetch URL so the full request lifecycle exercises a signed-URL code path. The
  # allowlist in Capture.safe_attrs/1 prevents the URL from reaching span attrs;
  # this test is defense-in-depth confirming the OTel exporter's coerce path also
  # does not re-surface it.

  test "no signed source URL leaks into any exported span or event attribute" do
    attach_otel_tracer()

    conn = call(request_path(), signed_miss_opts())
    assert conn.status == 200

    recs = drain_spans()
    values = all_string_attr_values(recs)

    assert values != [], "no attribute values collected — request/drain not wired"
    refute Enum.any?(values, &String.contains?(&1, "X-Amz-Signature"))
  end
end
