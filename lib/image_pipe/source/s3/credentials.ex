defmodule ImagePipe.Source.S3.Credentials do
  @moduledoc false

  alias ImagePipe.Source.S3.RefreshCache

  @type source_error :: {:error, {:source, atom()}}

  @spec validate(term()) :: {:ok, term()} | {:error, {:invalid_source_config, term()}}
  def validate({:static, opts}) when is_list(opts) do
    case normalize(opts) do
      {:ok, credentials} -> {:ok, {:static, credentials}}
      {:error, reason} -> {:error, {:invalid_source_config, reason}}
    end
  end

  def validate({:provider, provider, opts})
      when is_atom(provider) and is_list(opts) do
    cond do
      not (Code.ensure_loaded?(provider) and
               function_exported?(provider, :fetch_credentials, 3)) ->
        {:error, {:invalid_source_config, :invalid_credential_provider}}

      function_exported?(provider, :validate_options, 1) ->
        case provider.validate_options(opts) do
          :ok -> {:ok, {:provider, provider, opts}}
          {:error, reason} -> {:error, {:invalid_source_config, reason}}
        end

      true ->
        {:ok, {:provider, provider, opts}}
    end
  end

  def validate(_credentials), do: {:error, {:invalid_source_config, :invalid_credentials}}

  @spec fetch(String.t(), term(), keyword()) ::
          {:ok, keyword()} | source_error()
  def fetch(_scope, {:static, credentials}, _runtime_opts) do
    {:ok, credentials}
  end

  def fetch(scope, {:provider, provider, opts}, _runtime_opts) do
    key = {:s3_credentials, provider, opts, scope}

    fetch_fun = fn ->
      case provider.fetch_credentials(scope, opts, []) do
        {:ok, credentials, expiry} ->
          case normalize(credentials) do
            {:ok, normalized} -> {:ok, normalized, expiry}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :invalid_credential_provider_result}
      end
    end

    case RefreshCache.fetch(key, fetch_fun) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, _reason} -> {:error, {:source, :credentials_unavailable}}
    end
  end

  def fetch(_scope, _credentials, _runtime_opts),
    do: {:error, {:source, :credentials_unavailable}}

  defp normalize(opts) when is_list(opts) do
    with {:ok, access_key_id} <- fetch_binary(opts, :access_key_id),
         {:ok, secret_access_key} <- fetch_binary(opts, :secret_access_key),
         {:ok, token} <- optional_binary(opts, :token) do
      credentials = [access_key_id: access_key_id, secret_access_key: secret_access_key]
      {:ok, maybe_put_token(credentials, token)}
    end
  end

  defp normalize(_opts), do: {:error, :invalid_credentials}

  defp fetch_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_invalid -> {:error, {:invalid_credential, key}}
    end
  end

  defp optional_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_credential, key}}
      :error -> {:ok, nil}
    end
  end

  defp maybe_put_token(credentials, nil), do: credentials
  defp maybe_put_token(credentials, token), do: Keyword.put(credentials, :token, token)
end
