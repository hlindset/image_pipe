defmodule ImagePipeFiddleWeb.Imgproxy do
  @moduledoc "Forwards /img requests to ImagePipe.Dialect.Imgproxy with opts built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Dialect.Imgproxy.call(
      conn,
      :persistent_term.get({ImagePipeFiddle.Application, :imgproxy_opts})
    )
  end
end
