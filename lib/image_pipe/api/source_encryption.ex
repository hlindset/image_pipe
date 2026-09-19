defmodule ImagePipe.API.SourceEncryption do
  @moduledoc false

  @version 1
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @aad "image-pipe:source:v1"

  @enforce_keys [:keys]
  @derive {Inspect, except: [:keys]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{keys: [binary()]}

  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new(keys) when is_list(keys) do
    case Enum.all?(keys, &(is_binary(&1) and byte_size(&1) == @key_bytes)) do
      true -> {:ok, %__MODULE__{keys: keys}}
      false -> {:error, "expected source encryption keys to be 32-byte binaries"}
    end
  end

  def new(_keys),
    do: {:error, "expected source encryption keys to be a list of 32-byte binaries"}

  @doc false
  @spec disabled?(t()) :: boolean()
  def disabled?(%__MODULE__{keys: []}), do: true
  def disabled?(%__MODULE__{}), do: false

  @doc false
  @spec key?(t(), binary()) :: boolean()
  def key?(%__MODULE__{keys: keys}, candidate), do: candidate in keys

  @spec encrypt(term(), t()) ::
          {:ok, String.t()} | {:error, :invalid_source | :source_encryption_disabled}
  def encrypt(_source, %__MODULE__{keys: []}), do: {:error, :source_encryption_disabled}

  def encrypt(source, %__MODULE__{keys: [key | _keys]})
      when is_binary(source) and source != "" do
    case String.valid?(source) do
      true -> {:ok, encrypt_with_key(source, key)}
      false -> {:error, :invalid_source}
    end
  end

  def encrypt(_source, %__MODULE__{}), do: {:error, :invalid_source}

  @spec decrypt(term(), t()) :: {:ok, String.t()} | {:error, :invalid_concealed_source}
  def decrypt(token, %__MODULE__{keys: keys}) when is_binary(token) do
    with {:ok, payload} <- decode_token(token),
         {:ok, nonce, ciphertext, tag} <- split_payload(payload),
         {:ok, source} <- decrypt_with_keys(keys, nonce, ciphertext, tag),
         true <- String.valid?(source) do
      {:ok, source}
    else
      _error -> {:error, :invalid_concealed_source}
    end
  end

  def decrypt(_token, %__MODULE__{}), do: {:error, :invalid_concealed_source}

  defp encrypt_with_key(source, key) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        source,
        @aad,
        @tag_bytes,
        true
      )

    Base.url_encode64(
      <<@version, nonce::binary, ciphertext::binary, tag::binary>>,
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

  defp split_payload(<<@version, nonce::binary-size(@nonce_bytes), encrypted::binary>>)
       when byte_size(encrypted) > @tag_bytes do
    ciphertext_bytes = byte_size(encrypted) - @tag_bytes
    <<ciphertext::binary-size(^ciphertext_bytes), tag::binary-size(@tag_bytes)>> = encrypted
    {:ok, nonce, ciphertext, tag}
  end

  defp split_payload(_payload), do: :error

  defp decrypt_with_keys(keys, nonce, ciphertext, tag) do
    Enum.reduce_while(keys, :error, fn key, _error ->
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             @aad,
             tag,
             false
           ) do
        :error -> {:cont, :error}
        source -> {:halt, {:ok, source}}
      end
    end)
  end
end
