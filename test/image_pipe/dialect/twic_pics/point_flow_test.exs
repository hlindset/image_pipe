defmodule ImagePipe.Dialect.TwicPics.PointFlowTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.PointFlow
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.NeutralResolver
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

  test "an ordinary neutral operation delegates to the neutral resolver" do
    {:ok, op} = Operation.blur(2.0)
    shape = shape(800, 600)

    assert {neutral_ops, {:advance, neutral_shape, nil}} =
             NeutralResolver.resolve(shape, nil, op)

    assert {^neutral_ops, {:advance, ^neutral_shape, %PointFlow{guide: :point, point: nil}}} =
             PointFlow.resolve(shape, PointFlow.init(), {:operation, op})
  end

  test "a staged cover binds a concrete point and advances its measured shape" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}
    flow = %PointFlow{guide: :point, point: point}
    shape = shape(400, 400)

    {[%ExecResize{}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, flow, {:focused, resize()})

    {[%Crop{gravity: gravity}], {:advance, advanced, carried_flow}} =
      PointFlow.continue(tag, {200, 200}, shape, seam)

    assert gravity == {:fp, 0.25, 0.25}
    assert carried_flow.point == {{:ratio, 50, 1}, {:ratio, 50, 1}}

    assert advanced == %SourceShape{
             width: 200,
             height: 100,
             frame: :storage,
             pending_orientation: nil,
             decode_shrink: nil
           }
  end

  test "a nil point binds the centred anchor" do
    shape = shape(400, 400)

    {[%ExecResize{}], {:measure, tag, seam}} =
      PointFlow.resolve(shape, PointFlow.init(), {:focused, resize()})

    assert {[%Crop{gravity: {:anchor, :center, :center}}],
            {:advance, _shape, %PointFlow{point: nil}}} =
             PointFlow.continue(tag, {200, 200}, shape, seam)
  end

  test "a pending-orientation cover binds in storage and folds reflect_rotate" do
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

    assert advanced == %SourceShape{
             width: 20,
             height: 20,
             frame: :display,
             pending_orientation: nil,
             decode_shrink: nil
           }
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

  test "raises for a dimension-changing operation without an explicit point rule" do
    {:ok, operation} = Operation.rotate(45)

    assert_raise RuntimeError, ~r/Rotate/, fn ->
      PointFlow.resolve(shape(100, 100), PointFlow.init(), {:operation, operation})
    end
  end

  test "raises for trim without an explicit point rule" do
    {:ok, operation} = Operation.trim(threshold: 1.0, background: :auto)

    assert_raise RuntimeError, ~r/Trim/, fn ->
      PointFlow.resolve(shape(100, 100), PointFlow.init(), {:operation, operation})
    end
  end

  test "raises for padding without an explicit point rule" do
    {:ok, operation} =
      Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})

    assert_raise RuntimeError, ~r/Padding/, fn ->
      PointFlow.resolve(shape(100, 100), PointFlow.init(), {:operation, operation})
    end
  end
end
