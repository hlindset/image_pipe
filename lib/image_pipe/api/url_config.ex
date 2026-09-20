defmodule ImagePipe.API.URLConfig do
  @moduledoc """
  Reusable server-side URL configuration built by `ImagePipe.url_config/1`.

  Credentials are excluded from inspection. Keep this value on the server;
  only the generated URL belongs in client-facing data.
  """

  alias ImagePipe.API.Security
  alias ImagePipe.API.Signature.Keys
  alias ImagePipe.API.SourceEncryption

  @enforce_keys [:base_url, :keys, :source_encryption, :encrypt_source]
  @derive {Inspect, except: [:keys]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            base_url: String.t(),
            keys: Keys.t(),
            source_encryption: SourceEncryption.t(),
            encrypt_source: boolean()
          }

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) do
    {security, options} = Security.extract!(options)
    {encrypt_source, options} = Keyword.pop(options, :encrypt_source, false)
    encryption = Keyword.fetch!(security, :source_encryption)
    validate_encryption!(encrypt_source, encryption)
    {base_url, options} = Keyword.pop(options, :base_url, "")
    base_url = base_url!(base_url)

    case options do
      [] ->
        %__MODULE__{
          base_url: base_url,
          keys: Keyword.fetch!(security, :keys),
          source_encryption: encryption,
          encrypt_source: encrypt_source
        }

      _unknown ->
        raise ArgumentError, "unknown URL configuration options"
    end
  end

  defp validate_encryption!(true, encryption) do
    if SourceEncryption.disabled?(encryption),
      do: raise(ArgumentError, "encrypt_source requires source encryption keys")
  end

  defp validate_encryption!(false, _encryption), do: :ok

  defp validate_encryption!(_value, _encryption),
    do: raise(ArgumentError, "encrypt_source must be a boolean")

  defp base_url!(value) when is_binary(value) do
    with {:ok, uri} <- URI.new(value),
         true <- valid_authority?(uri),
         true <- is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo),
         false <- String.contains?(uri.path || "", "//"),
         true <- valid_path?(uri.path || "") do
      String.trim_trailing(value, "/")
    else
      _invalid -> invalid_base!()
    end
  end

  defp base_url!(_value), do: invalid_base!()

  defp valid_authority?(%URI{scheme: nil, host: nil, port: nil}), do: true

  defp valid_authority?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_authority?(_uri), do: false

  defp valid_path?(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/")
    |> valid_segments?()
  end

  defp valid_segments?([""]), do: true

  defp valid_segments?(segments),
    do:
      Enum.all?(segments, &(&1 not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, &1)))

  defp invalid_base!,
    do:
      raise(
        ArgumentError,
        "base_url must be an HTTP(S) URL or canonical unescaped path prefix without credentials, query, or fragment"
      )
end
