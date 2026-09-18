defmodule ImagePipe.Native.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native.Config
  alias ImagePipe.Native.SourceEncryption

  @source_key :binary.copy(<<42>>, 32)
  @signing_key String.duplicate("a1", 32)

  defmodule CustomDetector do
  end

  test "detector configuration defaults to the bundled detector in graceful mode" do
    config = Config.validate!([])

    assert config[:detector] == :default
    assert config[:detector_required] == false
  end

  test "accepts a custom detector or explicitly disabled detection" do
    assert Config.validate!(detector: CustomDetector)[:detector] == CustomDetector
    assert Config.validate!(detector: nil)[:detector] == nil
    assert Config.validate!(detector_required: true)[:detector_required] == true
  end

  test "rejects malformed detector configuration" do
    assert_raise ArgumentError, fn -> Config.validate!(detector: {CustomDetector, []}) end
    assert_raise ArgumentError, fn -> Config.validate!(detector_required: :yes) end
  end

  test "resolves the output configuration supported by the native dialect" do
    config =
      Config.validate!(
        quality: 72,
        format_quality: %{jpeg: 68},
        autoquality_method: :ssimulacra2,
        autoquality_max_iterations: 4,
        jpeg_options: %ImagePipe.Plan.Output.JpegOptions{interlace: true}
      )

    assert config[:quality] == 72
    assert config[:format_quality] == %{webp: 79, avif: 63, jpeg_xl: 77, jpeg: 68}
    assert config[:autoquality_method] == :ssimulacra2
    assert config[:autoquality_max_iterations] == 4
    assert config[:jpeg_options].interlace == true
  end

  test "resolves native metadata, color-profile, and HDR host policy" do
    config =
      Config.validate!(
        strip_metadata: false,
        keep_copyright: false,
        strip_color_profile: false,
        preserve_hdr: true
      )

    assert config[:strip_metadata] == false
    assert config[:keep_copyright] == false
    assert config[:strip_color_profile] == false
    assert config[:preserve_hdr] == true
  end

  test "rejects neutral configuration whose native URL surface is not available" do
    assert_raise ArgumentError, fn -> Config.validate!(auto_rotate: false) end
    assert_raise ArgumentError, fn -> Config.validate!(smart_crop_face_detection: true) end
  end

  test "normalizes exact 32-byte source encryption keys into a redacted keyring" do
    config =
      Config.validate!(
        keys: [@signing_key],
        source_encryption_keys: [@source_key]
      )

    assert %SourceEncryption{} = config[:source_encryption]
    refute Keyword.has_key?(config, :source_encryption_keys)
    refute inspect(config) =~ @source_key
  end

  test "defaults source encryption to a disabled redacted keyring" do
    config = Config.validate!([])

    assert %SourceEncryption{} = keyring = config[:source_encryption]

    assert SourceEncryption.encrypt("images/cat.jpg", keyring) ==
             {:error, :source_encryption_disabled}
  end

  test "requires signing keys and independent encryption key material" do
    assert_raise ArgumentError, "source encryption requires signing keys", fn ->
      Config.validate!(source_encryption_keys: [@source_key])
    end

    shared_key = :binary.copy(<<7>>, 32)

    assert_raise ArgumentError, "signing and source encryption keys must be independent", fn ->
      Config.validate!(
        keys: [Base.encode16(shared_key)],
        source_encryption_keys: [shared_key]
      )
    end
  end

  test "rejects malformed secret configuration without including its value" do
    malformed_source_key = "private-source-encryption-key"

    source_error =
      assert_raise ArgumentError, fn ->
        Config.validate!(
          keys: [@signing_key],
          source_encryption_keys: [malformed_source_key]
        )
      end

    refute Exception.message(source_error) =~ malformed_source_key

    malformed_signing_key = "private-signing-secret"

    signing_error =
      assert_raise ArgumentError, fn ->
        Config.validate!(keys: [malformed_signing_key])
      end

    refute Exception.message(signing_error) =~ malformed_signing_key

    for malformed_keys <- [malformed_signing_key, %{secret: malformed_signing_key}] do
      container_error =
        assert_raise ArgumentError, fn ->
          Config.validate!(keys: malformed_keys)
        end

      refute Exception.message(container_error) =~ malformed_signing_key
    end
  end
end
