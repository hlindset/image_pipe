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
