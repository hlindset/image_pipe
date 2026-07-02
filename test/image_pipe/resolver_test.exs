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
end
