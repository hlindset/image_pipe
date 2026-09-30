defmodule ImagePipe.Source.Input do
  @moduledoc false

  # Direct `{:file, path}` and `{:binary, bytes}` inputs. `ImagePipe.Source`
  # resolves and fetches them here without a mount.

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Parser
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @enforce_keys [:kind, :value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{kind: :file | :binary, value: binary()}

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
    source = %__MODULE__{kind: kind, value: value}

    with {:ok, resolved} <- Source.resolve(source, config, Source.runtime_opts(config)) do
      {:ok, resolved, config}
    end
  end

  def prepare(_input, _config), do: {:error, {:invalid_source, :invalid_input}}

  def resolve(%__MODULE__{kind: kind, value: value}, _opts, _runtime) do
    {:ok,
     %Resolved{
       source_kind: :input,
       identity: [kind: :local_input],
       internal_cache: :disabled,
       http_cache: :disabled,
       cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
       fetch: {kind, value}
     }}
  end

  def fetch(%Resolved{fetch: {:binary, bytes}}, _opts, _runtime),
    do: {:ok, %Response{stream: [bytes]}}

  def fetch(%Resolved{fetch: {:file, path}}, _opts, runtime) do
    limit = Keyword.fetch!(runtime, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> {:ok, %Response{path: path}}
      {:ok, %{type: :regular}} -> {:error, {:source, :body_too_large}}
      {:ok, _non_regular} -> {:error, {:source, :not_regular_file}}
      {:error, reason} -> {:error, {:source, reason}}
    end
  end
end
