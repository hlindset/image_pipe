defmodule ImagePipe.Parser.TwicPics.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Resolver, as: TwicPicsResolver
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.SourceShape

  test "resolves a focus operand against the shape and commits via StateUpdate" do
    shape =
      SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})

    op = %SetFocus{point: {:coord, {:px, 200}, {:px, 150}}}

    {[%StateUpdate{fields: %{focus: {x, y}}}], {:advance, ^shape, nil}} =
      TwicPicsResolver.resolve(shape, nil, op)

    assert x == {:ratio, 200, 1}
    assert y == {:ratio, 150, 1}
  end

  test "delegates non-focus ops to the neutral resolver" do
    shape =
      SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})

    {:ok, op} = Operation.blur(2.0)

    assert TwicPicsResolver.resolve(shape, nil, op) ==
             NeutralResolver.resolve(shape, nil, op)
  end
end
