defmodule ImagePipe.Dialect.Native.OptionSpecTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.OptionSpec

  @probe_subset_keys ~w(w h fit enlarge crop region anchor focus blur trim pad bg output format q expires preset)

  describe "all/0" do
    test "declares exactly the probe subset, one entry per key" do
      keys = Enum.map(OptionSpec.all(), & &1.key)

      assert Enum.sort(keys) == Enum.sort(@probe_subset_keys)
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
        assert spec.identity in [:representation, :gate]
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
    test "parse_dimension unwraps px to a plain integer, keeps auto" do
      assert OptionSpec.parse_dimension("800") == {:ok, 800}
      assert OptionSpec.parse_dimension("auto") == {:ok, :auto}
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

    test "parse_bg accepts color-only and color+alpha" do
      assert OptionSpec.parse_bg("f4f4f4") == {:ok, {{244, 244, 244}, nil}}
      assert OptionSpec.parse_bg("fff,0.5") == {:ok, {{255, 255, 255}, 0.5}}
    end

    test "parse_output accepts image and blurhash only" do
      assert OptionSpec.parse_output("image") == {:ok, :image}
      assert OptionSpec.parse_output("blurhash") == {:ok, :blurhash}
      assert OptionSpec.parse_output("lqip") == {:error, :invalid_output}
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
