defmodule ImagePipe.Transform.SourceShapeTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{PendingOrientation, SourceShape}

  test "seed builds a storage-frame shape" do
    po = PendingOrientation.from_exif(6, true)
    shape = SourceShape.seed(%{width: 4000, height: 3000, pending_orientation: po, decode_shrink: %{w: 2.0, h: 2.0}})
    assert %SourceShape{width: 4000, height: 3000, frame: :storage, pending_orientation: ^po, decode_shrink: %{w: 2.0, h: 2.0}} = shape
  end

  test "quarter_turn? reflects pending, false when nil" do
    q = SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(6, true), decode_shrink: nil})
    h = SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(3, true), decode_shrink: nil})
    n = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    assert SourceShape.quarter_turn?(q)
    refute SourceShape.quarter_turn?(h)
    refute SourceShape.quarter_turn?(n)
  end
end
