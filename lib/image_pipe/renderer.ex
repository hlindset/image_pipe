defmodule ImagePipe.Renderer do
  @moduledoc """
  Behaviour + dispatch facade for non-image (custom) terminal renderers. A renderer
  module declares which expensive pipeline stages it needs (`requires/1`) and formats
  a complete response body (`render/3`) over a neutral `ImagePipe.Plan.RenderContext`.
  A plan selects one via `render: {:custom, module, params}` — it carries the renderer
  module itself, so the core never enumerates renderers. `run/3`/`requires/1` are the
  only places the behaviour is invoked.

  The built-in `render: :image` terminal (a lazy, streamed encoded image) is NOT a
  renderer — it is produced by the encoder/streaming pipeline. This behaviour covers
  only the custom, complete-body outputs (e.g. JSON metadata, blurhash, lqip).
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Error, ImagePipe.Plan, ImagePipe.Telemetry],
    exports: []

  alias ImagePipe.Error
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Telemetry

  @type need :: :header
  @type body :: {content_type :: String.t(), iodata()}
  @type spec :: {:custom, module(), map()}

  @callback requires(params :: map()) :: [need()]
  @callback render(RenderContext.t(), params :: map(), keyword()) ::
              {:ok, body()} | {:error, term()}

  @spec requires(spec()) :: [need()]
  def requires({:custom, module, params}), do: module.requires(params)

  @doc """
  Invokes the renderer inside the `[:render]` span.

  The span lives on the facade so every caller of the behaviour gets it.
  (`ImagePipe.Dialect.Imgproxy`'s `/info` and `ImagePipe.Dialect.Native`'s
  blurhash terminals render through their own `RenderTerminal` funs, not this
  facade, and emit no `[:render]` span.)
  """
  @spec run(spec(), RenderContext.t(), keyword()) :: {:ok, body()} | {:error, term()}
  def run({:custom, module, params}, %RenderContext{} = context, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:render], %{renderer: module}, fn ->
      result = module.render(context, params, opts)
      {result, stop_metadata(result)}
    end)
  end

  defp stop_metadata({:ok, {content_type, _body}}),
    do: %{result: :ok, content_type: content_type}

  defp stop_metadata({:error, reason}),
    do: %{result: :render_error, error: Error.tag(reason)}
end
