defmodule ImagePipe.Transform.Operation.BitonalTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.State

  @rgb "priv/static/images/beach.jpg"

  defp state_from(path) do
    {:ok, image} = Image.open(path, access: :random)
    %State{image: image}
  end

  test "name/1 is :bitonal" do
    assert Bitonal.name(%Bitonal{}) == :bitonal
  end

  test "thresholds to pure black/white: every sampled luminance is 0 or 255" do
    {:ok, %State{image: out}} = Bitonal.execute(%Bitonal{}, state_from(@rgb))
    {w, h} = {Image.width(out), Image.height(out)}

    for {x, y} <- [{0, 0}, {div(w, 3), div(h, 3)}, {div(w, 2), div(h, 2)}, {w - 1, h - 1}] do
      [lum | _] = Image.get_pixel!(out, x, y)
      assert lum in [0, 255], "pixel at (#{x},#{y}) not bitonal: #{lum}"
    end
  end

  @rgba "test/support/image_pipe/test/sources/alpha.png"

  test "preserves the alpha band untouched (does not threshold alpha)" do
    {:ok, src} = Image.open(@rgba, access: :random)
    assert Image.has_alpha?(src)

    {:ok, %State{image: out}} = Bitonal.execute(%Bitonal{}, %State{image: src})
    assert Image.has_alpha?(out)

    {w, h} = {Image.width(out), Image.height(out)}

    for {x, y} <- [{0, 0}, {div(w, 2), div(h, 2)}, {w - 1, h - 1}] do
      [lum | _] = out_px = Image.get_pixel!(out, x, y)
      # luminance band thresholded to 0/255; alpha band identical to the source.
      assert lum in [0, 255]
      assert List.last(out_px) == List.last(Image.get_pixel!(src, x, y))
    end
  end
end
