defmodule ImagePipe.Transform.NeutralResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Trim
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  defp env_for(width, height) do
    {:ok, img} = Image.new(width, height)

    %{
      state: %State{image: img, source_dimensions: {width, height}},
      ctx: %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}
    }
  end

  setup do
    shape =
      SourceShape.seed(%{width: 100, height: 80, pending_orientation: nil, decode_shrink: nil})

    %{env: env_for(100, 80), shape: shape}
  end

  defp put_pending(%{state: %State{} = state} = env, po),
    do: %{env | state: %State{state | pending_orientation: po}}

  defp padding_op do
    %Padding{
      top: {:px, 2},
      right: {:px, 2},
      bottom: {:px, 2},
      left: {:px, 2},
      pixel_ratio: {:ratio, 1, 1},
      fill: :transparent
    }
  end

  test "trim → :acquire, pending kept, storage frame, no Flush", %{shape: s, env: e} do
    {ops, {:acquire, then_fn}, nil} =
      NeutralResolver.resolve(s, e, nil, %Trim{
        threshold: 10,
        background: :auto,
        equal_hor: false,
        equal_ver: false
      })

    assert [%ImagePipe.Transform.Operation.Trim{}] = ops
    {shape2, nil} = then_fn.({90, 70})
    assert shape2.frame == :storage and shape2.width == 90
  end

  test "trim under a non-identity pending keeps the pending on the shape", %{env: e} do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})
    e = put_pending(e, po)

    {ops, {:acquire, then_fn}, nil} =
      NeutralResolver.resolve(s, e, nil, %Trim{
        threshold: 10,
        background: :auto,
        equal_hor: false,
        equal_ver: false
      })

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    {shape2, nil} = then_fn.({90, 70})
    assert shape2.frame == :storage
    assert shape2.pending_orientation == po
    assert shape2.decode_shrink == nil
  end

  test "effect (blur) → :advance, dims unchanged, no Flush", %{shape: s, env: e} do
    {ops, {:advance, %SourceShape{width: 100, height: 80}, nil}, nil} =
      NeutralResolver.resolve(s, e, nil, %Blur{sigma: 1.0})

    assert [%ImagePipe.Transform.Operation.Blur{}] = ops
  end

  test "identity pending: no Flush emitted, pending cleared on the shape", %{env: e} do
    identity = PendingOrientation.from_exif(1, true)

    s =
      SourceShape.seed(%{
        width: 100,
        height: 80,
        pending_orientation: identity,
        decode_shrink: nil
      })

    e = put_pending(e, identity)

    {ops, {:advance, shape2, nil}, nil} = NeutralResolver.resolve(s, e, nil, padding_op())

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    assert shape2.pending_orientation == nil
    assert {shape2.width, shape2.height} == {104, 84}
  end

  test "padding under a non-identity pending flushes first, display-frame dims", %{env: e} do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})
    e = put_pending(e, po)

    {ops, {:advance, shape2, nil}, nil} = NeutralResolver.resolve(s, e, nil, padding_op())

    assert [%Flush{}, %ImagePipe.Transform.Operation.Padding{}] = ops
    assert shape2.pending_orientation == nil
    assert shape2.frame == :display
    # quarter turn: 100x80 storage displays as 80x100, plus 2px on each side
    assert {shape2.width, shape2.height} == {84, 104}
  end

  test "right-angle rotate folds into the pending with zero ops", %{shape: s, env: e} do
    {[], {:advance, shape2, nil}, nil} =
      NeutralResolver.resolve(s, e, nil, %PlanRotate{angle: 90, mirror: false})

    assert %PendingOrientation{user_angle: 90} = shape2.pending_orientation
    assert {shape2.width, shape2.height} == {100, 80}
  end

  test "resize under a non-identity pending emits a trailing Flush and acquires", %{env: e} do
    po = PendingOrientation.from_exif(3, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})
    e = put_pending(e, po)

    resize = %PlanResize{
      mode: :fit,
      width: {:px, 50},
      height: {:px, 40},
      dpr: {:ratio, 1, 1},
      enlargement: :forbid,
      guide: :center
    }

    {ops, {:acquire, then_fn}, nil} = NeutralResolver.resolve(s, e, nil, resize)

    assert %Flush{} = List.last(ops)
    assert [%ImagePipe.Transform.Operation.Resize{} | _] = ops
    {shape2, nil} = then_fn.({50, 40})
    assert shape2.frame == :display
    assert shape2.pending_orientation == nil
    assert shape2.decode_shrink == nil
    assert {shape2.width, shape2.height} == {50, 40}
  end

  test "resize with no pending emits no Flush and keeps the frame", %{shape: s, env: e} do
    resize = %PlanResize{
      mode: :fit,
      width: {:px, 50},
      height: {:px, 40},
      dpr: {:ratio, 1, 1},
      enlargement: :forbid,
      guide: :center
    }

    {ops, {:acquire, then_fn}, nil} = NeutralResolver.resolve(s, e, nil, resize)

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    {shape2, nil} = then_fn.({50, 40})
    assert shape2.frame == :storage
    assert shape2.decode_shrink == nil
  end

  test "region crop under a non-identity pending flushes before the crop", %{env: e} do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})
    e = put_pending(e, po)

    crop = %CropRegion{x: {:px, 0}, y: {:px, 0}, width: {:px, 30}, height: {:px, 20}}

    {ops, {:advance, shape2, nil}, nil} = NeutralResolver.resolve(s, e, nil, crop)

    assert [%Flush{}, %ImagePipe.Transform.Operation.Crop{}] = ops
    assert shape2.pending_orientation == nil
    assert shape2.frame == :display
    assert shape2.decode_shrink == nil
    assert {shape2.width, shape2.height} == {30, 20}
  end
end
