defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output.QualitySearch

  test "builds a size search with defaults for optional fields" do
    s = %QualitySearch.Size{target: 10_240, min_quality: 10, max_quality: 80}
    assert s.format_min == %{}
    assert s.format_max == %{}
    assert s.max_resolution == 0
  end

  test "builds an ssimulacra2 search" do
    s = %QualitySearch.Ssimulacra2{
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 1.0,
      format_min: %{avif: 60},
      format_max: %{avif: 65}
    }

    assert s.allowed_error == 1.0
    assert s.format_min == %{avif: 60}
  end

  test "builds a butteraugli search" do
    s = %QualitySearch.Butteraugli{
      target: 1.0,
      min_quality: 1,
      max_quality: 100,
      allowed_error: 0.1
    }

    assert s.allowed_error == 0.1
    assert s.format_min == %{}
    assert s.max_resolution == 0
  end

  test "enforces required keys" do
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Size, target: 1) end
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Ssimulacra2, target: 1.0) end
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Butteraugli, target: 1.0) end
  end

  test "url_min_quality/url_max_quality default to nil and are non-enforced" do
    for mod <- [
          QualitySearch.Size,
          QualitySearch.Ssimulacra2,
          QualitySearch.Butteraugli
        ] do
      s = struct(mod, target: 1, min_quality: 70, max_quality: 80)
      assert s.url_min_quality == nil
      assert s.url_max_quality == nil

      s2 = struct(mod, target: 1, min_quality: 70, max_quality: 80, url_min_quality: 75)
      assert s2.url_min_quality == 75
    end
  end

  # A config keyword shaped like Config.resolve!([]) for the autoquality keys.
  defp config(extra \\ []) do
    Keyword.merge(
      [
        autoquality_method: :none,
        autoquality_min_quality: 70,
        autoquality_max_quality: 80,
        autoquality_max_resolution: 0,
        autoquality_target: %{ssimulacra2: 78, butteraugli: 1.0},
        autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1},
        autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
        autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80}
      ],
      extra
    )
  end

  describe "from_config/1" do
    test ":none method yields :none" do
      assert {:ok, :none} = QualitySearch.from_config(config())
    end

    test "ssimulacra2 method builds the struct from seeded defaults" do
      assert {:ok, %QualitySearch.Ssimulacra2{target: 78, allowed_error: 1.0, min_quality: 70, max_quality: 80}} =
               QualitySearch.from_config(config(autoquality_method: :ssimulacra2))
    end

    test "butteraugli method builds from seeded defaults" do
      assert {:ok, %QualitySearch.Butteraugli{target: 1.0, allowed_error: 0.1}} =
               QualitySearch.from_config(config(autoquality_method: :butteraugli))
    end

    test "size method with no target errors (no :size default exists)" do
      assert {:error, {:invalid_option, :autoquality, :missing_target}} =
               QualitySearch.from_config(config(autoquality_method: :size))
    end

    test "size method with a config target builds" do
      cfg = config(autoquality_method: :size, autoquality_target: %{size: 50_000})
      assert {:ok, %QualitySearch.Size{target: 50_000}} = QualitySearch.from_config(cfg)
    end
  end

  describe "build/3 with URL fields" do
    test "url target overrides the config target and is range-checked" do
      assert {:ok, %QualitySearch.Ssimulacra2{target: 90}} =
               QualitySearch.build(:ssimulacra2, [target: 90], config())
    end

    test "an in-range seeded default survives the range re-check" do
      assert {:ok, %QualitySearch.Butteraugli{target: 1.0}} =
               QualitySearch.build(:butteraugli, [], config())
    end
  end
end
