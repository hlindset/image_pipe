defmodule ImagePipe.Dialect.Imgproxy.PipelineCarryTest do
  use ExUnit.Case, async: true

  # Pins the imgproxy padding/canvas carry: the no-enlarge DprScale cap is
  # computed once at the resize and reused by later padding/canvas ops in the
  # SAME pipeline, as a pipeline-local variable rather than resolver state.
  #
  # Every expected scale below is computed by hand from
  # `Lowering.scaled_padding_side/2` (round_half_to_even(side * scale)) and
  # `scale_canvas_dimension/2` (round(dim * scale)).

  alias ImagePipe.Dialect.Imgproxy.Effects
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  # ── helpers ────────────────────────────────────────────────────────────

  defp state_for(width, height) do
    {:ok, image} = Image.new(width, height, color: [255, 255, 255])
    %State{image: image}
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

  defp preq(fields), do: struct!(PipelineRequest, fields)

  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops})
      Chain.execute(state, ops, opts)
    end
  end

  # Runs the request and returns every executable op the chain saw, flattened —
  # the tests below pick out the padding/canvas ops by struct.
  defp executables(state, request) do
    pid = self()
    assert {:ok, %State{}} = Pipeline.run(state, geometry(), request, chain: recording_chain(pid))
    drain([])
  end

  defp drain(acc) do
    receive do
      {:ops, ops} -> drain(acc ++ ops)
    after
      0 -> acc
    end
  end

  defp paddings(ops), do: Enum.filter(ops, &match?(%Padding{}, &1))
  defp canvases(ops), do: Enum.filter(ops, &match?(%ExtendCanvas{}, &1))
  defp resizes(ops), do: Enum.filter(ops, &match?(%Resize{}, &1))

  # A 400x300 source asked to become 800x600 with enlargement DENIED: the
  # !Enlarge() block caps the scale. Shared by several cases below.
  #   display source     = 400x300
  #   base requested box = 800x600  (dpr forced to 1.0, enlarge forced true)
  #   max_without_enlarge = min(400/800, 300/600) = 0.5
  defp capped(fields) do
    preq(
      [width: {:pixels, 800}, height: {:pixels, 600}, resizing_type: :force, enlarge: false] ++
        fields
    )
  end

  # ── the resize computes the carry; !Enlarge() caps it ──────────────────

  describe "the no-enlarge cap (imgproxy's !Enlarge() DprScale block)" do
    test "a no-enlarge resize caps the padding scale below the requested dpr" do
      # requested_scale = 2.0, max_without_enlarge = 0.5
      # :resize compensation -> 2.0 / 0.5 = 4.0
      # capped -> min(4.0, max(0.5, 1.0)) = 1.0
      # padding top -> round_half_to_even(10 * 1.0) = 10
      ops = executables(state_for(400, 300), req([capped(dpr: 2.0, padding_top: 10)]))

      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "a bare dpr with no geometry still emits an auto/auto resize, so the scale caps to 1.0" do
      # The trap this pins: imgproxy's `resize_rule_requested?` means a bare dpr
      # (no width/height) STILL emits an :auto/:auto resize. That populates the
      # carry, and the auto/auto branch of max_padding_scale_without_enlarge/2
      # returns 1.0, so a no-enlarge geometry-less dpr caps to 1.0 (#237):
      #   requested_scale 2.0, max 1.0 -> uncompensated -> min(2.0, 1.0) = 1.0
      # padding top -> round_half_to_even(10 * 1.0) = 10.
      #
      # An assembly that skipped the rule would emit NO resize, leave the carry
      # nil, fall back to the dpr, and scale by 2.0 -> 20 — diverging from the
      # `Resize{width: :auto, height: :auto, dpr: {:ratio, 2, 1},
      # enlargement: :deny}` Assembly emits for this exact request.
      ops = executables(state_for(400, 300), req([preq(dpr: 2.0, padding_top: 10)]))

      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "the same request with enlargement ALLOWED uses the raw dpr (no cap)" do
      # enlargement: :allow short-circuits to tagged_dpr_float(dpr) = 2.0
      # padding top -> round_half_to_even(10 * 2.0) = 20
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 2.0, padding_top: 10, enlarge: true)])
        )

      assert [%Padding{top: 20}] = paddings(ops)
    end

    test "fill_down overrides el:1 and still denies enlargement, so the scale caps" do
      # `rs:fill_down:800:600/el:1/dpr:2/pd:10` on a 400x300 source.
      #
      # `Assembly.enlargement/1`'s FIRST clause matches on resizing_type
      # :fill_down and returns :deny, OVERRIDING `enlarge: true`. So
      # padding_scale/4 takes its no-enlarge branch:
      #   display source      = 400x300
      #   base requested box  = 800x600 (dpr forced 1.0, enlarge forced true)
      #   max_without_enlarge = min(400/800, 300/600) = 0.5
      #   :resize compensation (max < 1.0) -> 2.0 / 0.5 = 4.0
      #   capped -> min(4.0, max(0.5, 1.0)) = 1.0
      #   padding top -> round_half_to_even(10 * 1.0) = 10
      #
      # Reading `enlarge` alone — `if(preq.enlarge, do: :allow, else: :deny)` —
      # yields :allow, short-circuits to the raw dpr 2.0, and pads 20.
      ops =
        executables(
          state_for(400, 300),
          req([
            preq(
              width: {:pixels, 800},
              height: {:pixels, 600},
              resizing_type: :fill_down,
              enlarge: true,
              dpr: 2.0,
              padding_top: 10
            )
          ])
        )

      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "a zoom folds into the requested box, so it never reaches the auto/auto cap" do
      # `zoom:0.5/dpr:2/pd:10`, enlarge off, on a 400x300 source. `zoom_x`/`zoom_y`
      # make resize_rule_requested?/1 true, so an :auto/:auto :fit resize IS
      # emitted — and Assembly threads the zoom onto it, where it folds into
      # the requested box (`Resize.resolve_base_dimensions/2` -> `apply_zoom/2`):
      #   base (dpr forced 1.0, enlarge forced true) = 400*0.5 x 300*0.5 = 200x150
      #   max_without_enlarge = min(400/200, 300/150) = 2.0
      #   :resize compensation (max >= 1.0) -> uncompensated 2.0
      #   capped -> min(2.0, max(2.0, 1.0)) = 2.0
      #   padding top -> round_half_to_even(10 * 2.0) = 20
      #
      # This is the invariant `max_padding_scale_without_enlarge/2`'s own comment
      # states: "A zoom folds into the requested box upstream, so a zoomed request
      # never reaches this auto/auto clause." An emitted op WITHOUT zoom_x/zoom_y
      # leaves `requested_*` at :auto, does reach that clause, caps to 1.0 and
      # pads 10 — breaking the invariant the comment asserts.
      ops =
        executables(
          state_for(400, 300),
          req([preq(zoom_x: 0.5, zoom_y: 0.5, dpr: 2.0, padding_top: 10)])
        )

      assert [%Padding{top: 20}] = paddings(ops)
    end
  end

  # ── which requests emit a resize at all ────────────────────────────────

  describe "the {:auto, :auto, false} emission guard" do
    test "w:0 with no height and no resize rule emits no resize at all" do
      # `/w:0/pd:10/`: width {:pixels, 0}, height nil, resizing_type :fit (the
      # default). `Assembly.resize_operations/1` clauses 1 and 2 both miss
      # (height is nil, not {:pixels, 0}), clause 3 misses (:fit), and clause 4
      # routes to `resize_from_rule/1`, which MAPS THE DIMENSIONS FIRST —
      # {:pixels, 0} -> :auto and nil -> :auto — then hits
      # `resize_operations_for/3`'s `{:auto, :auto, false}` guard and emits `[]`.
      #
      # A flattened catch-all that never maps the dimensions can never reach that
      # guard and emits a `Resize(:fit, :auto, :auto, dpr 1.0, :deny)` instead.
      # The padding scale cannot see the difference (both give 10), so this
      # asserts on the emitted op list, which can.
      ops = executables(state_for(400, 300), req([preq(width: {:pixels, 0}, padding_top: 10)]))

      assert resizes(ops) == []
      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "the same w:0 WITH a resize rule does emit (the guard's third element)" do
      # Identical geometry, plus `dpr:2` -> resize_rule_requested?/1 true ->
      # `{:auto, :auto, true}` -> emits. Pins that the guard keys off the rule and
      # is not a blanket "both auto -> skip".
      ops =
        executables(
          state_for(400, 300),
          req([preq(width: {:pixels, 0}, dpr: 2.0, padding_top: 10)])
        )

      assert [%Resize{}] = resizes(ops)
      # auto/auto + no zoom -> cap 1.0 -> round_half_to_even(10 * 1.0) = 10
      assert [%Padding{top: 10}] = paddings(ops)
    end
  end

  # ── which carry slot the consumer reads ────────────────────────────────
  #
  # dpr 0.5 against the capped geometry is the case where the two slots
  # genuinely DIVERGE, so it can tell them apart:
  #   requested_scale = 0.5, max_without_enlarge = 0.5
  #   :resize            -> compensated 0.5/0.5 = 1.0 -> min(1.0, 1.0) = 1.0
  #   :canvas_preserving -> uncompensated       0.5   -> min(0.5, 1.0) = 0.5

  describe "padding reads the slot its pipeline mode selects" do
    test "without extend (mode :resize) padding consumes effective_padding_scale" do
      # scale 1.0 -> round_half_to_even(10 * 1.0) = 10
      ops = executables(state_for(400, 300), req([capped(dpr: 0.5, padding_top: 10)]))

      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "with extend (mode :canvas_preserving) padding consumes the uncompensated slot" do
      # Same geometry and dpr; only `extend` differs -> the OTHER slot, 0.5.
      # round_half_to_even(10 * 0.5) = 5
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 0.5, padding_top: 10, extend: true)])
        )

      assert [%Padding{top: 5}] = paddings(ops)
    end
  end

  describe "the pipeline mode is derived from the whole predicate closure" do
    test "extend_aspect_ratio with a resolvable target ratio also selects :canvas_preserving" do
      # extend_aspect_ratio_emits?/1 reaches resize_target_ratio/1, which reads
      # WIDTH/HEIGHT — not any extend* field. A port that copied only the
      # extend*-field readers would leave this request in mode :resize and scale
      # the padding by 1.0 -> 10 instead of the canvas_preserving 0.5 -> 5.
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 0.5, padding_top: 10, extend_aspect_ratio: true)])
        )

      assert [%Padding{top: 5}] = paddings(ops)
    end

    test "extend_aspect_ratio without a resolvable target ratio stays in mode :resize" do
      # No height -> resize_target_ratio/1 returns :no_ratio -> emits? false.
      # (Width-only, so the resize is a plain :fit; the cap arithmetic is the
      # same shape: max = 400/800 = 0.5, :resize compensation -> 1.0.)
      ops =
        executables(
          state_for(400, 300),
          req([
            preq(
              width: {:pixels, 800},
              enlarge: false,
              extend_aspect_ratio: true,
              dpr: 0.5,
              padding_top: 10
            )
          ])
        )

      assert [%Padding{top: 10}] = paddings(ops)
    end

    test "an explicitly disabled extend (extend:0 with a gravity) stays in mode :resize" do
      # The negative carve-out clause: `extend: false, extend_requested: true`
      # short-circuits to false even though extend_gravity is set. Without that
      # clause the gravity would select :canvas_preserving and scale by 0.5 -> 5.
      ops =
        executables(
          state_for(400, 300),
          req([
            capped(
              dpr: 0.5,
              padding_top: 10,
              extend: false,
              extend_requested: true,
              extend_gravity: {:anchor, :center, :center}
            )
          ])
        )

      assert [%Padding{top: 10}] = paddings(ops)
    end
  end

  describe "canvas always reads the canvas_preserving slot" do
    test "a canvas scales its target box by canvas_preserving_padding_scale, not the resize slot" do
      # canvas_preserving_padding_scale = 0.5 (the resize slot here is 1.0)
      # target box 800x600 -> round(800*0.5) x round(600*0.5) = 400x300
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 0.5, extend: true)])
        )

      assert [%ExtendCanvas{rule: {:dimensions, {:pixels, 400}, {:pixels, 300}}}] = canvases(ops)
    end

    test "extend_aspect_ratio emits its OWN canvas alongside the extend canvas" do
      # `Assembly.canvas_operations/1` emits BOTH `extend_operation/1` and
      # `extend_aspect_ratio_operation/1`, in that order.
      # The aspect-ratio canvas box is `{:ratio, w, 1}` x `{:ratio, h, 1}`, which
      # `Lowering.canvas_executables/2` turns into an `{:aspect_ratio, {w, h}}`
      # rule — deliberately NOT scaled by the carry (it is computed from the
      # already-dpr-scaled image; `scale_canvas_dimension/2` passes ratios
      # through).
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 0.5, extend: true, extend_aspect_ratio: true)])
        )

      assert [
               %ExtendCanvas{rule: {:dimensions, {:pixels, 400}, {:pixels, 300}}},
               %ExtendCanvas{rule: {:aspect_ratio, {800.0, 600.0}}}
             ] = canvases(ops)
    end

    test "extend_aspect_ratio alone emits the aspect-ratio canvas and no extend canvas" do
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 0.5, extend_aspect_ratio: true)])
        )

      assert [%ExtendCanvas{rule: {:aspect_ratio, {800.0, 600.0}}}] = canvases(ops)
    end
  end

  # ── the carry is pipeline-local ────────────────────────────────────────

  describe "carry scoping" do
    test "a later pipeline's padding never sees an earlier pipeline's computed scale" do
      # p1: 800x600 source asked for 400x300, enlargement denied, dpr 2.0
      #   base requested box  = 400x300 (dpr forced to 1.0)
      #   max_without_enlarge = min(800/400, 600/300) = 2.0
      #   :resize -> uncompensated (max >= 1.0) 2.0 -> min(2.0, 2.0) = 2.0
      #   p1 padding top -> round_half_to_even(10 * 2.0) = 20
      #
      # p2: padding only. No width/height and no resize rule (no dpr/zoom/min_*)
      #   -> NO resize op -> the carry slot is nil -> the fallback applies, and
      #   p2's own dpr is nil -> 1.0. p2 padding top -> 10.
      #
      # A carry leaked across the `-` boundary would scale p2 by p1's 2.0 -> 20.
      ops =
        executables(
          state_for(800, 600),
          req([
            preq(
              width: {:pixels, 400},
              height: {:pixels, 300},
              resizing_type: :force,
              enlarge: false,
              dpr: 2.0,
              padding_top: 10
            ),
            preq(padding_top: 10)
          ])
        )

      assert [%Padding{top: 20}, %Padding{top: 10}] = paddings(ops)
    end

    test "an effect between the resize and the padding does not lose the carry" do
      # Carry 2.0: an 800x600 source into 400x300 with dpr 2.0 leaves
      # max_without_enlarge = 2.0, so the :resize slot carries 2.0. The blur
      # resolves through the neutral delegation clause; if that clause dropped
      # the carry, the padding would fall back to 1.0 -> top 10.
      ops =
        executables(
          state_for(800, 600),
          req([
            preq(
              width: {:pixels, 400},
              height: {:pixels, 300},
              resizing_type: :force,
              enlarge: false,
              dpr: 2.0,
              padding_top: 10,
              effects: %Effects{blur: 2.0}
            )
          ])
        )

      assert [%Padding{top: 20}] = paddings(ops)
    end
  end
end
