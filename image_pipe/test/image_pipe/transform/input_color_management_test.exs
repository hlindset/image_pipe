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

  describe "condition/2" do
    setup do
      %{open: fn path -> Image.open!(path, access: :sequential) end}
    end

    test "idempotent when color already imported", %{open: open} do
      img = open.(@p3_fixture)
      state = %State{image: img, color_imported?: true, source_color_profile: <<1, 2, 3>>}
      assert {:ok, ^state} = ICM.condition(state, supports_hdr?: false)
    end

    test "wide-gamut (Display-P3) keeps its values and backs up its profile", %{open: open} do
      img = open.(@p3_fixture)
      {:ok, profile} = VixImage.header_value(img, "icc-profile-data")
      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
      assert out.color_imported? == false
      assert out.source_color_profile == profile
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB

      assert VixImage.write_to_binary(out.image) ==
               VixImage.write_to_binary(open.(@p3_fixture))
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

    test "tagged 16-bit RGB with alpha keeps its profile and alpha band", %{open: open} do
      {:ok, profile} = VixImage.header_value(open.(@p3_fixture), "icc-profile-data")
      img = open.(@rgba16_fixture)
      assert VixImage.bands(img) == 4

      {:ok, img} =
        VixImage.mutate(img, fn m ->
          :ok = MutableImage.set(m, "icc-profile-data", :VipsBlob, profile)
        end)

      {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: true)
      assert out.color_imported? == false
      assert out.source_color_profile == profile
      assert VixImage.interpretation(out.image) == :VIPS_INTERPRETATION_RGB16
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
