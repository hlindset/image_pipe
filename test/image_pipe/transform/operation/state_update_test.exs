defmodule ImagePipe.Transform.Operation.StateUpdateTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.State

  test "merges fields into State without touching the image" do
    {:ok, img} = Image.new(4, 4)
    state = %State{image: img}

    {:ok, %State{carried_point: {:fp, 0.25, 0.75}, image: ^img}} =
      StateUpdate.execute(%StateUpdate{fields: %{carried_point: {:fp, 0.25, 0.75}}}, state)
  end

  test "requires_materialization? is false" do
    refute StateUpdate.requires_materialization?(%StateUpdate{fields: %{}})
  end
end
