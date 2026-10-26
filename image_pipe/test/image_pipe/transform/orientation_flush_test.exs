defmodule ImagePipe.Transform.OrientationFlushTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  alias ImagePipe.Transform.{OrientationFlush, PendingOrientation, State}
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  defp marked, do: Image.Draw.rect!(Image.new!(40, 20, color: :white), 0, 0, 4, 4, color: :red)
  defp oriented(base, n), do: Image.set_orientation!(base, n)

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end

  defp assert_pixels_match(left, right) do
    assert Image.width(left) == Image.width(right)
    assert Image.height(left) == Image.height(right)

    for x <- sample_positions(Image.width(left)), y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y),
             "pixel mismatch at (#{x},#{y})"
    end
  end

  # Reference: apply EXIF (autorotate) then user rotate then user flip directly,
  # using the SAME primitives the flush uses — the exact `vips_rot` for the user
  # rotate, not Image.rotate/2's affine resampler (#211).
  defp reference(base, %PendingOrientation{} = po) do
    img = if po.auto_rotate?, do: elem(ok(Image.autorotate(base)), 0), else: base
    img = if po.user_angle != 0, do: rot_exact!(img, po.user_angle), else: img
    img = if po.user_flip_x, do: Image.flip!(img, :horizontal), else: img
    if po.user_flip_y, do: Image.flip!(img, :vertical), else: img
  end

  defp rot_exact!(img, 90), do: ok(Operation.rot(img, :VIPS_ANGLE_D90))
  defp rot_exact!(img, 180), do: ok(Operation.rot(img, :VIPS_ANGLE_D180))
  defp rot_exact!(img, 270), do: ok(Operation.rot(img, :VIPS_ANGLE_D270))

  defp ok({:ok, v}), do: v

  test "EXIF flush materializes the display frame and clears pending orientation" do
    for orientation <- 1..8 do
      base = marked()
      po = PendingOrientation.from_exif(orientation, true)

      state = %State{
        image: oriented(base, orientation),
        pending_orientation: po,
        materialized?: false
      }

      assert {:ok, %State{} = result} = OrientationFlush.flush(state)
      assert result.materialized?
      assert result.pending_orientation == nil
      assert_pixels_match(result.image, reference(oriented(base, orientation), po))
    end
  end

  test "auto_rotate?=false: EXIF tag is NOT applied (ar:0 regression guard), only user rotate" do
    base = marked()
    # Source carries orientation 6, but auto_rotate disabled + user rotate 90.
    po = %PendingOrientation{auto_rotate?: false, user_angle: 90}
    state = %State{image: oriented(base, 6), pending_orientation: po, materialized?: false}

    assert {:ok, %State{} = result} = OrientationFlush.flush(state)
    # Reference applies ONLY the user 90°, never the EXIF tag.
    expected = rot_exact!(oriented(base, 6), 90)
    assert_pixels_match(result.image, expected)
  end

  test "a last flush leaves the turn lazy with the same pixels" do
    for orientation <- 1..8 do
      base = marked()
      po = PendingOrientation.from_exif(orientation, true)
      state = %State{image: oriented(base, orientation), pending_orientation: po}

      assert {:ok, %State{} = result} = OrientationFlush.flush(state, false)
      assert result.materialized?
      assert result.pending_orientation == nil
      assert_pixels_match(result.image, reference(oriented(base, orientation), po))
    end
  end

  # A mirror needs no buffered stored frame, so the last flush still buffers
  # its result, and a corrupt source fails here instead of during encoding.
  test "a last flush buffers a mirror of a streamed source", %{tmp_dir: dir} do
    bytes = File.read!("test/support/image_pipe/test/sources/high_freq.jpg")
    path = Path.join(dir, "truncated.jpg")
    File.write!(path, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    {:ok, image} = VipsImage.new_from_file(path <> "[access=sequential,fail_on=error]")
    po = %PendingOrientation{auto_rotate?: false, user_flip_x: true}

    assert {:error, _reason} =
             OrientationFlush.flush(%State{image: image, pending_orientation: po}, false)
  end
end
