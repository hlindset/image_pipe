defmodule ImagePipe.Output.Terminal.BlurhashTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Terminal.Blurhash
  alias Vix.Vips.Image, as: Vimage

  @sources "test/support/image_pipe/test/imgproxy_differential/sources"
  @plain_srgb_fixture "#{@sources}/small.png"
  @wide_gamut_fixture "#{@sources}/icc_p3.png"

  @blurhash_pattern ~r/^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$/

  describe "identity/0" do
    test "stays the fixed 4x3 blurhash identity tuple" do
      assert Blurhash.identity() == {:blurhash, 1}
    end
  end

  describe "compute/1" do
    test "a known fixture produces a stable, plausibly-shaped blurhash string" do
      image = Image.open!(@plain_srgb_fixture, access: :random)

      assert {:ok, hash} = Blurhash.compute(image)
      assert hash =~ @blurhash_pattern
      # 4x3 components: 1 (size flag, base83) + 4 (max AC, avg color) + 2*(4*3 - 1)
      # (AC components) = 28 base83 chars.
      assert String.length(hash) == 28

      # Stable: re-running against the same fixture yields the same hash.
      assert {:ok, ^hash} = Blurhash.compute(image)
    end
  end

  describe "to_terminal_pixel_space/1 — pixel-space invariance" do
    # `icc_p3.png` is generated (mix imgproxy.gen_sources) by building this
    # exact sRGB pattern, untagged, then converting it to Display-P3 via
    # `Image.to_colorspace(icc, :p3, [])` — so this reference IS the sRGB
    # twin of the committed wide-gamut fixture, reconstructed in-test rather
    # than committed as a second source file.
    defp srgb_twin_of_wide_gamut_fixture do
      512
      |> Image.new!(512, color: [200, 50, 50])
      |> Image.Draw.rect!(0, 0, 64, 64, color: [255, 255, 255])
      |> Image.Draw.rect!(256, 0, 6, 512, color: [0, 255, 0])
      |> Image.Draw.rect!(0, 256, 512, 6, color: [0, 0, 255])
    end

    test "a wide-gamut/ICC source normalizes close to its untagged sRGB twin" do
      srgb_reference = srgb_twin_of_wide_gamut_fixture()
      wide_gamut_source = Image.open!(@wide_gamut_fixture, access: :random)

      assert {:ok, normalized_reference} = Blurhash.to_terminal_pixel_space(srgb_reference)
      assert {:ok, normalized_wide_gamut} = Blurhash.to_terminal_pixel_space(wide_gamut_source)

      assert Vimage.width(normalized_reference) == Vimage.width(normalized_wide_gamut)
      assert Vimage.height(normalized_reference) == Vimage.height(normalized_wide_gamut)

      assert {:ok, difference, _diff_image} =
               Image.compare(normalized_reference, normalized_wide_gamut, metric: :ae)

      # A proper ICC round-trip (sRGB -> P3 at generation time, P3 -> sRGB
      # here) is expected to be very close but not necessarily exact —
      # rounding in the profile conversion may legitimately differ by ~1
      # per channel. Assert closeness first, and only demand blurhash
      # STRING equality when the frames prove byte-identical (a brittle
      # hash-equality assertion is explicitly not wanted here).
      #
      # `:ae` is the fraction of *pixels* that differ (measured ~0.0233
      # here), and it only inspects band 0 (red) — a conversion that's
      # wrong on green/blue alone would still pass an `:ae`-only check. A
      # broken conversion (e.g. byte-reinterpreting the P3 source instead
      # of profile-converting it) drives `:ae` up to ~0.97, so a tight
      # bound catches it; measured `:rmse` (~0.00077, all bands) catches a
      # green/blue-only divergence that `:ae` would miss.
      assert difference < 0.05

      assert {:ok, rmse, _diff_image} =
               Image.compare(normalized_reference, normalized_wide_gamut, metric: :rmse)

      assert rmse < 0.002

      if difference == 0.0 do
        assert {:ok, hash_a} = Blurhash.compute(srgb_reference)
        assert {:ok, hash_b} = Blurhash.compute(wide_gamut_source)
        assert hash_a == hash_b
      end
    end

    test "a plain sRGB image with no embedded profile passes through as a no-op reinterpretation" do
      image = Image.open!(@plain_srgb_fixture, access: :random)

      assert {:ok, normalized} = Blurhash.to_terminal_pixel_space(image)

      assert {:ok, difference, _diff_image} = Image.compare(image, normalized, metric: :ae)
      assert difference == 0.0
    end
  end
end
