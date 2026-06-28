defmodule ImagePipe.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Config

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

    test "jxl_effort is validated-if-present but not defaulted" do
      refute Keyword.has_key?(Config.resolve!([], []), :jxl_effort)
      assert Config.resolve!(jxl_effort: 4)[:jxl_effort] == 4
    end

    test "resolve! is idempotent (same effective values; order is not significant)" do
      once = Config.resolve!(quality: 90, format_quality: %{webp: 50}, jxl_effort: 4)
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

    test "rejects out-of-range jxl_effort" do
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_effort: 0) end
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_effort: 10) end
    end

    test "rejects unknown neutral keys" do
      assert_raise ArgumentError, fn -> Config.resolve!(bogus: 1) end
    end
  end

  describe "introspection" do
    test "keys/0 lists the neutral keys" do
      assert :quality in Config.keys()
      assert :jxl_effort in Config.keys()
      refute :signature in Config.keys()
    end

    test "default/1 exposes neutral defaults including jxl_effort" do
      assert Config.default(:jxl_effort) == 7
      assert Config.default(:quality) == 80
    end
  end

  describe "autoquality fallback defaults" do
    test "resolve! seeds per-metric target and allowed_error defaults" do
      resolved = Config.resolve!([])
      assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 78, butteraugli: 1.0}
      assert Keyword.fetch!(resolved, :autoquality_allowed_error) == %{ssimulacra2: 1.0, butteraugli: 0.1}
    end

    test "a host override merges onto the seeded map, keeping the other metric" do
      resolved = Config.resolve!(autoquality_target: %{ssimulacra2: 90})
      assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 90, butteraugli: 1.0}
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
