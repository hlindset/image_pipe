defmodule ImagePipeFiddleWeb.Imgproxy do
  @moduledoc "Forwards /img requests to ImagePipe.Plug (imgproxy dialect) with opts built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(
      conn,
      :persistent_term.get({ImagePipeFiddle.Application, :imgproxy_opts})
    )
  end
end
