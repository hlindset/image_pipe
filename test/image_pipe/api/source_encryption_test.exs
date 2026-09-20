defmodule ImagePipe.API.SourceEncryptionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API
  alias ImagePipe.API.Config
  alias ImagePipe.API.Errors
  alias ImagePipe.API.Signature
  alias ImagePipe.API.SourceEncryption

  @key_a :binary.list_to_bin(Enum.to_list(0..31))
  @key_b :binary.list_to_bin(Enum.to_list(32..63))
  @source "https://example.test/a.jpg"
  # Independently generated using Python HMAC/HKDF and OpenSSL AES-CBC.
  @known_token "AZ1fjKX4xjZg9njW30WToe5U7cKt6833f7NiBT7SbOLlwPOyqrXwSHKDr2mx7rg8q7NyIO290mFAYXP7mYnm9b4kx6zFyOrfGZLTr111BmbT"

  describe "new/1" do
    test "accepts an ordered list of exact 32-byte raw keys" do
      assert {:ok, keyring} = SourceEncryption.new([@key_a, @key_b])
      refute inspect(keyring) =~ Base.encode16(@key_a)
      refute inspect(keyring) =~ @key_a
    end

    test "accepts an empty key list as disabled configuration" do
      assert {:ok, keyring} = SourceEncryption.new([])

      assert SourceEncryption.encrypt(@source, keyring) ==
               {:error, :source_encryption_disabled}
    end

    test "rejects malformed key configuration without echoing key material" do
      for invalid <- [@key_a <> <<0>>, binary_part(@key_a, 0, 31), "secret", 32, nil] do
        assert {:error, message} = SourceEncryption.new([invalid])
        assert message == "expected source encryption keys to be 32-byte binaries"

        if is_binary(invalid) do
          refute message =~ invalid
        end
      end

      assert {:error, "expected source encryption keys to be a list of 32-byte binaries"} =
               SourceEncryption.new(@key_a)
    end
  end

  describe "encrypt/2 and decrypt/2" do
    setup do
      {:ok, keyring} = SourceEncryption.new([@key_a])
      %{keyring: keyring}
    end

    test "round-trips a UTF-8 source with the fixed authenticated framing", %{keyring: keyring} do
      assert {:ok, token} = SourceEncryption.encrypt(@source, keyring)
      refute String.contains?(token, "=")

      assert {:ok, payload} = Base.url_decode64(token, padding: false)

      assert <<1, iv::binary-size(16), ciphertext::binary-size(32), tag::binary-size(32)>> =
               payload

      assert byte_size(iv) == 16
      assert byte_size(tag) == 32
      refute ciphertext == @source

      assert SourceEncryption.decrypt(token, keyring) == {:ok, @source}
    end

    test "derives a stable IV from the complete source", %{keyring: keyring} do
      assert {:ok, first} = SourceEncryption.encrypt(@source, keyring)
      assert {:ok, second} = SourceEncryption.encrypt(@source, keyring)
      assert first == second
      assert {:ok, changed} = SourceEncryption.encrypt(@source <> "?secret=changed", keyring)
      refute changed == first
      <<1, first_iv::binary-size(16), _::binary>> = Base.url_decode64!(first, padding: false)
      <<1, changed_iv::binary-size(16), _::binary>> = Base.url_decode64!(changed, padding: false)
      refute first_iv == changed_iv
      assert SourceEncryption.decrypt(first, keyring) == {:ok, @source}
      assert SourceEncryption.decrypt(second, keyring) == {:ok, @source}
    end

    test "matches the independently generated protocol vector", %{keyring: keyring} do
      assert SourceEncryption.encrypt(@source, keyring) == {:ok, @known_token}
      assert SourceEncryption.decrypt(@known_token, keyring) == {:ok, @source}
    end

    test "supports a random default and per-call explicit IV", %{keyring: keyring} do
      {:ok, random} = SourceEncryption.new([@key_a], :random)
      assert {:ok, first} = SourceEncryption.encrypt(@source, random)
      assert {:ok, second} = SourceEncryption.encrypt(@source, random)
      refute first == second
      assert SourceEncryption.decrypt(first, keyring) == {:ok, @source}
      assert SourceEncryption.decrypt(second, keyring) == {:ok, @source}
      assert {:ok, explicit} = SourceEncryption.encrypt(@source, keyring, iv: <<7::128>>)
      assert SourceEncryption.decrypt(explicit, random) == {:ok, @source}
    end

    test "encrypts with the first key and decrypts through a rotation keyring" do
      {:ok, old_keyring} = SourceEncryption.new([@key_a])
      {:ok, rotated_keyring} = SourceEncryption.new([@key_b, @key_a])
      {:ok, new_only_keyring} = SourceEncryption.new([@key_b])

      assert {:ok, old_token} = SourceEncryption.encrypt(@source, old_keyring)
      assert SourceEncryption.decrypt(old_token, rotated_keyring) == {:ok, @source}

      assert {:ok, new_token} = SourceEncryption.encrypt(@source, rotated_keyring)
      assert SourceEncryption.decrypt(new_token, new_only_keyring) == {:ok, @source}

      assert SourceEncryption.decrypt(new_token, old_keyring) ==
               {:error, :invalid_concealed_source}
    end

    test "rejects non-binary and invalid UTF-8 plaintext", %{keyring: keyring} do
      assert SourceEncryption.encrypt(42, keyring) == {:error, :invalid_source}
      assert SourceEncryption.encrypt(<<255>>, keyring) == {:error, :invalid_source}
    end

    test "collapses malformed and tampered tokens to one error", %{keyring: keyring} do
      assert {:ok, token} = SourceEncryption.encrypt(@source, keyring)
      {:ok, payload} = Base.url_decode64(token, padding: false)

      <<_version, iv::binary-size(16), ciphertext::binary-size(32), tag::binary-size(32)>> =
        payload

      malformed = [
        "",
        "not/base64",
        token <> "=",
        Base.url_encode64(<<2, iv::binary, ciphertext::binary, tag::binary>>, padding: false),
        Base.url_encode64(
          <<1, iv::binary, ciphertext::binary, binary_part(tag, 0, 31)::binary>>,
          padding: false
        ),
        mutate_payload(token, 1),
        mutate_payload(token, 17),
        mutate_payload(token, byte_size(payload) - 1)
      ]

      for malformed_token <- malformed do
        assert SourceEncryption.decrypt(malformed_token, keyring) ==
                 {:error, :invalid_concealed_source}
      end
    end

    test "rejects authenticated empty and invalid UTF-8 plaintext", %{keyring: keyring} do
      aad = "image-pipe:source:v1"

      <<key::binary-size(64), _::binary>> =
        SourceEncryption.HKDF.derive(@key_a, aad, "A256CBC-HS512+IV", 96)

      for plaintext <- ["", <<255>>] do
        {ciphertext, tag} = SourceEncryption.CBC.encrypt(plaintext, key, <<0::128>>, aad)
        token = Base.url_encode64(<<1, 0::128, ciphertext::binary, tag::binary>>, padding: false)
        assert SourceEncryption.decrypt(token, keyring) == {:error, :invalid_concealed_source}
      end
    end
  end

  describe "API lifecycle" do
    setup do
      config =
        Config.validate!(
          keys: [String.duplicate("a1", 32)],
          source_encryption_keys: [@key_a]
        )

      %{config: config}
    end

    test "the public helper returns a token that parse authenticates into plaintext", %{
      config: config
    } do
      assert {:ok, token} = API.encrypt_source(@source, config)
      signed_path = "/w=12/enc/#{token}"
      signature = Signature.sign(signed_path, config)
      conn = Plug.Test.conn(:get, "/sig=#{signature}#{signed_path}")

      assert {{:ok, request}, %{result: :ok, sig_key_index: 0}} = API.parse(conn, config)
      assert request.source == @source
    end

    test "signature validation precedes token validation", %{config: config} do
      invalid_conn = Plug.Test.conn(:get, "/sig=invalid/w=12/enc/not/a/token")

      assert {{:error, :invalid_signature}, %{result: :error}} =
               API.parse(invalid_conn, config)

      signed_path = "/w=12/enc/not/a/token"
      signature = Signature.sign(signed_path, config)
      signed_conn = Plug.Test.conn(:get, "/sig=#{signature}#{signed_path}")

      assert {{:error, :invalid_concealed_source}, %{result: :error}} =
               API.parse(signed_conn, config)
    end

    test "the public helper rejects disabled, empty, and invalid UTF-8 sources", %{config: config} do
      disabled = Config.validate!([])

      assert API.encrypt_source(@source, disabled) ==
               {:error, :source_encryption_disabled}

      assert API.encrypt_source("", config) == {:error, :invalid_source}
      assert API.encrypt_source(<<255>>, config) == {:error, :invalid_source}
    end

    test "concealment failures render and classify as a fixed parser-side 404" do
      conn = Errors.send(Plug.Test.conn(:get, "/enc/private"), :invalid_concealed_source)

      assert conn.status == 404
      assert conn.resp_body == "not found"
      assert API.classify_error(:invalid_concealed_source) == :parser_error
    end
  end

  defp mutate_payload(token, offset) do
    {:ok, payload} = Base.url_decode64(token, padding: false)
    <<prefix::binary-size(^offset), byte, suffix::binary>> = payload
    Base.url_encode64(<<prefix::binary, Bitwise.bxor(byte, 1), suffix::binary>>, padding: false)
  end
end
