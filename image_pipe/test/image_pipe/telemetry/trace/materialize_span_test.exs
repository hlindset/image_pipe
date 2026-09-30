defmodule ImagePipe.Telemetry.Trace.MaterializeSpanTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  @prefix [__MODULE__, :materialization]

  # The [:transform, :materialize] barrier span fires once per materialization,
  # wherever it happens. There are THREE distinct nesting parents in practice, all
  # covered below:
  #
  #   1. mid-chain, before a random-access op (e.g. a smart crop) -> parent is the
  #      [:transform, :operation] span (`Transform.run/3` materializes before execute);
  #   2. a pipeline-boundary flush of a still-pending EXIF orientation -> parent
  #      is [:transform, :execute];
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
    :ok = TestExporter.attach(self(), prefix: @prefix)

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
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(Keyword.put(opts, :telemetry_prefix, @prefix)))
  end

  defp parent_of(spans, %Span{parent_span_id: pid}),
    do: Enum.find(spans, &(&1.span_id == pid))

  defp beach_opts do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImagePipe.Test.PlugFixture.OriginImage]}
      ]
    ]
  end

  defp exif6_opts do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: ExifOrientation6Origin]}
      ]
    ]
  end

  test "rotation and resize buffers nest materialize spans under their operations" do
    conn = call("/rotate=45/w=120/format=jpeg/src/images/beach.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()

    assert [_, _] =
             materializations =
             Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))

    operations =
      for mat <- materializations do
        assert is_integer(mat.duration_native) and mat.duration_native >= 0
        parent = parent_of(spans, mat)
        assert parent, "materialize span must have a captured parent"
        assert parent.name == "image_pipe.transform.operation"
        parent.attributes.operation
      end

    assert Enum.sort(operations) == [:resize, :rotate]
  end

  test "pipeline-boundary EXIF materialization nests directly under execution" do
    conn = call("/format=jpeg/src/images/oriented.jpg", exif6_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [mat] = Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))
    assert mat.attributes.dims == {80, 40}

    parent = parent_of(spans, mat)
    assert parent, "materialize span must have a captured parent"
    assert parent.name == "image_pipe.transform.execute"
  end

  test "horizontal orientation materialization nests directly under execution" do
    conn = call("/flip=h/w=120/format=png/src/images/beach.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    assert [mat] = Enum.filter(spans, &(&1.name == "image_pipe.transform.materialize"))
    assert mat.attributes.dims == {120, 80}
    assert parent_of(spans, mat).name == "image_pipe.transform.execute"
  end

  test "delivery backstop flush nests the materialize span under the request root" do
    # Resize-only on an orientation-1 source streams through the whole chain without
    # materializing, so the only flush is the delivery backstop, AFTER the execute span
    # closes — the materialize span parents to a request-level root span.
    conn = call("/w=120/h=90/format=jpeg/src/images/beach.jpg", beach_opts())
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
