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

  # Runs with the libvips operation cache off (test_helper.exs), as the server
  # runs, so every check does its own icc_export.
  test "concurrent checks of different profiles give each profile's own answer" do
    srgb = File.read!("priv/icc/sRGB.icc")
    p3 = File.read!("priv/icc/DisplayP3.icc")

    results =
      1..400
      |> Task.async_stream(
        fn i ->
          # A distinct profile ID per call, so no check is answered from the table.
          if rem(i, 2) == 0,
            do: {:srgb, SrgbProfile.equivalent?(with_id(srgb, i))},
            else: {:p3, SrgbProfile.equivalent?(with_id(p3, i))}
        end,
        max_concurrency: 16,
        timeout: :infinity
      )
      |> Enum.frequencies_by(fn {:ok, result} -> result end)

    assert results == %{{:srgb, true} => 200, {:p3, false} => 200}
  end

  test "gray, truncated and malformed profiles are not equivalent" do
    srgb = File.read!("priv/icc/sRGB.icc")
    <<head::binary-size(16), _space::binary-size(4), rest::binary>> = srgb

    refute SrgbProfile.equivalent?(head <> "GRAY" <> rest)
    refute SrgbProfile.equivalent?(binary_part(srgb, 0, 100))
    refute SrgbProfile.equivalent?(head <> "RGB " <> :binary.copy(<<0>>, byte_size(rest)))
  end

  defp with_id(profile, id) do
    <<header::binary-size(84), _id::binary-size(16), rest::binary>> = profile
    header <> <<id::128>> <> rest
  end
end
