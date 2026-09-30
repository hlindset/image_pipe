defmodule ImagePipe.Source.Input do
  @moduledoc false
  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Reference
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Parser
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  def prepare({:source, value}, config) when is_binary(value) do
    with true <- String.valid?(value),
         {:ok, plan} <- Parser.translate(value, config),
         {:ok, source} <- Source.resolve(plan, config, Source.runtime_opts(config)) do
      {:ok, source, config}
    else
      false -> {:error, {:invalid_source, :invalid_encoding}}
      {:error, _reason} = error -> error
    end
  end

  def prepare({kind, value}, config) when kind in [:file, :binary] and is_binary(value) do
    source = %Reference{
      adapter: :image_pipe_input,
      id: Atom.to_string(kind),
      metadata: [value: value]
    }

    sources = Map.put(Keyword.fetch!(config, :sources), :image_pipe_input, {__MODULE__, []})
    config = Keyword.put(config, :sources, sources)

    with {:ok, resolved} <- Source.resolve(source, config, Source.runtime_opts(config)) do
      {:ok, resolved, config}
    end
  end

  def prepare(_input, _config), do: {:error, {:invalid_source, :invalid_input}}

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def resolve(%Reference{id: kind, metadata: metadata}, _opts, _runtime) do
    {:ok,
     %Resolved{
       adapter: :image_pipe_input,
       source_kind: :reference,
       identity: [kind: :local_input],
       internal_cache: :disabled,
       http_cache: :disabled,
       cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
       fetch: {kind, Keyword.fetch!(metadata, :value)}
     }}
  end

  @impl true
  def fetch(%Resolved{fetch: {"binary", bytes}}, _opts, _runtime),
    do: {:ok, %Response{stream: [bytes]}}

  def fetch(%Resolved{fetch: {"file", path}}, _opts, runtime) do
    limit = Keyword.fetch!(runtime, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> {:ok, %Response{path: path}}
      {:ok, %{type: :regular}} -> {:error, {:source, :body_too_large}}
      {:ok, _non_regular} -> {:error, {:source, :not_regular_file}}
      {:error, reason} -> {:error, {:source, reason}}
    end
  end
end
