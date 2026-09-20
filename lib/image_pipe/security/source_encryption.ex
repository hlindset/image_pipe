defmodule ImagePipe.Security.SourceEncryption do
  @moduledoc false

  alias ImagePipe.Security.SourceEncryption.{CBC, HKDF}

  @version 1
  @iv_bytes 16
  @tag_bytes 32
  @key_bytes 32
  @aad "image-pipe:source:v1"

  @enforce_keys [:keys, :derived_keys, :iv_mode]
  @derive {Inspect, except: [:keys, :derived_keys]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            keys: [binary()],
            derived_keys: [{binary(), binary()}],
            iv_mode: :deterministic | :random
          }

  @spec new(term(), term()) :: {:ok, t()} | {:error, String.t()}
  def new(keys, iv_mode \\ :deterministic)

  def new(_keys, iv_mode) when iv_mode not in [:deterministic, :random],
    do: {:error, "expected iv_mode to be :deterministic or :random"}

  def new(keys, iv_mode) when is_list(keys) do
    case Enum.all?(keys, &(is_binary(&1) and byte_size(&1) == @key_bytes)) do
      true ->
        {:ok, %__MODULE__{keys: keys, derived_keys: Enum.map(keys, &derive/1), iv_mode: iv_mode}}

      false ->
        {:error, "expected source encryption keys to be 32-byte binaries"}
    end
  end

  def new(_keys, _iv_mode),
    do: {:error, "expected source encryption keys to be a list of 32-byte binaries"}

  @doc false
  @spec disabled?(t()) :: boolean()
  def disabled?(%__MODULE__{keys: []}), do: true
  def disabled?(%__MODULE__{}), do: false

  @doc false
  @spec key?(t(), binary()) :: boolean()
  def key?(%__MODULE__{keys: keys}, candidate), do: candidate in keys

  @spec encrypt(term(), t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def encrypt(source, keyring, options \\ [])

  def encrypt(_source, %__MODULE__{keys: []}, _options),
    do: {:error, :source_encryption_disabled}

  def encrypt(source, %__MODULE__{derived_keys: [key | _keys], iv_mode: mode}, options)
      when is_binary(source) and source != "" do
    case String.valid?(source) do
      true ->
        with {:ok, iv} <- resolve_iv(options, mode, source, key) do
          {:ok, encrypt_with_key(source, key, iv)}
        end

      false ->
        {:error, :invalid_source}
    end
  end

  def encrypt(_source, %__MODULE__{}, _options), do: {:error, :invalid_source}

  @spec decrypt(term(), t()) :: {:ok, String.t()} | {:error, :invalid_concealed_source}
  def decrypt(token, %__MODULE__{derived_keys: keys}) when is_binary(token) do
    with {:ok, payload} <- decode_token(token),
         {:ok, iv, ciphertext, tag} <- split_payload(payload),
         {:ok, source} <- decrypt_with_keys(keys, iv, ciphertext, tag),
         true <- source != "" and String.valid?(source) do
      {:ok, source}
    else
      _error -> {:error, :invalid_concealed_source}
    end
  end

  def decrypt(_token, %__MODULE__{}), do: {:error, :invalid_concealed_source}

  defp derive(key) do
    <<cbc_key::binary-size(64), iv_key::binary-size(32)>> =
      HKDF.derive(key, @aad, "A256CBC-HS512+IV", 96)

    {cbc_key, iv_key}
  end

  defp resolve_iv([], mode, source, key), do: resolve_iv([iv: mode], mode, source, key)

  defp resolve_iv([iv: :deterministic], _mode, source, {_cbc_key, iv_key}),
    do: {:ok, binary_part(:crypto.mac(:hmac, :sha256, iv_key, source), 0, @iv_bytes)}

  defp resolve_iv([iv: :random], _mode, _source, _key),
    do: {:ok, :crypto.strong_rand_bytes(@iv_bytes)}

  defp resolve_iv([iv: iv], _mode, _source, _key)
       when is_binary(iv) and byte_size(iv) == @iv_bytes,
       do: {:ok, iv}

  defp resolve_iv(_options, _mode, _source, _key), do: {:error, :invalid_encryption_options}

  defp encrypt_with_key(source, {key, _iv_key}, iv) do
    {ciphertext, tag} = CBC.encrypt(source, key, iv, @aad)

    Base.url_encode64(
      <<@version, iv::binary, ciphertext::binary, tag::binary>>,
      padding: false
    )
  end

  defp decode_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, payload} -> canonical_token(token, payload)
      :error -> :error
    end
  end

  defp canonical_token(token, payload) do
    case Base.url_encode64(payload, padding: false) do
      ^token -> {:ok, payload}
      _other -> :error
    end
  end

  defp split_payload(<<@version, iv::binary-size(@iv_bytes), encrypted::binary>>)
       when byte_size(encrypted) > @tag_bytes and rem(byte_size(encrypted) - @tag_bytes, 16) == 0 do
    ciphertext_bytes = byte_size(encrypted) - @tag_bytes
    <<ciphertext::binary-size(^ciphertext_bytes), tag::binary-size(@tag_bytes)>> = encrypted
    {:ok, iv, ciphertext, tag}
  end

  defp split_payload(_payload), do: :error

  defp decrypt_with_keys(keys, iv, ciphertext, tag) do
    Enum.reduce_while(keys, :error, fn {key, _iv_key}, _error ->
      case CBC.decrypt(ciphertext, tag, key, iv, @aad) do
        :error -> {:cont, :error}
        {:ok, source} -> {:halt, {:ok, source}}
      end
    end)
  end
end
