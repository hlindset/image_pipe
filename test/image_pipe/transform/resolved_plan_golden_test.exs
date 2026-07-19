defmodule ImagePipe.Transform.ResolvedPlanGoldenTest do
  @moduledoc """
  Resolve-driver seam behaviors (Resolve Stage 1), over hand-built plans.

  Each test drives `ImagePipe.Transform.Executor.run_neutral/4` directly with a
  capturing chain (no pixels run, except the identity-streaming guard, which
  runs the real chain to keep its materialization claim honest) and, where
  geometry matters, an injected `measure_dims`, asserting the driver's seam
  contracts:

    * a downstream consumer resolves against the ACQUIRED (measured) dims, not
      the planned dims (the ±1 divergence);
    * a multi-executable expansion stages at the realized-dims seam, with the
      trailing op observing the advanced shape (staged continuation, §4.4);
    * an identity pending orientation streams — the boundary clears it without a
      flush and the state ends unmaterialized.
  """

  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation.Blur, as: PlanBlur
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush, as: ExecFlush
  alias ImagePipe.Transform.Operation.Resize, as: ExecResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  describe "identity-streaming guard" do
    # An identity pending orientation (EXIF orientation 1, auto-rotate on) with
    # effects only: the boundary must clear the pending without a flush and the
    # state must end unmaterialized (the streaming fast path). We drive the real
    # chain so the materialization claim is honest — a regression that flushes at
    # the boundary would feed the chain a %Flush{} op AND materialize, failing
    # both assertions.
    test "identity pending streams — no flush, materialized? stays false" do
      {:ok, image} = Image.new(200, 150, color: :white)
      state = %State{image: image}

      shape =
        SourceShape.seed(%{
          width: 200,
          height: 150,
          pending_orientation: PendingOrientation.from_exif(1, true),
          decode_shrink: nil
        })

      batches_agent = start_supervised!({Agent, fn -> [] end})

      recording_chain = fn %State{} = st, ops, opts ->
        Agent.update(batches_agent, &[ops | &1])
        Chain.execute(st, ops, opts)
      end

      assert {:ok, %State{} = final} =
               Executor.run_neutral(
                 [%PlanBlur{sigma: 2.0}],
                 shape,
                 state,
                 chain: recording_chain
               )

      refute final.materialized?,
             "identity pending must end materialized? == false (a regression that always flushes flips this)"

      flush_batches =
        batches_agent
        |> Agent.get(&Enum.reverse/1)
        |> Enum.filter(fn ops -> Enum.any?(ops, &match?(%ExecFlush{}, &1)) end)

      assert flush_batches == [],
             "identity pending must feed the chain no flush op, got #{inspect(flush_batches)}"
    end
  end

  describe "±1 divergence (synthetic, driver-seam injection)" do
    # Proves downstream consumers follow the ACQUIRED dims, not the planned dims.
    #
    # Plan = a plain fit resize (measures its realized dims) followed by a
    # 1/3 gravity crop (a downstream consumer that resolves against the measured
    # frame). We run Executor.run/5 directly with:
    #   * opts[:chain] — a capturing chain: it records each op batch and the
    #     source_dimensions the driver overlaid onto State before that batch, and
    #     returns State unchanged (no pixels ever run).
    #   * opts[:measure_dims] — injecting the resize's realized dims MINUS ONE
    #     ({199, 149}) at its :measure, standing in for the ±1 float-rounding
    #     skew that real libvips can produce and that we cannot force otherwise.
    #
    # The reference "recorded_realized" is a plain fit resize into 200x150 over
    # high_freq.jpg — the realized dims a resize op reports at its
    # `{:op_stop, :resize, 0, {200, 150}, :ok}` measure. We inject {199, 149}.
    #
    # imgproxy crop-size math (ground truth, /Users/hlindset/src/imgproxy):
    #   * prepare.go:56-65  CalcCropSize(orig, crop): for 0<crop<1 returns
    #     max(1, imath.Scale(orig, crop)).
    #   * imath/imath.go:24-30  Scale(a, s) = Round(a*s); imath.go:16-18
    #     Round = math.Round = round half away from zero.
    #   * prepare.go:272-273  c.CropWidth  = CalcCropSize(SrcWidth,  CropWidth())
    #                         c.CropHeight = CalcCropSize(SrcHeight, CropHeight())
    #   * crop.go:15          CropWidth = MinNonZero(cropWidth, imgWidth) (clamp).
    #   The crop resolves BEFORE the scale (crop.go), i.e. against the measured
    #   source frame — this is why the downstream box follows measured dims.
    #
    # Hand-derived boxes for a 1/3 crop:
    #   from measured {199, 149}: width Round(199/3)=Round(66.333)=66,
    #                             height Round(149/3)=Round(49.666)=50
    #   from planned  {200, 150}: width Round(200/3)=Round(66.666)=67,
    #                             height Round(150/3)=Round(50.000)=50
    #   The WIDTH axis diverges (67 -> 66) under the -1 injection; the height axis
    #   happens not to cross a rounding boundary at 150->149 (50 both ways), which
    #   is exactly why the width axis is the documented ±1 edge here.
    test "downstream 1/3 crop resolves against measured (recorded-1) dims" do
      recorded_realized = {200, 150}
      injected = {199, 149}

      # ImagePipe.Transform.Geometry.round_half_away_from_zero mirrors Go's
      # math.Round; assert on committed integers, not "sane" values.
      expected_box_from_measured = {66, 50}
      expected_box_from_planned = {67, 50}

      plan = [
        %PlanResize{
          mode: :fit,
          width: {:px, 200},
          height: {:px, 150},
          dpr: {:ratio, 1, 1},
          enlargement: :deny,
          guide: :center
        },
        %CropGuided{width: {:ratio, 1, 3}, height: {:ratio, 1, 3}, guide: :center}
      ]

      # A concrete source image so overlay/State are well-formed; pixels never run.
      {:ok, image} = Image.new(1600, 1200, color: :white)
      {w0, h0} = recorded_realized

      shape =
        SourceShape.seed(%{
          width: 1600,
          height: 1200,
          pending_orientation: nil,
          decode_shrink: nil
        })

      state = %State{image: image}

      batches_agent = start_supervised!({Agent, fn -> [] end})

      capturing_chain = fn %State{} = st, ops, _opts ->
        Agent.update(batches_agent, &[{ops, st.source_dimensions} | &1])
        {:ok, st}
      end

      # Inject recorded_realized - 1 at the resize's :measure.
      inject = fn _image -> injected end

      assert {:ok, %State{}} =
               Executor.run_neutral(
                 plan,
                 shape,
                 state,
                 chain: capturing_chain,
                 measure_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      # Two op batches: [resize] then [crop]. The crop batch's overlaid
      # source_dimensions is the measured (injected) frame — the direct evidence
      # the driver propagated the measured dims to the downstream consumer.
      assert [{[%_{}], _resize_dims}, {[%Crop{} = crop], crop_source_dims}] = batches

      assert crop_source_dims == injected,
             "downstream crop saw source_dimensions #{inspect(crop_source_dims)}, expected measured #{inspect(injected)}"

      # The crop is a symbolic 1/3 scale; the executable box comes from resolving
      # it against the frame the driver fed it. Resolving against the measured
      # frame yields the hand-derived box and differs from the planned frame's.
      {aw, ah} = injected
      box_from_measured = Crop.resolved_box_dims(crop, aw, ah)
      {pw, ph} = recorded_realized
      box_from_planned = Crop.resolved_box_dims(crop, pw, ph)

      assert box_from_measured == expected_box_from_measured
      assert box_from_planned == expected_box_from_planned

      assert box_from_measured != box_from_planned,
             "the ±1 injection must move the downstream box (measured vs planned): #{inspect(box_from_measured)} vs #{inspect(box_from_planned)}"

      # Keep w0/h0 referenced so the recorded reference stays self-documenting.
      assert {w0, h0} == recorded_realized
    end
  end

  describe "staged continuation (spec §4.4 Stage 3)" do
    # A cover expands to [resize, crop]. Staged, the driver executes [resize],
    # measures the realized post-resize dims, and only then receives [crop] —
    # parameterized against the MEASURED intermediate. The trailing blur
    # observes the advanced shape via the driver overlay.
    test "a plain cover splits at the realized-dims seam; the crop box follows measured dims" do
      plan = [
        %PlanResize{
          mode: :cover,
          width: {:px, 100},
          height: {:px, 100},
          dpr: {:ratio, 1, 1},
          enlargement: :deny,
          guide: :center
        },
        %PlanBlur{sigma: 1.0}
      ]

      {:ok, image} = Image.new(800, 600, color: :white)

      shape =
        SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})

      state = %State{image: image}
      batches_agent = start_supervised!({Agent, fn -> [] end})

      capturing_chain = fn %State{} = st, ops, _opts ->
        Agent.update(batches_agent, &[{ops, st.source_dimensions} | &1])
        {:ok, st}
      end

      # Realized cover intermediate for 800x600 -> 100x100 is {133, 100}; inject
      # a -1 divergence on the height ({133, 99}) to prove the crop box resolves
      # against the MEASURED seam dims, not the planned ones (the 100px box
      # bounds to the 99px measured frame).
      inject = fn _image -> {133, 99} end

      assert {:ok, %State{}} =
               Executor.run_neutral(
                 plan,
                 shape,
                 state,
                 chain: capturing_chain,
                 measure_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      # Three batches: [resize] / [crop] (the stage) / [blur].
      assert [
               {[%ExecResize{}], _},
               {[%Crop{} = crop], _},
               {[_blur], blur_source_dims}
             ] = batches

      # The result-crop box is bounded to the measured frame; the advanced shape
      # the blur sees is the crop box, computed purely from the injected dims —
      # {100, 99}, not the planned {100, 100}.
      assert Crop.resolved_box_dims(crop, 133, 99) == {100, 99}
      assert blur_source_dims == {100, 99}
    end

    # Under a pending quarter turn the emission is [resize, crop, Flush]; staged
    # it becomes [resize] / [crop, Flush], with the final shape computed purely:
    # the compensated crop's storage-frame box, axis-swapped by the flush.
    test "a pending-orientation cover stages; the final shape is the flushed crop box" do
      po = PendingOrientation.from_exif(6, true)

      plan = [
        %PlanResize{
          mode: :cover,
          width: {:px, 20},
          height: {:px, 20},
          dpr: {:ratio, 1, 1},
          enlargement: :deny,
          guide: :center
        },
        %PlanBlur{sigma: 1.0}
      ]

      {:ok, image} = Image.new(40, 80, color: :white)

      shape =
        SourceShape.seed(%{width: 40, height: 80, pending_orientation: po, decode_shrink: nil})

      state = %State{image: image}
      batches_agent = start_supervised!({Agent, fn -> [] end})

      capturing_chain = fn %State{} = st, ops, _opts ->
        Agent.update(batches_agent, &[{ops, st.source_dimensions} | &1])
        {:ok, st}
      end

      # The display-frame cover of the 80x40 display source into 20x20 is a
      # 40x20 display intermediate == a 20x40 storage forcing resize.
      inject = fn _image -> {20, 40} end

      assert {:ok, %State{}} =
               Executor.run_neutral(
                 plan,
                 shape,
                 state,
                 chain: capturing_chain,
                 measure_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      assert [
               {[%ExecResize{mode: :force}], _},
               {[%Crop{}, %ExecFlush{}], _},
               {[_blur], blur_source_dims}
             ] = batches

      # Storage-frame 20x20 crop box, quarter-turn-swapped by the flush -> 20x20.
      assert blur_source_dims == {20, 20}
    end
  end
end
