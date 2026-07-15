defmodule ImagePipe.Parser.Imgproxy.SignatureAdapterTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Parser.Imgproxy.Signature

  # These tests exercise ImagePipe.Parser.Imgproxy.validate_options!/1 —
  # the framework parser adapter's mount-time option validation — not
  # Signature itself. ImagePipe.Dialect.Imgproxy has no equivalent top-level
  # option-validation entry point yet (it arrives with the dialect's own Plug
  # chain), so these stay single-arm rather than being force-fit into the
  # dual-run loop below.
  test "imgproxy parser exposes parser-owned option validation" do
    options =
      []
      |> Imgproxy.validate_options!()
      |> Keyword.fetch!(:imgproxy)

    assert %Signature{mode: :disabled} = Keyword.fetch!(options, :signature)
    assert %ImagePipe.Parser.Imgproxy.Presets{} = Keyword.fetch!(options, :presets)
  end

  describe "Imgproxy.validate_options!/1" do
    test "rejects unknown top-level imgproxy options" do
      assert_raise ArgumentError, ~r/unknown.*:trusted_signatures/, fn ->
        Imgproxy.validate_options!(imgproxy: [trusted_signatures: ["local-dev!"]])
      end

      assert_raise ArgumentError, ~r/unknown.*:keys/, fn ->
        Imgproxy.validate_options!(imgproxy: [keys: ["74657374"], salts: ["73616c74"]])
      end
    end

    test "rejects explicit nil signature config" do
      assert_raise ArgumentError, ~r/invalid value for :signature option/, fn ->
        Imgproxy.validate_options!(imgproxy: [signature: nil])
      end
    end
  end
end

