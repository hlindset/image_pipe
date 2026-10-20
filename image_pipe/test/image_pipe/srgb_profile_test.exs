defmodule ImagePipe.SrgbProfileTest do
  use ExUnit.Case, async: true

  alias ImagePipe.SrgbProfile
  alias Vix.Vips.Image, as: VipsImage

  test "sRGB profiles are equivalent" do
    {:ok, woman} = VipsImage.new_from_file("priv/static/images/woman.jpg")
    {:ok, facebook} = VipsImage.header_value(woman, "icc-profile-data")

    assert SrgbProfile.equivalent?(facebook)
    assert SrgbProfile.equivalent?(File.read!("priv/icc/sRGB.icc"))
  end

  test "wide-gamut profiles are not equivalent" do
    refute SrgbProfile.equivalent?(File.read!("priv/icc/DisplayP3.icc"))
    refute SrgbProfile.equivalent?(File.read!("priv/icc/AdobeRGB.icc"))
  end

  test "gray, truncated and malformed profiles are not equivalent" do
    srgb = File.read!("priv/icc/sRGB.icc")
    <<head::binary-size(16), _space::binary-size(4), rest::binary>> = srgb

    refute SrgbProfile.equivalent?(head <> "GRAY" <> rest)
    refute SrgbProfile.equivalent?(binary_part(srgb, 0, 100))
    refute SrgbProfile.equivalent?(head <> "RGB " <> :binary.copy(<<0>>, byte_size(rest)))
  end
end
