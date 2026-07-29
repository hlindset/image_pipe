defmodule ImagePipe.RendererTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer

  defmodule StubRenderer do
    @behaviour ImagePipe.Renderer
    @impl true
    def requires(_params), do: [:header]
    @impl true
    def render(%RenderContext{info: info}, params, _opts),
      do: {:ok, {"application/json", "stub:#{info.format}:#{params[:k]}"}}
  end

  test "requires/1 delegates to the spec's module" do
    spec = {:custom, StubRenderer, %{}}
    assert Renderer.requires(spec) == [:header]
  end

  test "run/3 delegates to the module with context, params, opts" do
    spec = {:custom, StubRenderer, %{k: "v"}}
    ctx = %RenderContext{info: %SourceInfo{format: :jpeg, width: 1, height: 1, orientation: 1}}

    assert {:ok, {"application/json", "stub:jpeg:v"}} =
             Renderer.run(spec, ctx, telemetry_prefix: [:renderer_test])
  end
end