for {impl, suffix} <- [
      {ImagePipe.Parser.Imgproxy.Signature, Framework},
      {ImagePipe.Dialect.Imgproxy.Signature, Dialect}
    ] do
  defmodule Module.concat(ImgproxySignatureTest, suffix) do
    use ExUnit.Case, async: true

    @signature impl

    describe "normalize_config!/1" do
      test "returns disabled config when imgproxy signature config is absent" do
        assert %@signature{mode: :disabled, key_salt_pairs: [], signature_size: 32} =
                 @signature.normalize_config!(nil)
      end

      test "normalizes hex key and salt pairs" do
        assert %@signature{
                 mode: :enabled,
                 key_salt_pairs: [{"test-key", "test-salt"}],
                 signature_size: 8,
                 trusted_signatures: trusted_signatures
               } =
                 @signature.normalize_config!(
                   keys: ["746573742d6b6579"],
                   salts: ["746573742d73616c74"],
                   signature_size: 8,
                   trusted_signatures: ["local-dev!"]
                 )

        assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
      end

      test "rejects unknown signature options" do
        assert_raise ArgumentError, ~r/unknown options.*:trusted_signature/, fn ->
          @signature.normalize_config!(
            keys: ["74657374"],
            salts: ["73616c74"],
            trusted_signature: ["typo"]
          )
        end
      end

      test "rejects empty signing config" do
        assert_raise ArgumentError,
                     ~r/at least one key\/salt pair or trusted signature is required/,
                     fn ->
                       @signature.normalize_config!(keys: [], salts: [])
                     end
      end

      test "supports trusted-only signing config" do
        assert %@signature{
                 mode: :enabled,
                 key_salt_pairs: [],
                 trusted_signatures: trusted_signatures
               } = @signature.normalize_config!(trusted_signatures: ["local-dev!"])

        assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
      end

      test "rejects mismatched key and salt counts" do
        assert_raise ArgumentError, ~r/keys and salts must have the same length/, fn ->
          @signature.normalize_config!(keys: ["74657374"], salts: [])
        end
      end

      test "rejects malformed hex key and salt values" do
        for config <- [
              [keys: ["not-hex"], salts: ["74657374"]],
              [keys: ["74657374"], salts: ["not-hex"]],
              [keys: [""], salts: ["74657374"]],
              [keys: ["74657374"], salts: [""]]
            ] do
          assert_raise ArgumentError,
                       ~r/keys and salts must be non-empty hex-encoded strings/,
                       fn ->
                         @signature.normalize_config!(config)
                       end
        end
      end

      test "rejects signature sizes outside 1..32" do
        for signature_size <- [0, 33] do
          assert_raise ArgumentError, ~r/signature_size must be an integer from 1 to 32/, fn ->
            @signature.normalize_config!(
              keys: ["74657374"],
              salts: ["73616c74"],
              signature_size: signature_size
            )
          end
        end

        assert_raise ArgumentError, ~r/invalid value for :signature_size option/, fn ->
          @signature.normalize_config!(
            keys: ["74657374"],
            salts: ["73616c74"],
            signature_size: "8"
          )
        end
      end

      test "rejects malformed trusted signatures" do
        for trusted_signatures <- ["local-dev", [""], [:not_binary]] do
          assert_raise ArgumentError,
                       ~r/trusted_signatures must be a list of non-empty strings/,
                       fn ->
                         @signature.normalize_config!(
                           keys: ["74657374"],
                           salts: ["73616c74"],
                           trusted_signatures: trusted_signatures
                         )
                       end
        end
      end
    end

    describe "verify/3" do
      test "accepts disabled-signing placeholders when signing is disabled" do
        config = @signature.disabled()

        assert :ok = @signature.verify("_", "/plain/images/cat.jpg", config)
        assert :ok = @signature.verify("unsafe", "/plain/images/cat.jpg", config)

        assert @signature.verify("signed-value", "/plain/images/cat.jpg", config) ==
                 {:error, {:unsupported_signature, "signed-value"}}
      end

      test "matches upstream full and truncated primitive HMAC vectors" do
        full =
          @signature.normalize_config!(
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          )

        truncated =
          @signature.normalize_config!(
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"],
            signature_size: 8
          )

        assert :ok = @signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", full)
        assert :ok = @signature.verify("dtLwhdnPPis", "asd", truncated)
        assert @signature.verify("dtLwhdnPPis", "asd", full) == {:error, :invalid_signature}
      end

      test "matches upstream key rotation vectors" do
        config =
          @signature.normalize_config!(
            keys: ["746573742d6b6579", "746573742d6b657932"],
            salts: ["746573742d73616c74", "746573742d73616c7432"]
          )

        assert :ok =
                 @signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", config)

        assert :ok =
                 @signature.verify("jbDffNPt1-XBgDccsaE-XJB9lx8JIJqdeYIZKgOqZpg", "asd", config)
      end

      test "accepts exact trusted signatures before Base64 decoding" do
        config = @signature.normalize_config!(trusted_signatures: ["truested", "local-dev!"])

        assert :ok = @signature.verify("truested", "asd", config)
        assert :ok = @signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config)

        assert @signature.verify("untrusted", "asd", config) ==
                 {:error, {:invalid_signature_encoding, "untrusted"}}

        assert @signature.verify(
                 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 "asd",
                 config
               ) ==
                 {:error, :invalid_signature}
      end

      test "matches upstream processing handler request fixture" do
        config =
          @signature.normalize_config!(
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          )

        signed_path = "/rs:fill:4:4/plain/local:///test1.png"

        assert :ok =
                 @signature.verify(
                   "My9d3xq_PYpVHsPrCyww0Kh1w5KZeZhIlWhsa4az1TI",
                   signed_path,
                   config
                 )

        assert @signature.verify("unsafe", signed_path, config) == {:error, :invalid_signature}
      end

      test "matches public docs signing vector" do
        config =
          @signature.normalize_config!(
            keys: ["736563726574"],
            salts: ["68656c6c6f"]
          )

        signed_path =
          "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png"

        assert :ok =
                 @signature.verify(
                   "oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8",
                   signed_path,
                   config
                 )
      end

      test "rejects malformed Base64 and wrong signatures" do
        config =
          @signature.normalize_config!(
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          )

        assert @signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config) ==
                 {:error, {:invalid_signature_encoding, "local-dev!"}}

        assert @signature.verify(
                 "dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY=",
                 "asd",
                 config
               ) ==
                 {:error,
                  {:invalid_signature_encoding, "dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY="}}

        assert @signature.verify(
                 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 "/w:300/plain/images/cat.jpg",
                 config
               ) == {:error, :invalid_signature}
      end

      test "rejects overlong encoded signatures before decoding" do
        config =
          @signature.normalize_config!(
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          )

        overlong_signature = String.duplicate("a", 1_000)
        overlong_padded_signature = overlong_signature <> "="

        assert @signature.verify(overlong_signature, "/w:300/plain/images/cat.jpg", config) ==
                 {:error, :invalid_signature}

        assert @signature.verify(
                 overlong_padded_signature,
                 "/w:300/plain/images/cat.jpg",
                 config
               ) ==
                 {:error, :invalid_signature}
      end
    end
  end
end
