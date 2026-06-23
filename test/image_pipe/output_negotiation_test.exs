defmodule ImagePipe.Output.NegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Negotiation

  describe "modern_candidates/2" do
    test "detects enabled modern formats from Accept" do
      assert Negotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]

      assert Negotiation.modern_candidates("image/avif;q=0,image/*;q=1",
               output_capabilities: %{jpeg_xl: true}
             ) == [:jpeg_xl, :webp]

      assert Negotiation.modern_candidates("image/jpeg", []) == []
      assert Negotiation.modern_candidates(nil, []) == []
    end

    test "treats missing, empty, and global wildcard-only Accept as no modern format signal" do
      assert Negotiation.modern_candidates(nil, []) == []
      assert Negotiation.modern_candidates("", []) == []
      assert Negotiation.modern_candidates("   ", []) == []
      assert Negotiation.modern_candidates("*/*", []) == []
      assert Negotiation.modern_candidates("*/*;q=1", []) == []
      assert Negotiation.modern_candidates("*/*; q=0.8", []) == []
      assert Negotiation.modern_candidates("application/json,*/*;q=1", []) == []
    end

    test "respects automatic format feature flags" do
      assert Negotiation.modern_candidates("image/avif,image/webp", auto_avif: false) == [
               :webp
             ]

      assert Negotiation.modern_candidates("image/avif,image/webp",
               auto_avif: false,
               auto_webp: false
             ) == []
    end

    test "uses server preference before relative q-values" do
      assert Negotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]
    end

    test "matches image wildcard and explicit modern formats when global wildcard is also present" do
      assert Negotiation.modern_candidates("image/*", output_capabilities: %{jpeg_xl: true}) ==
               [:jpeg_xl, :avif, :webp]

      assert Negotiation.modern_candidates("image/webp,*/*", []) == [:webp]
    end

    test "exact q zero excludes a modern format even when wildcard matches" do
      assert Negotiation.modern_candidates("image/avif;q=0,image/*;q=1",
               output_capabilities: %{jpeg_xl: true}
             ) == [:jpeg_xl, :webp]

      assert Negotiation.modern_candidates("image/avif;q=0,image/avif;q=1,*/*;q=1", []) == []
    end

    test "image wildcard exclusion leaves global wildcard ignored" do
      assert Negotiation.modern_candidates("image/*;q=0,*/*;q=1", []) == []
    end
  end

  describe "modern_candidates/2 JPEG XL" do
    test "an explicit image/jxl Accept yields jpeg_xl" do
      assert Negotiation.modern_candidates("image/jxl", output_capabilities: %{jpeg_xl: true}) ==
               [:jpeg_xl]
    end

    test "jpeg_xl outranks avif and webp when several are accepted" do
      opts = [output_capabilities: %{jpeg_xl: true, avif: true, webp: true}]

      assert Negotiation.modern_candidates("image/webp,image/avif,image/jxl", opts) ==
               [:jpeg_xl, :avif, :webp]
    end

    test "server preference puts jpeg_xl first even against higher client q-values" do
      opts = [output_capabilities: %{jpeg_xl: true, avif: true, webp: true}]

      assert Negotiation.modern_candidates("image/jxl;q=0.1,image/avif;q=1", opts) ==
               [:jpeg_xl, :avif]
    end

    test "auto_jpeg_xl is enabled by default" do
      assert Negotiation.modern_candidates("image/jxl", output_capabilities: %{jpeg_xl: true}) ==
               [:jpeg_xl]
    end

    test "auto_jpeg_xl: false drops jpeg_xl while leaving avif and webp" do
      opts = [auto_jpeg_xl: false, output_capabilities: %{jpeg_xl: true}]

      assert Negotiation.modern_candidates("image/jxl,image/avif", opts) == [:avif]
      assert Negotiation.modern_candidates("image/jxl", opts) == []
    end

    test "a build that cannot write jpeg_xl drops it from the candidates" do
      opts = [output_capabilities: %{jpeg_xl: false}]

      assert Negotiation.modern_candidates("image/jxl,image/avif", opts) == [:avif]
      assert Negotiation.modern_candidates("image/jxl", opts) == []
    end
  end

  describe "modern_candidates/2 malformed q-values" do
    test "an out-of-range q-value is ignored, not treated as an exclusion" do
      # q=1.5 is invalid; it must not veto a duplicate valid webp entry.
      assert Negotiation.modern_candidates("image/webp;q=1.5,image/webp", []) == [:webp]
      # ...nor make webp unacceptable on its own.
      assert Negotiation.modern_candidates("image/webp;q=1.5", []) == [:webp]
    end

    test "an unparseable q-value is ignored, not treated as an exclusion" do
      assert Negotiation.modern_candidates("image/avif;q=abc", []) == [:avif]
      assert Negotiation.modern_candidates("image/avif;q=abc,image/avif", []) == [:avif]
    end

    test "a genuine in-range q=0 still excludes, unlike a malformed weight" do
      assert Negotiation.modern_candidates("image/webp;q=0,image/webp;q=1", []) == []
      assert Negotiation.modern_candidates("image/avif;q=0", []) == []
    end
  end

  describe "modern_candidates/2 capability filtering" do
    test "drops avif when the build cannot write it" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:webp]
    end

    test "an avif-only Accept on an avif-less build yields no modern candidates" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif", opts) == []
    end

    test "keeps both when the build supports both" do
      opts = [output_capabilities: %{avif: true, webp: true}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:avif, :webp]
    end
  end
end
