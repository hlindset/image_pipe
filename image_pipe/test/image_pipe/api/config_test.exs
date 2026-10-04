defmodule ImagePipe.Plug.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plug.Config
  alias ImagePipe.Security.SourceEncryption
  alias ImagePipe.Test.DetectorFixtures.PartialDetector
  alias ImagePipe.Test.DetectorFixtures.UnavailableDetector

  @source_key String.duplicate("2a", 32)
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
  end

  test "detector_required needs a detector that can detect at least one class" do
    message =
      "invalid ImagePipe processing options: detector_required: " <>
        "the detector is not available in this build"

    for detector <- [nil, UnavailableDetector] do
      error =
        assert_raise ArgumentError, fn ->
          Config.validate!(detector: detector, detector_required: true)
        end

      assert error.message == message

      assert_raise ArgumentError, message, fn ->
        ImagePipe.config(detector: detector, detector_required: true)
      end
    end

    assert Config.validate!(detector: PartialDetector, detector_required: true)[
             :detector_required
           ]
  end

  test "rejects malformed detector configuration" do
    assert_raise ArgumentError, fn -> Config.validate!(detector: {CustomDetector, []}) end
    assert_raise ArgumentError, fn -> Config.validate!(detector_required: :yes) end
  end

  test "clock defaults to system seconds and accepts a zero-arity host function" do
    default_clock = Config.validate!([])[:clock]
    assert is_function(default_clock, 0)
    assert abs(default_clock.() - System.os_time(:second)) <= 1

    clock = fn -> 1_999_999_999 end
    assert Config.validate!(clock: clock)[:clock] == clock
  end

  test "clock rejects values that are not zero-arity functions" do
    assert_raise ArgumentError, fn -> Config.validate!(clock: :system) end
    assert_raise ArgumentError, fn -> Config.validate!(clock: fn value -> value end) end
  end

  test "resolves the output configuration supported by the API" do
    config =
      Config.validate!(
        quality: 72,
        format_quality: %{jpeg: 68},
        autoquality: true,
        autoquality_target: 82.5,
        jpeg_options: [interlace: true]
      )

    assert config[:quality] == 72
    assert config[:format_quality] == %{webp: 79, avif: 63, jpeg: 68}
    assert config[:autoquality] == true
    assert config[:autoquality_target] == 82.5
    assert config[:jpeg_options].interlace == true
  end

  test "resolves API metadata, color-profile, and HDR host policy" do
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

  test "applies runtime and output defaults" do
    config = Config.validate!([])

    assert config[:max_body_bytes] == 10_000_000
    assert config[:max_input_pixels] == 40_000_000
    assert config[:max_result_width] == 8_192
    assert config[:max_result_height] == 8_192
    assert config[:max_result_pixels] == 40_000_000
    assert config[:auto_avif] == true
    assert config[:auto_webp] == true
    assert config[:allow_debug_headers] == false
    assert config[:quality] == 80
    assert config[:preserve_hdr] == false
    assert config[:format_quality] == %{webp: 79, avif: 63}
    assert config[:autoquality] == false
    assert config[:autoquality_target] == 75
    assert config[:jpeg_options] == %JpegOptions{}
    assert config[:png_options] == %PngOptions{}
    assert config[:webp_options] == %WebpOptions{}
    assert config[:avif_options] == %AvifOptions{effort: 3, subsample_mode: :off}
    refute Keyword.has_key?(config, :format_order)
    refute Keyword.has_key?(config, :allow_origin)
  end

  test "delegates cache and source adapter validation" do
    assert_raise ArgumentError, fn -> Config.validate!(cache: :not_a_cache_config) end

    assert_raise ArgumentError, fn ->
      Config.validate!(
        sources: [
          path: [adapter: ImagePipe.SourceTest.CustomAdapter, match: :path, options: :not_options]
        ]
      )
    end
  end

  test "validates request and result safety limits" do
    config =
      Config.validate!(
        max_body_bytes: 123,
        max_input_pixels: 456,
        max_result_width: 78,
        max_result_height: 90,
        max_result_pixels: 1_234
      )

    assert config[:max_body_bytes] == 123
    assert config[:max_input_pixels] == 456
    assert config[:max_result_width] == 78
    assert config[:max_result_height] == 90
    assert config[:max_result_pixels] == 1_234

    for {key, value} <- [
          max_body_bytes: 0,
          max_input_pixels: 0,
          max_result_width: 0,
          max_result_height: -1,
          max_result_pixels: "40MP"
        ] do
      assert_raise ArgumentError, ~r/#{key}/, fn -> Config.validate!([{key, value}]) end
    end
  end

  test "validates automatic output format preferences and order" do
    config =
      Config.validate!(
        auto_avif: false,
        auto_webp: false,
        format_order: [:avif]
      )

    assert config[:auto_avif] == false
    assert config[:auto_webp] == false
    assert config[:format_order] == [:avif]

    for order <- [[:avif, :jpeg], [:avif, :avif], []] do
      assert_raise ArgumentError, ~r/format_order/, fn ->
        Config.validate!(format_order: order)
      end
    end
  end

  test "validates telemetry, CORS, debug-header, and storage-vary controls" do
    config =
      Config.validate!(
        telemetry_prefix: [:private, :image_pipe],
        allow_origin: "https://images.example",
        allow_debug_headers: true,
        storage_inputs: [{:header, "accept-language"}, {:cookie, "variant"}]
      )

    assert config[:telemetry_prefix] == [:private, :image_pipe]
    assert config[:allow_origin] == "https://images.example"
    assert config[:allow_debug_headers] == true

    assert config[:storage_inputs] == [
             {:header, "accept-language"},
             {:cookie, "variant"}
           ]

    for invalid <- [[], [:valid, "invalid"]] do
      assert_raise ArgumentError, ~r/telemetry_prefix/, fn ->
        Config.validate!(telemetry_prefix: invalid)
      end
    end

    for invalid <- ["", "*\r\nSet-Cookie: x=1"] do
      assert_raise ArgumentError, ~r/allow_origin/, fn ->
        Config.validate!(allow_origin: invalid)
      end
    end

    assert_raise ArgumentError, ~r/allow_debug_headers/, fn ->
      Config.validate!(allow_debug_headers: "yes")
    end

    assert_raise ArgumentError, ~r/storage_inputs/, fn ->
      Config.validate!(storage_inputs: [{:header, ""}])
    end
  end

  test "merges sparse output maps and builds encoder options from keyword lists" do
    config =
      Config.validate!(
        format_quality: %{webp: 50},
        jpeg_options: [interlace: true],
        avif_options: [subsample_mode: :on]
      )

    assert config[:format_quality] == %{webp: 50, avif: 63}
    assert config[:jpeg_options] == %JpegOptions{interlace: true}
    assert config[:avif_options] == %AvifOptions{subsample_mode: :on, effort: 3}
  end

  test "rejects invalid output ranges, formats, targets, and encoder settings" do
    invalid_configs = [
      [quality: 0],
      [quality: 101],
      [format_quality: %{wepb: 70}],
      [autoquality: :ssimulacra2],
      [autoquality_target: 0],
      [autoquality_target: 100.5],
      [autoquality_target: %{ssimulacra2: 75}],
      [jpeg_options: [quant_table: 9]],
      [png_options: [bitdepth: 3]],
      [webp_options: [preset: :bogus]],
      [webp_options: [effort: 7]],
      [jpeg_options: [interlace: "yes"]],
      [avif_options: [lossless: true]],
      [jpeg_options: %JpegOptions{interlace: true}]
    ]

    for invalid <- invalid_configs do
      assert_raise ArgumentError, fn -> Config.validate!(invalid) end
    end

    assert_raise ArgumentError, fn -> Config.validate!(format_quality: %{wepb: 70}) end
  end

  test "rejects retired host controls now owned by API request options" do
    assert_raise ArgumentError, fn -> Config.validate!(auto_rotate: false) end
    assert_raise ArgumentError, fn -> Config.validate!(smart_crop_face_detection: true) end
  end

  describe "watermarks" do
    @mounts [
      sources: [
        files: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: "/srv/images", root_id: "images"]
        ]
      ]
    ]

    test "normalizes named entries to plan sources with a base opacity" do
      config =
        Config.validate!(
          @mounts ++
            [
              watermarks: %{
                logo: [source: "brand/logo.png", opacity: 0.6],
                badge: [source: "b.png"]
              }
            ]
        )

      assert %{
               "logo" => %{
                 source: %ImagePipe.Plan.Source.Path{segments: ["brand", "logo.png"]},
                 opacity: 0.6
               },
               "badge" => %{opacity: 1.0}
             } = config[:watermarks]

      assert config[:request_watermarks] == false
      assert Config.validate!([])[:watermarks] == %{}
      assert Config.validate!(request_watermarks: true)[:request_watermarks] == true
    end

    test "rejects malformed entries" do
      for watermarks <- [
            %{"logo" => [source: "logo.png"]},
            %{Logo: [source: "logo.png"]},
            %{logo: []},
            %{logo: [source: "logo.png", opacity: 0]},
            %{logo: [source: "logo.png", opacity: 1.5]},
            %{logo: [source: "logo.png", extra: true]},
            %{logo: [source: "s3://bucket/logo.png"]},
            %{unset: [source: "logo.png"]}
          ] do
        assert_raise ArgumentError, fn ->
          Config.validate!(@mounts ++ [watermarks: watermarks])
        end
      end

      assert_raise ArgumentError, fn -> Config.validate!(request_watermarks: :yes) end
    end
  end

  test "rejects unknown mount options" do
    assert_raise ArgumentError, ~r/bogus/, fn -> Config.validate!(bogus: 1) end
  end

  test "lists the URL options among the valid ones for an unknown option" do
    error = assert_raise ArgumentError, fn -> ImagePipe.config(key: [@signing_key]) end
    assert error.message =~ "unknown options [:key]"
    assert error.message =~ ":keys"
    assert error.message =~ ":base_url"
  end

  test "normalizes hex-encoded 32-byte source encryption keys into a redacted keyring" do
    config =
      Config.validate!(
        keys: [@signing_key],
        source_encryption_keys: [@source_key]
      )

    assert %SourceEncryption{} = config[:source_encryption]
    refute Keyword.has_key?(config, :source_encryption_keys)
    refute inspect(config) =~ @source_key
    refute inspect(config) =~ @signing_key
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

    shared_key = String.duplicate("A7", 32)

    assert_raise ArgumentError, "signing and source encryption keys must be independent", fn ->
      Config.validate!(
        keys: [shared_key],
        source_encryption_keys: [String.downcase(shared_key)]
      )
    end
  end

  test "rejects a static wm-enc without source encryption keys" do
    for {options, owner} <- [
          {[presets: %{"wm" => "wm-enc=AQID"}], ~s(preset "wm")},
          {[request_defaults: "wm-enc=AQID"], "request_defaults"}
        ] do
      error = assert_raise ArgumentError, fn -> ImagePipe.config(options) end
      assert error.message =~ "#{owner} uses wm-enc, which needs source_encryption_keys"
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

  test "validates security option shapes without exposing secret values" do
    secret = "private-configuration-value"

    for invalid <- [
          [keys: [%{secret: secret}]],
          [source_encryption_keys: secret],
          [source_encryption_keys: [%{secret: secret}]],
          [iv_mode: secret],
          [encrypt_source: secret]
        ] do
      error = assert_raise ArgumentError, fn -> ImagePipe.config(invalid) end
      refute Exception.message(error) =~ secret
    end
  end

  test "security defaults and valid overrides preserve unrelated configuration" do
    defaults = Config.validate!([])
    assert defaults[:encrypt_source] == false
    assert defaults[:source_encryption].iv_mode == :deterministic

    config =
      Config.validate!(
        keys: [@signing_key],
        source_encryption_keys: [@source_key],
        iv_mode: :random,
        encrypt_source: true,
        base_url: "/images",
        quality: 72
      )

    assert config[:encrypt_source] == true
    assert config[:source_encryption].iv_mode == :random
    assert config[:quality] == 72
    assert config[:base_url] == "/images"

    assert_raise ArgumentError, fn ->
      ImagePipe.config(encrypt_source: true)
    end

    assert_raise ArgumentError, fn -> ImagePipe.config(encrypt_souce: true) end
  end

  property "quality overrides preserve unrelated API defaults" do
    check all quality <- integer(1..100) do
      config = Config.validate!(quality: quality)
      assert config[:quality] == quality
      assert config[:strip_metadata] == true
      assert config[:auto_webp] == true
    end
  end

  test "source configuration errors name the source and the problem" do
    file = [adapter: ImagePipe.Source.File, options: [root: "/srv/images", root_id: "media"]]

    cases = [
      {[photos: file],
       "invalid source :photos: required :match option not found, " <>
         "received options: [:adapter, :options]"},
      {[photos: [adapter: ImagePipe.Source.File, match: :path, options: [root: "/srv"]]],
       "invalid source :photos: required :root_id option not found, " <>
         "received options: [:root]"},
      {[photos: [match: :path] ++ file, archive: [match: :path] ++ file],
       "invalid source :archive: match :path is already used by source :photos"},
      {:photos, "invalid sources: expected a keyword list of named sources"}
    ]

    for {sources, message} <- cases do
      assert_raise ArgumentError, message, fn -> ImagePipe.config(sources: sources) end
    end
  end
end
