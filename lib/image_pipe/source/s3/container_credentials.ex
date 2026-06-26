defmodule ImagePipe.Source.S3.ContainerCredentials do
  @moduledoc """
  Credential provider for ECS/Fargate/EKS container credentials.

      credentials: {:provider, ImagePipe.Source.S3.ContainerCredentials,
                    relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")}

  Options (the host typically wires these from the AWS-injected env vars):
    * `:relative_uri` — joined to `:base_url` (default `"http://169.254.170.2"`).
    * `:full_uri` — absolute URL (takes precedence over `:relative_uri`). Only
      accepted for a loopback host or over `https` (see `validate_options/1`).
    * `:auth_token` — value for the `Authorization` header (optional).
    * `:base_url` — base for `:relative_uri`, default `"http://169.254.170.2"`.
    * `:plug` — test-only Req plug.
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms), default 2000.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  @base_url "http://169.254.170.2"
  @default_timeout_ms 2_000

  @opts_schema NimbleOptions.new!(
                 base_url: [type: :string],
                 full_uri: [type: :string],
                 relative_uri: [type: :string],
                 auth_token: [type: :string],
                 plug: [type: :any],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer]
               )

  @impl true
  def validate_options(opts) do
    with {:ok, validated} <- schema_validate(opts),
         :ok <- validate_full_uri(validated) do
      :ok
    end
  end

  defp schema_validate(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # AWS only trusts AWS_CONTAINER_CREDENTIALS_FULL_URI when it targets a loopback
  # host or uses https; mirror that so a misconfigured full_uri can't exfiltrate
  # the auth token to an arbitrary host.
  defp validate_full_uri(opts) do
    case Keyword.get(opts, :full_uri) do
      nil ->
        :ok

      url ->
        uri = URI.parse(url)

        if uri.scheme == "https" or loopback_host?(uri.host) do
          :ok
        else
          {:error, "full_uri must use https or a loopback host"}
        end
    end
  end

  defp loopback_host?(host),
    do: host in ["localhost", "127.0.0.1", "::1", "169.254.170.2", "169.254.170.23"]

  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, url} <- resolve_url(opts),
         {:ok, body} <- get(opts, url) do
      parse_credentials(body)
    end
  end

  defp resolve_url(opts) do
    cond do
      url = Keyword.get(opts, :full_uri) -> {:ok, url}
      rel = Keyword.get(opts, :relative_uri) -> {:ok, base_url(opts) <> rel}
      true -> {:error, :container_uri_missing}
    end
  end

  defp get(opts, url) do
    req_opts =
      [
        method: :get,
        url: url,
        retry: false,
        redirect: false,
        headers: auth_headers(opts),
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> maybe_plug(opts)

    try do
      case Req.request!(req_opts) do
        %{status: 200, body: body} -> {:ok, body}
        _other -> {:error, :container_credentials_unavailable}
      end
    rescue
      _exception -> {:error, :container_unreachable}
    end
  end

  defp parse_credentials(body) do
    with {:ok, map} <- decode_json(body),
         %{
           "AccessKeyId" => access_key_id,
           "SecretAccessKey" => secret_access_key,
           "Token" => token,
           "Expiration" => expiration
         } <- map,
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok, [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token],
       expiry}
    else
      _other -> {:error, :container_invalid_credentials}
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :container_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :container_invalid_credentials}

  defp auth_headers(opts) do
    case Keyword.get(opts, :auth_token) do
      nil -> []
      token -> [{"authorization", token}]
    end
  end

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)
end
