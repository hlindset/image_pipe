defmodule ImagePipe.Transform.Operation.DuotoneTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @duotone %Duotone{intensity: 0.8, shadow: [10, 20, 30], highlight: [220, 230, 240]}
  @neutral %Duotone{intensity: 0.8, shadow: [0, 0, 0], highlight: [179, 179, 179]}

  test "gray and bitonal outputs feed neutral and colored duotones while preserving alpha" do
    # A neutral color keeps the gray frame, a colored one promotes it to RGB.
    source = Image.new!(7, 5, color: [120, 80, 40, 97], bands: 4)

    for %producer_module{} = producer <- [%Gray{}, %Bitonal{}],
        {%effect_module{} = effect, bands} <- [{@neutral, 2}, {@duotone, 4}] do
      assert {:ok, %State{image: one_colour}} =
               producer_module.execute(producer, %State{image: source})

      assert VipsImage.bands(one_colour) == 2

      assert {:ok, %State{image: output}} =
               effect_module.execute(effect, %State{image: one_colour})

      assert VipsImage.bands(output) == bands
      assert List.last(Image.get_pixel!(output, 3, 2)) == 97
    end
  end
end
