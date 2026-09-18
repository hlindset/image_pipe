defmodule ImagePipe.Native.PipelineTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Path
  alias ImagePipe.Native.Pipeline
  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Request.Group
  alias ImagePipe.Native.Request.Output
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal, as: ExecutableBitonal
  alias ImagePipe.Transform.Operation.Blur, as: ExecutableBlur
  alias ImagePipe.Transform.Operation.Brightness, as: ExecutableBrightness
  alias ImagePipe.Transform.Operation.Colorize, as: ExecutableColorize
  alias ImagePipe.Transform.Operation.Contrast, as: ExecutableContrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone, as: ExecutableDuotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Gradient, as: ExecutableGradient
  alias ImagePipe.Transform.Operation.Gray, as: ExecutableGray
  alias ImagePipe.Transform.Operation.Monochrome, as: ExecutableMonochrome
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate, as: ExecutablePixelate
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImagePipe.Transform.Operation.Saturation, as: ExecutableSaturation
  alias ImagePipe.Transform.Operation.Sharpen, as: ExecutableSharpen
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

  defp planning_chain(pid) do
    fn state, ops, _opts ->
      send(pid, {:ops, ops})
      {:ok, state}
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

      request =
        req([
          group(%{
            resize: %{
              w: 800,
              h: :auto,
              fit: :contain,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            }
          })
        ])

      assert [
               {:ops,
                [
                  %ExecutableResize{
                    mode: :force,
                    width: {:pixels, 800},
                    height: {:pixels, 600}
                  }
                ]}
             ] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end

    test "{:resize_tail, tail} executes the result-crop tail then is terminal" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            resize: %{
              w: 300,
              h: 400,
              fit: :cover,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            },
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
            resize: %{
              w: 300,
              h: 400,
              fit: :cover,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            },
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
    test "parsed effect options lower in fixed stage order without DPR parameter scaling" do
      state = state_for(32, 24)

      path =
        "/dpr=2/gradient=1,red,left,0.25,0.75/colorize=1,ff0000,keep-alpha/" <>
          "saturation=0.5/contrast=1.25/brightness=-20/" <>
          "duotone=1,112233,ffeecc/monochrome=1,red/bitonal/gray/" <>
          "pixelate=8/sharpen=1.5/blur=2/src/test"

      {:ok, lexed} = Plug.Test.conn(:get, path) |> Path.extract()
      assert {:ok, request} = Parser.parse(lexed, [])

      assert Pipeline.operation_names(request) == [
               :blur,
               :sharpen,
               :pixelate,
               :gray,
               :bitonal,
               :monochrome,
               :duotone,
               :brightness,
               :contrast,
               :saturation,
               :colorize,
               :gradient
             ]

      operations =
        collect_ops(fn pid -> run(state, request, chain: planning_chain(pid)) end)
        |> Enum.flat_map(fn {:ops, operations} -> operations end)

      assert [
               %ExecutableBlur{sigma: 2.0},
               %ExecutableSharpen{sigma: 1.5},
               %ExecutablePixelate{size: 8},
               %ExecutableGray{},
               %ExecutableBitonal{},
               %ExecutableMonochrome{intensity: 1.0, color: [255, 0, 0]},
               %ExecutableDuotone{
                 intensity: 1.0,
                 shadow: [17, 34, 51],
                 highlight: [255, 238, 204]
               },
               %ExecutableBrightness{value: -20},
               %ExecutableContrast{value: 1.25},
               %ExecutableSaturation{value: 0.5},
               %ExecutableColorize{opacity: 1.0, color: [255, 0, 0], keep_alpha: true},
               %ExecutableGradient{
                 opacity: 1.0,
                 color: [255, 0, 0],
                 angle: 90.0,
                 start: 0.25,
                 stop: 0.75
               }
             ] = operations
    end

    test "plain w=800" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            resize: %{
              w: 800,
              h: :auto,
              fit: :contain,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            }
          })
        ])

      assert [
               {:ops,
                [
                  %ExecutableResize{
                    mode: :force,
                    width: {:pixels, 800},
                    height: {:pixels, 600}
                  }
                ]}
             ] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
    end

    test "fit=cover/w=300/h=400/focus=... emits resize then result crop with {:fp, ...} gravity" do
      state = state_for(1600, 1200)

      request =
        req([
          group(%{
            resize: %{
              w: 300,
              h: 400,
              fit: :cover,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            },
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
            resize: %{
              w: 300,
              h: :auto,
              fit: :contain,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            }
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

      assert %ExecutableResize{
               mode: :force,
               width: {:pixels, 300},
               height: {:pixels, 200}
             } = resize
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
          group(%{
            resize: %{
              w: 500,
              h: :auto,
              fit: :contain,
              enlarge: false,
              zoom: {1.0, 1.0},
              min_w: nil,
              min_h: nil
            }
          }),
          group(%{trim: {{255, 255, 255}, 0}})
        ])

      assert [{:ops, [resize]}, {:ops, [trim]}] =
               collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)

      assert %ExecutableResize{
               mode: :force,
               width: {:pixels, 500},
               height: {:pixels, 400}
             } = resize

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

  # ── operation_names/1 drift pin ──────────────────────────────────────────
  #
  # `operation_names/1` builds the `[:transform, :execute]` span's start
  # metadata; it structurally mirrors the private `group_operations/2` that
  # `run/4` actually executes. Both are `defp` and take a live `SourceShape`, so
  # a direct `operation_names == Enum.map(group_operations(group, shape),
  # &Operation.name/1)` comparison would require exporting an implementation
  # helper — forbidden by the boundary rule. Instead this pins the mirror
  # against REAL execution, transitively through `run/4` (whose only source of
  # per-group ops IS `group_operations/2`): for a fully-loaded group the names
  # helper must list exactly the ops `run/4` runs, in order — so dropping (or
  # adding) a category in either helper alone flips this test.

  describe "operation_names/1 mirrors what run/4 executes" do
    test "a fully-loaded group: the names helper lists exactly the executed ops, in order" do
      state = state_for(1600, 1200)

      path =
        "/trim=auto/region=100,100,800,600/w=400/h=400/blur=3/extend/pad=10/bg=ff0000/src/test"

      {:ok, lexed} = Plug.Test.conn(:get, path) |> Path.extract()
      {:ok, request} = Parser.parse(lexed, [])

      names = Pipeline.operation_names(request)
      assert names == [:trim, :crop_region, :resize, :blur, :canvas, :padding, :background]

      executed =
        collect_ops(fn pid -> run(state, request, chain: recording_chain(pid)) end)
        |> Enum.flat_map(fn {:ops, ops} -> ops end)
        |> Enum.map(&executable_category/1)

      # Executables carry a different name namespace than the semantic ops the
      # metadata helper names, and one `%Crop{}` module serves both crop forms —
      # so compare on a coarse category with crop_region/crop_guided collapsed.
      assert executed == Enum.map(names, &coarse_category/1)
    end
  end

  defp executable_category(%ExecutableTrim{}), do: :trim
  defp executable_category(%Crop{}), do: :crop
  defp executable_category(%ExecutableResize{}), do: :resize
  defp executable_category(%ExecutableBlur{}), do: :blur
  defp executable_category(%ExtendCanvas{}), do: :canvas
  defp executable_category(%Padding{}), do: :padding
  defp executable_category(%Background{}), do: :background

  defp coarse_category(name) when name in [:crop_region, :crop_guided], do: :crop
  defp coarse_category(name), do: name

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

  # ── decode preflight ───────────────────────────────────────────────────
  #
  # `decode_request/2` feeds concrete extents to
  # `DecodePlanner.open_options_for/5`.

  describe "decode_request/2" do
    defp preflight_geometry(dims) do
      %SourceGeometry{
        storage_dimensions: dims,
        display_dimensions: dims,
        pending_orientation: %PendingOrientation{},
        source_format: :png
      }
    end

    defp preflight_shrink(resize, dims, format) do
      request = req([group(%{resize: resize})])

      DecodePlanner.open_options_for(
        Pipeline.decode_request(request, preflight_geometry(dims)),
        format,
        dims
      )
    end

    test "a single-axis resize targets that axis alone, not a synthesized aspect" do
      # A `w=400` request against a NON-proportional 3200x2405 source. Deriving
      # the missing axis from the aspect (`round(400 * 2405/3200)` = 301) binds
      # `min/2` tighter than the targeted axis alone and halves the shrink.
      resize = %{
        w: 400,
        h: :auto,
        fit: :contain,
        enlarge: false,
        zoom: {1.0, 1.0},
        min_w: nil,
        min_h: nil
      }

      assert Pipeline.decode_request(
               req([group(%{resize: resize})]),
               preflight_geometry({3200, 2405})
             ).resize_target == {400, nil}

      assert preflight_shrink(resize, {3200, 2405}, :jpeg)[:shrink] == 8
      assert_in_delta preflight_shrink(resize, {3200, 2405}, :webp)[:scale], 0.125, 1.0e-12
      refute Keyword.has_key?(preflight_shrink(resize, {3200, 2405}, :png), :shrink)
    end

    test "two-axis resize preserves both concrete targets" do
      resize = %{
        w: 250,
        h: 190,
        fit: :contain,
        enlarge: false,
        zoom: {1.0, 1.0},
        min_w: nil,
        min_h: nil
      }

      assert Pipeline.decode_request(
               req([group(%{resize: resize})]),
               preflight_geometry({2401, 3199})
             ).resize_target == {250, 190}

      assert preflight_shrink(resize, {2401, 3199}, :jpeg)[:shrink] == 8
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
