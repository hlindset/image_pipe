defmodule ImagePipe.Dialect.IIIF.InfoRenderer do
  @moduledoc "Renders the IIIF info.json via the Phase 1 Renderer mechanism."

  @behaviour ImagePipe.Renderer

  alias ImagePipe.Dialect.IIIF.Info
  alias ImagePipe.Plan.RenderContext

  @impl true
  def requires(_params), do: [:header]

  @impl true
  def render(%RenderContext{info: info}, params, _opts) do
    {:ok, {"application/json", JSON.encode_to_iodata!(Info.document(info, params))}}
  end
end
