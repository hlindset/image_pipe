defmodule ImagePipeFiddleWeb.IIIF do
  @moduledoc """
  Forwards /iiif-image requests to ImagePipe.Plug with opts built at boot. CORS
  and OPTIONS preflight are handled by ImagePipe.Plug itself via the
  `allow_origin: "*"` mount option.
  """
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(
      conn,
      :persistent_term.get({ImagePipeFiddle.Application, :iiif_opts})
    )
  end
end
