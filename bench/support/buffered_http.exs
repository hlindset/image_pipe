defmodule CoordinatedCacheBench.BufferedHTTP do
  @moduledoc false
  @behaviour ImagePipe.Source
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Response

  @impl true
  defdelegate validate_options(opts), to: HTTP

  @impl true
  def resolve(source, opts, runtime) do
    with {:ok, resolved} <- HTTP.resolve(source, opts, runtime) do
      # Benchmark the output-only lifecycle with a complete binary source.
      {:ok, %{resolved | source_kind: :reference}}
    end
  end

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
