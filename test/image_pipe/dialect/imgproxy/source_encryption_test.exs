defmodule ImagePipe.Dialect.Imgproxy.SourceEncryptionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData

  alias ImagePipe.Dialect.Imgproxy.SourceEncryption

  @aes128_key "000102030405060708090a0b0c0d0e0f"
  @aes192_key "000102030405060708090a0b0c0d0e0f1011121314151617"
  @aes256_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  @fixed_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  @source_url "images/beach.jpg"
  @expected_segment "EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ"

  @docs_key "1eb5b0e971ad7f45324c1bb15c947cb207c43152fa5c6c7f35c4f36e0c18e0f1"
  @docs_segment "p5VjorNdhs7mRRw8gA9TWoRlGci3l1kuzqN43UQlRaRIQ0qtBKW3qFABIsx-ZRz_cVc8iVTYbhsNsxNBL1BHaQ"

  test "validate_key/1 decodes 16/24/32-byte hex keys" do
    assert {:ok, %SourceEncryption{key: decoded}} =
             SourceEncryption.validate_key(@aes128_key)

    assert decoded == Base.decode16!(@aes128_key, case: :mixed)

    assert {:ok, %SourceEncryption{key: decoded}} =
             SourceEncryption.validate_key(@aes192_key)

    assert decoded == Base.decode16!(@aes192_key, case: :mixed)

    assert {:ok, %SourceEncryption{key: decoded}} =
             SourceEncryption.validate_key(@aes256_key)

    assert decoded == Base.decode16!(@aes256_key, case: :mixed)
  end

  test "validate_key/1 rejects malformed keys" do
    for key <- ["", "not-hex", String.duplicate("00", 15), String.duplicate("00", 33)] do
      assert SourceEncryption.validate_key(key) ==
               {:error, "must be a non-empty hex-encoded AES key"}
    end
  end

  test "encrypt_source_url/3 with a fixed IV matches the known-good vector" do
    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key, iv: @fixed_iv) ==
             {:ok, @expected_segment}
  end

  test "encrypt_source_url/3 returns stable errors for malformed runtime input" do
    assert SourceEncryption.encrypt_source_url(:not_binary, @aes128_key) ==
             {:error, :invalid_source_url}

    assert SourceEncryption.encrypt_source_url(@source_url, :not_binary) ==
             {:error, :invalid_key}

    assert SourceEncryption.encrypt_source_url(@source_url, "not-hex") ==
             {:error, :invalid_key}

    assert {:ok, _segment} = SourceEncryption.encrypt_source_url(@source_url, @aes128_key, [])

    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key, %{iv: @fixed_iv}) ==
             {:error, :invalid_options}

    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key, unknown: true) ==
             {:error, :invalid_options}

    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key, iv: :not_binary) ==
             {:error, :invalid_iv}

    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key,
             iv: :binary.copy("x", 15)
           ) == {:error, :invalid_iv}

    assert SourceEncryption.encrypt_source_url(@source_url, @aes128_key,
             iv: :binary.copy("x", 17)
           ) == {:error, :invalid_iv}
  end

  test "decrypt_source/2 rejects a nil config" do
    assert SourceEncryption.decrypt_source(@expected_segment, nil) ==
             {:error, :missing_source_url_encryption_key}
  end

  test "decrypt_source/2 decodes the imgproxy docs encrypted source example" do
    config = %SourceEncryption{key: Base.decode16!(@docs_key, case: :mixed)}

    assert SourceEncryption.decrypt_source(@docs_segment, config) ==
             {:ok, "http://example.com/images/curiosity.jpg"}
  end

  test "decrypt_source/2 collapses malformed payloads to stable error reasons" do
    config = %SourceEncryption{key: Base.decode16!(@aes128_key, case: :mixed)}

    assert SourceEncryption.decrypt_source("not+base64", config) ==
             {:error, :invalid_base64}

    assert SourceEncryption.decrypt_source(
             Base.url_encode64(String.duplicate("x", 31), padding: false),
             config
           ) == {:error, :invalid_payload_size}

    assert SourceEncryption.decrypt_source(
             Base.url_encode64(@fixed_iv <> String.duplicate("x", 17), padding: false),
             config
           ) == {:error, :invalid_payload_size}

    assert SourceEncryption.decrypt_source(
             Base.url_encode64(@fixed_iv <> String.duplicate("x", 16), padding: false),
             config
           ) == {:error, :invalid_padding}
  end

  test "inspect/1 redacts the AES key" do
    # `@derive {Inspect, except: [:key]}` lives on the struct this arm copies,
    # so each arm must prove its own redaction. Asserted here rather than only
    # through the adapter: the adapter block is single-arm and phase 2 deletes
    # it, which would otherwise leave this property with no test on either arm.
    key = Base.decode16!(@aes128_key, case: :mixed)
    dumped = inspect(%SourceEncryption{key: key})

    refute dumped =~ @aes128_key
    refute dumped =~ inspect(key)
    assert dumped =~ "..."
  end

  property "encrypt_source_url/3 and decrypt_source/2 round-trip" do
    check all key <- member_of([@aes128_key, @aes192_key, @aes256_key]),
              source <- source_url(),
              iv <- binary(length: 16),
              max_runs: 75 do
      config = %SourceEncryption{key: Base.decode16!(key, case: :mixed)}

      assert {:ok, segment} = SourceEncryption.encrypt_source_url(source, key, iv: iv)
      assert SourceEncryption.decrypt_source(segment, config) == {:ok, source}
    end
  end

  defp source_url do
    length =
      integer(0..48)
      |> map(fn length -> length + rem(16 - rem(length, 16), 16) end)

    length
    |> bind(fn byte_count ->
      StreamData.binary(length: byte_count)
    end)
    |> map(fn bytes -> "images/" <> Base.url_encode64(bytes, padding: false) <> ".jpg" end)
  end
end
