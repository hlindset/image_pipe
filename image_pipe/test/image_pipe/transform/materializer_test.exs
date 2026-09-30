defmodule ImagePipe.Transform.MaterializerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.{Materializer, PendingOrientation, State}

  test "materialize/1 returns a memory-resident State with materialized?: true" do
    {:ok, image} = Image.new(32, 24, color: :white)
    state = %State{image: image, materialized?: false}

    assert {:ok, %State{} = result} = Materializer.materialize(state)
    assert result.materialized? == true
    assert Image.width(result.image) == 32
    assert Image.height(result.image) == 24
  end

  test "no pending: copy_memory only, sets materialized?, leaves pending nil" do
    state = %State{image: Image.new!(10, 10, color: :red), materialized?: false}

    assert {:ok, %State{materialized?: true, pending_orientation: nil}} =
             Materializer.materialize(state)
  end

  test "pending set: copy-only — orientation untouched, pending kept" do
    base = Image.set_orientation!(Image.new!(40, 20, color: :red), 6)
    po = PendingOrientation.from_exif(6, true)
    state = %State{image: base, pending_orientation: po, materialized?: false}

    assert {:ok, %State{} = result} = Materializer.materialize(state)
    assert result.materialized? == true
    assert result.pending_orientation == po
    assert {Image.width(result.image), Image.height(result.image)} == {40, 20}
  end
end
