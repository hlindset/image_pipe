defmodule ImagePipe.ResolverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Resolver
  alias ImagePipe.Transform.SourceShape

  defmodule Dummy do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: %{n: 0}
    @impl true
    def behavior_version, do: 1
    @impl true
    def resolve(%SourceShape{} = shape, %{n: n}, op),
      do: {[{:emitted, op}], {:advance, shape, %{n: n + 1}}}
  end

  test "facade dispatches, threads strategy_state via the continuation" do
    shape =
      SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

    {ops, cont} = Resolver.resolve({Dummy, Dummy.init()}, shape, :op)
    assert ops == [{:emitted, :op}]
    assert {:advance, ^shape, %{n: 1}} = cont
  end

  describe "rewrap/2" do
    setup do
      shape =
        SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

      %{shape: shape, carry: %{scale: 2.5}}
    end

    test "substitutes the carry into a stateless :advance", %{shape: shape, carry: carry} do
      assert Resolver.rewrap({:advance, shape, nil}, carry) == {:advance, shape, carry}
    end

    test "re-attaches the carry after a :measure resolves to a final shape",
         %{shape: shape, carry: carry} do
      continuation = {:measure, fn {5, 5} -> {shape, nil} end}

      assert {:measure, after_measure} = Resolver.rewrap(continuation, carry)
      assert after_measure.({5, 5}) == {shape, carry}
    end

    test "re-wraps the continuation of a staged expansion", %{shape: shape, carry: carry} do
      continuation = {:measure, fn {5, 5} -> {[:stage_op], {:advance, shape, nil}} end}

      assert {:measure, after_measure} = Resolver.rewrap(continuation, carry)
      assert after_measure.({5, 5}) == {[:stage_op], {:advance, shape, carry}}
    end

    test "carries through every stage of a nested :measure expansion",
         %{shape: shape, carry: carry} do
      continuation =
        {:measure,
         fn {5, 5} ->
           {[:stage_one], {:measure, fn {3, 3} -> {[:stage_two], {:advance, shape, nil}} end}}
         end}

      assert {:measure, outer} = Resolver.rewrap(continuation, carry)
      assert {[:stage_one], {:measure, inner}} = outer.({5, 5})
      assert inner.({3, 3}) == {[:stage_two], {:advance, shape, carry}}
    end
  end
end
