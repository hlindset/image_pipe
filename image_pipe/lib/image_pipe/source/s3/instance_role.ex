defmodule ImagePipe.Source.S3.InstanceRole do
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.MetadataRequest

  @base_url "http://169.254.169.254"
  @ttl_seconds 21_600

  @opts_schema NimbleOptions.new!(
                 base_url: [
                   type: :string,
                   doc: """
                   Base URL of the instance metadata service. The default value is \
                   `"http://169.254.169.254"`.
                   """
                 ],
                 ttl_seconds: [
                   type: :pos_integer,
                   doc: """
                   Lifetime requested for each metadata session token, in seconds. \
                   The default value is `21600`.
                   """
                 ],
                 receive_timeout: [
                   type: :non_neg_integer,
                   doc: "Milliseconds to wait for each response. The default value is `2000`."
                 ],
                 connect_timeout: [
                   type: :non_neg_integer,
                   doc: "Milliseconds to wait for a connection. The default value is `2000`."
                 ],
                 plug: [type: :any, doc: false]
               )

  @moduledoc """
  Credential provider for the IAM role attached to an EC2 instance, including
  Elastic Beanstalk, read from the instance metadata service (IMDSv2).

      credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}

  Setting up credentials is covered in
  [Serving images from S3](serving-from-s3.md#choose-credentials).

  ## Options

  #{NimbleOptions.docs(@opts_schema)}
  """

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
  def fetch_credentials(_scope, opts) do
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
          [role | _] -> {:ok, String.trim(role)}
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
    case JSON.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :imds_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :imds_invalid_credentials}

  defp token_header(token), do: [{"x-aws-ec2-metadata-token", token}]

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
  defp ttl(opts), do: Keyword.get(opts, :ttl_seconds, @ttl_seconds)

  @doc false
  def options_schema, do: @opts_schema.schema
end
