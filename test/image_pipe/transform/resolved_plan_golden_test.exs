defmodule ImagePipe.Transform.ResolvedPlanGoldenTest do
  @moduledoc """
  Cross-implementation net for the resolve-driven pipeline (Resolve Stage 1).

  For each case in `ImagePipe.Test.ResolvedPlanCases.cases/0` we run the NEW
  (resolve-driver-backed) pipeline via `record!/1` and compare its telemetry
  against the committed OLD-pipeline recording from `expected/0`. Both event
  streams are collapsed through ONE canonicalizer (`canonicalize/1`) that folds
  ONLY the two prescribed representational shifts introduced by making the
  orientation flush an explicit `%Flush{}` op; every other difference (an op's
  realized dims, an op appearing/disappearing, a flush moving or changing frame)
  survives canonicalization and fails the golden. That surviving-difference
  behavior IS the net.

  See `canonicalize/1` for the two rules.
  """

  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Test.ResolvedPlanCases
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.ResolveDriver
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @expected ResolvedPlanCases.expected()

  # ── The normalization contract ────────────────────────────────────────────
  #
  # Making the pending-orientation flush an explicit `%Flush{}` op shifts the
  # telemetry REPRESENTATION in exactly two ways between the OLD and NEW
  # pipelines. `canonicalize/1` collapses ONLY these two and nothing else.
  #
  # Rule A — flush representation.
  #   OLD: a boundary/scheduler flush is a STANDALONE materialize pair
  #        `{:materialize_start}, {:materialize_stop, dims, result}`.
  #   NEW: the same flush is an explicit `%Flush{}` op wrapping that pair:
  #        `{:op_start, :flush, i, _}, {:materialize_start},
  #         {:materialize_stop, dims, _}, {:op_stop, :flush, i, dims, _}`.
  #   Both collapse to a single `{:flush, dims}` token at that ordinal position.
  #   The flush op's index and the op-span wrapper are dropped; the dims and the
  #   position are preserved.
  #
  # Rule B — requires_materialization? nesting.
  #   A materializing op (trim, any `requires_materialization?: true` op) shows
  #   its materialize pair STANDALONE-BEFORE the op in the OLD stream but NESTED
  #   inside the op's span in the NEW stream. Both collapse so the materialize is
  #   attributed to that op at the same position:
  #        `{:op, name, dims, materialized: true}`.
  #
  # Disambiguating a STANDALONE materialize pair (OLD stream): a standalone pair
  # immediately followed by an `{:op_start, ...}` is that op's own
  # materialization (Rule B, standalone-before form); any other standalone pair
  # is a flush (Rule A). This is the only place old-vs-new shape differs, and it
  # matches the recorder's stated convention.
  #
  # A materialize pair NESTED inside an op span attributes to that op: if the op
  # is `:flush` the frame emits `{:flush, dims}` (Rule A, new form); otherwise it
  # marks the op `materialized: true` (Rule B, new form).
  #
  # The result is a single ordered token stream mixing `{:op, name, dims,
  # materialized}` and `{:flush, dims}` tokens. Comparing the full stream keeps
  # both the op sequence (with realized dims) and the flush tokens (position +
  # dims) in one assertion.

  @doc false
  def canonicalize(events), do: canonicalize(events, [], [])

  # Done: reverse the accumulated tokens.
  defp canonicalize([], [], acc), do: Enum.reverse(acc)

  # Standalone materialize pair (no open op frame). Peek ahead: an immediately
  # following op_start makes this the following op's own materialization (Rule B
  # standalone-before) — attributed when that op stops. Otherwise it is a flush
  # (Rule A old form) → emit a {:flush, dims} token here.
  #
  # This peek-ahead assumes a SINGLE pipeline per case: a mid-stream boundary
  # flush immediately followed by the next pipeline's first op would otherwise
  # be misclassified as that op's own Rule-B materialization, hiding a real
  # reorder. `cases/0` is guarded below to fail loudly the day a case adds a
  # second pipeline (Stage 2 SetFocus/TwicPics multi-pipeline plans).
  defp canonicalize(
         [{:materialize_start}, {:materialize_stop, dims, _res} | rest],
         [] = _stack,
         acc
       ) do
    case rest do
      [{:op_start, _n, _i, _p} | _] ->
        # Rule B standalone-before: carry the pending materialize as a sentinel
        # so the next op_start's frame picks it up.
        canonicalize(rest, [{:pending_materialize, dims}], acc)

      _ ->
        canonicalize(rest, [], [{:flush, dims} | acc])
    end
  end

  # op_start with a pending standalone materialize (Rule B old form): open the
  # op frame already marked materialized.
  defp canonicalize(
         [{:op_start, name, _i, _p} | rest],
         [{:pending_materialize, _mdims}],
         acc
       ) do
    canonicalize(rest, [{name, true}], acc)
  end

  # op_start (no pending): open an unmaterialized op frame.
  defp canonicalize([{:op_start, name, _i, _p} | rest], [], acc) do
    canonicalize(rest, [{name, false}], acc)
  end

  # Materialize pair NESTED inside an open op frame: attribute to that op. Mark
  # the frame materialized (the frame decides flush-vs-op at op_stop).
  defp canonicalize(
         [{:materialize_start}, {:materialize_stop, _dims, _res} | rest],
         [{name, _materialized?}],
         acc
       ) do
    canonicalize(rest, [{name, true}], acc)
  end

  # op_stop: close the frame. A :flush op emits {:flush, dims}; any other op
  # emits {:op, name, dims, materialized: bool}.
  defp canonicalize([{:op_stop, name, _i, dims, _res} | rest], [{name, materialized?}], acc) do
    token =
      case name do
        :flush -> {:flush, dims}
        _ -> {:op, name, dims, materialized: materialized?}
      end

    canonicalize(rest, [], [token | acc])
  end

  describe "ResolvedPlan golden (old-path-baked, two-rule canonicalizer)" do
    for kase <- ResolvedPlanCases.cases() do
      @kase kase
      @tag :resolved_plan_golden
      test "#{kase.name}: new pipeline reproduces old op/flush/dims" do
        parsed_plan = ResolvedPlanCases.parse_plan!(@kase)

        assert length(parsed_plan.pipelines) == 1,
               "#{@kase.name}: canonicalize/1's peek-ahead heuristic assumes a single " <>
                 "pipeline per case (a mid-stream boundary flush would be misclassified " <>
                 "as the next pipeline's op materialization) — got #{length(parsed_plan.pipelines)} pipelines"

        recorded = ResolvedPlanCases.record!(@kase)
        expected = Enum.find(@expected, &(&1.name == @kase.name))

        assert expected, "no committed expected recording for #{@kase.name}"

        new_tokens = canonicalize(recorded.events)
        old_tokens = canonicalize(expected.events)

        assert new_tokens == old_tokens,
               """
               #{@kase.name}: canonical token streams diverge.

               NEW (resolve driver): #{inspect(new_tokens, pretty: true)}
               OLD (pre-cutover):    #{inspect(old_tokens, pretty: true)}

               Raw NEW events: #{inspect(recorded.events, pretty: true)}
               Raw OLD events: #{inspect(expected.events, pretty: true)}
               """

        assert recorded.final_dims == expected.final_dims,
               "#{@kase.name}: final_dims #{inspect(recorded.final_dims)} != #{inspect(expected.final_dims)}"

        assert recorded.final_materialized == expected.final_materialized,
               "#{@kase.name}: final_materialized #{inspect(recorded.final_materialized)} != #{inspect(expected.final_materialized)}"
      end
    end
  end

  describe "identity-streaming guard" do
    # EXIF orientation 1 with effects only: the pipeline must never flush and must
    # end unmaterialized. A regression that always flushes at the boundary flips
    # this true and fails here (this is a NEW assertion, not a recording).
    test "identity pending streams — no flush, materialized? stays false" do
      kase = Enum.find(ResolvedPlanCases.cases(), &(&1.name == :identity_streaming))
      recorded = ResolvedPlanCases.record!(kase)

      refute recorded.final_materialized,
             "identity_streaming must end materialized? == false (a regression that always flushes flips this)"

      flush_tokens =
        recorded.events
        |> canonicalize()
        |> Enum.filter(&match?({:flush, _}, &1))

      assert flush_tokens == [],
             "identity_streaming must record no flush, got #{inspect(flush_tokens)}"
    end
  end

  describe "±1 divergence (synthetic, driver-seam injection)" do
    # Proves downstream consumers follow the ACQUIRED dims, not the planned dims.
    #
    # Plan = a plain fit resize (acquires its realized dims) followed by a
    # 1/3 gravity crop (a downstream consumer that resolves against the acquired
    # frame). We run ResolveDriver.run/5 directly with:
    #   * opts[:chain] — a capturing chain: it records each op batch and the
    #     source_dimensions the driver overlaid onto State before that batch, and
    #     returns State unchanged (no pixels ever run).
    #   * opts[:acquire_dims] — injecting the resize's realized dims MINUS ONE
    #     ({199, 149}) at its :acquire, standing in for the ±1 float-rounding
    #     skew that real libvips can produce and that we cannot force otherwise.
    #
    # The reference "recorded_realized" is the committed golden's plain fit
    # resize into 200x150 over high_freq.jpg (resolved_plan_expected.exs:
    # {:op_stop, :resize, 0, {200, 150}, :ok}). We inject {199, 149}.
    #
    # imgproxy crop-size math (ground truth, /Users/hlindset/src/imgproxy):
    #   * prepare.go:56-65  CalcCropSize(orig, crop): for 0<crop<1 returns
    #     max(1, imath.Scale(orig, crop)).
    #   * imath/imath.go:24-30  Scale(a, s) = Round(a*s); imath.go:16-18
    #     Round = math.Round = round half away from zero.
    #   * prepare.go:272-273  c.CropWidth  = CalcCropSize(SrcWidth,  CropWidth())
    #                         c.CropHeight = CalcCropSize(SrcHeight, CropHeight())
    #   * crop.go:15          CropWidth = MinNonZero(cropWidth, imgWidth) (clamp).
    #   The crop resolves BEFORE the scale (crop.go), i.e. against the acquired
    #   source frame — this is why the downstream box follows acquired dims.
    #
    # Hand-derived boxes for a 1/3 crop:
    #   from acquired {199, 149}: width Round(199/3)=Round(66.333)=66,
    #                             height Round(149/3)=Round(49.666)=50
    #   from planned  {200, 150}: width Round(200/3)=Round(66.666)=67,
    #                             height Round(150/3)=Round(50.000)=50
    #   The WIDTH axis diverges (67 -> 66) under the -1 injection; the height axis
    #   happens not to cross a rounding boundary at 150->149 (50 both ways), which
    #   is exactly why the width axis is the documented ±1 edge here.
    test "downstream 1/3 crop resolves against acquired (recorded-1) dims" do
      recorded_realized = {200, 150}
      injected = {199, 149}

      # ImagePipe.Transform.Geometry.round_half_away_from_zero mirrors Go's
      # math.Round; assert on committed integers, not "sane" values.
      expected_box_from_acquired = {66, 50}
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

      # Inject recorded_realized - 1 at the resize's :acquire.
      inject = fn _image -> injected end

      assert {:ok, %State{}} =
               ResolveDriver.run(
                 plan,
                 shape,
                 {NeutralResolver, NeutralResolver.init()},
                 state,
                 chain: capturing_chain,
                 acquire_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      # Two op batches: [resize] then [crop]. The crop batch's overlaid
      # source_dimensions is the acquired (injected) frame — the direct evidence
      # the driver propagated the acquired dims to the downstream consumer.
      assert [{[%_{}], _resize_dims}, {[%Crop{} = crop], crop_source_dims}] = batches

      assert crop_source_dims == injected,
             "downstream crop saw source_dimensions #{inspect(crop_source_dims)}, expected acquired #{inspect(injected)}"

      # The crop is a symbolic 1/3 scale; the executable box comes from resolving
      # it against the frame the driver fed it. Resolving against the acquired
      # frame yields the hand-derived box and differs from the planned frame's.
      {aw, ah} = injected
      box_from_acquired = Crop.resolved_box_dims(crop, aw, ah)
      {pw, ph} = recorded_realized
      box_from_planned = Crop.resolved_box_dims(crop, pw, ph)

      assert box_from_acquired == expected_box_from_acquired
      assert box_from_planned == expected_box_from_planned

      assert box_from_acquired != box_from_planned,
             "the ±1 injection must move the downstream box (acquired vs planned): #{inspect(box_from_acquired)} vs #{inspect(box_from_planned)}"

      # Keep w0/h0 referenced so the recorded reference stays self-documenting.
      assert {w0, h0} == recorded_realized
    end
  end
end
