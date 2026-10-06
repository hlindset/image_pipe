defmodule CoordinatedCacheBench.BufferedHTTP do
  @moduledoc false
  @behaviour ImagePipe.Source

  @impl true
  def source_kinds, do: [:path, :url, :object]
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Response

  @impl true
  defdelegate validate_options(opts), to: HTTP

  @impl true
  defdelegate identifiers(opts), to: HTTP

  @impl true
  defdelegate resolve(source, opts, runtime), to: HTTP

  @impl true
  def fetch(source, opts, runtime) do
    with {:ok, response} <- HTTP.fetch(source, opts, runtime) do
      try do
        body = response.stream |> Enum.to_list() |> IO.iodata_to_binary()
        {:ok, %Response{stream: [body], origin: response.origin}}
      after
        Response.close(response)
      end
    end
  end
end
