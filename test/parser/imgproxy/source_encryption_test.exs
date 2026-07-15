# The tests in this module exercise ImagePipe.Parser.Imgproxy.validate_options!/1,
# .encrypt_source_url/3 (a one-line delegate to SourceEncryption), and .parse/2 —
# i.e. the framework parser adapter's wiring, not SourceEncryption's own public
# API in isolation. ImagePipe.Dialect.Imgproxy has no equivalent top-level
# validate_options!/parse entry point yet (that arrives with the dialect's own
# Plug chain), so this module stays single-arm. The dual-run coverage of
# SourceEncryption itself — the module Task 10 actually copies — lives in the
# `for {impl, suffix} <- [...]` block below, calling validate_key/1,
# encrypt_source_url/3, and decrypt_source/2 directly on both arms.
defmodule ImagePipe.Parser.Imgproxy.SourceEncryptionAdapterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test
  import StreamData

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Parser.Imgproxy.SourceEncryption
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Source

  @aes128_key "000102030405060708090a0b0c0d0e0f"
  @aes192_key "000102030405060708090a0b0c0d0e0f1011121314151617"
  @aes256_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  @fixed_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  @source_url "images/beach.jpg"
  @expected_segment "EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ"

  @docs_key "1eb5b0e971ad7f45324c1bb15c947cb207c43152fa5c6c7f35c4f36e0c18e0f1"
  @docs_segment "p5VjorNdhs7mRRw8gA9TWoRlGci3l1kuzqN43UQlRaRIQ0qtBKW3qFABIsx-ZRz_cVc8iVTYbhsNsxNBL1BHaQ"

  test "validates and stores decoded encryption key material" do
    imgproxy_opts =
      [imgproxy: [source_url_encryption_key: @aes128_key]]
      |> Imgproxy.validate_options!()
      |> Keyword.fetch!(:imgproxy)

    assert %SourceEncryption{key: decoded_key} =
             Keyword.fetch!(imgproxy_opts, :source_url_encryption)

    assert decoded_key == Base.decode16!(@aes128_key, case: :mixed)
    refute inspect(imgproxy_opts) =~ @aes128_key
    refute inspect(imgproxy_opts) =~ inspect(decoded_key)
  end

  test "rejects malformed encryption keys without echoing the key value" do
    for key <- ["", "not-hex", String.duplicate("00", 15), String.duplicate("00", 33)] do
      assert_raise ArgumentError, ~r/invalid imgproxy config/, fn ->
        Imgproxy.validate_options!(imgproxy: [source_url_encryption_key: key])
      end

      try do
        Imgproxy.validate_options!(imgproxy: [source_url_encryption_key: key])
      rescue
        error in ArgumentError ->
          if key != "" do
            refute Exception.message(error) =~ key
          end
      end
    end
  end

  test "public helper encrypts a source URL into an imgproxy source segment" do
    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, iv: @fixed_iv) ==
             {:ok, @expected_segment}
  end

  test "public helper returns stable errors for malformed runtime input" do
    assert Imgproxy.encrypt_source_url(:not_binary, @aes128_key) == {:error, :invalid_source_url}
    assert Imgproxy.encrypt_source_url(@source_url, :not_binary) == {:error, :invalid_key}
    assert Imgproxy.encrypt_source_url(@source_url, "not-hex") == {:error, :invalid_key}
    assert {:ok, _segment} = Imgproxy.encrypt_source_url(@source_url, @aes128_key, [])

    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, %{iv: @fixed_iv}) ==
             {:error, :invalid_options}

    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, unknown: true) ==
             {:error, :invalid_options}

    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, iv: :not_binary) ==
             {:error, :invalid_iv}

    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, iv: fixed_binary(15)) ==
             {:error, :invalid_iv}

    assert Imgproxy.encrypt_source_url(@source_url, @aes128_key, iv: fixed_binary(17)) ==
             {:error, :invalid_iv}
  end

  test "parses the imgproxy docs encrypted source example" do
    opts = parser_opts(source_url_encryption_key: @docs_key)

    assert {:ok,
            %Plan{
              source: %Source.URL{
                scheme: :http,
                host: "example.com",
                path: ["images", "curiosity.jpg"]
              }
            }} =
             Imgproxy.parse(conn(:get, "/_/enc/#{@docs_segment}"), opts)
  end

  test "parses encrypted output suffixes before SEO filename segments" do
    opts =
      parser_opts(
        source_url_encryption_key: @aes128_key,
        base64_url_includes_filename: true
      )

    assert {:ok,
            %Plan{
              source: %Source.Path{segments: ["images", "beach.jpg"]},
              output: %Output{mode: {:explicit, :webp}}
            }} =
             Imgproxy.parse(conn(:get, "/_/enc/#{@expected_segment}.webp/puppy.jpg"), opts)
  end

  test "collapses configured encrypted parse failures to one public parser reason" do
    opts = parser_opts(source_url_encryption_key: @aes128_key)

    malformed_paths = [
      "/_/enc/not+base64",
      "/_/enc/#{Base.url_encode64(String.duplicate("x", 31), padding: false)}",
      "/_/enc/#{Base.url_encode64(@fixed_iv <> String.duplicate("x", 17), padding: false)}",
      "/_/enc/#{Base.url_encode64(@fixed_iv <> String.duplicate("x", 16), padding: false)}",
      "/_/enc/#{encrypted_segment(<<255>>, @aes128_key, @fixed_iv)}"
    ]

    for path <- malformed_paths do
      assert Imgproxy.parse(conn(:get, path), opts) == {:error, :invalid_encrypted_source}
    end
  end

  property "public helper emits source segments that the parser decrypts" do
    check all key <- member_of([@aes128_key, @aes192_key, @aes256_key]),
              source <- source_url(),
              iv <- binary(length: 16),
              filename <- seo_filename(),
              max_runs: 75 do
      opts =
        parser_opts(
          source_url_encryption_key: key,
          base64_url_includes_filename: true
        )

      assert {:ok, segment} = Imgproxy.encrypt_source_url(source, key, iv: iv)

      assert {:ok, %Plan{source: %Source.Path{segments: parsed_segments}}} =
               Imgproxy.parse(conn(:get, "/_/enc/#{segment}/#{filename}"), opts)

      assert parsed_segments == String.split(source, "/", trim: false)
    end
  end

  defp parser_opts(imgproxy_opts) do
    Imgproxy.validate_options!(imgproxy: imgproxy_opts)
  end

  defp encrypted_segment(source, key, iv) do
    {:ok, segment} = Imgproxy.encrypt_source_url(source, key, iv: iv)
    segment
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

  defp seo_filename do
    string(:alphanumeric, min_length: 1, max_length: 24)
    |> map(&(&1 <> ".jpg"))
  end

  defp fixed_binary(size), do: :binary.copy("x", size)
