defmodule ImagePipe.Transform.Operation.ColorizeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "50% black overlay halves a white pixel" do
    image = Image.new!(4, 4, color: [255, 255, 255], bands: 3)
    op = %Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: false}
    {:ok, %State{image: out}} = Colorize.execute(op, %State{image: image})
    [r, g, b] = List.flatten(VipsImage.get_pixel!(out, 0, 0))
    assert_in_delta r, 128, 2
    assert_in_delta g, 128, 2
    assert_in_delta b, 128, 2
  end

  # Build a 4-band RGBA source (semi-transparent) to pin the keep_alpha contract.
  defp rgba_source, do: Image.new!(4, 4, color: [255, 255, 255, 128], bands: 4)

  test "keep_alpha: false (default) drops alpha → opaque 3-band result" do
    op = %Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: false}
    {:ok, %State{image: out}} = Colorize.execute(op, %State{image: rgba_source()})
    refute Image.has_alpha?(out)
    assert VipsImage.bands(out) == 3
  end

  test "keep_alpha: true preserves the source alpha band" do
    op = %Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: true}
    {:ok, %State{image: out}} = Colorize.execute(op, %State{image: rgba_source()})
    assert Image.has_alpha?(out)
    [_r, _g, _b, a] = List.flatten(VipsImage.get_pixel!(out, 0, 0))
    assert_in_delta a, 128, 2
  end
end
