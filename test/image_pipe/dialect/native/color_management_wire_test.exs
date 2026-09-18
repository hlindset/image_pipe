defmodule ImagePipe.Native.ColorManagementWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/imgproxy_differential/sources"

  test "wide-gamut source pixels are converted once before PNG delivery" do
    source = Image.open!(@sources <> "/icc_p3.png", access: :random)
    assert {:ok, profile} = VipsImage.header_value(source, "icc-profile-data")
    assert byte_size(profile) > 0

    {:ok, imported} = Operation.icc_import(source, embedded: true, pcs: :VIPS_PCS_XYZ)
    {:ok, reference} = Operation.colourspace(imported, :VIPS_INTERPRETATION_sRGB)

    config =
      ImagePipe.Plug.init(
        sources: [path: {ImagePipe.Source.File, root: @sources, root_id: "wide-gamut"}]
      )

    conn =
      conn(:get, "/format=png/src/icc_p3.png")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 200
    actual = Image.from_binary!(conn.resp_body)
    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(reference)
    refute VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(source)
  end
end
