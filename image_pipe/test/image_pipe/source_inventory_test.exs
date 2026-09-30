defmodule ImagePipe.SourceInventoryTest do
  @moduledoc """
  Drift guard for the committed image test sources. Fails when the
  `SourceInventory` and the bytes on disk disagree — a source added/removed
  without an entry, or a regenerated source whose dims/format/interpretation/
  profile changed (a libvips bump or a content edit) without the inventory being
  updated.
  """
  use ExUnit.Case, async: true

  alias ImagePipe.Test.SourceInventory
  alias Vix.Vips.Image, as: VixImage

  @sources_dir "test/support/image_pipe/test/sources"

  test "the inventory and the sources/ directory list exactly the same files" do
    on_disk =
      @sources_dir
      |> File.ls!()
      |> Enum.reject(&String.ends_with?(&1, ".md"))
      |> MapSet.new()

    inventoried = MapSet.new(SourceInventory.files())

    assert on_disk == inventoried,
           "sources/ and SourceInventory disagree — update " <>
             "test/support/image_pipe/test/source_inventory.ex.\n" <>
             "  only on disk: #{inspect(MapSet.to_list(MapSet.difference(on_disk, inventoried)))}\n" <>
             "  only in inventory: #{inspect(MapSet.to_list(MapSet.difference(inventoried, on_disk)))}"
  end

  test "each inventory entry's recorded facts match the decoded source" do
    for entry <- SourceInventory.entries() do
      img = VixImage.new_from_file(Path.join(@sources_dir, entry.file)) |> ok!()

      {:ok, format} = VixImage.header_value(img, "format")
      profile? = match?({:ok, _}, VixImage.header_value(img, "icc-profile-data"))

      actual = %{
        width: VixImage.width(img),
        height: VixImage.height(img),
        bands: VixImage.bands(img),
        format: format,
        interpretation: VixImage.interpretation(img),
        profile?: profile?
      }

      expected = Map.take(entry, [:width, :height, :bands, :format, :interpretation, :profile?])

      assert actual == expected,
             "#{entry.file}: decoded facts drifted from SourceInventory.\n" <>
               "  expected: #{inspect(expected)}\n" <>
               "  actual:   #{inspect(actual)}\n" <>
               "If this was a deliberate regeneration, update the inventory entry."
    end
  end

  defp ok!({:ok, value}), do: value
end
