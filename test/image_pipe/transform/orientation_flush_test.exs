defmodule ImagePipe.Transform.OrientationFlushTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{OrientationFlush, PendingOrientation, State}
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
end
