defmodule ImagePipe.TwicpicsSourceInventoryTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.SourceInventory

  @sources_dir "test/support/image_pipe/test/twicpics_differential/sources"
  alias Vix.Vips.Image, as: VixImage

  test "every committed source has an inventory entry and vice versa" do
    on_disk = @sources_dir |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> MapSet.new()
    inventoried = SourceInventory.all() |> Enum.map(& &1.file) |> MapSet.new()
    assert on_disk == inventoried
  end

  # Read facts via the same API the imgproxy drift test uses (proven): `header_value`
  # for the band format, `VixImage.interpretation/1` for colour interpretation. Note
  # `Image.interpretation/1` does NOT exist — use `VixImage.interpretation/1`.
  test "inventory facts match the decoded bytes" do
    for entry <- SourceInventory.all() do
      {:ok, img} = VixImage.new_from_file(Path.join(@sources_dir, entry.file))
      {:ok, format} = VixImage.header_value(img, "format")
      profile? = match?({:ok, _}, VixImage.header_value(img, "icc-profile-data"))

      assert {VixImage.width(img), VixImage.height(img)} == {entry.width, entry.height}
      assert VixImage.bands(img) == entry.bands
      assert format == entry.format
      assert VixImage.interpretation(img) == entry.interpretation
      assert profile? == entry.profile?
    end
  end
end
