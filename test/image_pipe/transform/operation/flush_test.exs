defmodule ImagePipe.Transform.Operation.FlushTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.{PendingOrientation, State}

  test "quarter-turn flush swaps dims and clears pending" do
    {:ok, img} = Image.new(40, 30)
    state = %State{image: img, pending_orientation: %PendingOrientation{user_angle: 90}}

    {:ok, %State{image: out, pending_orientation: nil, materialized?: true}} =
      Flush.execute(%Flush{}, state)

    assert Image.width(out) == 30 and Image.height(out) == 40
  end

  test "nil pending is a plain copy, dims unchanged" do
    {:ok, img} = Image.new(40, 30)

    {:ok, %State{image: out}} =
      Flush.execute(%Flush{}, %State{image: img, pending_orientation: nil})

    assert Image.width(out) == 40 and Image.height(out) == 30
  end

  test "requires_materialization? is false (self-managing)" do
    refute Flush.requires_materialization?(%Flush{})
  end
end
