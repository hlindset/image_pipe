defmodule ImagePipe.Transform.Operation.GradientTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp white(w \\ 16, h \\ 16), do: Image.new!(w, h, color: [255, 255, 255], bands: 3)
  defp lum(image, x, y), do: image |> VipsImage.get_pixel!(x, y) |> List.flatten() |> hd()

  test "down gradient (0°): top transparent, bottom opaque black" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 8, 0) > 230
    assert lum(out, 8, 15) < 25
  end

  test "left gradient (90°): right transparent, left opaque" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 90.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 15, 8) > 230
    assert lum(out, 0, 8) < 25
  end

  test "up gradient (180°): bottom transparent, top opaque" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 180.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 8, 15) > 230
    assert lum(out, 8, 0) < 25
  end

  test "right gradient (270°): left transparent, right opaque" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 270.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 0, 8) > 230
    assert lum(out, 15, 8) < 25
  end

  test "oblique 45° gradient (down-left): top-right transparent, bottom-left opaque" do
    # 45° clockwise from 0°=down points between down and left → direction (-√2/2, √2/2).
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 45.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 15, 0) > 230
    assert lum(out, 0, 15) < 25
    # the off-axis corners sit on the iso-line through the center → mid-gray
    mid = lum(out, 0, 0)
    assert mid > 80 and mid < 175
  end

  test "non-default start/stop keeps the top quarter fully transparent" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.25, stop: 0.75}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    # rows in p < 0.25 are untouched (white)
    assert lum(out, 8, 0) > 250
    assert lum(out, 8, 3) > 250
    # rows in p > 0.75 are fully black
    assert lum(out, 8, 13) < 5
    assert lum(out, 8, 15) < 5
  end

  test "degenerate start == stop is a hard step with no crash/NaN" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.5, stop: 0.5}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    # top half (p < 0.5) untouched, bottom half (p >= 0.5) full color
    assert lum(out, 8, 0) > 250
    assert lum(out, 8, 7) > 250
    assert lum(out, 8, 8) < 5
    assert lum(out, 8, 15) < 5
    # no NaN leaked through
    refute_nan(out)
  end

  test "partial opacity blends toward the color" do
    op = %Gradient{opacity: 0.5, color: [0, 0, 0], angle: 0.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    # bottom row: m = 0.5 → out = 255*0.5 ≈ 127
    bottom = lum(out, 8, 15)
    assert bottom > 110 and bottom < 145
  end

  defp refute_nan(image) do
    for x <- [0, 8, 15], y <- [0, 8, 15] do
      [v | _] = List.flatten(VipsImage.get_pixel!(image, x, y))
      assert v == v, "NaN at #{x},#{y}"
    end
  end
end
