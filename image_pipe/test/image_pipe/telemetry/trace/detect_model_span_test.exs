defmodule ImagePipe.Telemetry.Trace.DetectModelSpanTest do
  # TestExporter routes spans through a global receiver, so this module is async: false.
  use ExUnit.Case, async: false

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImagePipe.Transform.Detector.Composite

  defmodule FaceChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(_), do: {__MODULE__, :v}
    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule ObjectChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["car"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(_), do: {__MODULE__, :v}
    @impl true
    def detect(_, _), do: {:ok, []}
  end

  setup do
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)
  end

  defp collect_spans do
    receive do
      {:span, %Span{} = span} -> [span | collect_spans()]
    after
      200 -> []
    end
  end

  test "model spans of concurrently run children nest under the detect span" do
    telemetry_opts = [telemetry_prefix: [:image_pipe]]
    composite = Composite.new([FaceChild, ObjectChild])

    {:ok, []} =
      Telemetry.span(telemetry_opts, [:transform, :detect], %{}, fn ->
        result =
          Composite.detect(composite, :image, classes: :all, telemetry_opts: telemetry_opts)

        {result, %{result: :ok}}
      end)

    spans = collect_spans()
    assert [detect] = Enum.filter(spans, &(&1.name == "image_pipe.transform.detect"))
    models = Enum.filter(spans, &(&1.name == "image_pipe.transform.detect.model"))
    assert length(models) == 2

    for model <- models do
      assert model.trace_id == detect.trace_id
      assert model.parent_span_id == detect.span_id
    end
  end
end
