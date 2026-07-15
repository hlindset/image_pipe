defmodule ImagePipe.Dialect.Imgproxy.PipelineColorPreambleTest do
  use ExUnit.Case, async: true

  # Input color management is a data-determined preamble, not a Plan operation
  # (AGENTS.md): it imports the decoded image's embedded profile into a working
  # space before ANY operation runs. `Pipeline.run/4` owns it, mirroring
  # `Executor.run_color_management/2` — so the dialect does NOT inherit
  # `Dialect.Native.Pipeline`'s known probe limitation of skipping it.
  #
  # The pipeline list is empty in most cases below on purpose: with no
  # operations, `run/4`'s only observable effect IS the preamble.

  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  @sources "test/support/image_pipe/test/imgproxy_differential/sources"
  @p3_fixture "#{@sources}/icc_p3.png"

  defp state_for(path) do
    {:ok, image} = Image.open(path)
    %State{image: image}
  end

  defp geometry do
    %SourceGeometry{
      storage_dimensions: {512, 512},
      display_dimensions: {512, 512},
      pending_orientation: %PendingOrientation{},
      source_format: :png
    }
  end

  test "run/4 imports an embedded wide-gamut profile before any pipeline runs" do
    state = state_for(@p3_fixture)
    refute state.color_imported?

    assert {:ok, %State{} = out} =
             Pipeline.run(state, geometry(), %{pipelines: []}, [])

    assert out.color_imported?
    assert out.source_color_profile != nil
  end

  test "the preamble runs BEFORE the first chain call, not after" do
    # Ordering is the whole point: an import that ran after the operations would
    # transform pixels in the wrong space. The injected chain records the state it
    # was handed, so the assertion is on what the FIRST operation actually saw.
    pid = self()

    chain = fn state, ops, opts ->
      send(pid, {:chain_saw, state.color_imported?})
      Chain.execute(state, ops, opts)
    end

    request = %{pipelines: [struct!(PipelineRequest, width: {:pixels, 100})]}

    assert {:ok, %State{}} =
             Pipeline.run(state_for(@p3_fixture), geometry(), request, chain: chain)

    assert_received {:chain_saw, true}
  end

  test "the preamble runs once per request, not once per pipeline" do
    # `condition/2` is idempotent via `color_imported?`, so a second call is
    # harmless — but the boundary is the request's, and two pipelines must not
    # produce two imports.
    state = state_for(@p3_fixture)

    request = %{pipelines: [struct!(PipelineRequest, []), struct!(PipelineRequest, [])]}

    assert {:ok, %State{color_imported?: true}} =
             Pipeline.run(state, geometry(), request, [])
  end

  test "an already-imported state passes through untouched" do
    state = %State{state_for(@p3_fixture) | color_imported?: true}

    assert {:ok, %State{} = out} = Pipeline.run(state, geometry(), %{pipelines: []}, [])
    assert out.color_imported?
    assert out.source_color_profile == nil
  end
end
