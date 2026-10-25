defmodule ImagePipe.VipsHeaderTest do
  # Toggles the global libvips operation cache, so this module can't run async.
  use ExUnit.Case, async: false

  alias ImagePipe.VipsHeader
  alias Vix.Vips.Image, as: VipsImage

  @moduletag :tmp_dir

  @source Path.expand("../support/image_pipe/test/sources/high_freq.jpg", __DIR__)

  test "removes and sets fields on a new image, leaving the original alone" do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30])
    {:ok, image} = VipsHeader.edit(image, [{:set, "exif-ifd0-Artist", :gchararray, "Ada"}])

    {:ok, edited} =
      VipsHeader.edit(image, [
        {:remove, "exif-ifd0-Artist"},
        {:set, "exif-ifd0-Copyright", :gchararray, "CC0"}
      ])

    assert {:error, _} = VipsImage.header_value(edited, "exif-ifd0-Artist")
    assert {:ok, "CC0"} = VipsImage.header_value(edited, "exif-ifd0-Copyright")
    assert {:ok, "Ada"} = VipsImage.header_value(image, "exif-ifd0-Artist")
    assert {:error, _} = VipsImage.header_value(image, "exif-ifd0-Copyright")
  end

  test "reads no pixels, so a truncated streamed source edits and fails later", %{tmp_dir: dir} do
    image = truncated_stream(dir)

    assert {:ok, edited} = VipsHeader.edit(image, [{:remove, "exif-data"}])
    assert {:error, _} = VipsImage.copy_memory(edited)
  end

  test "with the operation cache on, buffers first and returns a decode failure",
       %{tmp_dir: dir} do
    image = truncated_stream(dir)
    Vix.Vips.cache_set_max(100)
    on_exit(fn -> Vix.Vips.cache_set_max(0) end)

    assert {:error, {:decode, _reason}} = VipsHeader.edit(image, [{:remove, "exif-data"}])

    {:ok, image} = Image.new(8, 8, color: [10, 20, 30])

    assert {:ok, edited} =
             VipsHeader.edit(image, [{:set, "exif-ifd0-Copyright", :gchararray, "CC0"}])

    assert {:ok, "CC0"} = VipsImage.header_value(edited, "exif-ifd0-Copyright")
  end

  defp truncated_stream(dir) do
    bytes = File.read!(@source)
    path = Path.join(dir, "truncated.jpg")
    File.write!(path, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    {:ok, image} = VipsImage.new_from_file(path <> "[access=sequential,fail_on=error]")
    image
  end
end
