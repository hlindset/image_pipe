defmodule ImagePipe.Transform.Operation.RotateTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  defp state_for(image), do: %State{image: image, materialized?: true}

  defp run(op, image) do
    {:ok, %State{image: result}} = Transform.execute(op, state_for(image))
    result
  end

  test "requires materialization" do
    assert Transform.requires_materialization?(%Rotate{angle: 45})
    assert Transform.requires_materialization?(%Rotate{angle: 90})
  end

  test "name is :rotate" do
    assert Transform.transform_name(%Rotate{angle: 90}) == :rotate
  end

  test "right angle uses lossless rot: a 90° turn of a WxH image is HxW, no new bands" do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    result = run(%Rotate{angle: 90}, image)
    assert Image.width(result) == 20
    assert Image.height(result) == 40
    refute Image.has_alpha?(result)
  end

  test "arbitrary angle grows the bounding box and adds transparent corners" do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    result = run(%Rotate{angle: 45}, image)
    assert Image.width(result) > 40
    assert Image.height(result) > 20
    assert Image.has_alpha?(result)
    pixel = Image.get_pixel!(result, 0, 0)
    assert List.last(pixel) == 0, "corner not transparent: #{inspect(pixel)}"
  end

  test "arbitrary angle does not dark-fringe opaque content (premultiply works)" do
    {:ok, image} = Image.new(60, 60, color: [240, 240, 240])
    result = run(%Rotate{angle: 10}, image)

    [r, g, b | _] =
      Image.get_pixel!(result, div(Image.width(result), 2), div(Image.height(result), 2))

    assert r > 200 and g > 200 and b > 200, "interior darkened: #{inspect([r, g, b])}"
  end

  test "arbitrary angle on an already-alpha source preserves interior alpha and transparent corners" do
    {:ok, image} = Image.new(40, 40, color: [200, 100, 50, 128], bands: 4)
    result = run(%Rotate{angle: 30}, image)
    assert Image.has_alpha?(result)
    # exposed corner fully transparent
    assert List.last(Image.get_pixel!(result, 0, 0)) == 0

    # interior keeps the source's semi-transparent alpha (~128), not double-premultiplied to 0/opaque
    interior = Image.get_pixel!(result, div(Image.width(result), 2), div(Image.height(result), 2))
    a = List.last(interior)
    assert a > 100 and a < 160, "interior alpha not preserved: #{inspect(interior)}"
  end

  test "arbitrary angle does not double-premultiply: constant colour survives an alpha step" do
    # A spatially-constant colour with a hard alpha step (opaque left, faint right).
    # For a premultiply-CORRECT resample, a constant colour is preserved at every
    # covered pixel — premultiply → resample → unpremultiply cancels for a constant
    # colour whatever the alpha. vips_rotate premultiplies internally (via affine),
    # so a manual premultiply on top of it double-premultiplies and inflates the
    # colour wherever the alpha varies — i.e. along the rotated seam.
    {:ok, opaque} = Image.new(20, 40, color: [100, 150, 200, 255], bands: 4)
    {:ok, faint} = Image.new(20, 40, color: [100, 150, 200, 96], bands: 4)
    {:ok, source} = Operation.join(opaque, faint, :VIPS_DIRECTION_HORIZONTAL)

    result = run(%Rotate{angle: 25}, source)
    w = Image.width(result)
    h = Image.height(result)

    max_dev =
      for x <- 0..(w - 1), y <- 0..(h - 1), reduce: 0 do
        acc ->
          [r, g, b, a] = Image.get_pixel!(result, x, y)
          # Skip the transparent exposed corners; unpremultiply noise blows up at
          # very low alpha, so only inspect pixels with meaningful coverage.
          if a >= 128 do
            max(acc, Enum.max([abs(r - 100), abs(g - 150), abs(b - 200)]))
          else
            acc
          end
      end

    assert max_dev <= 10,
           "constant colour distorted across the alpha seam (double-premultiply?): max channel dev #{max_dev}"
  end

  test "mirror flips horizontally before rotating" do
    {:ok, left} = Image.new(20, 20, color: [255, 0, 0])
    {:ok, right} = Image.new(20, 20, color: [0, 0, 255])
    {:ok, joined} = Operation.join(left, right, :VIPS_DIRECTION_HORIZONTAL)
    result = run(%Rotate{angle: 0, mirror: true}, joined)
    [r | _] = Image.get_pixel!(result, 1, 10)
    assert r == 0, "left edge should now be the (blue) mirrored right half"
  end
end
