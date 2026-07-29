defmodule ImagePipe.Telemetry.Trace.MaterializeSpanTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  # The [:transform, :materialize] barrier span fires once per materialization,
  # wherever it happens. There are THREE distinct nesting parents in practice, all
  # covered below:
  #
  #   1. mid-chain, before a random-access op (e.g. a smart crop) -> parent is the
  #      [:transform, :operation] span (Chain.maybe_materialize, inside run_operation);
  #   2. a pipeline-boundary flush of a still-pending EXIF orientation, executed as
  #      an explicit Flush operation by the resolve driver -> parent is that Flush
  #      op's [:transform, :operation] span, which itself nests under
  #      [:transform, :execute];
  #   3. the delivery backstop (the runner's materialize-for-delivery step), which
  #      runs AFTER [:transform, :execute] has closed -> parent is the request root.
  #
  # (Every successful request materializes at least once: a chain that never
  # materializes mid-pipeline hits the delivery backstop, so there is no "zero
  # materialize spans" outcome to assert.)

  # EXIF-orientation-6 source (40x80 stored, displayed 80x40 after autorotate). A
  # no-geometry request on it defers the EXIF orientation and flushes it at the
  # pipeline boundary inside [:transform, :execute].
  defmodule ExifOrientation6Origin do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, _opts) do
      body =
        40
        |> Image.new!(80, color: :white)
        |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
        |> Image.set_orientation!(6)
        |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

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
      dialect: ImagePipe.Dialect.IIIF,
      resolver:
        {ImagePipe.Dialect.IIIF.Resolver.Static,
         map: %{"beach" => %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]}}},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ]
    ]
  end

  defp exif6_opts do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver:
        {ImagePipe.Dialect.IIIF.Resolver.Static,
         map: %{"oriented" => %ImagePipe.Plan.Source.Path{segments: ["images", "oriented.jpg"]}}},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: ExifOrientation6Origin]}
      ]
    ]
  end

  test "mid-chain materializing op yields a materialize span nested under an operation" do
    # An arbitrary (non-quarter-turn) rotation needs random pixel access, so the chain
    # materializes mid-pipeline immediately before the rotate operation, inside its
    # operation span.
    conn = call("/beach/full/120,/45/default.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [mat] = Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))

    assert is_integer(mat.duration_native) and mat.duration_native >= 0

    parent = parent_of(spans, mat)
    assert parent, "materialize span must have a captured parent"
    assert parent.name == "image_pipe.transform.operation"
  end

  test "pipeline-boundary EXIF flush nests the materialize span under the Flush op span" do
    # No-geometry request on an orientation-6 source: the deferred EXIF orientation is
    # flushed at the pipeline boundary as an explicit Flush operation, so the
    # materialize span nests under that Flush operation's [:transform, :operation]
    # span, which itself sits inside the execute span.
    conn = call("/oriented/full/max/0/default.jpg", exif6_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [mat] = Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))

    parent = parent_of(spans, mat)
    assert parent, "materialize span must have a captured parent"
    assert parent.name == "image_pipe.transform.operation"

    grandparent = parent_of(spans, parent)
    assert grandparent, "the Flush operation span must have a captured parent"
    assert grandparent.name == "image_pipe.transform.execute"
  end

  test "delivery backstop flush nests the materialize span under the request root" do
    # Resize-only on an orientation-1 source streams through the whole chain without
    # materializing, so the only flush is the delivery backstop, AFTER the execute span
    # closes — the materialize span parents to a request-level root span.
    conn = call("/beach/full/!120,90/0/default.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [mat] = Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))

    # The delivery backstop runs after [:transform, :execute] has closed, so the
    # materialize span is not nested under any transform stage span.
    refute Enum.any?(spans, fn s ->
             s.span_id == mat.parent_span_id and
               s.name in ["image_pipe.transform.execute", "image_pipe.transform.operation"]
           end)
  end
end
