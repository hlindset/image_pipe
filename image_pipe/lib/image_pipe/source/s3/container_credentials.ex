defmodule ImagePipe.Source.S3.ContainerCredentials do
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.MetadataRequest

  @base_url "http://169.254.170.2"

  @opts_schema NimbleOptions.new!(
                 base_url: [
                   type: :string,
                   doc: """
                   Base URL that `:relative_uri` is appended to. The default value is \
                   `"http://169.254.170.2"`.
                   """
                 ],
                 full_uri: [
                   type: :string,
                   doc: """
                   Full credentials URL, from `AWS_CONTAINER_CREDENTIALS_FULL_URI`. \
                   Takes precedence over `:relative_uri`. Must use `https`, a loopback \
                   host, or the ECS or EKS credential endpoint, so the token can't be \
                   sent to another host.
                   """
                 ],
                 relative_uri: [
                   type: :string,
                   doc: """
                   Credentials path, from `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`. \
                   Must start with `/`.
                   """
                 ],
                 auth_token: [
                   type: :string,
                   doc: """
                   `Authorization` header value, from \
                   `AWS_CONTAINER_AUTHORIZATION_TOKEN`.
                   """
                 ],
                 auth_token_file: [
                   type: :string,
                   doc: """
                   Path of a file holding the `Authorization` header value, from \
                   `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`. The file is read again on \
                   every refresh, since the platform rotates it. Takes precedence over \
                   `:auth_token`.
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
  Credential provider for ECS, Fargate, and EKS container credentials.

      credentials:
        {:provider, ImagePipe.Source.S3.ContainerCredentials,
         relative_uri: System.fetch_env!("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")}

  Pass the values the platform sets in the `AWS_CONTAINER_*` environment
  variables. Fetching fails when neither `:full_uri` nor `:relative_uri` is
  given. Setting up credentials is covered in
  [Serving images from S3](serving-from-s3.md#choose-credentials).

  ## Options

  #{NimbleOptions.docs(@opts_schema)}
  """

  @doc false
  def options_schema, do: @opts_schema.schema

  @impl true
  def validate_options(opts) do
    case schema_validate(opts) do
      {:ok, validated} -> validate_full_uri(validated)
      {:error, _message} = error -> error
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
        validate_relative_uri(Keyword.get(opts, :relative_uri))

      url ->
        uri = URI.parse(url)

        if uri.scheme == "https" or loopback_host?(uri.host) do
          :ok
        else
          {:error, "full_uri must use https or a loopback host"}
        end
    end
  end

  defp validate_relative_uri(nil), do: :ok
  defp validate_relative_uri("/" <> _path), do: :ok
  defp validate_relative_uri(_uri), do: {:error, "relative_uri must start with /"}

  defp loopback_host?(host),
    do: host in ["localhost", "127.0.0.1", "::1", "169.254.170.2", "169.254.170.23"]

  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, url} <- resolve_url(opts),
         {:ok, headers} <- auth_headers(opts),
         {:ok, body} <- get(opts, url, headers) do
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

  defp get(opts, url, headers) do
    case MetadataRequest.request(opts, method: :get, url: url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _other -> {:error, :container_credentials_unavailable}
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
    case JSON.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :container_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :container_invalid_credentials}

  defp auth_headers(opts) do
    case {Keyword.get(opts, :auth_token_file), Keyword.get(opts, :auth_token)} do
      {nil, nil} -> {:ok, []}
      {nil, token} -> {:ok, [{"authorization", token}]}
      {path, _token} -> read_token(path)
    end
  end

  defp read_token(path) do
    with {:ok, contents} <- File.read(path),
         token when token != "" <- String.trim(contents) do
      {:ok, [{"authorization", token}]}
    else
      _unreadable -> {:error, :container_token_unreadable}
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
end
