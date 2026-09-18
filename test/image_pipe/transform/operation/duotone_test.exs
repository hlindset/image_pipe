defmodule ImagePipe.Transform.Operation.DuotoneTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @duotone %Duotone{intensity: 0.8, shadow: [10, 20, 30], highlight: [220, 230, 240]}
  @monochrome %Monochrome{intensity: 0.8, color: [179, 179, 179]}

  test "gray and bitonal outputs feed monochrome and duotone while preserving alpha" do
    source = Image.new!(7, 5, color: [120, 80, 40, 97], bands: 4)

    for producer <- [%Gray{}, %Bitonal{}], effect <- [@monochrome, @duotone] do
      assert {:ok, %State{image: one_colour}} =
               ImagePipe.Transform.execute(producer, %State{image: source})

      assert VipsImage.bands(one_colour) == 2

      assert {:ok, %State{image: output}} =
               ImagePipe.Transform.execute(effect, %State{image: one_colour})

      assert VipsImage.bands(output) == 4
      assert List.last(Image.get_pixel!(output, 3, 2)) == 97
    end
  end
end
