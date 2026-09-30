defmodule ImagePipe.Transform.Operation.BrightnessTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp mid_gray, do: Image.new!(4, 4, color: [128, 128, 128], bands: 3)

  test "positive brightness adds toward white" do
    {:ok, %State{image: out}} =
      Brightness.execute(%Brightness{value: 50}, %State{image: mid_gray()})

    [r, _g, _b] = flat_pixel(out, 0, 0)
    assert r > 170 and r < 190
  end

  test "zero brightness is identity" do
    {:ok, %State{image: out}} =
      Brightness.execute(%Brightness{value: 0}, %State{image: mid_gray()})

    assert flat_pixel(out, 0, 0) == [128, 128, 128]
  end

  test "additive offset saturates at 255, not wraps" do
    light = Image.new!(4, 4, color: [200, 200, 200], bands: 3)
    {:ok, %State{image: out}} = Brightness.execute(%Brightness{value: 100}, %State{image: light})
    assert flat_pixel(out, 0, 0) == [255, 255, 255]
  end

  test "additive offset floors at 0, not wraps" do
    dark = Image.new!(4, 4, color: [40, 40, 40], bands: 3)
    {:ok, %State{image: out}} = Brightness.execute(%Brightness{value: -100}, %State{image: dark})
    assert flat_pixel(out, 0, 0) == [0, 0, 0]
  end

  defp flat_pixel(image, x, y), do: image |> VipsImage.get_pixel!(x, y) |> List.flatten()
end
