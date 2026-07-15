defmodule ImagePipe.Dialect.Imgproxy.PipelineCarryTest do
  use ExUnit.Case, async: true

  # Pins the imgproxy padding/canvas carry [spec D5]: the no-enlarge DprScale
  # cap is computed once at the resize and reused by later padding/canvas ops in
  # the SAME pipeline, as a pipeline-local variable rather than resolver state —
  # and the `{:effective, fallback, mode}` marker is never constructed.
  #
  # Every expected scale below is computed by hand from
  # `Lowering.scaled_padding_side/2` (round_half_to_even(side * scale)) and
  # `scale_canvas_dimension/2` (round(dim * scale)); the arithmetic that
  # produces the scale is the verbatim copy of the framework resolver's.

  alias ImagePipe.Dialect.Imgproxy.Effects
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Padding
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
      # framework arm, which emits `Resize{width: :auto, height: :auto,
      # dpr: {:ratio, 2, 1}, enlargement: :deny}` for this exact request.
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
      # The capped setup: carry 1.0, but dpr_fallback 2.0. The blur resolves
      # through the neutral delegation clause; if that clause dropped the carry,
      # the padding would fall back to the dpr and scale by 2.0 -> 20.
      ops =
        executables(
          state_for(400, 300),
          req([capped(dpr: 2.0, padding_top: 10, effects: %Effects{blur: 2.0})])
        )

      assert [%Padding{top: 10}] = paddings(ops)
    end
  end
end
