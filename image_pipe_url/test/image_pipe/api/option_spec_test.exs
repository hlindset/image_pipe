defmodule ImagePipe.API.OptionSpecTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}

  test "rejects unsupported filter, layout and scale values" do
    for value <- ["1001", String.duplicate("9", 400)] do
      assert OptionSpec.parse_blur(value) == {:error, :invalid_blur}
      assert OptionSpec.parse_progressive_blur(value) == {:error, :invalid_progressive_blur}
    end

    for value <- ["0.0000001", "10.1", String.duplicate("9", 400)] do
      assert OptionSpec.parse_sharpen(value) == {:error, :invalid_sharpen}
    end

    assert OptionSpec.parse_blur("1000") == {:ok, 1000.0}
    assert OptionSpec.parse_sharpen("0") == {:ok, 0.0}
    assert OptionSpec.parse_sharpen("0.000001") == {:ok, 0.000001}
    assert OptionSpec.parse_sharpen("10") == {:ok, 10.0}

    assert OptionSpec.parse_dpr("2147483648") == {:error, :invalid_dpr}
    assert OptionSpec.parse_zoom("2147483648") == {:error, :invalid_zoom}

    assert OptionSpec.parse_crop("#{String.duplicate("9", 400)}pct,10") ==
             {:error, :invalid_element}
  end

  @api_keys ~w(rotate flip gray bitonal dpr w h min-w min-h fit enlarge zoom extend extend-ratio extend-at extend-offset crop crop-ratio crop-ratio-enlarge region anchor anchor-offset focus detect blur progressive-blur sharpen pixelate monochrome duotone brightness contrast saturation colorize gradient trim trim-symmetry pad bg wm wm-src64 wm-enc wm-opacity wm-scale wm-at wm-offset wm-tile wm-gap orient page output format q format-q meta dpi profile hdr autoquality max-bytes jpeg-options png-options webp-options avif-options filename attachment cb debug expires preset)

  describe "all/0" do
    test "declares API options, one entry per key" do
      keys = Enum.map(OptionSpec.all(), & &1.key)

      assert Enum.sort(keys) == Enum.sort(@api_keys)
      assert Enum.uniq(keys) == keys
    end

    test "every option declares all fields plus at least one example" do
      for %OptionSpec{} = spec <- OptionSpec.all() do
        assert is_binary(spec.key) and spec.key != ""
        assert spec.scope in [:group, :request]

        assert spec.value == :flag or is_function(spec.value, 1) or
                 match?({:flag, fun} when is_function(fun, 1), spec.value)

        assert is_binary(spec.summary) and spec.summary != ""

        assert is_list(spec.examples) and spec.examples != [],
               "#{spec.key} must declare at least one example"

        for example <- spec.examples do
          assert is_binary(example) and example != ""
        end
      end
    end
  end

  describe "value parsers — happy paths" do
    test "parse_dpr accepts positive finite decimals and normalizes to float" do
      assert OptionSpec.parse_dpr("2") == {:ok, 2.0}
      assert OptionSpec.parse_dpr("1.5") == {:ok, 1.5}
      assert OptionSpec.parse_dpr("0") == {:error, :invalid_dpr}
      assert OptionSpec.parse_dpr("-1") == {:error, :invalid_dpr}
      assert OptionSpec.parse_dpr("1e2") == {:error, :invalid_dpr}
    end

    test "parse_dimension unwraps px to a plain integer, keeps auto" do
      assert OptionSpec.parse_dimension("800") == {:ok, 800}
      assert OptionSpec.parse_dimension("auto") == {:ok, :auto}
    end

    test "parse_min_dimension accepts positive integers but not auto" do
      assert OptionSpec.parse_min_dimension("320") == {:ok, 320}
      assert OptionSpec.parse_min_dimension("0") == {:error, :invalid_min_dimension}
      assert OptionSpec.parse_min_dimension("auto") == {:error, :invalid_min_dimension}
      assert OptionSpec.parse_min_dimension("2.5") == {:error, :invalid_min_dimension}
    end

    test "parse_zoom accepts a positive scalar or x,y pair" do
      assert OptionSpec.parse_zoom("2") == {:ok, {2.0, 2.0}}
      assert OptionSpec.parse_zoom("1.25,0.75") == {:ok, {1.25, 0.75}}
      assert OptionSpec.parse_zoom("0") == {:error, :invalid_zoom}
      assert OptionSpec.parse_zoom("1,-1") == {:error, :invalid_zoom}
      assert OptionSpec.parse_zoom("1,2,3") == {:error, :invalid_zoom}
      assert OptionSpec.parse_zoom("1e2") == {:error, :invalid_zoom}
    end

    test "DPR and zoom reject decimals outside the floating-point range" do
      for value <- [String.duplicate("9", 1_000), String.duplicate("9", 1_000) <> ".5"] do
        assert OptionSpec.parse_dpr(value) == {:error, :invalid_dpr}
        assert OptionSpec.parse_zoom(value) == {:error, :invalid_zoom}
        assert OptionSpec.parse_zoom(value <> ",1") == {:error, :invalid_zoom}
        assert OptionSpec.parse_zoom("1," <> value) == {:error, :invalid_zoom}
      end
    end

    test "parse_fit translates hyphenated URL spellings to atoms" do
      assert OptionSpec.parse_fit("contain") == {:ok, :contain}
      assert OptionSpec.parse_fit("cover") == {:ok, :cover}
      assert OptionSpec.parse_fit("stretch") == {:ok, :stretch}
      assert OptionSpec.parse_fit("auto") == {:ok, :auto}
      assert OptionSpec.parse_fit("bogus") == {:error, :invalid_fit}
    end

    test "parse_crop parses a w,h length pair" do
      assert OptionSpec.parse_crop("600,400") == {:ok, {{:px, 600}, {:px, 400}}}
      assert OptionSpec.parse_crop("80pct,60pct") == {:ok, {{:pct, 80}, {:pct, 60}}}
    end

    test "parse_crop_ratio reduces ratio and decimal spellings to tagged integers" do
      assert OptionSpec.parse_crop_ratio("3:2") == {:ok, {:ratio, 3, 2}}
      assert OptionSpec.parse_crop_ratio("6:4") == {:ok, {:ratio, 3, 2}}
      assert OptionSpec.parse_crop_ratio("1.5") == {:ok, {:ratio, 3, 2}}
      assert OptionSpec.parse_crop_ratio("1.500") == {:ok, {:ratio, 3, 2}}
      assert OptionSpec.parse_crop_ratio("2") == {:ok, {:ratio, 2, 1}}
    end

    test "parse_crop_ratio rejects zero, signs, malformed ratios, and exponent notation" do
      for value <- [
            "0",
            "0.0",
            "0:1",
            "1:0",
            "-1",
            "+1:2",
            "1:-2",
            "1.5:2",
            "1:2:3",
            "1e2"
          ] do
        assert OptionSpec.parse_crop_ratio(value) == {:error, :invalid_crop_ratio}
      end
    end

    test "parse_crop_ratio bounds reduced components to the native axis range" do
      safe = "2147483647"
      overflow = "2147483648"
      huge = String.duplicate("9", 400)

      assert {:ok, {:ratio, _numerator, 1}} = OptionSpec.parse_crop_ratio("#{safe}:1")
      assert {:ok, {:ratio, 1, _denominator}} = OptionSpec.parse_crop_ratio("1:#{safe}")
      assert OptionSpec.parse_crop_ratio("#{overflow}:1") == {:error, :invalid_crop_ratio}
      assert OptionSpec.parse_crop_ratio("1:#{overflow}") == {:error, :invalid_crop_ratio}
      assert OptionSpec.parse_crop_ratio("#{huge}:1") == {:error, :invalid_crop_ratio}
      assert OptionSpec.parse_crop_ratio("1:#{huge}") == {:error, :invalid_crop_ratio}
      assert OptionSpec.parse_crop_ratio("#{huge}:#{huge}") == {:ok, {:ratio, 1, 1}}
    end

    test "parse_region parses an x,y,w,h length quad" do
      assert OptionSpec.parse_region("0,0,600,400") ==
               {:ok, {{:px, 0}, {:px, 0}, {:px, 600}, {:px, 400}}}
    end

    test "parse_region rejects a negative origin" do
      for region <- ["-1,0,600,400", "0,-1,600,400", "-10pct,0,600,400", "0,-0.5,600,400"] do
        assert OptionSpec.parse_region(region) == {:error, :invalid_element}, region
      end
    end

    test "parse_anchor translates named positions and smart modes" do
      assert OptionSpec.parse_anchor("center") == {:ok, :center}
      assert OptionSpec.parse_anchor("top-left") == {:ok, :top_left}
      assert OptionSpec.parse_anchor("bottom-right") == {:ok, :bottom_right}
      assert OptionSpec.parse_anchor("smart") == {:ok, :smart}
      assert OptionSpec.parse_anchor("smart-face") == {:ok, :smart_face}
      assert OptionSpec.parse_anchor("bogus") == {:error, :invalid_anchor}
    end

    test "parse_named_anchor excludes smart" do
      assert OptionSpec.parse_named_anchor("center") == {:ok, :center}
      assert OptionSpec.parse_named_anchor("bottom-right") == {:ok, :bottom_right}
      assert OptionSpec.parse_named_anchor("smart") == {:error, :invalid_anchor}
      assert OptionSpec.parse_named_anchor("smart-face") == {:error, :invalid_anchor}
    end

    test "parse_detect produces typed classes and explicit weights" do
      assert OptionSpec.parse_detect("all") == {:ok, [{:all, 1.0}]}

      assert OptionSpec.parse_detect("face,car") ==
               {:ok, [{"face", 1.0}, {"car", 1.0}]}

      assert OptionSpec.parse_detect("all:1,face:3") ==
               {:ok, [{:all, 1.0}, {"face", 3.0}]}

      assert OptionSpec.parse_detect("all:3,face:3,car") ==
               {:ok, [{:all, 3.0}, {"face", 3.0}, {"car", 1.0}]}

      assert OptionSpec.parse_detect("car:1.0") == {:ok, [{"car", 1.0}]}
    end

    test "parse_detect accepts custom class tokens and rejects invalid or duplicate items" do
      assert OptionSpec.parse_detect("license_plate,dog-v2") ==
               {:ok, [{"license_plate", 1.0}, {"dog-v2", 1.0}]}

      for value <- [
            "",
            "Car",
            "traffic light",
            "_face",
            "face/eye",
            "face=eye",
            "face:",
            "face:0",
            "face:-1",
            "face:1e2",
            "face:1000000.1",
            "face:1:2",
            "face,face:2",
            "all:1,all:2"
          ] do
        assert OptionSpec.parse_detect(value) == {:error, :invalid_detect}
      end

      assert OptionSpec.parse_detect("face:1000000") ==
               {:ok, [{"face", 1_000_000.0}]}
    end

    test "parse_offset accepts signed px/pct pairs within pixel arithmetic range" do
      assert OptionSpec.parse_offset("10,-20pct") ==
               {:ok, {{:px, 10}, {:pct, -20}}}

      assert OptionSpec.parse_offset("0.5,-0.25pct") ==
               {:ok, {{:px, 0.5}, {:pct, -0.25}}}

      assert OptionSpec.parse_offset("1") == {:error, :invalid_offset}
      assert OptionSpec.parse_offset("1,2,3") == {:error, :invalid_offset}
      assert OptionSpec.parse_offset("1em,2") == {:error, :invalid_offset}

      safe_with_axis_headroom = "2147483647"
      unsafe_with_axis_headroom = "2147483648"

      assert {:ok, {{:px, _safe}, {:px, 0}}} =
               OptionSpec.parse_offset("#{safe_with_axis_headroom},0")

      assert OptionSpec.parse_offset("#{unsafe_with_axis_headroom},0") ==
               {:error, :invalid_offset}

      huge = String.duplicate("9", 400)
      assert OptionSpec.parse_offset("#{huge},0") == {:error, :invalid_offset}
      assert OptionSpec.parse_offset("0,-#{huge}pct") == {:error, :invalid_offset}
    end

    test "parse_focus parses an x,y fraction pair" do
      assert OptionSpec.parse_focus("0.25,0.75") == {:ok, {0.25, 0.75}}
    end

    test "parse_blur coerces an integer sigma to a float" do
      assert OptionSpec.parse_blur("2") == {:ok, 2.0}
      assert OptionSpec.parse_blur("2.5") == {:ok, 2.5}
      assert OptionSpec.parse_blur("0") == {:ok, 0.0}
      assert OptionSpec.parse_blur("-1") == {:error, :invalid_blur}
    end

    test "scalar effect parsers preserve implemented ranges" do
      assert OptionSpec.parse_sharpen("0") == {:ok, 0.0}
      assert OptionSpec.parse_sharpen("1.5") == {:ok, 1.5}
      assert OptionSpec.parse_sharpen("-1") == {:error, :invalid_sharpen}

      assert OptionSpec.parse_pixelate("1") == {:ok, 1}
      assert OptionSpec.parse_pixelate("8") == {:ok, 8}
      assert OptionSpec.parse_pixelate("0") == {:error, :invalid_pixelate}
      assert OptionSpec.parse_pixelate("1.5") == {:error, :invalid_pixelate}

      assert OptionSpec.parse_brightness("-255") == {:ok, -255}
      assert OptionSpec.parse_brightness("255") == {:ok, 255}
      assert OptionSpec.parse_brightness("256") == {:error, :invalid_brightness}
      assert OptionSpec.parse_brightness("1.5") == {:error, :invalid_brightness}

      assert OptionSpec.parse_contrast("1") == {:ok, 1.0}
      assert OptionSpec.parse_saturation("0.25") == {:ok, 0.25}
      assert OptionSpec.parse_contrast("0") == {:error, :invalid_contrast}
      assert OptionSpec.parse_saturation("-1") == {:error, :invalid_saturation}
    end

    test "monochrome and duotone use strict API positional arities" do
      assert OptionSpec.parse_monochrome("0.5") ==
               {:ok, %{intensity: 0.5, color: {179, 179, 179}}}

      assert OptionSpec.parse_monochrome("1,red") ==
               {:ok, %{intensity: 1.0, color: {255, 0, 0}}}

      assert OptionSpec.parse_duotone("0.25") ==
               {:ok, %{intensity: 0.25, shadow: {0, 0, 0}, highlight: {255, 255, 255}}}

      assert OptionSpec.parse_duotone("1,112233,ffeecc") ==
               {:ok, %{intensity: 1.0, shadow: {17, 34, 51}, highlight: {255, 238, 204}}}

      for value <- ["0.5,", "0.5,red,blue", "0.5,,white"] do
        assert OptionSpec.parse_monochrome(value) == {:error, :invalid_monochrome}
      end

      assert OptionSpec.parse_duotone("0.5,112233") ==
               {:ok, %{intensity: 0.5, shadow: {17, 34, 51}, highlight: {255, 255, 255}}}

      for value <- ["0.5,", "0.5,,white", "0.5,black,", "0.5,black,white,red"] do
        assert OptionSpec.parse_duotone(value) == {:error, :invalid_duotone}
      end
    end

    test "colorize requires color and accepts only the keep-alpha literal" do
      assert OptionSpec.parse_colorize("0.5,red") ==
               {:ok, %{opacity: 0.5, color: {255, 0, 0}, keep_alpha: false}}

      assert OptionSpec.parse_colorize("1,ff0000,keep-alpha") ==
               {:ok, %{opacity: 1.0, color: {255, 0, 0}, keep_alpha: true}}

      for value <- ["0.5", "0.5,", "0.5,red,true", "0.5,red,false", "0.5,red,"] do
        assert OptionSpec.parse_colorize(value) == {:error, :invalid_colorize}
      end
    end

    test "gradient fills trailing defaults and maps named directions" do
      assert OptionSpec.parse_gradient("0.5,black") ==
               {:ok, %{opacity: 0.5, color: {0, 0, 0}, angle: 0.0, start: 0.0, stop: 1.0}}

      assert OptionSpec.parse_gradient("1,red,left,0.25,0.75") ==
               {:ok, %{opacity: 1.0, color: {255, 0, 0}, angle: 90.0, start: 0.25, stop: 0.75}}

      for value <- [
            "1",
            "1,red,",
            "1,red,down,",
            "1,red,down,0,",
            "1,red,sideways",
            "1,red,down,-0.1",
            "1,red,down,0,1.1"
          ] do
        assert OptionSpec.parse_gradient(value) == {:error, :invalid_gradient}
      end
    end

    test "composite effects validate colors even at zero intensity or opacity" do
      assert OptionSpec.parse_monochrome("0,not-a-color") == {:error, :invalid_monochrome}
      assert OptionSpec.parse_duotone("0,black,not-a-color") == {:error, :invalid_duotone}
      assert OptionSpec.parse_colorize("0,not-a-color") == {:error, :invalid_colorize}
      assert OptionSpec.parse_gradient("0,not-a-color") == {:error, :invalid_gradient}
    end

    test "effect numeric overflow is rejected instead of raising" do
      huge = String.duplicate("9", 400)

      assert OptionSpec.parse_sharpen(huge) == {:error, :invalid_sharpen}
      assert OptionSpec.parse_contrast(huge) == {:error, :invalid_contrast}
      assert OptionSpec.parse_monochrome("#{huge}.0") == {:error, :invalid_monochrome}
      assert OptionSpec.parse_gradient("1,red,#{huge}") == {:error, :invalid_gradient}
    end

    test "parse_trim accepts auto, color-only, and color+tolerance" do
      assert OptionSpec.parse_trim("auto") == {:ok, :auto}
      assert OptionSpec.parse_trim("fff") == {:ok, {{255, 255, 255}, nil}}
      assert OptionSpec.parse_trim("fff,10") == {:ok, {{255, 255, 255}, 10}}
    end

    test "parse_trim_symmetry accepts horizontal, vertical, or both axes" do
      assert OptionSpec.parse_trim_symmetry("h") == {:ok, :horizontal}
      assert OptionSpec.parse_trim_symmetry("v") == {:ok, :vertical}
      assert OptionSpec.parse_trim_symmetry("hv") == {:ok, :both}
      assert OptionSpec.parse_trim_symmetry("vh") == {:error, :invalid_trim_symmetry}
    end

    test "parse_bg accepts color-only and color+alpha" do
      assert OptionSpec.parse_bg("f4f4f4") == {:ok, {{244, 244, 244}, nil}}
      assert OptionSpec.parse_bg("fff,0.5") == {:ok, {{255, 255, 255}, 0.5}}
    end

    test "parse_output accepts the outputs and info's placeholder flags" do
      assert OptionSpec.parse_output("image") == {:ok, :image}
      assert OptionSpec.parse_output("blurhash") == {:ok, :blurhash}
      assert OptionSpec.parse_output("info") == {:ok, :info}
      assert OptionSpec.parse_output("info,lqip-css") == {:ok, {:info, [:lqip_css]}}

      assert OptionSpec.parse_output("info,lqip-css,blurhash") ==
               {:ok, {:info, [:blurhash, :lqip_css]}}

      for value <- [
            "lqip",
            "info,",
            "info,info",
            "info,image",
            "info,blurhash,blurhash",
            "blurhash,lqip-css",
            "image,blurhash"
          ] do
        assert OptionSpec.parse_output(value) == {:error, :invalid_output}, value
      end
    end

    test "filename and cachebuster use the nonempty ASCII path-token grammar" do
      for value <- ["cat", "cat.jpg", "Card_v2.small-1"] do
        assert OptionSpec.parse_filename(value) == {:ok, value}
        assert OptionSpec.parse_cachebuster(value) == {:ok, value}
      end

      for value <- ["", "cat photo", "cat/photo", "cat%20photo", "café", "*"] do
        assert OptionSpec.parse_filename(value) == {:error, :invalid_filename}
        assert OptionSpec.parse_cachebuster(value) == {:error, :invalid_cachebuster}
      end
    end

    test "parse_orientation accepts auto and none only" do
      assert OptionSpec.parse_orientation("auto") == {:ok, :auto}
      assert OptionSpec.parse_orientation("none") == {:ok, :none}
      assert OptionSpec.parse_orientation("sideways") == {:error, :invalid_orientation}
    end

    test "parse_page accepts non-negative integers only" do
      assert OptionSpec.parse_page("0") == {:ok, 0}
      assert OptionSpec.parse_page("12") == {:ok, 12}

      for value <- ["-1", "1.5", "", "two", "1e2"] do
        assert OptionSpec.parse_page(value) == {:error, :invalid_page}
      end
    end

    test "parse_format accepts supported output formats" do
      assert OptionSpec.parse_format("avif") == {:ok, :avif}
      assert OptionSpec.parse_format("webp") == {:ok, :webp}
      assert OptionSpec.parse_format("jpeg") == {:ok, :jpeg}
      assert OptionSpec.parse_format("png") == {:ok, :png}
    end

    test "parse_quality accepts 1..100 integers only" do
      assert OptionSpec.parse_quality("80") == {:ok, 80}
      assert OptionSpec.parse_quality("0") == {:error, :invalid_quality}
      assert OptionSpec.parse_quality("101") == {:error, :invalid_quality}
      assert OptionSpec.parse_quality("50.5") == {:error, :invalid_quality}
    end

    test "metadata policy uses the exact API vocabulary" do
      assert OptionSpec.parse_metadata("strip") == {:ok, :strip}
      assert OptionSpec.parse_metadata("copyright") == {:ok, :copyright}
      assert OptionSpec.parse_metadata("keep") == {:ok, :keep}

      for value <- ["", "all", "true", "Copyright"] do
        assert OptionSpec.parse_metadata(value) == {:error, :invalid_metadata}
      end
    end

    test "color profile policy canonicalizes named profiles" do
      assert OptionSpec.parse_color_profile("strip") == {:ok, :strip}
      assert OptionSpec.parse_color_profile("preserve") == {:ok, :preserve_source}
      assert OptionSpec.parse_color_profile("srgb") == {:ok, {:convert, :srgb}}
      assert OptionSpec.parse_color_profile("display-p3") == {:ok, {:convert, :display_p3}}
      assert OptionSpec.parse_color_profile("adobe-rgb") == {:ok, {:convert, :adobe_rgb}}

      for value <- ["", "keep", "p3", "display_p3", "adobergb", "sRGB"] do
        assert OptionSpec.parse_color_profile(value) == {:error, :invalid_color_profile}
      end
    end

    test "HDR policy uses tonemap and preserve only" do
      assert OptionSpec.parse_hdr("tonemap") == {:ok, :tone_map}
      assert OptionSpec.parse_hdr("preserve") == {:ok, :preserve}

      for value <- ["", "tone-map", "keep", "Tonemap"] do
        assert OptionSpec.parse_hdr(value) == {:error, :invalid_hdr}
      end
    end

    test "format qualities use canonical formats and reject duplicates" do
      assert OptionSpec.parse_format_qualities("avif:60,webp:70") ==
               {:ok, %{avif: {:quality, 60}, webp: {:quality, 70}}}

      for value <- ["", "avif", "gif:60", "avif:0", "avif:101", "avif:60,avif:70"] do
        assert OptionSpec.parse_format_qualities(value) == {:error, :invalid_format_qualities}
      end
    end

    test "autoquality parses a target as a float" do
      assert OptionSpec.parse_autoquality("75") == {:ok, 75.0}
      assert OptionSpec.parse_autoquality("82.5") == {:ok, 82.5}
      assert OptionSpec.parse_autoquality("100") == {:ok, 100.0}
    end

    test "autoquality rejects targets outside above 0 and up to 100" do
      for value <- ["", "0", "-1", "100.1", "none", "ssimulacra2", "target:75"] do
        assert OptionSpec.parse_autoquality(value) == {:error, :invalid_autoquality}
      end
    end

    test "max bytes is a positive integer" do
      assert OptionSpec.parse_max_bytes("12000") == {:ok, 12_000}

      for value <- ["0", "-1", "1.5", ""] do
        assert OptionSpec.parse_max_bytes(value) == {:error, :invalid_max_bytes}
      end
    end

    test "dpi is an integer from 1 to 65535" do
      assert OptionSpec.parse_dpi("1") == {:ok, 1}
      assert OptionSpec.parse_dpi("300") == {:ok, 300}
      assert OptionSpec.parse_dpi("65535") == {:ok, 65_535}

      for value <- ["0", "-1", "65536", "72.5", ""] do
        assert OptionSpec.parse_dpi(value) == {:error, :invalid_dpi}
      end
    end

    test "codec option parsers produce typed sparse structs" do
      assert OptionSpec.parse_jpeg_options(
               "progressive,subsample:on,trellis-quant,overshoot-deringing:false,optimize-scans,quant-table:8"
             ) ==
               {:ok,
                %JpegOptions{
                  interlace: true,
                  subsample_mode: :on,
                  trellis_quant: true,
                  overshoot_deringing: false,
                  optimize_scans: true,
                  quant_table: 8
                }}

      assert OptionSpec.parse_png_options("interlace:false,palette,bitdepth:4,filter:paeth") ==
               {:ok, %PngOptions{interlace: false, palette: true, bitdepth: 4, filter: :paeth}}

      assert OptionSpec.parse_webp_options(
               "lossless,near-lossless:false,smart-subsample,preset:photo,effort:6"
             ) ==
               {:ok,
                %WebpOptions{
                  lossless: true,
                  near_lossless: false,
                  smart_subsample: true,
                  preset: :photo,
                  effort: 6
                }}

      assert OptionSpec.parse_avif_options("subsample:auto,effort:9") ==
               {:ok, %AvifOptions{subsample_mode: :auto, effort: 9}}
    end

    test "codec option parsers reject aliases, duplicates, unknowns, empty fields, and ranges" do
      invalid = [
        {&OptionSpec.parse_jpeg_options/1, "progressive:true"},
        {&OptionSpec.parse_jpeg_options/1, "progressive,progressive:false"},
        {&OptionSpec.parse_jpeg_options/1, "subsample:bad"},
        {&OptionSpec.parse_jpeg_options/1, "quant-table:9"},
        {&OptionSpec.parse_png_options/1, "interlace:true"},
        {&OptionSpec.parse_png_options/1, "bitdepth:3"},
        {&OptionSpec.parse_png_options/1, "filter:average"},
        {&OptionSpec.parse_webp_options/1, "preset:portrait"},
        {&OptionSpec.parse_webp_options/1, "effort:7"},
        {&OptionSpec.parse_avif_options/1, "effort:10"},
        {&OptionSpec.parse_png_options/1, "palette,"},
        {&OptionSpec.parse_webp_options/1, ""}
      ]

      for {parser, value} <- invalid do
        assert parser.(value) == {:error, :invalid_encoder_options}
      end
    end

    test "parse_expires accepts positive integers only" do
      assert OptionSpec.parse_expires("1999999999") == {:ok, 1_999_999_999}
      assert OptionSpec.parse_expires("0") == {:error, :invalid_expires}
      assert OptionSpec.parse_expires("-1") == {:error, :invalid_expires}
    end

    test "parse_preset_names splits a comma list and validates grammar" do
      assert OptionSpec.parse_preset_names("card") == {:ok, ["card"]}
      assert OptionSpec.parse_preset_names("card,mobile") == {:ok, ["card", "mobile"]}
      assert OptionSpec.parse_preset_names("card!") == {:error, :invalid_preset_name}
    end
  end
end
