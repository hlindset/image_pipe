defmodule ImagePipe.Transform.ResizeExecuteTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  test "execute resizes decoded pixels and clears the preshrink coordinate frame" do
    {:ok, shrunk_image} = Image.new(375, 250, color: [128, 128, 128])

    state = %State{
      image: shrunk_image,
      source_dimensions: {3000, 2000},
      decode_shrink: %{w: 8.0, h: 8.0}
    }

    operation = %Resize{width: 300, height: 200}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    # The residual resize has finished the downscale: source_dimensions clears.
    assert new_state.source_dimensions == nil
    assert new_state.decode_shrink == nil
  end

  test "execute with no shrink (source_dimensions nil) resizes straight from the image dims" do
    {:ok, image} = Image.new(375, 250, color: [128, 128, 128])
    state = %State{image: image, source_dimensions: nil}

    operation = %Resize{width: 300, height: 200}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    assert new_state.source_dimensions == nil
  end
end
