defmodule ImagePipeFiddleWeb.NativeSigned do
  @moduledoc "Forwards signed native requests using the demo-only signing configuration."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    config = :persistent_term.get({ImagePipeFiddle.Application, :native_signed_opts})
    ImagePipe.Plug.call(conn, config)
  end
end
