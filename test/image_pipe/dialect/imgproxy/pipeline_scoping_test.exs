defmodule ImagePipe.Dialect.Imgproxy.PipelineScopingTest do
  use ExUnit.Case, async: true

  # Pins the boundary-crossing contract for imgproxy `-` pipelines: each
  # pipeline re-seeds its SourceShape, starts a fresh carry, and flushes
  # pending orientation at its OWN boundary — `Executor.execute_pipeline/4`'s
  # scoping, NOT `Dialect.Native.Pipeline`'s single-seed/single-flush `then`
  # groups. Every observation uses only the three native-precedent seams
  # (`:chain`, `:measure_dims`, `:continue`). Carry freshness needs padding and
  # is pinned in the carry test.

  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  # ── helpers ────────────────────────────────────────────────────────────

  defp state_for(width, height, opts \\ []) do
    {:ok, image} = Image.new(width, height, color: [255, 255, 255])

    %State{
      image: image,
      pending_orientation: Keyword.get(opts, :pending_orientation),
      decode_shrink: Keyword.get(opts, :decode_shrink)
    }
  end

  defp geometry do
    %SourceGeometry{
      storage_dimensions: {1, 1},
      display_dimensions: {1, 1},
      pending_orientation: %PendingOrientation{},
      source_format: :png
    }
  end

  defp req(pipelines), do: %{pipelines: pipelines}

  defp preq(fields \\ []), do: struct!(PipelineRequest, fields)

  # Wraps the REAL Chain.execute so the recorded batches are genuine executable
  # op sequences and genuine geometry, not hand-computed ones.
  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops})
      Chain.execute(state, ops, opts)
    end
  end

  defp run(state, request, opts \\ []) do
    Pipeline.run(state, geometry(), request, opts)
  end

  defp collect_ops(fun) do
    pid = self()
    assert {:ok, %State{}} = fun.(pid)
    drain_ops([])
  end

  defp drain_ops(acc) do
    receive do
      {:ops, _ops} = msg -> drain_ops([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── the flush boundary is per-pipeline ─────────────────────────────────

  test "an empty pipeline still flushes at its own boundary, so the NEXT pipeline starts in the display frame" do
    # THE discriminating case for flush scoping. EXIF 6 is a quarter turn: a
    # 1600x1200 storage image displays as 1200x1600.
    #
    # Per-pipeline flush (correct): p1 assembles no ops, but its boundary
    # flushes anyway -> the Flush is the FIRST batch, and p2's resize then
    # re-seeds from an already-oriented 1200x1600 image with NO pending, so it
    # resolves as a plain bare resize.
    #
    # Single-flush (native-style, WRONG here): nothing flushes between the
    # pipelines, so p2's resize still sees the pending orientation and takes
    # NeutralResolver's `{:resize_flush_tail, _}` path — the resize would be
    # the FIRST batch and would carry the Flush in its own tail.
    po = PendingOrientation.from_exif(6, true)
    state = state_for(1600, 1200, pending_orientation: po)

    request = req([preq(), preq(width: {:pixels, 400})])

    assert [{:ops, [%Flush{}]}, {:ops, [resize]}] =
             collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

    # A bare, already-oriented resize: no compensation, no flush tail.
    assert %ExecutableResize{mode: :fit, width: {:pixels, 400}, height: :auto} = resize
  end

  test "pending orientation is flushed at EVERY pipeline boundary (provable with EMPTY ops)" do
    # Flush needs no operations at all — run_pipeline calls flush_boundary
    # unconditionally. Two pipelines, both assembling zero ops: p1's boundary
    # flushes; once it has run, p2's boundary sees no pending and clears
    # without a second Flush (which an unconditional per-pipeline emit would
    # wrongly produce).
    po = PendingOrientation.from_exif(6, true)
    state = state_for(1600, 1200, pending_orientation: po)

    assert [{:ops, [%Flush{}]}] =
             collect_ops(fn pid ->
               run(state, req([preq(), preq()]), chain: recording_chain(pid))
             end)
  end

  test "an identity pending orientation clears at the boundary without a Flush (streaming fast path)" do
    po = PendingOrientation.from_exif(1, true)
    assert PendingOrientation.identity?(po)

    state = state_for(1600, 1200, pending_orientation: po)

    assert [] =
             collect_ops(fn pid ->
               run(state, req([preq()]), chain: recording_chain(pid))
             end)
  end

  # ── the SourceShape re-seeds per pipeline ──────────────────────────────

  test "SourceShape re-seeds per pipeline: p2's width-only resize derives height from p1's OUTPUT aspect" do
    # An ABSOLUTE p2 resize would not reveal the seed — use a width-only resize
    # (height :auto), whose auto height resolves against the CURRENT shape's
    # aspect. p1 forces 1600x1200 (4:3) to 400x200 (2:1) so p1's OUTPUT aspect
    # differs from the source's: p2 (width 200, height auto) must land on
    # 200x100 (p1's 2:1), not 200x150 (the original 4:3).
    state = state_for(1600, 1200)

    request =
      req([
        preq(width: {:pixels, 400}, height: {:pixels, 200}, resizing_type: :force),
        preq(width: {:pixels, 200})
      ])

    assert {:ok, %State{} = final} = run(state, request)

    assert {Image.width(final.image), Image.height(final.image)} == {200, 100}
  end

  test "an empty request runs zero pipelines and returns the state unchanged" do
    state = state_for(1600, 1200)
    assert state.pending_orientation == nil

    # The singleton default PipelineRequest: no ops, no pending orientation ->
    # the ONLY permitted chain activity is none at all.
    assert [] =
             collect_ops(fn pid ->
               run(state, req([preq()]), chain: recording_chain(pid))
             end)

    assert {:ok, %State{} = final} = run(state, req([preq()]))
    assert {Image.width(final.image), Image.height(final.image)} == {1600, 1200}
  end
end
