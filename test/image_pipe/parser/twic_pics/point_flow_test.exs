defmodule ImagePipe.Parser.TwicPics.PointFlowTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.PointFlow
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h),
    do: SourceShape.seed(%{width: w, height: h, pending_orientation: nil, decode_shrink: nil})

  defp continuation(shape), do: {:advance, shape, nil}

  test "a known point- and dims-neutral effect passes the carried point through unchanged" do
    point = {{:ratio, 10, 1}, {:ratio, 20, 1}}
    shape = shape(100, 100)

    assert {[%Blur{sigma: 2.0}], {:advance, _shape, ^point}} =
             PointFlow.advance([%Blur{sigma: 2.0}], continuation(shape), point, shape)
  end

  # Guards the architecture-review invariant (#447): a dims-changing executable
  # that PointFlow does not know how to advance the point through must fail
  # loudly rather than silently carry the point through unchanged.
  test "raises for a dims-changing op it has no explicit advance rule for" do
    shape = shape(100, 100)
    point = {{:ratio, 10, 1}, {:ratio, 20, 1}}

    assert_raise RuntimeError, ~r/Rotate/, fn ->
      PointFlow.advance([%Rotate{angle: 45}], continuation(shape), point, shape)
    end
  end

  test "raises for Trim" do
    shape = shape(100, 100)
    point = {{:ratio, 10, 1}, {:ratio, 20, 1}}

    op = %Trim{threshold: nil, background: nil, equal_hor: false, equal_ver: false}

    assert_raise RuntimeError, ~r/Trim/, fn ->
      PointFlow.advance([op], continuation(shape), point, shape)
    end
  end

  test "raises for Padding" do
    shape = shape(100, 100)
    point = {{:ratio, 10, 1}, {:ratio, 20, 1}}

    op = %Padding{top: 0, right: 0, bottom: 0, left: 0, fill: [0, 0, 0, 0]}

    assert_raise RuntimeError, ~r/Padding/, fn ->
      PointFlow.advance([op], continuation(shape), point, shape)
    end
  end
end
