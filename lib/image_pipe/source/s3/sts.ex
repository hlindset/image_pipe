defmodule ImagePipe.Source.S3.Sts do
  @moduledoc false
  # Shared AWS STS Query-protocol client for the AssumeRole (#8) and
  # AssumeRoleWithWebIdentity (#7) credential providers.
  #
  # STS always responds with XML. Rather than pull in :xmerl/sweet_xml (atom
  # explosion + XXE on untrusted XML, plus sweet_xml is only a transitive dep),
  # we extract the four credential fields from the fixed-schema <Credentials>
  # block with a scoped regex. STS values are base64/ISO-8601 — they never
  # contain `<`, `>`, or `&` — so the extraction is robust, and a recorded-sample
  # test pins it to real wire output.

  @credentials_block ~r{<Credentials>(?<inner>.*?)</Credentials>}s

  @version "2011-06-15"
  @default_session_name "image-pipe"
  @default_timeout_ms 5_000

  @spec assume_role(keyword()) :: {:ok, keyword(), DateTime.t()} | {:error, term()}
  def assume_role(opts) do
    region = Keyword.fetch!(opts, :region)

    params =
      [
        {"Action", "AssumeRole"},
        {"Version", @version},
        {"RoleArn", Keyword.fetch!(opts, :role_arn)},
        {"RoleSessionName", session_name(opts)}
      ]
      |> maybe_put("ExternalId", Keyword.get(opts, :external_id))

    sigv4 =
      opts
      |> Keyword.fetch!(:base_credentials)
      |> Keyword.take([:access_key_id, :secret_access_key, :token])
      |> Keyword.merge(service: :sts, region: region)

    post(region, params, [aws_sigv4: sigv4], opts)
  end

  @spec assume_role_with_web_identity(keyword()) ::
          {:ok, keyword(), DateTime.t()} | {:error, term()}
  def assume_role_with_web_identity(opts) do
    region = Keyword.fetch!(opts, :region)

    params = [
      {"Action", "AssumeRoleWithWebIdentity"},
      {"Version", @version},
      {"RoleArn", Keyword.fetch!(opts, :role_arn)},
      {"RoleSessionName", session_name(opts)},
      {"WebIdentityToken", Keyword.fetch!(opts, :web_identity_token)}
    ]

    # Unsigned: the OIDC token is the authentication.
    post(region, params, [], opts)
  end

  # do not inspect/log `opts`, `params`, or `body` here — the signed body carries
  # the base secret key (via the SigV4 signature) and, for web-identity, the OIDC
  # token. Errors stay opaque; the response body is never put in an error term.
  defp post(region, params, sign_opts, opts) do
    req_opts =
      [
        method: :post,
        url: endpoint(region),
        body: URI.encode_query(params),
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        retry: false,
        redirect: false,
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> Keyword.merge(sign_opts)
      |> maybe_plug(opts)

    case safe_request(req_opts) do
      {:ok, %{status: 200, body: body}} -> parse_credentials(to_string(body))
      {:ok, %{status: _other}} -> {:error, :sts_request_failed}
      {:error, _reason} -> {:error, :sts_unreachable}
    end
  end

  defp safe_request(req_opts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  defp endpoint(region), do: "https://sts." <> region <> ".amazonaws.com/"

  defp session_name(opts), do: Keyword.get(opts, :role_session_name, @default_session_name)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)

  @spec parse_credentials(binary()) ::
          {:ok, keyword(), DateTime.t()} | {:error, :sts_invalid_response}
  def parse_credentials(xml) when is_binary(xml) do
    with %{"inner" => inner} <- Regex.named_captures(@credentials_block, xml),
         {:ok, access_key_id} <- field(inner, "AccessKeyId"),
         {:ok, secret_access_key} <- field(inner, "SecretAccessKey"),
         {:ok, token} <- field(inner, "SessionToken"),
         {:ok, expiration} <- field(inner, "Expiration"),
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok,
       [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token], expiry}
    else
      _other -> {:error, :sts_invalid_response}
    end
  end

  def parse_credentials(_other), do: {:error, :sts_invalid_response}

  defp field(inner, tag) do
    case Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, inner) do
      [_, value] ->
        case String.trim(value) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _none ->
        :error
    end
  end
end
