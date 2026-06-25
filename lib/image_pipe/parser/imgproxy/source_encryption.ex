defmodule ImagePipe.Parser.Imgproxy.SourceEncryption do
  @moduledoc false

  @enforce_keys [:key]
  @derive {Inspect, except: [:key]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{key: binary()}
  @type helper_error :: :invalid_source_url | :invalid_key | :invalid_iv | :invalid_options

  @spec validate_key(term()) :: {:ok, t()} | {:error, String.t()}
  def validate_key(key) do
    case decode_key(key) do
      {:ok, decoded_key} -> {:ok, %__MODULE__{key: decoded_key}}
      {:error, :invalid_key} -> {:error, "must be a non-empty hex-encoded AES key"}
    end
  end

  @spec encrypt_source_url(term(), term(), term()) :: {:ok, binary()} | {:error, helper_error()}
  def encrypt_source_url(source_url, hex_key, opts \\ [])

  def encrypt_source_url(source_url, _hex_key, _opts) when not is_binary(source_url),
    do: {:error, :invalid_source_url}

  def encrypt_source_url(_source_url, _hex_key, opts) when not is_list(opts),
    do: {:error, :invalid_options}

  def encrypt_source_url(source_url, hex_key, opts) do
    with :ok <- validate_helper_options(opts),
         {:ok, key} <- decode_key(hex_key),
         {:ok, iv} <- helper_iv(opts),
         {:ok, cipher} <- cipher_for_key(key) do
      payload =
        source_url
        |> pkcs7_pad()
        |> then(&:crypto.crypto_one_time(cipher, key, iv, &1, true))
        |> then(&(iv <> &1))
        |> Base.url_encode64(padding: false)

      {:ok, payload}
    end
  end

  @spec decrypt_source(binary(), t() | nil) ::
          {:ok, binary()}
          | {:error,
             :missing_source_url_encryption_key
             | :invalid_base64
             | :invalid_payload_size
             | :invalid_padding
             | :invalid_utf8}
  def decrypt_source(_source, nil), do: {:error, :missing_source_url_encryption_key}

  def decrypt_source(source, %__MODULE__{key: key}) when is_binary(source) do
    with {:ok, payload} <- decode_payload(source),
         {:ok, iv, ciphertext} <- split_payload(payload),
         {:ok, cipher} <- cipher_for_key(key),
         plaintext <- :crypto.crypto_one_time(cipher, key, iv, ciphertext, false),
         {:ok, unpadded} <- pkcs7_unpad(plaintext),
         :ok <- validate_utf8(unpadded) do
      {:ok, unpadded}
    end
  end

  defp decode_key(key) when is_binary(key) do
    with {:ok, decoded} <- decode_hex(key),
         true <- byte_size(decoded) in [16, 24, 32] do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid_key}
    end
  end

  defp decode_key(_key), do: {:error, :invalid_key}

  defp decode_hex(key) do
    case Base.decode16(key, case: :mixed) do
      {:ok, ""} -> {:error, :invalid_key}
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_key}
    end
  end

  defp validate_helper_options(opts) do
    case Keyword.keyword?(opts) and Keyword.keys(opts) -- [:iv] == [] do
      true -> :ok
      false -> {:error, :invalid_options}
    end
  end

  defp helper_iv(opts) do
    case Keyword.fetch(opts, :iv) do
      {:ok, iv} when is_binary(iv) and byte_size(iv) == 16 -> {:ok, iv}
      {:ok, _iv} -> {:error, :invalid_iv}
      :error -> {:ok, :crypto.strong_rand_bytes(16)}
    end
  end

  defp cipher_for_key(key) do
    case byte_size(key) do
      16 -> {:ok, :aes_128_cbc}
      24 -> {:ok, :aes_192_cbc}
      32 -> {:ok, :aes_256_cbc}
      _size -> {:error, :invalid_key}
    end
  end

  defp pkcs7_pad(plaintext) do
    padding_size = 16 - rem(byte_size(plaintext), 16)
    plaintext <> :binary.copy(<<padding_size>>, padding_size)
  end

  defp decode_payload(source) do
    source
    |> String.trim_trailing("=")
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, payload} -> {:ok, payload}
      :error -> {:error, :invalid_base64}
    end
  end

  defp split_payload(payload) when byte_size(payload) >= 32 do
    <<iv::binary-size(16), ciphertext::binary>> = payload

    case rem(byte_size(ciphertext), 16) do
      0 -> {:ok, iv, ciphertext}
      _remainder -> {:error, :invalid_payload_size}
    end
  end

  defp split_payload(_payload), do: {:error, :invalid_payload_size}

  defp pkcs7_unpad(plaintext) when byte_size(plaintext) > 0 do
    padding_size = :binary.last(plaintext)

    with true <- padding_size in 1..16,
         true <- padding_size <= byte_size(plaintext),
         padding <- :binary.part(plaintext, byte_size(plaintext) - padding_size, padding_size),
         true <- padding == :binary.copy(<<padding_size>>, padding_size) do
      unpadded_size = byte_size(plaintext) - padding_size
      {:ok, :binary.part(plaintext, 0, unpadded_size)}
    else
      _invalid -> {:error, :invalid_padding}
    end
  end

  defp pkcs7_unpad(_plaintext), do: {:error, :invalid_padding}

  defp validate_utf8(plaintext) do
    case String.valid?(plaintext) do
      true -> :ok
      false -> {:error, :invalid_utf8}
    end
  end
end
