defmodule ImagePipe.Dialect.TwicPics.PointFlowTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.PointFlow
  alias ImagePipe.Parser.TwicPics.Resolver, as: LegacyResolver
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize, as: ExecResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h, po \\ nil) do
    SourceShape.seed(%{width: w, height: h, pending_orientation: po, decode_shrink: nil})
  end

  defp resize(guide \\ :center) do
    %PlanResize{
      mode: :cover,
      width: {:px, 200},
      height: {:px, 100},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: guide
    }
  end

  test "set_focus resolves the operand into the local carry" do
    operand = {:coord, {:px, 200}, {:px, 150}}
    flow = PointFlow.set_focus(shape(800, 600), PointFlow.init(), operand)

    assert %PointFlow{guide: :point, point: {x, y}} = flow
    assert x == {:ratio, 200, 1}
    assert y == {:ratio, 150, 1}
  end

  test "a later set_focus overwrites the carried point" do
    flow =
      PointFlow.init()
      |> then(&PointFlow.set_focus(shape(800, 600), &1, {:coord, {:px, 5}, {:px, 5}}))
      |> then(&PointFlow.set_focus(shape(800, 600), &1, {:coord, {:px, 10}, {:px, 20}}))

    assert flow.point == {{:ratio, 10, 1}, {:ratio, 20, 1}}
  end

  test "auto focus preserves an old point and a later literal focus replaces it" do
    literal = {:coord, {:px, 10}, {:px, 20}}

    flow = PointFlow.set_focus(shape(800, 600), PointFlow.init(), literal)
    assert %PointFlow{guide: {:smart, :face_assist}, point: old_point} = PointFlow.set_auto(flow)
    assert old_point == {{:ratio, 10, 1}, {:ratio, 20, 1}}

    replaced =
      flow
      |> PointFlow.set_auto()
      |> then(&PointFlow.set_focus(shape(800, 600), &1, {:coord, {:px, 30}, {:px, 40}}))

    assert replaced == %PointFlow{
             guide: :point,
             point: {{:ratio, 30, 1}, {:ratio, 40, 1}}
           }
  end

  test "an ordinary neutral operation matches the legacy resolver" do
    {:ok, op} = Operation.blur(2.0)
    shape = shape(800, 600)

    assert PointFlow.resolve(shape, PointFlow.init(), {:operation, op}) ==
             legacy_resolve(shape, nil, op)
  end

  test "a staged cover binds a concrete point and translates the carry like legacy" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}
    flow = %PointFlow{guide: :point, point: point}
    shape = shape(400, 400)

    {[%ExecResize{}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, flow, {:focused, resize()})

    {[%Crop{gravity: gravity}], {:advance, _shape, carried_flow}} =
      PointFlow.continue(tag, {200, 200}, shape, seam)

    assert gravity == {:fp, 0.25, 0.25}
    assert carried_flow.point == {{:ratio, 50, 1}, {:ratio, 50, 1}}

    assert {[%ExecResize{}], {:measure, legacy_tag, legacy_seam}} =
             LegacyResolver.resolve(shape, point, resize(:deferred))

    assert {[%Crop{gravity: ^gravity}], {:advance, _shape, carried_point}} =
             LegacyResolver.continue(legacy_tag, {200, 200}, shape, legacy_seam)

    assert carried_flow.point == carried_point
  end

  test "a nil point binds the centred anchor" do
    shape = shape(400, 400)

    {[%ExecResize{}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, PointFlow.init(), {:focused, resize()})

    assert {[%Crop{gravity: {:anchor, :center, :center}}],
            {:advance, _shape, %PointFlow{point: nil}}} =
             PointFlow.continue(tag, {200, 200}, shape, seam)
  end

  test "a pending-orientation cover binds in storage and folds reflect_rotate like legacy" do
    po = PendingOrientation.from_exif(6, true)
    point = {{:ratio, 20, 1}, {:ratio, 36, 1}}
    flow = %PointFlow{guide: :point, point: point}
    shape = shape(40, 80, po)

    resize = %PlanResize{resize() | width: {:px, 20}, height: {:px, 20}}

    {[%ExecResize{mode: :force}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, flow, {:focused, resize})

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, advanced, carried_flow}} =
      PointFlow.continue(tag, {20, 40}, shape, seam)

    assert gravity == {:fp, 0.5, 0.45}
    assert carried_flow.point == {{:ratio, 10, 1}, {:ratio, 10, 1}}
    assert {advanced.width, advanced.height} == {20, 20}
    assert advanced.pending_orientation == nil

    {[%ExecResize{}], {:measure, legacy_tag, legacy_seam}} =
      LegacyResolver.resolve(shape, point, %PlanResize{resize | guide: :deferred})

    assert {legacy_ops, {:advance, legacy_shape, legacy_point}} =
             LegacyResolver.continue(legacy_tag, {20, 40}, shape, legacy_seam)

    assert [%Crop{gravity: ^gravity}, %Flush{}] = legacy_ops
    assert advanced == legacy_shape
    assert carried_flow.point == legacy_point
  end

  test "the flush fold moves an off-centre carry" do
    po = PendingOrientation.from_exif(6, true)
    point = {{:ratio, 20, 1}, {:ratio, 4, 1}}
    shape = shape(40, 80, po)
    flow = %PointFlow{guide: :point, point: point}
    resize = %PlanResize{resize() | width: {:px, 20}, height: {:px, 20}}

    {[%ExecResize{}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, flow, {:focused, resize})

    assert {[%Crop{gravity: {:fp, 0.5, 0.05}}, %Flush{}],
            {:advance, _shape, %PointFlow{point: carried}}} =
             PointFlow.continue(tag, {20, 40}, shape, seam)

    assert carried == {{:ratio, 18, 1}, {:ratio, 10, 1}}
  end

  test "smart mode passes the old point through the pixel-selected crop" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}
    flow = PointFlow.set_auto(%PointFlow{guide: :point, point: point})
    {:ok, op} = Operation.crop_guided({:px, 50}, {:px, 50}, :center)

    assert {[%Crop{gravity: {:smart, :face_assist}}],
            {:advance, _shape, %PointFlow{guide: {:smart, :face_assist}, point: ^point}}} =
             PointFlow.resolve(shape(400, 400), flow, {:focused, op})
  end

  test "a region crop resets auto to point mode and translates the carried point" do
    flow =
      PointFlow.init()
      |> then(&PointFlow.set_focus(shape(640, 480), &1, {:coord, {:px, 300}, {:px, 200}}))
      |> PointFlow.set_auto()

    {:ok, operation} =
      Operation.crop_region({:px, 100}, {:px, 100}, {:px, 500}, {:px, 300})

    assert {[
              %Crop{
                width: {:pixels, 500},
                height: {:pixels, 300},
                crop_from: %{left: {:pixels, 100}, top: {:pixels, 100}}
              }
            ],
            {:advance, _shape,
             %PointFlow{
               guide: :point,
               point: {{:ratio, 200, 1}, {:ratio, 100, 1}}
             }}} = PointFlow.resolve(shape(640, 480), flow, {:operation, operation})
  end

  test "a known point- and dims-neutral effect passes the carry unchanged" do
    point = {{:ratio, 10, 1}, {:ratio, 20, 1}}
    flow = %PointFlow{guide: :point, point: point}
    {:ok, operation} = Operation.blur(2.0)

    assert {[%Blur{sigma: 2.0}], {:advance, _shape, ^flow}} =
             PointFlow.resolve(shape(100, 100), flow, {:operation, operation})
  end

  test "raises for an unknown dims-changing operation" do
    assert_raise RuntimeError, ~r/Rotate/, fn ->
      PointFlow.resolve(
        shape(100, 100),
        PointFlow.init(),
        {:operation, %PlanRotate{angle: 45}}
      )
    end
  end

  test "raises for Trim" do
    operation = %PlanTrim{threshold: 1.0, background: :auto, equal_hor: false, equal_ver: false}

    assert_raise RuntimeError, ~r/Trim/, fn ->
      PointFlow.resolve(shape(100, 100), PointFlow.init(), {:operation, operation})
    end
  end

  test "raises for Padding" do
    operation = %PlanPadding{
      top: {:px, 0},
      right: {:px, 0},
      bottom: {:px, 0},
      left: {:px, 0},
      pixel_ratio: {:ratio, 1, 1},
      fill: :transparent
    }

    assert_raise RuntimeError, ~r/Padding/, fn ->
      PointFlow.resolve(shape(100, 100), PointFlow.init(), {:operation, operation})
    end
  end

  defp legacy_resolve(shape, point, operation) do
    case LegacyResolver.resolve(shape, point, operation) do
      {ops, {:advance, next_shape, next_point}} ->
        {ops, {:advance, next_shape, %PointFlow{guide: :point, point: next_point}}}

      {ops, {:measure, tag, seam}} ->
        {ops, {:measure, tag, seam}}
    end
  end
end
