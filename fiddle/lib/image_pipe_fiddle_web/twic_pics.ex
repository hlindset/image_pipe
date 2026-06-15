defmodule ImagePipeFiddleWeb.TwicPics do
  @moduledoc "Forwards /twic requests to ImagePipe.Plug with opts built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(conn, :persistent_term.get({ImagePipeFiddle.Application, :twicpics_opts}))
  end
end
