defmodule ImagePipe.Transform.Operation.SaturationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "saturation of 1.0 is identity on a colorful pixel" do
    image = Image.new!(4, 4, color: [200, 40, 40], bands: 3)
    {:ok, %State{image: out}} = Saturation.execute(%Saturation{value: 1.0}, %State{image: image})
    [r, g, b] = List.flatten(VipsImage.get_pixel!(out, 0, 0))
    assert_in_delta r, 200, 2
    assert_in_delta g, 40, 2
    assert_in_delta b, 40, 2
  end
end
