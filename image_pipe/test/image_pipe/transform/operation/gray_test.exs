defmodule ImagePipe.Transform.Operation.GrayTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.State

  @rgb "priv/static/images/beach.jpg"

  defp state_from(path) do
    {:ok, image} = Image.open(path, access: :random)
    %State{image: image}
  end

  test "desaturates: R, G, B bands are equal at sampled points" do
    {:ok, %State{image: out}} = Gray.execute(%Gray{}, state_from(@rgb))
    {:ok, srgb} = Image.to_colorspace(out, :srgb)

    for {x, y} <- [{0, 0}, {10, 10}, {50, 40}] do
      {:ok, [r, g, b | _]} = Image.get_pixel(srgb, x, y)
      assert r == g and g == b
    end
  end

  @rgba "test/support/image_pipe/test/sources/alpha.png"

  test "preserves an alpha band (RGBA -> 2-band B_W + alpha)" do
    {:ok, image} = Image.open(@rgba, access: :random)
    assert Image.has_alpha?(image)
    {:ok, %State{image: out}} = Gray.execute(%Gray{}, %State{image: image})
    assert Image.has_alpha?(out)
  end
end
