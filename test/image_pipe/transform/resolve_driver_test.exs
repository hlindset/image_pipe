defmodule ImagePipe.Transform.ResolveDriverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.{Chain, ResolveDriver, SourceShape, State}

  defmodule Probe do
    @behaviour ImagePipe.Resolver

    @impl true
    def init, do: nil

    @impl true
    def behavior_version, do: 1

    @impl true
    def resolve(%SourceShape{} = shape, agent, :pure) do
      {[], {:advance, %{shape | width: shape.width + 1}, agent}}
    end

    def resolve(%SourceShape{} = shape, agent, :opaque) do
      then_fn = fn {w, h} ->
        Agent.update(agent, &[{:acquired, w, h} | &1])
        {%{shape | width: w, height: h}, agent}
      end

      {[], {:acquire, then_fn}}
    end
  end

  test "acquire uses injected dims; advance is pure; overlay feeds State from the shape" do
    {:ok, img} = Image.new(10, 10)
    agent = start_supervised!({Agent, fn -> [] end})

    shape =
      SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

    chain = fn %State{} = state, ops, opts ->
      Agent.update(agent, &[{:overlaid_dims, state.source_dimensions} | &1])
      Chain.execute(state, ops, opts)
    end

    {:ok, %State{}} =
      ResolveDriver.run([:pure, :opaque, :pure], shape, {Probe, agent}, %State{image: img},
        acquire_dims: fn _ -> {77, 66} end,
        chain: chain
      )

    assert Agent.get(agent, &Enum.reverse/1) ==
             [
               {:overlaid_dims, {10, 10}},
               {:overlaid_dims, {11, 10}},
               {:acquired, 77, 66},
               {:overlaid_dims, {77, 66}}
             ]
  end
end
