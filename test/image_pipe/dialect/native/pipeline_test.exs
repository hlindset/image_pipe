defmodule ImagePipe.Dialect.Native.PipelineTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImagePipe.Transform.Operation.Trim, as: ExecutableTrim
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

  defp req(groups, output \\ %Output{}) do
    %Request{groups: groups, output: output, source: "test"}
  end

  defp group(fields), do: struct!(Group, fields)

  # Wraps the REAL Chain.execute so op-emission tests see genuine (not
  # hand-computed) executable op sequences and geometry — every `ops` list
  # handed to Chain is forwarded to `pid` before executing for real.
  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops})
      Chain.execute(state, ops, opts)
    end
  end

  defp run(state, request, opts \\ []) do
    Pipeline.run(state, geometry(), request, opts)
  end

  # ── follow/5: every continuation tag reachable by the probe's ops ───────
  #
  # Enumerated against `NeutralResolver.continue/4`'s clauses (verified by
  # reading the source, not assumed): `:trim` and `:resize` are terminal on
  # first measure; `{:resize_tail, tail}` and `{:resize_flush_tail, tail}`
  # execute one further tail stage and then are terminal. No reachable clause
  # emits a further `{:measure, _, nil}` — see the Task 14 report for the
  # full enumeration.

  describe "follow/5 continuation handling" do
    test ":trim is terminal on first measure" do
      state = state_for(200, 100)
      request = req([group(%{trim: :auto})])

      assert [{:ops, [%ExecutableTrim{threshold: 10.0, background: :auto}]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end

    test ":resize is terminal on first measure (bare, no result-crop tail)" do
      state = state_for(1600, 1200)
      request = req([group(%{resize: %{w: 800, h: :auto, fit: :contain, enlarge: false}})])

      assert [{:ops, [%ExecutableResize{mode: :fit, width: {:pixels, 800}, height: :auto}]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end

    test "{:resize_tail, tail} executes the result-crop tail then is terminal" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            resize: %{w: 300, h: 400, fit: :cover, enlarge: false},
            guide: {:focus, 0.25, 0.75}
          })
        ])

      assert [{:ops, [resize]}, {:ops, [crop]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %ExecutableResize{mode: :fill, width: {:pixels, 300}, height: {:pixels, 400}} =
               resize

      assert %Crop{crop_from: :gravity, gravity: {:fp, 0.25, 0.75}} = crop
    end

    test "{:resize_flush_tail, tail} executes the compensated tail + Flush then is terminal" do
      # EXIF orientation 6 (a quarter turn): storage dims are the pre-rotation
      # frame, so a landscape 1600x1200 storage image displays as portrait.
      po = PendingOrientation.from_exif(6, true)
      state = state_for(1600, 1200, pending_orientation: po)

      request =
        req([
          group(%{
            resize: %{w: 300, h: 400, fit: :cover, enlarge: false},
            guide: {:anchor, :center}
          })
        ])

      assert [{:ops, [resize]}, {:ops, [crop, flush]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %ExecutableResize{mode: :force} = resize
      assert %Crop{crop_from: :gravity} = crop
      assert %Flush{} = flush
    end

    test "crashes (does not degrade) once continuation recursion exceeds the depth cap" do
      state = state_for(200, 100)
      request = req([group(%{trim: :auto})])

      # A pathological `continue` that always re-emits a further measure —
      # unreachable from any real `NeutralResolver.continue/4` clause for this
      # probe's operation set, but proves the depth cap is load-bearing.
      bogus_continue = fn _tag, _dims, _pre_shape, nil -> {[], {:measure, :bogus, nil}} end
      identity_chain = fn state, _ops, _opts -> {:ok, state} end

      assert_raise FunctionClauseError, fn ->
        run(state, request, chain: identity_chain, continue: bogus_continue)
      end
    end
  end

  # ── exact op-emission per group ──────────────────────────────────────────

  describe "op emission per group" do
    test "plain w=800" do
      state = state_for(1600, 1200)
      request = req([group(%{resize: %{w: 800, h: :auto, fit: :contain, enlarge: false}})])

      assert [{:ops, [%ExecutableResize{mode: :fit, width: {:pixels, 800}, height: :auto}]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end

    test "fit=cover/w=300/h=400/focus=... emits resize then result crop with {:fp, ...} gravity" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            resize: %{w: 300, h: 400, fit: :cover, enlarge: false},
            guide: {:focus, 0.25, 0.75}
          })
        ])

      assert [{:ops, [resize]}, {:ops, [crop]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %ExecutableResize{mode: :fill, width: {:pixels, 300}, height: {:pixels, 400}} =
               resize

      assert %Crop{crop_from: :gravity, gravity: {:fp, 0.25, 0.75}} = crop
    end

    test "crop=600,400/anchor=smart/w=300 emits the guided crop before the resize" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            crop: {{:px, 600}, {:px, 400}},
            guide: {:anchor_smart},
            resize: %{w: 300, h: :auto, fit: :contain, enlarge: false}
          })
        ])

      assert [{:ops, [crop]}, {:ops, [resize]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %Crop{
               crop_from: :gravity,
               gravity: :smart,
               width: {:pixels, 600},
               height: {:pixels, 400}
             } =
               crop

      assert %ExecutableResize{mode: :fit, width: {:pixels, 300}, height: :auto} = resize
    end

    test "region=10,20,100,200 emits a coordinate crop with no gravity" do
      state = state_for(1600, 1200)
      request = req([group(%{region: {{:px, 10}, {:px, 20}, {:px, 100}, {:px, 200}}})])

      assert [{:ops, [crop]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %Crop{
               crop_from: %{left: {:pixels, 10}, top: {:pixels, 20}},
               width: {:pixels, 100},
               height: {:pixels, 200}
             } = crop
    end

    test "pct crops resolve against the current (group-start) display dims" do
      state = state_for(800, 600)

      request =
        req([group(%{crop: {{:pct, 50}, {:pct, 50}}, guide: {:anchor, :center}})])

      assert [{:ops, [crop]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %Crop{width: {:pixels, 400}, height: {:pixels, 300}} = crop
    end

    test "w=500/then/trim=fff: group boundary runs trim as its own stage after the resize" do
      state = state_for(1000, 800)

      request =
        req([
          group(%{resize: %{w: 500, h: :auto, fit: :contain, enlarge: false}}),
          group(%{trim: {{255, 255, 255}, 0}})
        ])

      assert [{:ops, [resize]}, {:ops, [trim]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %ExecutableResize{mode: :fit, width: {:pixels, 500}, height: :auto} = resize
      assert %ExecutableTrim{threshold: threshold, background: %ImagePipe.Plan.Color{}} = trim
      assert threshold == 0.0
    end

    test "pad+bg emits padding then background, in that order" do
      state = state_for(200, 100)
      request = req([group(%{pad: {10, 20, 30, 40}, bg: {255, 0, 0, 1.0}})])

      assert [{:ops, [pad]}, {:ops, [bg]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %Padding{top: 10, right: 20, bottom: 30, left: 40, fill: :transparent} = pad
      assert %Background{color: [255, 0, 0, 255]} = bg
    end

    test "an all-zero pad shorthand is a Tier-1 identity (no padding op emitted)" do
      state = state_for(200, 100)
      request = req([group(%{pad: {0, 0, 0, 0}})])

      assert [] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end
  end

  # ── anchor=smart never reads State.detector ──────────────────────────────

  describe "smart guide does not require a configured detector" do
    test "anchor=smart succeeds with State.detector left unconfigured (nil)" do
      state = state_for(400, 400)
      assert state.detector == nil

      request =
        req([group(%{crop: {{:px, 200}, {:px, 200}}, guide: {:anchor_smart}})])

      assert {:ok, %State{}} = run(state, request)
    end
  end

  # Runs `fun` (which must itself call `run/3` with a `chain` built from the
  # given pid via `recording_chain/1`), asserts the pipeline succeeded, and
  # returns the ordered list of `{:ops, list}` messages the chain recorded.
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
end
