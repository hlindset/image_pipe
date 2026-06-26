defmodule ImagePipe.Source.S3.InstanceRole do
  @moduledoc """
  Credential provider for an EC2 instance role via IMDSv2.

  Use on EC2 (incl. Elastic Beanstalk) where a role is attached to the instance:

      credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}

  Options:
    * `:base_url` — IMDS base, default `"http://169.254.169.254"`.
    * `:ttl_seconds` — token TTL requested from IMDS, default `21600`.
    * `:plug` — test-only Req plug; routes requests to a `Plug` instead of the network.
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms), default 2000.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.MetadataRequest

  @base_url "http://169.254.169.254"
  @ttl_seconds 21_600

  @opts_schema NimbleOptions.new!(
                 base_url: [type: :string],
                 ttl_seconds: [type: :pos_integer],
                 # test-only Req hook; :any so the schema doesn't reject a fn
                 plug: [type: :any],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer]
               )

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # NOTE: a fresh IMDSv2 token is fetched on every call, milliseconds before the
  # role/creds GET (TTL @ttl_seconds), so the token cannot expire mid-call — we
  # do NOT need the AWS SDK's "re-fetch token on 401" retry (the SDK needs it
  # because it caches the token across calls; we don't).
  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, token} <- imds_token(opts),
         {:ok, role} <- role_name(opts, token),
         {:ok, body} <- role_credentials(opts, token, role) do
      parse_credentials(body)
    end
  end

  defp imds_token(opts) do
    case MetadataRequest.request(opts,
           method: :put,
           url: base_url(opts) <> "/latest/api/token",
           headers: [{"x-aws-ec2-metadata-token-ttl-seconds", Integer.to_string(ttl(opts))}]
         ) do
      {:ok, %{status: 200, body: token}} -> {:ok, to_string(token)}
      _other -> {:error, :imds_token_unavailable}
    end
  end

  defp role_name(opts, token) do
    case MetadataRequest.request(opts,
           method: :get,
           url: base_url(opts) <> "/latest/meta-data/iam/security-credentials/",
           headers: token_header(token)
         ) do
      {:ok, %{status: 200, body: body}} ->
        case body |> to_string() |> String.split("\n", trim: true) do
          [role | _] -> {:ok, role}
          [] -> {:error, :imds_no_role}
        end

      _other ->
        {:error, :imds_no_role}
    end
  end

  defp role_credentials(opts, token, role) do
    case MetadataRequest.request(opts,
           method: :get,
           url:
             base_url(opts) <>
               "/latest/meta-data/iam/security-credentials/" <> URI.encode(role),
           headers: token_header(token)
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _other -> {:error, :imds_credentials_unavailable}
    end
  end

  defp parse_credentials(body) do
    with {:ok, map} <- decode_json(body),
         # IMDS returns "Code":"Success" on the happy path; a non-Success body
         # omits the key material, so this match fails closed AND distinguishes
         # the success shape explicitly.
         %{
           "Code" => "Success",
           "AccessKeyId" => access_key_id,
           "SecretAccessKey" => secret_access_key,
           "Token" => token,
           "Expiration" => expiration
         } <- map,
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok, [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token],
       expiry}
    else
      _other -> {:error, :imds_invalid_credentials}
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :imds_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :imds_invalid_credentials}

  defp token_header(token), do: [{"x-aws-ec2-metadata-token", token}]

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
  defp ttl(opts), do: Keyword.get(opts, :ttl_seconds, @ttl_seconds)
end
