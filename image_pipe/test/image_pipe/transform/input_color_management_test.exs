defmodule ImagePipe.Transform.InputColorManagementTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.InputColorManagement, as: ICM
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  # Minimal 128-byte profile with the given 4-byte tag at offset 20 (PCS field).
  defp profile_with_pcs(tag) do
    <<0::size(20 * 8), tag::binary-size(4), 0::size(104 * 8)>>
  end

  # Minimal 128-byte header whose byte fields satisfy every check in
  # vips_icc_is_srgb_iec61966:
  #   offset  8 – version  <<2, 16, 0, 0>>   (2.1)
  #   offset 16 – colorspace "RGB "
  #   offset 24 – date    <<7, 206, 0, 2, 0, 9>>  (1998-12-01)
  #   offset 48 – mfr     "IEC "
  #   offset 52 – model   "sRGB"
  #   offset 80 – creator "HP  "
  defp srgb_iec61966_header do
    date = <<7, 206, 0, 2, 0, 9>>

    <<
      # offset 0–7: profile size + preferred CMM (ignored)
      0::size(8 * 8),
      # offset 8–11: version 2.1 = <<2, 16, 0, 0>>
      2,
      16,
      0,
      0,
      # offset 12–15: profile/device class (ignored)
      0::size(4 * 8),
      # offset 16–19: colorspace "RGB "
      "RGB ",
      # offset 20–23: PCS (XYZ – not checked by srgb_iec61966?)
      "XYZ ",
      # offset 24–29: date <<7, 206, 0, 2, 0, 9>>
      date::binary,
      # offset 30–47: rest of date padding + profile file signature (ignored)
      0::size(18 * 8),
      # offset 48–51: device manufacturer "IEC "
      "IEC ",
      # offset 52–55: device model "sRGB"
      "sRGB",
      # offset 56–79: device attributes + rendering intent + illuminant (ignored)
      0::size(24 * 8),
      # offset 80–83: profile creator "HP  "
      "HP  ",
      # offset 84–127: remainder
      0::size(44 * 8)
    >>
  end

  @sources "test/support/image_pipe/test/sources"
  @p3_fixture "#{@sources}/icc_p3.png"
  @plain_srgb_fixture "#{@sources}/small.png"
  @cmyk_fixture "#{@sources}/cmyk.jpg"
  @rgba16_fixture "#{@sources}/rgba16.png"

  describe "pcs/1" do
    test "returns :VIPS_PCS_XYZ when bytes 20–23 are 'XYZ '" do
      assert ICM.pcs(profile_with_pcs("XYZ ")) == :VIPS_PCS_XYZ
    end

    test "returns :VIPS_PCS_LAB for any non-XYZ tag" do
      assert ICM.pcs(profile_with_pcs("Lab ")) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_LAB for profiles shorter than 128 bytes" do
      assert ICM.pcs(<<0, 1, 2>>) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_LAB for nil" do
      assert ICM.pcs(nil) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_XYZ for the Display-P3 fixture (its header carries XYZ PCS)" do
      {:ok, img} = Image.open(@p3_fixture)
      {:ok, p3} = VixImage.header_value(img, "icc-profile-data")
      assert ICM.pcs(p3) == :VIPS_PCS_XYZ
    end
  end

  describe "srgb_iec61966?/1" do
    test "true for a header that satisfies all vips_icc_is_srgb_iec61966 checks" do
      assert ICM.srgb_iec61966?(srgb_iec61966_header())
    end

    test "false for a Display-P3 fixture profile" do
      {:ok, img} = Image.open(@p3_fixture)
      {:ok, p3} = VixImage.header_value(img, "icc-profile-data")
      refute ICM.srgb_iec61966?(p3)
    end

    test "false for a profile shorter than 128 bytes" do
      refute ICM.srgb_iec61966?(<<0, 1, 2>>)
    end

    test "false for nil" do
      refute ICM.srgb_iec61966?(nil)
    end

    test "false when any single check field differs" do
      base = srgb_iec61966_header()

      # Mutate manufacturer "IEC " → "IEC!"
      <<pre::binary-size(48), _::binary-size(4), rest::binary>> = base
      assert ICM.srgb_iec61966?(<<pre::binary, "IEC!", rest::binary>>) == false

      # Mutate model "sRGB" → "sRGb"
      <<pre2::binary-size(52), _::binary-size(4), rest2::binary>> = base
      assert ICM.srgb_iec61966?(<<pre2::binary, "sRGb", rest2::binary>>) == false

      # Mutate creator "HP  " → "hp  "
      <<pre3::binary-size(80), _::binary-size(4), rest3::binary>> = base
      assert ICM.srgb_iec61966?(<<pre3::binary, "hp  ", rest3::binary>>) == false
    end
  end

  describe "condition/2" do
    setup do
      %{open: fn path -> Image.open!(path, access: :sequential) end}
    end

    test "idempotent when color already imported", %{open: open} do
      img = open.(@p3_fixture)
      state = %State{image: img, color_imported?: true, source_color_profile: <<1, 2, 3>>}
      assert {:ok, ^state} = ICM.condition(state, supports_hdr?: false)
    end

    test "wide-gamut (Display-P3) imports: records profile, sets imported, lands sRGB", %{
      open: open
    } do
      img = open.(@p3_fixture)
      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert out.color_imported? == true
      assert is_binary(out.source_color_profile)
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
    end

    test "untagged sRGB is a no-op: no import, no backup, still sRGB", %{open: open} do
      img = open.(@plain_srgb_fixture)
      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert out.color_imported? == false
      assert out.source_color_profile == nil
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
    end

    test "CMYK with embedded profile imports and lands sRGB", %{open: open} do
      img = open.(@cmyk_fixture)
      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert out.color_imported? == true
      assert is_binary(out.source_color_profile)
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
    end

    test "16-bit RGB with alpha imports via band split/rejoin and keeps the alpha band", %{
      open: open
    } do
      # The differential rgba16 source carries no embedded profile — it is full-range
      # HDR content (#240), not a color-managed image. Attach a profile here (the same
      # mutate pattern as the scRGB test) so the 16-bit-with-alpha import path — which
      # needs an embedded profile to import — is genuinely exercised.
      {:ok, profile} = VixImage.header_value(open.(@p3_fixture), "icc-profile-data")
      img = open.(@rgba16_fixture)
      assert VixImage.bands(img) == 4

      {:ok, img} =
        VixImage.mutate(img, fn m ->
          :ok = MutableImage.set(m, "icc-profile-data", :VipsBlob, profile)
        end)

      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert out.color_imported? == true
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
      assert VixImage.bands(out.image) == 4
    end

    test "linear (scRGB) drops profile, does not record backup, still converts", %{open: open} do
      # Start from a profiled source so the profile-drop is genuinely exercised.
      img = open.(@p3_fixture)
      {:ok, profile} = VixImage.header_value(img, "icc-profile-data")
      assert is_binary(profile)
      {:ok, linear} = Operation.colourspace(img, :VIPS_INTERPRETATION_scRGB)

      {:ok, linear} =
        VixImage.mutate(linear, fn m ->
          :ok = MutableImage.set(m, "icc-profile-data", :VipsBlob, profile)
        end)

      assert {:ok, _} = VixImage.header_value(linear, "icc-profile-data")
      {:ok, out} = ICM.condition(%State{image: linear}, supports_hdr?: false)
      assert out.color_imported? == false
      assert out.source_color_profile == nil
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
      assert VixImage.header_value(out.image, "icc-profile-data") == {:error, "No such field"}
    end

    test "dimensions are preserved by conditioning", %{open: open} do
      img = open.(@p3_fixture)
      {w, h} = {VixImage.width(img), VixImage.height(img)}
      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert {VixImage.width(out.image), VixImage.height(out.image)} == {w, h}
    end
  end

  describe "working_space/2 (supports_hdr?: false)" do
    test "8-bit color and grey stay as-is" do
      assert ICM.working_space(:VIPS_INTERPRETATION_sRGB, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB, false) == :VIPS_INTERPRETATION_RGB
      assert ICM.working_space(:VIPS_INTERPRETATION_B_W, false) == :VIPS_INTERPRETATION_B_W
    end

    test "16-bit tone-maps to 8-bit standard" do
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB16, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_GREY16, false) == :VIPS_INTERPRETATION_B_W
    end

    test "CMYK and unknown go to sRGB" do
      assert ICM.working_space(:VIPS_INTERPRETATION_CMYK, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_scRGB, false) == :VIPS_INTERPRETATION_sRGB
    end
  end

  describe "working_space/2 (supports_hdr?: true)" do
    test "8-bit color and grey stay as-is (ph:1 is a no-op for 8-bit sources)" do
      assert ICM.working_space(:VIPS_INTERPRETATION_sRGB, true) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB, true) == :VIPS_INTERPRETATION_RGB
      assert ICM.working_space(:VIPS_INTERPRETATION_B_W, true) == :VIPS_INTERPRETATION_B_W
    end

    test "RGB16 stays RGB16" do
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB16, true) == :VIPS_INTERPRETATION_RGB16
    end

    test "GREY16 stays GREY16" do
      assert ICM.working_space(:VIPS_INTERPRETATION_GREY16, true) == :VIPS_INTERPRETATION_GREY16
    end

    test "other interpretations (e.g. scRGB, LAB) map to RGB16" do
      assert ICM.working_space(:VIPS_INTERPRETATION_scRGB, true) == :VIPS_INTERPRETATION_RGB16
      assert ICM.working_space(:VIPS_INTERPRETATION_LAB, true) == :VIPS_INTERPRETATION_RGB16
    end
  end
end
