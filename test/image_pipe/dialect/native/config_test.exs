defmodule ImagePipe.Native.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native.Config

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
end
