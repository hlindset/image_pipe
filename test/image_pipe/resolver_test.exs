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

    @impl true
    def continue({:finish, extra}, {w, h}, %SourceShape{} = shape, %{n: n}),
      do: {%{shape | width: w, height: h}, %{n: n + extra}}
  end

  setup do
    shape =
      SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

    %{shape: shape}
  end

  test "resolve/3 dispatches, threads strategy_state via the continuation", %{shape: shape} do
    {ops, cont} = Resolver.resolve({Dummy, Dummy.init()}, shape, :op)
    assert ops == [{:emitted, :op}]
    assert {:advance, ^shape, %{n: 1}} = cont
  end

  test "continue/5 dispatches with the continuation-carried state, not the strategy tuple's",
       %{shape: shape} do
    # The strategy tuple carries the stale resolve-time state; the state that
    # travels is the one in the {:measure, tag, state} continuation.
    assert {%SourceShape{width: 7, height: 5}, %{n: 42}} =
             Resolver.continue({Dummy, %{n: 999}}, {:finish, 40}, {7, 5}, shape, %{n: 2})
  end

  describe "rewrap/2" do
    setup %{shape: shape} do
      %{shape: shape, carry: %{scale: 2.5}}
    end

    test "substitutes the carry into a stateless :advance", %{shape: shape, carry: carry} do
      assert Resolver.rewrap({:advance, shape, nil}, carry) == {:advance, shape, carry}
    end

    test "substitutes the carry into a stateless :measure", %{carry: carry} do
      assert Resolver.rewrap({:measure, {:resize_tail, [:crop]}, nil}, carry) ==
               {:measure, {:resize_tail, [:crop]}, carry}
    end
  end
end
