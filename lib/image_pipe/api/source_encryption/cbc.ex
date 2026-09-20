defmodule ImagePipe.API.SourceEncryption.CBC do
  @moduledoc false

  # A256CBC-HS512, RFC 7518 §5.2.5. Authenticate before decrypting/unpadding.
  def encrypt(plaintext, <<mac_key::binary-size(32), enc_key::binary-size(32)>>, iv, aad) do
    padding = 16 - rem(byte_size(plaintext), 16)
    padded = plaintext <> :binary.copy(<<padding>>, padding)
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, enc_key, iv, padded, true)
    {ciphertext, tag(mac_key, aad, iv, ciphertext)}
  end

  def decrypt(ciphertext, tag, <<mac_key::binary-size(32), enc_key::binary-size(32)>>, iv, aad) do
    case Plug.Crypto.secure_compare(tag, tag(mac_key, aad, iv, ciphertext)) do
      true ->
        :aes_256_cbc
        |> :crypto.crypto_one_time(enc_key, iv, ciphertext, false)
        |> unpad()

      false ->
        :error
    end
  end

  defp tag(key, aad, iv, ciphertext) do
    :hmac
    |> :crypto.mac(:sha512, key, [aad, iv, ciphertext, <<bit_size(aad)::64>>])
    |> binary_part(0, 32)
  end

  defp unpad(padded) do
    padding = :binary.last(padded)
    size = byte_size(padded) - padding

    case padding in 1..16 and
           binary_part(padded, size, padding) == :binary.copy(<<padding>>, padding) do
      true -> {:ok, binary_part(padded, 0, size)}
      false -> :error
    end
  end
end
