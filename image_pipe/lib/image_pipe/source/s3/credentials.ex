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
    case provider.validate_options(opts) do
      :ok -> {:ok, {:provider, provider, opts}}
      {:error, reason} -> {:error, {:invalid_source_config, reason}}
    end
  end

  def validate(_credentials), do: {:error, {:invalid_source_config, :invalid_credentials}}

  @spec fetch(String.t(), term()) :: {:ok, keyword()} | source_error()
  def fetch(_scope, {:static, credentials}), do: {:ok, credentials}

  def fetch(scope, {:provider, provider, opts}) do
    case RefreshCache.fetch(
           cache_key(provider, opts, scope),
           label(provider, scope),
           fetch_fun(provider, opts, scope)
         ) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, _reason} -> {:error, {:source, :credentials_unavailable}}
    end
  end

  def fetch(_scope, _credentials), do: {:error, {:source, :credentials_unavailable}}

  # Starts fetching provider credentials before any request needs them.
  @spec warm(String.t(), {:provider, module(), keyword()}) :: :ok | {:error, term()}
  def warm(scope, {:provider, provider, opts}),
    do:
      RefreshCache.warm(
        cache_key(provider, opts, scope),
        label(provider, scope),
        fetch_fun(provider, opts, scope)
      )

  # The provider's options can hold secrets, so the label names only the
  # provider and the bucket.
  defp label(provider, scope),
    do: "S3 credentials for bucket #{inspect(scope)} from #{inspect(provider)}"

  defp cache_key(provider, opts, scope) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({:s3_credentials, provider, opts, scope}, [:deterministic])
    )
  end

  defp fetch_fun(provider, opts, scope), do: fn -> resolve_provider(provider, scope, opts) end

  defp resolve_provider(provider, scope, opts) do
    case provider.fetch_credentials(scope, opts) do
      {:ok, credentials, expiry} -> normalize_with_expiry(credentials, expiry)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_credential_provider_result}
    end
  end

  defp normalize_with_expiry(credentials, expiry)
       when expiry == :never or is_struct(expiry, DateTime) do
    case normalize(credentials) do
      {:ok, normalized} -> {:ok, normalized, expiry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_with_expiry(_credentials, _expiry), do: {:error, :invalid_credential_expiry}

  defp normalize(opts) when is_list(opts) do
    with {:ok, access_key_id} <- fetch_binary(opts, :access_key_id),
         {:ok, secret_access_key} <- fetch_binary(opts, :secret_access_key),
         {:ok, token} <- optional_binary(opts, :token) do
      credentials = [access_key_id: access_key_id, secret_access_key: secret_access_key]
      {:ok, maybe_put_token(credentials, token)}
    end
  end

  defp normalize(_opts), do: {:error, :invalid_credentials}

  # Each value is sent in a request header or signs one, so a line break or
  # NUL would fail every fetch. The error names the setting, not the value.
  defp fetch_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> header_safe(value, key)
      _missing_or_invalid -> {:error, {:invalid_credential, key}}
    end
  end

  defp optional_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> header_safe(value, key)
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_credential, key}}
      :error -> {:ok, nil}
    end
  end

  defp header_safe(value, key) do
    if String.contains?(value, ["\r", "\n", <<0>>]),
      do: {:error, {:invalid_credential, key}},
      else: {:ok, value}
  end

  defp maybe_put_token(credentials, nil), do: credentials
  defp maybe_put_token(credentials, token), do: Keyword.put(credentials, :token, token)
end
