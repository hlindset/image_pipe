defmodule ImagePipe.Parser.TwicPics.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Resolver, as: TwicPicsResolver
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Directive
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize, as: ExecResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h, po \\ nil) do
    SourceShape.seed(%{width: w, height: h, pending_orientation: po, decode_shrink: nil})
  end

  test "set_focus resolves the operand into the carry with zero ops" do
    op = %Directive{name: :set_focus, payload: {:coord, {:px, 200}, {:px, 150}}}

    assert {[], {:advance, returned_shape, {x, y}}} =
             TwicPicsResolver.resolve(shape(800, 600), nil, op)

    assert returned_shape == shape(800, 600)
    assert x == {:ratio, 200, 1}
    assert y == {:ratio, 150, 1}
  end

  test "a later set_focus overwrites the carried point" do
    op = %Directive{name: :set_focus, payload: {:coord, {:px, 10}, {:px, 20}}}

    assert {[], {:advance, _shape, {x, y}}} =
             TwicPicsResolver.resolve(shape(800, 600), {{:ratio, 5, 1}, {:ratio, 5, 1}}, op)

    assert {x, y} == {{:ratio, 10, 1}, {:ratio, 20, 1}}
  end

  test "delegated ops still match the neutral resolution for a nil point" do
    {:ok, op} = Operation.blur(2.0)

    {neutral_ops, {:advance, neutral_shape, nil}} =
      NeutralResolver.resolve(shape(800, 600), nil, op)

    assert {^neutral_ops, {:advance, ^neutral_shape, nil}} =
             TwicPicsResolver.resolve(shape(800, 600), nil, op)
  end

  # focus (100,100) on a 400x400 source, cover=200x100 (staged [resize] ->
  # seam -> [crop]): the cover intermediate is 200x200 (injected at the seam),
  # so the point scales to (50,50) and the crop's :carried gravity substitutes
  # to fp (0.25, 0.25) against the 200x200 intermediate. The 200x100 box crops
  # at origin (0, 0) — round_ties_to_even(0.25*200 - 100) = -50 clamps to 0,
  # round_ties_to_even(0.25*200 - 50) = 0 — so the carry stays (50, 50).
  test "a staged cover substitutes :carried to a concrete fp and translates the carry" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 200},
      height: {:px, 100},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{}], {:acquire, stage}} =
      TwicPicsResolver.resolve(shape(400, 400), point, resize)

    {[%Crop{gravity: gravity}], {:advance, _shape, carried}} = stage.({200, 200})

    assert gravity == {:fp, 0.25, 0.25}
    assert carried == {{:ratio, 50, 1}, {:ratio, 50, 1}}
  end

  test "a nil point substitutes the centred anchor (the hot fallback path)" do
    resize = %PlanResize{
      mode: :cover,
      width: {:px, 200},
      height: {:px, 100},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{}], {:acquire, stage}} = TwicPicsResolver.resolve(shape(400, 400), nil, resize)
    {[%Crop{gravity: gravity}], {:advance, _shape, nil}} = stage.({200, 200})

    assert gravity == {:anchor, :center, :center}
  end

  # Under a pending quarter turn the stage is [crop, Flush]: the fp substitutes
  # against the storage-frame point BEFORE the flush (never gravity-remapped —
  # compensate_crop's :carried clause), and the carry reflect-rotates with the
  # flush. Storage 40x80 EXIF-6 source, point (20, 36) storage-frame,
  # cover=20x20 -> forcing resize to storage 20x40 (injected), point scales to
  # (10, 18), fp (0.5, 0.45); the 20x20 box (display->storage swap is identity
  # for a square) crops at top = round_ties_to_even(0.45*40 - 10) = 8 ->
  # carry (10, 10); the flush maps fraction (0.5, 0.5) by rotate-90 to
  # (0.5, 0.5) on the swapped 20x20 frame -> carry (10, 10).
  test "a pending-orientation cover substitutes storage-frame fp and folds reflect_rotate" do
    po = %PendingOrientation{auto_rotate?: true, exif_angle: 90}
    point = {{:ratio, 20, 1}, {:ratio, 36, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 20},
      height: {:px, 20},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{mode: :force}], {:acquire, stage}} =
      TwicPicsResolver.resolve(shape(40, 80, po), point, resize)

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, advanced, carried}} = stage.({20, 40})

    assert gravity == {:fp, 0.5, 0.45}
    assert carried == {{:ratio, 10, 1}, {:ratio, 10, 1}}
    assert {advanced.width, advanced.height} == {20, 20}
    assert advanced.pending_orientation == nil
  end

  # The reflect fold, discriminated: an UNCLAMPED fp crop always centres the
  # carry, and the centre is a fixed point of reflect_rotate — so this case
  # uses a point whose crop origin CLAMPS (top round_ties_to_even(0.05*40 - 10)
  # = -8 -> 0), leaving the off-centre carry (10, 2) that the flush must
  # actually move: fractions (0.5, 0.1) rotate-90 to (0.9, 0.5) on the swapped
  # 20x20 frame -> (18, 10). A dropped/mis-framed %Flush{} step yields (10, 2).
  test "the flush fold moves an off-centre carry" do
    po = %PendingOrientation{auto_rotate?: true, exif_angle: 90}
    point = {{:ratio, 20, 1}, {:ratio, 4, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 20},
      height: {:px, 20},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{mode: :force}], {:acquire, stage}} =
      TwicPicsResolver.resolve(shape(40, 80, po), point, resize)

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, _advanced, carried}} = stage.({20, 40})

    assert gravity == {:fp, 0.5, 0.05}
    assert carried == {{:ratio, 18, 1}, {:ratio, 10, 1}}
  end

  # The Pinned-behavior-1 decision record: a smart/detect-gravity crop never
  # advances the point (it passes through unchanged, not nil'ed). This is the
  # plan's one deliberate, detector-gated divergence — at resolve time the
  # detection outcome does not exist, so the old success-path translate cannot
  # be reproduced. Documented in docs/twicpics_support_matrix.md.
  test "a smart-gravity crop passes the point through unchanged" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}
    {:ok, op} = Operation.crop_guided({:px, 50}, {:px, 50}, {:smart, :face_assist})

    {[%Crop{gravity: {:smart, :face_assist}}], {:advance, _shape, carried}} =
      TwicPicsResolver.resolve(shape(400, 400), point, op)

    assert carried == point
  end
end
