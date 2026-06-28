defmodule ImagePipe.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Config
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}

  describe "resolve!/2 layering" do
    test "applies neutral defaults when host and overlay are empty" do
      resolved = Config.resolve!([], [])
      assert resolved[:quality] == 80
      assert resolved[:auto_rotate] == true
      assert resolved[:preserve_hdr] == false
      assert resolved[:format_quality] == %{webp: 79, avif: 63, jpeg_xl: 77}
      assert resolved[:autoquality_method] == :none
      assert resolved[:autoquality_format_min_quality] == %{avif: 60, jpeg_xl: 45}
    end

    test "host overrides win over overlay which wins over defaults" do
      resolved = Config.resolve!([quality: 90], autoquality_method: :ssimulacra2, quality: 50)
      assert resolved[:quality] == 90
      assert resolved[:autoquality_method] == :ssimulacra2
    end

    test "a host-set boolean false survives (presence-based, not ||)" do
      resolved = Config.resolve!(strip_metadata: false, preserve_hdr: true)
      assert resolved[:strip_metadata] == false
      assert resolved[:preserve_hdr] == true
    end

    test "map keys merge across layers, keeping untouched formats" do
      resolved = Config.resolve!([format_quality: %{webp: 50}], format_quality: %{avif: 40})
      assert resolved[:format_quality] == %{webp: 50, avif: 40, jpeg_xl: 77}
    end

    test "defaults the five encoder-option keys to unset structs" do
      resolved = Config.resolve!([])
      assert Keyword.fetch!(resolved, :jpeg_options) == %JpegOptions{}
      assert Keyword.fetch!(resolved, :png_options) == %PngOptions{}
      assert Keyword.fetch!(resolved, :webp_options) == %WebpOptions{}
      assert Keyword.fetch!(resolved, :avif_options) == %AvifOptions{}
      assert Keyword.fetch!(resolved, :jxl_options) == %JxlOptions{}
    end

    test "merges a host-set encoder option over the unset default" do
      resolved = Config.resolve!(jpeg_options: %JpegOptions{interlace: true})
      assert Keyword.fetch!(resolved, :jpeg_options) == %JpegOptions{interlace: true}
    end

    test "the layer/2 rewrite still merges existing plain-map keys (format_quality)" do
      resolved = Config.resolve!(format_quality: %{webp: 70})
      fq = Keyword.fetch!(resolved, :format_quality)
      assert fq[:webp] == 70
      assert fq[:avif] == 63
    end

    test "resolve! is idempotent (same effective values; order is not significant)" do
      once =
        Config.resolve!(
          quality: 90,
          format_quality: %{webp: 50},
          jxl_options: %JxlOptions{effort: 4}
        )

      assert Map.new(Config.resolve!(once)) == Map.new(once)
    end
  end

  describe "resolve!/2 range checks" do
    test "rejects out-of-range quality" do
      assert_raise ArgumentError, fn -> Config.resolve!(quality: 0) end
      assert_raise ArgumentError, fn -> Config.resolve!(quality: 101) end
    end

    test "rejects inverted effective autoquality bracket" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_min_quality: 80, autoquality_max_quality: 70)
      end
    end

    test "rejects an out-of-band ssimulacra2 target via Metric range" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_target: %{ssimulacra2: 150})
      end
    end

    test "rejects negative allowed_error and unsupported metric" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_allowed_error: %{ssimulacra2: -1})
      end

      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_allowed_error: %{size: 1})
      end
    end

    test "rejects out-of-range jxl_options effort" do
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_options: %JxlOptions{effort: 0}) end
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_options: %JxlOptions{effort: 10}) end
    end

    test "rejects out-of-range / unknown encoder-option values (libvips ranges)" do
      assert_raise ArgumentError, ~r/quant_table/, fn ->
        Config.resolve!(jpeg_options: %JpegOptions{quant_table: 9})
      end

      assert_raise ArgumentError, ~r/bitdepth/, fn ->
        Config.resolve!(png_options: %PngOptions{bitdepth: 3})
      end

      assert_raise ArgumentError, ~r/preset/, fn ->
        Config.resolve!(webp_options: %WebpOptions{preset: :bogus})
      end

      assert_raise ArgumentError, ~r/effort/, fn ->
        Config.resolve!(webp_options: %WebpOptions{effort: 7})
      end

      assert_raise ArgumentError, ~r/interlace.*must be a boolean/, fn ->
        Config.resolve!(jpeg_options: %JpegOptions{interlace: "yes"})
      end
    end

    test "rejects unknown neutral keys" do
      assert_raise ArgumentError, fn -> Config.resolve!(bogus: 1) end
    end
  end

  describe "introspection" do
    test "keys/0 lists the neutral keys" do
      assert :quality in Config.keys()
      assert :jxl_options in Config.keys()
      assert :jpeg_options in Config.keys()
      refute :signature in Config.keys()
    end

    test "default/1 exposes neutral defaults including the unset encoder-option structs" do
      assert Config.default(:jxl_options) == %JxlOptions{}
      assert Config.default(:jpeg_options) == %JpegOptions{}
      assert Config.default(:quality) == 80
    end
  end

  describe "apply_to_output/2 encoder options" do
    test "stamps non-empty encoder_options onto Plan.Output" do
      resolved = Config.resolve!(webp_options: %WebpOptions{preset: :photo})

      {:ok, out} =
        Config.apply_to_output(%ImagePipe.Plan.Output{mode: :automatic}, resolved)

      assert out.encoder_options == %{webp: %WebpOptions{preset: :photo}}
    end

    test "leaves encoder_options empty when nothing is set" do
      {:ok, out} =
        Config.apply_to_output(%ImagePipe.Plan.Output{mode: :automatic}, Config.resolve!([]))

      assert out.encoder_options == %{}
    end
  end

  describe "autoquality fallback defaults" do
    test "resolve! seeds per-metric target and allowed_error defaults" do
      resolved = Config.resolve!([])
      assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 78, butteraugli: 1.0}

      assert Keyword.fetch!(resolved, :autoquality_allowed_error) == %{
               ssimulacra2: 1.0,
               butteraugli: 0.1
             }
    end

    test "a host override merges onto the seeded map, keeping the other metric" do
      resolved = Config.resolve!(autoquality_target: %{ssimulacra2: 90})
      assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 90, butteraugli: 1.0}
    end
  end

  describe "apply_to_output/2" do
    alias ImagePipe.Plan.Output
    alias ImagePipe.Plan.Output.QualitySearch.Ssimulacra2

    test "stamps the neutral fields, normalizing quality, without touching :quality" do
      resolved = Config.resolve!([])
      base = %Output{mode: {:explicit, :webp}}

      assert {:ok, out} = Config.apply_to_output(base, resolved)
      assert out.quality == :default
      assert out.default_quality == {:quality, 80}

      assert out.format_qualities == %{
               webp: {:quality, 79},
               avif: {:quality, 63},
               jpeg_xl: {:quality, 77}
             }

      assert out.color_profile == :strip
      assert out.hdr == :tone_map
      assert out.quality_search == :none
    end

    test "a URL quality on the base output is preserved" do
      resolved = Config.resolve!([])
      base = %Output{mode: {:explicit, :webp}, quality: {:quality, 55}}
      assert {:ok, out} = Config.apply_to_output(base, resolved)
      assert out.quality == {:quality, 55}
    end

    test "keep_copyright is forced false when metadata is not stripped" do
      resolved = Config.resolve!(strip_metadata: false, keep_copyright: true)
      assert {:ok, out} = Config.apply_to_output(%Output{mode: :automatic}, resolved)
      assert out.strip_metadata == false
      assert out.keep_copyright == false
    end

    test "builds the quality_search from a configured autoquality method" do
      resolved = Config.resolve!(autoquality_method: :ssimulacra2)

      assert {:ok, %Output{quality_search: %Ssimulacra2{target: 78}}} =
               Config.apply_to_output(%Output{mode: :automatic}, resolved)
    end

    test "propagates a from_config error (size method, no target)" do
      resolved = Config.resolve!(autoquality_method: :size)

      assert {:error, {:invalid_option, :autoquality, :missing_target}} =
               Config.apply_to_output(%Output{mode: :automatic}, resolved)
    end
  end

  describe "reject_unsupported!/3" do
    test ":all returns the input keyword verbatim (same keys and order)" do
      input = [quality: 80, strip_metadata: true]
      assert Config.reject_unsupported!(input, :all, "IIIF") == input
    end

    test "a declared subset returns input unchanged when all keys are inside it" do
      input = [quality: 80]
      assert Config.reject_unsupported!(input, [:quality, :strip_metadata], "X") == input
    end

    test "raises a dialect-named ArgumentError for an out-of-subset key" do
      assert_raise ArgumentError,
                   ~r/Demo parser does not support config.*autoquality_method/,
                   fn ->
                     Config.reject_unsupported!(
                       [autoquality_method: :ssimulacra2],
                       [:quality],
                       "Demo"
                     )
                   end
    end
  end

  property "scalar defaults survive when host omits them" do
    check all q <- integer(1..100) do
      resolved = Config.resolve!(quality: q)
      assert resolved[:quality] == q
      assert resolved[:auto_rotate] == true
    end
  end
end
