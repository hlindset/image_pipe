defmodule ImagePipeFiddleWeb.Native do
  @moduledoc "Forwards native image requests using the configuration built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(conn, :persistent_term.get({ImagePipeFiddle.Application, :native_opts}))
  end
end
