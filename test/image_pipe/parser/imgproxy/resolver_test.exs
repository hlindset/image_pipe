defmodule ImagePipe.Parser.Imgproxy.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.Imgproxy.Resolver, as: ImgproxyResolver
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h) do
    SourceShape.seed(%{width: w, height: h, pending_orientation: nil, decode_shrink: nil})
  end

  defp resolve(shape, carry, op) do
    ImgproxyResolver.resolve(shape, %{}, carry, op)
  end

  test "auto resize buckets landscape source x landscape target to cover (prepare.go:88-97)" do
    {:ok, op} = Operation.resize(:auto, {:px, 300}, {:px, 200})

    {[%Resize{mode: :fill} | _], _cont, _carry} =
      resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "auto resize buckets landscape source x portrait target to fit" do
    {:ok, op} = Operation.resize(:auto, {:px, 200}, {:px, 300})

    {[%Resize{mode: :fit} | _], _cont, _carry} =
      resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "a resize stashes the padding scales; a later padding consumes them (#237)" do
    {:ok, resize} = Operation.resize(:fit, {:px, 100}, {:px, 100}, dpr: 2)
    {_ops, _cont, carry} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)

    assert %{effective_padding_scale: scale} = carry
    assert is_number(scale)

    {:ok, padding} =
      Operation.padding({:px, 10}, {:px, 10}, {:px, 10}, {:px, 10},
        pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
      )

    {[%Padding{top: top} | _], _cont, _carry} = resolve(shape(100, 75), carry, padding)
    assert top == round(10 * scale)
  end

  test "a geometry-less dpr caps the padding scale to 1.0 (#237)" do
    {:ok, resize} = Operation.resize(:fit, :auto, :auto, dpr: 2)
    {_ops, _cont, carry} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)
    assert carry.effective_padding_scale == 1.0
  end
end