end

for {impl, suffix} <- [
      {ImagePipe.Parser.Imgproxy.SourceEncryption, Framework},
      {ImagePipe.Dialect.Imgproxy.SourceEncryption, Dialect}
    ] do
  defmodule Module.concat(SourceEncryptionTest, suffix) do
    use ExUnit.Case, async: true
    use ExUnitProperties

    import StreamData

    @source_encryption impl

    @aes128_key "000102030405060708090a0b0c0d0e0f"
    @aes192_key "000102030405060708090a0b0c0d0e0f1011121314151617"
    @aes256_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    @fixed_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
    @source_url "images/beach.jpg"
    @expected_segment "EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ"

    @docs_key "1eb5b0e971ad7f45324c1bb15c947cb207c43152fa5c6c7f35c4f36e0c18e0f1"
    @docs_segment "p5VjorNdhs7mRRw8gA9TWoRlGci3l1kuzqN43UQlRaRIQ0qtBKW3qFABIsx-ZRz_cVc8iVTYbhsNsxNBL1BHaQ"

    test "validate_key/1 decodes 16/24/32-byte hex keys" do
      assert {:ok, %{key: decoded}} = @source_encryption.validate_key(@aes128_key)
      assert decoded == Base.decode16!(@aes128_key, case: :mixed)

      assert {:ok, %{key: decoded}} = @source_encryption.validate_key(@aes192_key)
      assert decoded == Base.decode16!(@aes192_key, case: :mixed)

      assert {:ok, %{key: decoded}} = @source_encryption.validate_key(@aes256_key)
      assert decoded == Base.decode16!(@aes256_key, case: :mixed)
    end

    test "validate_key/1 rejects malformed keys" do
      for key <- ["", "not-hex", String.duplicate("00", 15), String.duplicate("00", 33)] do
        assert @source_encryption.validate_key(key) ==
                 {:error, "must be a non-empty hex-encoded AES key"}
      end
    end

    test "encrypt_source_url/3 with a fixed IV matches the known-good vector" do
      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key, iv: @fixed_iv) ==
               {:ok, @expected_segment}
    end

    test "encrypt_source_url/3 returns stable errors for malformed runtime input" do
      assert @source_encryption.encrypt_source_url(:not_binary, @aes128_key) ==
               {:error, :invalid_source_url}

      assert @source_encryption.encrypt_source_url(@source_url, :not_binary) ==
               {:error, :invalid_key}

      assert @source_encryption.encrypt_source_url(@source_url, "not-hex") ==
               {:error, :invalid_key}

      assert {:ok, _segment} = @source_encryption.encrypt_source_url(@source_url, @aes128_key, [])

      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key, %{iv: @fixed_iv}) ==
               {:error, :invalid_options}

      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key, unknown: true) ==
               {:error, :invalid_options}

      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key, iv: :not_binary) ==
               {:error, :invalid_iv}

      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key,
               iv: :binary.copy("x", 15)
             ) == {:error, :invalid_iv}

      assert @source_encryption.encrypt_source_url(@source_url, @aes128_key,
               iv: :binary.copy("x", 17)
             ) == {:error, :invalid_iv}
    end

    test "decrypt_source/2 rejects a nil config" do
      assert @source_encryption.decrypt_source(@expected_segment, nil) ==
               {:error, :missing_source_url_encryption_key}
    end

    test "decrypt_source/2 decodes the imgproxy docs encrypted source example" do
      config = %@source_encryption{key: Base.decode16!(@docs_key, case: :mixed)}

      assert @source_encryption.decrypt_source(@docs_segment, config) ==
               {:ok, "http://example.com/images/curiosity.jpg"}
    end

    test "decrypt_source/2 collapses malformed payloads to stable error reasons" do
      config = %@source_encryption{key: Base.decode16!(@aes128_key, case: :mixed)}

      assert @source_encryption.decrypt_source("not+base64", config) ==
               {:error, :invalid_base64}

      assert @source_encryption.decrypt_source(
               Base.url_encode64(String.duplicate("x", 31), padding: false),
               config
             ) == {:error, :invalid_payload_size}

      assert @source_encryption.decrypt_source(
               Base.url_encode64(@fixed_iv <> String.duplicate("x", 17), padding: false),
               config
             ) == {:error, :invalid_payload_size}

      assert @source_encryption.decrypt_source(
               Base.url_encode64(@fixed_iv <> String.duplicate("x", 16), padding: false),
               config
             ) == {:error, :invalid_padding}
    end

    property "encrypt_source_url/3 and decrypt_source/2 round-trip" do
      check all key <- member_of([@aes128_key, @aes192_key, @aes256_key]),
                source <- source_url(),
                iv <- binary(length: 16),
                max_runs: 75 do
        config = %@source_encryption{key: Base.decode16!(key, case: :mixed)}

        assert {:ok, segment} = @source_encryption.encrypt_source_url(source, key, iv: iv)
        assert @source_encryption.decrypt_source(segment, config) == {:ok, source}
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
end
