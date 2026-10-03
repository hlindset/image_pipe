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

  # Direct inputs aren't staged, so their digest is taken here: the bytes in
  # hand, or one read of the file.
  def resolve(%__MODULE__{kind: kind, value: value}, _opts, runtime) do
    with {:ok, digest} <- digest(kind, value, runtime) do
      {:ok,
       %Resolved{
         identity: [kind: :local_input],
         internal_cache: :disabled,
         http_cache: :validators,
         cache_semantics: %CacheSemantics{
           byte_identity: {:strong, {:sha256, digest}},
           stable?: true
         },
         fetch: {kind, value}
       }}
    end
  end

  defp digest(:binary, bytes, _runtime), do: {:ok, :crypto.hash(:sha256, bytes)}

  defp digest(:file, path, runtime) do
    with :ok <- check_file(path, runtime) do
      digest =
        path
        |> File.stream!(65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()

      {:ok, digest}
    end
  rescue
    _error in File.Error -> {:error, {:source, :unreadable}}
  end

  def fetch(%Resolved{fetch: {:binary, bytes}}, _opts, _runtime),
    do: {:ok, %Response{stream: [bytes]}}

  def fetch(%Resolved{fetch: {:file, path}}, _opts, runtime) do
    with :ok <- check_file(path, runtime), do: {:ok, %Response{path: path}}
  end

  defp check_file(path, runtime) do
    limit = Keyword.fetch!(runtime, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= limit -> :ok
      {:ok, %{type: :regular}} -> {:error, {:source, :body_too_large}}
      {:ok, _non_regular} -> {:error, {:source, :not_regular_file}}
      {:error, reason} -> {:error, {:source, reason}}
    end
  end
end
