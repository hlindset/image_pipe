defmodule ImagePipe.Transform.SourceShapeTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{PendingOrientation, SourceShape}

  test "seed builds a storage-frame shape" do
    po = PendingOrientation.from_exif(6, true)

    shape =
      SourceShape.seed(%{
        width: 4000,
        height: 3000,
        pending_orientation: po,
        decode_shrink: %{w: 2.0, h: 2.0}
      })

    assert %SourceShape{
             width: 4000,
             height: 3000,
             frame: :storage,
             pending_orientation: ^po,
             decode_shrink: %{w: 2.0, h: 2.0}
           } = shape
  end

  test "quarter_turn? reflects pending, false when nil" do
    q =
      SourceShape.seed(%{
        width: 10,
        height: 10,
        pending_orientation: PendingOrientation.from_exif(6, true),
        decode_shrink: nil
      })

    h =
      SourceShape.seed(%{
        width: 10,
        height: 10,
        pending_orientation: PendingOrientation.from_exif(3, true),
        decode_shrink: nil
      })

    n = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    assert SourceShape.quarter_turn?(q)
    refute SourceShape.quarter_turn?(h)
    refute SourceShape.quarter_turn?(n)
  end

  describe "live_dims/1" do
    test "returns the shape dims when no shrink is outstanding" do
      shape =
        ImagePipe.Transform.SourceShape.seed(%{
          width: 800,
          height: 600,
          pending_orientation: nil,
          decode_shrink: nil
        })

      assert ImagePipe.Transform.SourceShape.live_dims(shape) == {800, 600}
    end

    test "round-trips the decoded extent through the realized shrink factor" do
      # original 1000x750 decoded at shrink 4.0 -> live 250x188 (factor = original / decoded)
      shape =
        ImagePipe.Transform.SourceShape.seed(%{
          width: 1000,
          height: 750,
          pending_orientation: nil,
          decode_shrink: %{w: 1000 / 250, h: 750 / 188}
        })

      assert ImagePipe.Transform.SourceShape.live_dims(shape) == {250, 188}
    end
  end
end
