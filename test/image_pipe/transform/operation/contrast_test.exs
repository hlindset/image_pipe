defmodule ImagePipe.Transform.Operation.ContrastTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "contrast of 1.0 is identity" do
    image = Image.new!(4, 4, color: [80, 80, 80], bands: 3)
    {:ok, %State{image: out}} = Contrast.execute(%Contrast{value: 1.0}, %State{image: image})
    assert List.flatten(VipsImage.get_pixel!(out, 0, 0)) == [80, 80, 80]
  end
end
