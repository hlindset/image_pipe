defmodule ImagePipe.Native.OptionSpecTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native.OptionSpec

  @native_keys ~w(rotate flip gray bitonal dpr w h min-w min-h fit enlarge zoom crop crop-ratio crop-ratio-enlarge region anchor focus blur trim trim-symmetry pad bg orient output format q debug expires preset)

  describe "all/0" do
    test "declares native options, one entry per key" do
      keys = Enum.map(OptionSpec.all(), & &1.key)

      assert Enum.sort(keys) == Enum.sort(@native_keys)
      assert Enum.uniq(keys) == keys
    end

    test "every option declares all fields plus at least one example" do
      for %OptionSpec{} = spec <- OptionSpec.all() do
        assert is_binary(spec.key) and spec.key != ""
        assert spec.scope in [:group, :request]
        assert spec.value == :flag or is_function(spec.value, 1)
        assert is_nil(spec.stage) or (is_integer(spec.stage) and spec.stage > 0)
        assert is_list(spec.prerequisites)
        assert is_list(spec.conflicts)
        assert spec.identity in [:representation, :gate, :presentation]
        assert spec.terminal_applicability in [:both, :image]
        assert is_binary(spec.summary) and spec.summary != ""

        assert is_list(spec.examples) and spec.examples != [],
               "#{spec.key} must declare at least one example"

        for example <- spec.examples do
          assert is_binary(example) and example != ""
        end
      end
    end

    test "group-scoped options declare a pipeline stage; request-scoped options do not" do
      for %OptionSpec{} = spec <- OptionSpec.all() do
        case spec.scope do
          :group -> assert is_integer(spec.stage)
          :request -> assert is_nil(spec.stage)
        end
      end
    end

    test "conflicts reference other declared keys, never the option's own key" do
      known_keys = MapSet.new(OptionSpec.all(), & &1.key)

      for %OptionSpec{} = spec <- OptionSpec.all(), conflict <- spec.conflicts do
        assert conflict != spec.key
        assert MapSet.member?(known_keys, conflict)
      end
    end

    test "conflicts are symmetric" do
      by_key = Map.new(OptionSpec.all(), &{&1.key, &1})

      for %OptionSpec{} = spec <- OptionSpec.all(), conflict <- spec.conflicts do
        assert spec.key in by_key[conflict].conflicts
      end
    end
  end

  describe "fetch/1" do
    test "finds a declared option by key" do
      assert %OptionSpec{key: "w"} = OptionSpec.fetch("w")
    end

    test "returns nil for an unknown key" do
      assert OptionSpec.fetch("bogus") == nil
    end
  end

  describe "value parsers — happy paths" do
    test "parse_dpr accepts positive finite decimals and normalizes to float" do
      assert OptionSpec.parse_dpr("2") == {:ok, 2.0}
      assert OptionSpec.parse_dpr("1.5") == {:ok, 1.5}
      assert OptionSpec.parse_dpr("0") == {:error, :invalid_dpr}
      assert OptionSpec.parse_dpr("-1") == {:error, :invalid_dpr}
      assert OptionSpec.parse_dpr("1e2") == {:error, :invalid_dpr}
      assert OptionSpec.parse_dpr(String.duplicate("9", 1_000)) == {:error, :invalid_dpr}
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

    test "parse_fit translates hyphenated URL spellings to atoms" do
      assert OptionSpec.parse_fit("contain") == {:ok, :contain}
      assert OptionSpec.parse_fit("cover") == {:ok, :cover}
      assert OptionSpec.parse_fit("cover-down") == {:ok, :cover_down}
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

    test "parse_crop_ratio reserves float headroom for a signed-32-bit pixel axis" do
      safe = String.duplicate("9", 298)
      overflow = String.duplicate("9", 300)
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

    test "parse_anchor translates hyphenated positions and smart" do
      assert OptionSpec.parse_anchor("center") == {:ok, :center}
      assert OptionSpec.parse_anchor("top-left") == {:ok, :top_left}
      assert OptionSpec.parse_anchor("bottom-right") == {:ok, :bottom_right}
      assert OptionSpec.parse_anchor("smart") == {:ok, :smart}
      assert OptionSpec.parse_anchor("bogus") == {:error, :invalid_anchor}
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

    test "parse_output accepts image and blurhash only" do
      assert OptionSpec.parse_output("image") == {:ok, :image}
      assert OptionSpec.parse_output("blurhash") == {:ok, :blurhash}
      assert OptionSpec.parse_output("lqip") == {:error, :invalid_output}
    end

    test "parse_orientation accepts auto and none only" do
      assert OptionSpec.parse_orientation("auto") == {:ok, :auto}
      assert OptionSpec.parse_orientation("none") == {:ok, :none}
      assert OptionSpec.parse_orientation("sideways") == {:error, :invalid_orientation}
    end

    test "parse_format translates jxl to :jpeg_xl" do
      assert OptionSpec.parse_format("avif") == {:ok, :avif}
      assert OptionSpec.parse_format("webp") == {:ok, :webp}
      assert OptionSpec.parse_format("jpeg") == {:ok, :jpeg}
      assert OptionSpec.parse_format("png") == {:ok, :png}
      assert OptionSpec.parse_format("jxl") == {:ok, :jpeg_xl}
    end

    test "parse_quality accepts 1..100 integers only" do
      assert OptionSpec.parse_quality("80") == {:ok, 80}
      assert OptionSpec.parse_quality("0") == {:error, :invalid_quality}
      assert OptionSpec.parse_quality("101") == {:error, :invalid_quality}
      assert OptionSpec.parse_quality("50.5") == {:error, :invalid_quality}
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
