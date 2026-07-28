defmodule ImagePipe.RendererSpanTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer

  defmodule OkRenderer do
    @behaviour ImagePipe.Renderer
    @impl true
    def requires(_params), do: [:header]
    @impl true
    def render(%RenderContext{}, _params, _opts), do: {:ok, {"application/json", "{}"}}
  end

  defmodule FailRenderer do
    @behaviour ImagePipe.Renderer
    @impl true
    def requires(_params), do: [:header]
    @impl true
    def render(%RenderContext{}, _params, _opts), do: {:error, :boom}
  end

  @prefix [:renderer_span_test]

  setup do
    handler = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [@prefix ++ [:render, :start], @prefix ++ [:render, :stop]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp context do
    %RenderContext{info: %SourceInfo{format: :jpeg, width: 10, height: 10, orientation: 1}}
  end

  test "run/3 emits the [:render] span with the renderer and content type" do
    assert {:ok, {"application/json", "{}"}} =
             Renderer.run({:custom, OkRenderer, %{}}, context(), telemetry_prefix: @prefix)

    assert_received {:telemetry, [:renderer_span_test, :render, :start], _,
                     %{renderer: OkRenderer}}

    assert_received {:telemetry, [:renderer_span_test, :render, :stop], _,
                     %{result: :ok, content_type: "application/json"}}
  end

  test "a render failure closes the span with :render_error" do
    assert {:error, :boom} =
             Renderer.run({:custom, FailRenderer, %{}}, context(), telemetry_prefix: @prefix)

    assert_received {:telemetry, [:renderer_span_test, :render, :stop], _,
                     %{result: :render_error, error: :boom}}
  end
end
