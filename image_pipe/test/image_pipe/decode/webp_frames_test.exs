defmodule ImagePipe.Decode.WebpFramesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Decode.WebpFrames
  alias ImagePipe.Test.MultiFrameSources
  alias Vix.Vips.Image, as: VipsImage

  @moduletag :tmp_dir

  test "counts the frames libvips reports for an animated WebP" do
    for frames <- [2, 3, 40] do
      body = MultiFrameSources.repeated_frame_webp(frames)
      assert WebpFrames.animated?(body)
      assert WebpFrames.count({:buffer, body}, 1_000) == {:ok, frames}

      {:ok, image} = VipsImage.new_from_buffer(body, access: :VIPS_ACCESS_RANDOM)
      assert VipsImage.header_value(image, "n-pages") == {:ok, frames}
    end

    body = MultiFrameSources.encode(:webp, 3)
    assert WebpFrames.animated?(body)
    assert WebpFrames.count({:buffer, body}, 1_000) == {:ok, 3}
  end

  test "stops counting once the limit is exceeded" do
    body = MultiFrameSources.repeated_frame_webp(50)
    assert WebpFrames.count({:buffer, body}, 9) == {:ok, 10}
  end

  test "still images are not animated" do
    refute WebpFrames.animated?(MultiFrameSources.encode(:webp, 1))
    refute WebpFrames.animated?(Image.new!(4, 4) |> Image.write!(:memory, suffix: ".webp"))

    refute WebpFrames.animated?(
             MultiFrameSources.riff_webp(
               MultiFrameSources.riff_chunk("VP8X", <<0x10, 0::24, 0::24, 0::24>>)
             )
           )

    refute WebpFrames.animated?(Image.new!(4, 4) |> Image.write!(:memory, suffix: ".png"))
  end

  property "counts ANMF chunks in any chunk layout, from a buffer or a file", %{tmp_dir: dir} do
    check all chunks <- list_of(chunk(), max_length: 30),
              limit <- integer(1..40) do
      body =
        MultiFrameSources.riff_webp(
          Enum.map_join(chunks, fn {id, data} -> MultiFrameSources.riff_chunk(id, data) end)
        )

      frames = Enum.count(chunks, &match?({"ANMF", _}, &1))
      expected = min(frames, limit + 1)

      path = Path.join(dir, "source.webp")
      File.write!(path, body)

      assert WebpFrames.count({:buffer, body}, limit) == {:ok, expected}
      assert WebpFrames.count({:path, path}, limit) == {:ok, expected}
    end
  end

  property "a truncated container never counts more than the complete one" do
    check all chunks <- list_of(chunk(), max_length: 20),
              cut <- integer(0..400) do
      body =
        MultiFrameSources.riff_webp(
          Enum.map_join(chunks, fn {id, data} -> MultiFrameSources.riff_chunk(id, data) end)
        )

      truncated = binary_part(body, 0, min(cut, byte_size(body)))
      frames = Enum.count(chunks, &match?({"ANMF", _}, &1))

      assert {:ok, count} = WebpFrames.count({:buffer, truncated}, 1_000)
      assert count <= frames
    end
  end

  defp chunk do
    tuple(
      {member_of(["ANMF", "ANIM", "VP8X", "EXIF", "XMP ", "ICCP", "ALPH", "JUNK"]),
       binary(max_length: 21)}
    )
  end
end
