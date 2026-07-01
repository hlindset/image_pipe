defmodule ImagePipe.ResolverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Resolver
  alias ImagePipe.Transform.SourceShape

  defmodule Dummy do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: %{n: 0}
    @impl true
    def resolve(%SourceShape{} = shape, env, %{n: n}, op),
      do: {[{:emitted, op, env}], {:advance, shape, %{n: n + 1}}, %{n: n + 1}}
  end

  test "facade dispatches, passes env opaquely, threads strategy_state via the spec" do
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    {ops, cont, {Dummy, st}} = Resolver.resolve({Dummy, Dummy.init()}, shape, :env_token, :op)
    assert ops == [{:emitted, :op, :env_token}]
    assert {:advance, ^shape, %{n: 1}} = cont
    assert st == %{n: 1}
  end
end
