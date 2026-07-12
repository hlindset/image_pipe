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
    ImgproxyResolver.resolve(shape, carry, op)
  end

  # Deliberately pure destructuring: this asserts the carry rides in the data
  # tuple. Carry survival THROUGH the seam is pinned by the continue/4
  # assertion in the #237 test below.
  defp carry_of({:advance, _shape, carry}), do: carry
  defp carry_of({:measure, _tag, carry}), do: carry

  test "auto resize buckets landscape source x landscape target to cover (prepare.go:88-97)" do
    {:ok, op} = Operation.resize(:auto, {:px, 300}, {:px, 200})

    {[%Resize{mode: :fill} | _], _cont} =
      resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "auto resize buckets landscape source x portrait target to fit" do
    {:ok, op} = Operation.resize(:auto, {:px, 200}, {:px, 300})

    {[%Resize{mode: :fit} | _], _cont} =
      resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "a resize stashes the padding scales; a later padding consumes them (#237)" do
    {:ok, resize} = Operation.resize(:fit, {:px, 100}, {:px, 100}, dpr: 2)
    {_ops, cont} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)
    carry = carry_of(cont)

    assert %{effective_padding_scale: scale} = carry
    assert is_number(scale)

    {:ok, padding} =
      Operation.padding({:px, 10}, {:px, 10}, {:px, 10}, {:px, 10},
        pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
      )

    {[%Padding{top: top} | _], _cont} = resolve(shape(100, 75), carry, padding)
    assert top == round(10 * scale)

    # The seam re-attachment: continue/4 delegates the neutral tag and
    # re-attaches the carry, so the stash survives a measure.
    assert {%SourceShape{}, ^carry} =
             ImgproxyResolver.continue(:resize, {100, 75}, shape(800, 600), carry)
  end

  test "a geometry-less dpr caps the padding scale to 1.0 (#237)" do
    {:ok, resize} = Operation.resize(:fit, :auto, :auto, dpr: 2)
    {_ops, cont} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)
    assert carry_of(cont).effective_padding_scale == 1.0
  end
end
