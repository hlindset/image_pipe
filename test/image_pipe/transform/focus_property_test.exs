defmodule ImagePipe.Transform.FocusPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.PendingOrientation

  # A reduced rational fraction in [0, 1).
  defp fraction do
    gen all(d <- integer(1..64), n <- integer(0..(d - 1))) do
      g = max(1, Integer.gcd(n, d))
      {:ratio, div(n, g), div(d, g)}
    end
  end

  # A pending orientation from the REAL producers (from_exif + folds), not a
  # hand-built struct.
  defp pending_orientation do
    gen all(
          exif <- integer(1..8),
          auto? <- boolean(),
          angle <- member_of([0, 90, 180, 270]),
          flip <- member_of([:none, :horizontal, :vertical, :both])
        ) do
      po = PendingOrientation.from_exif(exif, auto?)
      po = PendingOrientation.fold_rotate(po, angle)
      if flip == :none, do: po, else: PendingOrientation.fold_flip(po, flip)
    end
  end

  defp reduced?({:ratio, n, d}), do: Integer.gcd(abs(n), d) == 1 and d > 0

  property "scale then inverse scale returns the original reduced rational" do
    check all(
            fx <- fraction(),
            fy <- fraction(),
            n <- integer(1..32),
            d <- integer(1..32)
          ) do
      point = {fx, fy}

      round_trip =
        point
        |> Focus.scale({:ratio, n, d}, {:ratio, n, d})
        |> Focus.scale({:ratio, d, n}, {:ratio, d, n})

      assert round_trip == {fx, fy}
      {rx, ry} = round_trip
      assert reduced?(rx) and reduced?(ry)
    end
  end

  property "inverse_fraction undoes forward_fraction for any real orientation" do
    check all(
            fx <- fraction(),
            fy <- fraction(),
            po <- pending_orientation()
          ) do
      {gx, gy} = Focus.inverse_fraction(Focus.forward_fraction({fx, fy}, po), po)
      assert {gx, gy} == {fx, fy}
      assert reduced?(gx) and reduced?(gy)
    end
  end

  property "four user quarter-turns return the carried point on a non-square frame" do
    # A square frame can hide a dim-swap bug, so use w != h.
    po = PendingOrientation.fold_rotate(%PendingOrientation{}, 90)

    check all(
            x <- integer(0..299),
            y <- integer(0..399)
          ) do
      start = {{:ratio, x, 1}, {:ratio, y, 1}}

      # dims after each 90° turn alternate 300x400 <-> 400x300
      p1 = Focus.reflect_rotate(start, po, {300, 400})
      p2 = Focus.reflect_rotate(p1, po, {400, 300})
      p3 = Focus.reflect_rotate(p2, po, {300, 400})
      p4 = Focus.reflect_rotate(p3, po, {400, 300})

      assert p4 == start

      # The intermediate single turn lands in the swapped (400x300) frame: the new
      # x came from the old y reflected (continuous coordinate dim - y), so it lies
      # in the CLOSED interval [0, 400] — y = 0 reflects to the right boundary 400
      # (fraction 1.0, the far edge), which to_fp clamps to the last pixel. (This is
      # the continuous-coordinate reflection, matching Orientation.flip_x_point's
      # `1 - u`; it is not an integer pixel index, so dim is a valid boundary value.)
      {{:ratio, nx, dx}, _ny} = p1
      assert nx / dx >= 0 and nx / dx <= 400
    end
  end
end
