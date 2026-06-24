defmodule ImagePipe.Output.EncodeSearch do
  @moduledoc """
  Best-effort binary search over encoder quality.

  Given a resolved quality-search objective (`:size`, `:ssimulacra2`, or
  `:butteraugli`) and/or a hard `max_bytes` budget, probe candidate qualities
  within `[min_quality, max_quality]` and return the already-encoded buffer for
  the winning quality, alongside `meta` describing the outcome.

  Two public entry points:

    * `search/3` — the pure core. Encoding and scoring are injected as closures
      (`:encode_fun`, `:score_fun`), so the loop is fully testable without real
      images. It owns memoization, the iteration cap, the objective phase, and
      the `max_bytes` cap phase.
    * `run/3` — the production wrapper. It extracts the objective and budget from
      a `%ImagePipe.Output.Resolved{}`, builds the real encode/score closures
      from `ImagePipe.Output.Encoder` and the metric runtime under
      `ImagePipe.Output.Metric.*`, and delegates to `search/3`.

  ## Monotonicity contract

  The binary search assumes encoded byte size is non-decreasing in quality, and
  the perceptual score is monotone in quality in the metric's direction —
  non-decreasing for `:higher_better` (SSIMULACRA2), non-increasing for
  `:lower_better` (butteraugli distance). The loop branches on direction rather
  than negating, so each walk arm is audited per polarity. Real encoders can
  violate this locally. The consequence is bounded — the result may be a step or
  two off the true optimum — and acceptable for a best-effort search: the winning
  quality is always one that was actually probed and re-measured, and is always
  within `[min_quality, max_quality]`. Do not "fix" a real-encoder flake by
  replacing the search.
  """

  alias ImagePipe.Output.ContentClassifier
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.JxlDistance
  alias ImagePipe.Output.Metric
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Telemetry

  @default_max_iterations 6
  @default_max_bump_passes 2
  @max_bytes_alone_floor 10
  @max_bytes_alone_base 90

  @type outcome :: :hit | :best_effort | :skipped | :native

  # Why a `:best_effort` result fell short of the objective/budget. `nil` on a
  # `:hit`. `:ceiling`/`:floor` — the objective never cleared its band/target and
  # pinned to the bracket ceiling/floor; `:max_bytes` — the hard budget could not
  # be met even at the floor; `:bump_exhausted` — the crop confirm undershot
  # through every bump pass.
  @type limiting_factor :: :ceiling | :floor | :max_bytes | :bump_exhausted

  @type meta :: %{
          # 0 = native distance encode, no Q chosen
          quality: 0..100,
          bytes: non_neg_integer(),
          iterations: non_neg_integer(),
          outcome: outcome(),
          score: float() | nil,
          confirm_passes: non_neg_integer(),
          scorer: :full | :crop,
          tiles_scored: pos_integer() | nil,
          limiting_factor: limiting_factor() | nil
        }

  # Mutable-ish search context threaded through the loop as an immutable struct.
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:encode_fun]
    defstruct encode_fun: nil,
              score_fun: nil,
              confirm_fun: nil,
              confirm_band: nil,
              confirm_max_quality: nil,
              max_bump_passes: 2,
              scorer: :full,
              scorer_tiles: nil,
              encode_memo: %{},
              score_memo: %{},
              confirm_memo: %{},
              probe_log: %{},
              confirm_passes: 0,
              iterations: 0,
              max_iterations: 0,
              phase: nil,
              limiting_factor: nil,
              telemetry_opts: []
  end

  @doc """
  Pure search core. See the module doc for `:encode_fun`/`:score_fun`/
  `:base_quality`/`:max_iterations` semantics.
  """
  @spec search(
          :none | RQS.Size.t() | RQS.Ssimulacra2.t() | RQS.Butteraugli.t(),
          nil | pos_integer(),
          keyword()
        ) ::
          {:ok, binary(), meta()} | {:error, term()}
  def search(quality_search, max_bytes, opts) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])

    ctx = %Ctx{
      encode_fun: Keyword.fetch!(opts, :encode_fun),
      score_fun: Keyword.get(opts, :score_fun),
      confirm_fun: Keyword.get(opts, :confirm_fun),
      confirm_band: Keyword.get(opts, :confirm_band),
      confirm_max_quality: Keyword.get(opts, :confirm_max_quality),
      max_bump_passes: Keyword.get(opts, :max_bump_passes, @default_max_bump_passes),
      scorer: Keyword.get(opts, :scorer, :full),
      scorer_tiles: Keyword.get(opts, :scorer_tiles),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      telemetry_opts: telemetry_opts
    }

    Telemetry.span(
      telemetry_opts,
      [:encode, :search],
      search_start_meta(quality_search, max_bytes),
      fn ->
        result = do_search(quality_search, max_bytes, ctx, opts)
        {result, search_stop_meta(quality_search, result)}
      end
    )
  end

  defp do_search(quality_search, max_bytes, ctx, opts) do
    with {:ok, objective_q, objective_outcome, _objective_score, ctx} <-
           objective_phase(quality_search, %{ctx | phase: :objective}, opts),
         {:ok, confirmed_q, confirmed_outcome, ctx} <-
           confirm_phase(objective_q, objective_outcome, ctx),
         {:ok, final_q, final_outcome, ctx} <-
           cap_phase(quality_search, max_bytes, confirmed_q, confirmed_outcome, ctx) do
      build_result(final_q, final_outcome, ctx)
    end
  end

  # Product-neutral search descriptor for the span start: objective + bracket +
  # target/budget. `:none` (max_bytes-alone) carries nils for the objective-only
  # fields. No URLs/secrets — derived from the resolved descriptor and budget.
  defp search_start_meta(%mod{} = rqs, max_bytes)
       when mod in [RQS.Size, RQS.Ssimulacra2, RQS.Butteraugli] do
    %{
      objective: objective_of(rqs),
      min_quality: rqs.min_quality,
      max_quality: rqs.max_quality,
      target: rqs.target,
      max_bytes: max_bytes
    }
  end

  defp search_start_meta(:none, max_bytes) do
    %{
      objective: :none,
      min_quality: nil,
      max_quality: nil,
      target: nil,
      max_bytes: max_bytes
    }
  end

  # Map the result `meta` onto telemetry keys. The keys deliberately differ from
  # the internal `meta` (`chosen_*` vs `quality`/`bytes`) so an observer reads
  # the search verdict, not the loop's bookkeeping. `:result` gives the generic
  # Logger fallback an outcome.
  defp search_stop_meta(quality_search, {:ok, _binary, meta}) do
    %{
      result: :ok,
      objective: objective_of(quality_search),
      chosen_quality: meta.quality,
      chosen_bytes: meta.bytes,
      iterations: meta.iterations,
      outcome: meta.outcome,
      final_score: meta.score,
      scorer: meta.scorer,
      tiles_scored: meta.tiles_scored,
      confirm_passes: meta.confirm_passes,
      limiting_factor: meta.limiting_factor
    }
  end

  defp search_stop_meta(quality_search, {:error, reason}) do
    %{result: :processing_error, objective: objective_of(quality_search), error: reason}
  end

  defp objective_of(:none), do: :none
  defp objective_of(%RQS.Size{}), do: :size
  defp objective_of(%RQS.Ssimulacra2{}), do: :ssimulacra2
  defp objective_of(%RQS.Butteraugli{}), do: :butteraugli

  @doc """
  Production wrapper. Builds the real encode/score closures from an already
  finalized image plus its `%Resolved{}`, then delegates to `search/3`.
  """
  @spec run(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, binary(), meta()} | {:error, term()}
  def run(
        finalized_image,
        %Resolved{quality_search: %RQS.NativeJxlButteraugli{} = nqs} = resolved,
        opts
      ) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])
    native_jxl_butteraugli(finalized_image, nqs, resolved.max_bytes, telemetry_opts)
  end

  def run(finalized_image, %Resolved{} = resolved, opts) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])
    encode_fun = fn quality -> encode_leg(finalized_image, resolved, quality, telemetry_opts) end
    scorer = Keyword.get(opts, :scorer, :full)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    with {:ok, search_opts} <- score_opts(finalized_image, resolved, scorer, telemetry_opts) do
      base_quality = base_quality(resolved)

      try do
        search(
          resolved.quality_search,
          resolved.max_bytes,
          [
            encode_fun: encode_fun,
            base_quality: base_quality,
            max_iterations: max_iterations,
            scorer: scorer,
            telemetry_opts: telemetry_opts
          ] ++ search_opts
        )
      catch
        {:image_pipe_score_error, reason} -> {:error, {:encode, reason}}
      end
    end
  end

  # --- native JXL butteraugli strategy --------------------------------------

  @native_distance_max 25.0

  # libvips drives JXL `distance` directly: there is no external measure and no
  # band loop. We clamp the target into the Q-bracket's distance range, then
  # either encode once (no max_bytes) or degrade distance until the bytes fit.
  defp native_jxl_butteraugli(image, nqs, max_bytes, telemetry_opts) do
    # Q-bracket → distance bracket; clamp the target. `dist` is decreasing in Q,
    # so max_quality is the distance floor (lowest distance / highest quality
    # allowed) and min_quality is the distance ceiling.
    dist_floor = JxlDistance.from_quality(nqs.max_quality)
    dist_ceil = JxlDistance.from_quality(nqs.min_quality)
    effective = nqs.target |> max(dist_floor) |> min(dist_ceil)

    Telemetry.span(telemetry_opts, [:encode, :search], native_start_meta(nqs, max_bytes), fn ->
      result = native_encode(image, effective, max_bytes)
      {result, native_stop_meta(result)}
    end)
  end

  defp native_encode(image, distance, nil) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance) do
      {:ok, bin, native_meta(bin, :native, nil)}
    end
  end

  defp native_encode(image, distance, max_bytes) do
    native_descend(image, distance, max_bytes)
  end

  # Raise distance (degrade) from the clamped target until bytes fit or we hit the
  # distance ceiling. Coarse geometric steps; max_bytes is the hard cap.
  # `effective` is always <= dist_ceil = from_quality(min_quality) <= ~14.5
  # (min_quality >= 1), and `min/2` caps each step at exactly 25.0, so the
  # recursion saturates at @native_distance_max in finite steps.
  defp native_descend(image, distance, max_bytes) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance) do
      cond do
        byte_size(bin) <= max_bytes ->
          {:ok, bin, native_meta(bin, :native, nil)}

        distance >= @native_distance_max ->
          {:ok, bin, native_meta(bin, :best_effort, :max_bytes)}

        true ->
          native_descend(image, min(@native_distance_max, distance * 1.5 + 0.5), max_bytes)
      end
    end
  end

  defp native_meta(bin, outcome, factor) do
    %{
      # 0 = native distance encode, no Q chosen
      quality: 0,
      bytes: byte_size(bin),
      iterations: 0,
      outcome: outcome,
      score: nil,
      confirm_passes: 0,
      scorer: :full,
      tiles_scored: nil,
      limiting_factor: factor
    }
  end

  defp native_start_meta(nqs, max_bytes) do
    %{
      objective: :butteraugli,
      min_quality: nqs.min_quality,
      max_quality: nqs.max_quality,
      target: nqs.target,
      max_bytes: max_bytes
    }
  end

  defp native_stop_meta({:ok, _binary, meta}) do
    %{
      result: :ok,
      objective: :butteraugli,
      chosen_quality: meta.quality,
      chosen_bytes: meta.bytes,
      iterations: meta.iterations,
      outcome: meta.outcome,
      final_score: meta.score,
      scorer: meta.scorer,
      tiles_scored: meta.tiles_scored,
      confirm_passes: meta.confirm_passes,
      limiting_factor: meta.limiting_factor
    }
  end

  defp native_stop_meta({:error, reason}) do
    %{result: :processing_error, objective: :butteraugli, error: reason}
  end

  @doc """
  Whether to skip the search entirely because the image is too large. True only
  when `max_resolution` is positive and the image megapixels exceed it. The
  caller stamps `outcome: :skipped` and encodes once at the resolved quality.
  """
  @spec skip?(%{max_resolution: non_neg_integer()}, number()) :: boolean()
  def skip?(%{max_resolution: max_resolution}, megapixels),
    do: max_resolution > 0 and megapixels > max_resolution

  # --- objective phase ------------------------------------------------------

  # No objective: the caller is running a max_bytes-alone search. The "objective
  # quality" upper bound is the supplied base_quality (or a sane default).
  defp objective_phase(:none, ctx, opts) do
    base = Keyword.get(opts, :base_quality, @max_bytes_alone_base)
    {:ok, base, :none, nil, ctx}
  end

  defp objective_phase(%RQS.Size{} = rqs, ctx, _opts) do
    # Highest q in [min, max] with byte_size <= target.
    predicate = fn bytes, _score -> bytes <= rqs.target end

    case search_highest_satisfying(rqs.min_quality, rqs.max_quality, predicate, ctx) do
      {:error, _} = err ->
        err

      {best, outcome, ctx} ->
        # None fit → floor (min_quality), best-effort.
        chosen = best || rqs.min_quality
        ctx = set_factor(ctx, if(best, do: nil, else: :floor))
        with {:ok, ctx} <- ensure_probed(chosen, ctx), do: {:ok, chosen, outcome, nil, ctx}
    end
  end

  defp objective_phase(%RQS.Ssimulacra2{} = rqs, ctx, _opts),
    do: quality_objective_phase(rqs, :higher_better, ctx)

  defp objective_phase(%RQS.Butteraugli{} = rqs, ctx, _opts),
    do: quality_objective_phase(rqs, :lower_better, ctx)

  defp quality_objective_phase(rqs, direction, ctx) do
    band_lo = rqs.target - rqs.allowed_error
    band_hi = rqs.target + rqs.allowed_error

    case search_to_target(rqs.min_quality, rqs.max_quality, band_lo, band_hi, direction, ctx) do
      {:error, _} = err ->
        err

      {chosen, outcome, factor, ctx} ->
        ctx = set_factor(ctx, factor)

        with {:ok, ctx} <- ensure_probed(chosen, ctx) do
          {:ok, chosen, outcome, Map.get(ctx.score_memo, chosen), ctx}
        end
    end
  end

  # --- cap (max_bytes) phase ------------------------------------------------

  # No hard byte budget: the objective's result stands.
  defp cap_phase(_quality_search, nil, objective_q, objective_outcome, ctx),
    do: {:ok, objective_q, objective_outcome, ctx}

  defp cap_phase(quality_search, max_bytes, objective_q, objective_outcome, ctx) do
    floor = cap_floor(quality_search)
    ctx = %{ctx | phase: :cap}

    with {:ok, ctx} <- ensure_probed(objective_q, ctx) do
      upper_bytes = byte_size(Map.fetch!(ctx.encode_memo, objective_q))

      if upper_bytes <= max_bytes do
        # Objective pick already fits the hard budget. For a max_bytes-alone
        # search (objective `:none`) the budget IS the predicate, so a fit is a
        # `:hit`; for a real objective its own verdict stands (the budget didn't
        # bind), so keep it.
        {:ok, objective_q, fit_outcome(objective_outcome), ctx}
      else
        cap_descend(floor, objective_q, max_bytes, ctx)
      end
    end
  end

  defp fit_outcome(:none), do: :hit
  defp fit_outcome(outcome), do: outcome

  # Objective pick exceeds the byte budget — search [floor, objective_q] for the
  # highest q that fits, falling back to the floor when even it exceeds.
  defp cap_descend(floor, objective_q, max_bytes, ctx) do
    predicate = fn bytes, _score -> bytes <= max_bytes end

    case search_highest_satisfying(floor, objective_q, predicate, ctx) do
      {:error, _} = err ->
        err

      {nil, _outcome, ctx} ->
        ctx = set_factor(ctx, :max_bytes)

        with {:ok, ctx} <- ensure_probed(floor, ctx),
             do: {:ok, floor, :best_effort, ctx}

      {best, outcome, ctx} ->
        {:ok, best, outcome, set_factor(ctx, nil)}
    end
  end

  defp cap_floor(:none), do: @max_bytes_alone_floor
  defp cap_floor(%RQS.Size{min_quality: min_quality}), do: min_quality
  defp cap_floor(%RQS.Ssimulacra2{min_quality: min_quality}), do: min_quality
  defp cap_floor(%RQS.Butteraugli{min_quality: min_quality}), do: min_quality

  # --- confirm phase (objective-neutral re-validation) ----------------------

  # No confirm closure: the objective's verdict stands. Every production path takes
  # this clause — full-frame ssim2, :size, :none, and (since #369) crop scoring,
  # which ships its objective winner directly using the conservative offset.
  defp confirm_phase(objective_q, objective_outcome, %Ctx{confirm_fun: nil} = ctx),
    do: {:ok, objective_q, objective_outcome, ctx}

  # A `confirm_fun` was supplied (the `mix autoquality.bench` crop+confirm
  # baseline): the objective ran on an ESTIMATE, so re-validate the winner against
  # the authoritative measure and linear-bump on undershoot (cap @max_bump_passes).
  defp confirm_phase(objective_q, _objective_outcome, ctx) do
    with {:ok, ctx} <- confirm_score(objective_q, :confirm, ctx) do
      if Map.fetch!(ctx.confirm_memo, objective_q) >= ctx.confirm_band do
        {:ok, objective_q, :hit, set_factor(ctx, nil)}
      else
        bump(objective_q, ctx)
      end
    end
  end

  # Linear scan q+1..q+cap (bounded by confirm_max_quality), first clearing q wins;
  # else best-effort at the highest q tried. Linear (not binary) is deliberate:
  # encoder score-vs-quality is only approximately monotone, and a linear scan
  # catches a local non-monotone dip a binary step could skip.
  defp bump(objective_q, %Ctx{max_bump_passes: cap, confirm_max_quality: max_q} = ctx) do
    last_q = min(objective_q + cap, max_q)
    do_bump(objective_q + 1, last_q, objective_q, ctx)
  end

  defp do_bump(try_q, last_q, best_q, ctx) when try_q > last_q,
    do: {:ok, best_q, :best_effort, set_factor(ctx, :bump_exhausted)}

  defp do_bump(try_q, last_q, _best_q, ctx) do
    case confirm_score(try_q, :bump, ctx) do
      {:error, _} = err ->
        err

      {:ok, ctx} ->
        if Map.fetch!(ctx.confirm_memo, try_q) >= ctx.confirm_band,
          do: {:ok, try_q, :hit, set_factor(ctx, nil)},
          else: do_bump(try_q + 1, last_q, try_q, ctx)
    end
  end

  # Authoritatively score q once (memoized), counting the pass, under a confirm
  # probe span tagged with `phase` (:confirm | :bump). A confirm_memo hit emits
  # nothing. The probe span owns the encode/score legs: the encode is forced even
  # past the iteration cap (the confirm MUST run) and emits its `:encode` leg only
  # when q was not already encoded.
  defp confirm_score(q, phase, ctx) do
    if Map.has_key?(ctx.confirm_memo, q) do
      {:ok, ctx}
    else
      confirm_probe(q, phase, ctx)
    end
  end

  defp confirm_probe(q, phase, ctx) do
    Telemetry.span(
      ctx.telemetry_opts,
      [:encode, :search, :probe],
      %{quality: q, phase: phase},
      fn ->
        case ensure_encoded_raw(q, phase, ctx) do
          {:ok, ctx} ->
            score = ctx.confirm_fun.(Map.fetch!(ctx.encode_memo, q))

            ctx = %{
              ctx
              | confirm_memo: Map.put(ctx.confirm_memo, q, score),
                confirm_passes: ctx.confirm_passes + 1
            }

            {{:ok, ctx}, confirm_probe_meta(q, ctx)}

          {:error, reason} = err ->
            {err, %{result: :processing_error, error: reason}}
        end
      end
    )
  end

  # --- binary search primitives ---------------------------------------------

  # Find the HIGHEST q in [lo, hi] satisfying `predicate`. Monotone-decreasing
  # predicate (holds at q ⇒ holds at every lower q). Returns
  # {best_q | nil, :hit | :best_effort, ctx}: `:hit` when at least one probed q
  # satisfied; `best_q` is the highest such q. Stops early at the encode cap.
  defp search_highest_satisfying(lo, hi, predicate, ctx) do
    do_highest(lo, hi, predicate, ctx, nil)
  end

  defp do_highest(lo, hi, _predicate, ctx, best) when lo > hi do
    {best, outcome_for(best), ctx}
  end

  defp do_highest(lo, hi, predicate, ctx, best) do
    mid = div(lo + hi, 2)

    case probe(mid, predicate, ctx) do
      {:error, _} = err ->
        err

      {:capped, ctx} ->
        {best, outcome_for(best), ctx}

      {:satisfied, ctx} ->
        # mid fits; try to go higher.
        do_highest(mid + 1, hi, predicate, ctx, max_q(best, mid))

      {:unsatisfied, ctx} ->
        # mid too big; go lower.
        do_highest(lo, mid - 1, predicate, ctx, best)
    end
  end

  # Walk-to-target: converge toward the symmetric band `[band_lo, band_hi]`,
  # branching on the metric `direction`. Probe the midpoint; in-band → accept and
  # stop. The "acceptable overshoot" arm is the side that meets or *exceeds* the
  # quality target — for `:higher_better` that is `score > band_hi`, for
  # `:lower_better` (distance) it is `score < band_lo`. An acceptable overshoot is
  # recorded as the nearest-overshoot fallback and the walk continues *lower* in
  # quality (toward the band); the other arm walks *higher*. Returns
  # {chosen_q, :hit | :best_effort, limiting_factor | nil, ctx}.
  #
  # On an empty band (integer-quality granularity straddles it) the recorded
  # overshoot — the just-past-band q on the acceptable side — wins, a `:hit`
  # (quality target met). If no q ever reached or overshot the band (every probe
  # undershot up to max_quality), pin to the ceiling as a `:best_effort`/`:ceiling`
  # result. For both directions the acceptable q are found by walking *down* in
  # quality and the unreachable pin is the *ceiling* (max_quality, the best quality),
  # so `resolve_target`'s semantics hold under the `acceptable_overshoot?` flip.
  # `ceiling` (the original `hi`) is threaded so the fallback can name max_quality
  # after `hi` has narrowed.
  defp search_to_target(lo, hi, band_lo, band_hi, direction, ctx) do
    do_target(lo, hi, band_lo, band_hi, direction, hi, nil, ctx)
  end

  defp do_target(lo, hi, _band_lo, _band_hi, _direction, ceiling, overshoot, ctx)
       when lo > hi do
    resolve_target(overshoot, ceiling, ctx)
  end

  defp do_target(lo, hi, band_lo, band_hi, direction, ceiling, overshoot, ctx) do
    mid = div(lo + hi, 2)

    case probe_score(mid, ctx) do
      {:error, _} = err ->
        err

      {:capped, ctx} ->
        resolve_target(overshoot, ceiling, ctx)

      {:ok, score, ctx} ->
        cond do
          score >= band_lo and score <= band_hi ->
            {mid, :hit, nil, ctx}

          # Acceptable overshoot: a satisfying-or-better q. Record it (each is lower
          # in quality than the last) and search lower for an in-band q.
          acceptable_overshoot?(direction, score, band_lo, band_hi) ->
            do_target(lo, mid - 1, band_lo, band_hi, direction, ceiling, mid, ctx)

          true ->
            do_target(mid + 1, hi, band_lo, band_hi, direction, ceiling, overshoot, ctx)
        end
    end
  end

  defp acceptable_overshoot?(:higher_better, score, _band_lo, band_hi), do: score > band_hi
  defp acceptable_overshoot?(:lower_better, score, band_lo, _band_hi), do: score < band_lo

  # No overshoot ever seen → undershot to the ceiling (best-effort); else ship the
  # nearest overshoot (quality target met, just above the band).
  defp resolve_target(nil, ceiling, ctx), do: {ceiling, :best_effort, :ceiling, ctx}
  defp resolve_target(overshoot, _ceiling, ctx), do: {overshoot, :hit, nil, ctx}

  # Encode (and, for ssim2, score) `q`, memoizing both, then evaluate the
  # predicate. Returns :satisfied/:unsatisfied, or :capped when the encode cap
  # would be exceeded by a NEW distinct encode (already-memoized q never caps).
  defp probe(q, predicate, ctx) do
    case materialize(q, ctx) do
      {:error, _} = err ->
        err

      :capped ->
        {:capped, ctx}

      {:ok, bytes, score, ctx} ->
        if predicate.(bytes, score), do: {:satisfied, ctx}, else: {:unsatisfied, ctx}
    end
  end

  # Like `probe`, but surfaces the raw ssim2 score for the walk-to-target band
  # comparison instead of collapsing it through a predicate. `:capped` when a NEW
  # distinct encode would exceed the iteration cap.
  defp probe_score(q, ctx) do
    case materialize(q, ctx) do
      {:error, _} = err -> err
      :capped -> {:capped, ctx}
      {:ok, _bytes, score, ctx} -> {:ok, score, ctx}
    end
  end

  # Ensure q is encoded (and scored when a score_fun is present), memoized.
  # Returns {:ok, byte_size, score | nil, ctx} | :capped | {:error, _}. A NEW
  # distinct encode runs under an objective/cap probe span (memo hits and the cap
  # never reach it).
  defp materialize(q, ctx) do
    cond do
      Map.has_key?(ctx.encode_memo, q) ->
        bytes = byte_size(Map.fetch!(ctx.encode_memo, q))
        {:ok, bytes, Map.get(ctx.score_memo, q), ctx}

      ctx.iterations >= ctx.max_iterations ->
        :capped

      true ->
        case encode_probe(q, ctx) do
          {:ok, ctx} ->
            {:ok, byte_size(Map.fetch!(ctx.encode_memo, q)), Map.get(ctx.score_memo, q), ctx}

          {:error, _} = err ->
            err
        end
    end
  end

  # Encode a specific quality (e.g. the chosen boundary) without requiring the
  # predicate, so its buffer/score is in the memo for the final result. Respects
  # the cap only when a NEW encode is needed; if capped and already absent, we
  # force the encode anyway because the result MUST carry a real buffer. A NEW
  # encode runs under an objective/cap probe span (a memo hit emits nothing).
  defp ensure_probed(q, ctx) do
    if Map.has_key?(ctx.encode_memo, q), do: {:ok, ctx}, else: encode_probe(q, ctx)
  end

  # Encode (+ estimate-score) a NEW distinct q under a `[:encode, :search, :probe]`
  # span tagged with the current phase (:objective | :cap). `:index` is the
  # distinct-encode ordinal (`iterations` after the increment); `:score` is the
  # estimate when a score_fun ran, else nil. All product-neutral numbers. The
  # encode/decode/metric cost legs are emitted by the injected closures and nest
  # under this span.
  defp encode_probe(q, ctx) do
    Telemetry.span(
      ctx.telemetry_opts,
      [:encode, :search, :probe],
      %{quality: q, phase: ctx.phase},
      fn ->
        case do_encode(q, ctx.phase, ctx) do
          {:ok, ctx} -> {{:ok, ctx}, objective_probe_meta(q, ctx)}
          {:error, reason} = err -> {err, %{result: :processing_error, error: reason}}
        end
      end
    )
  end

  # Raw encode + memoize + estimate-score, WITHOUT a probe span: the caller owns
  # the span (encode_probe for objective/cap, confirm_probe for confirm/bump), so
  # a bump that encodes a never-seen q emits a single probe, not two. `phase` is
  # the enclosing probe span's phase, logged per distinct encode so the delivered
  # quality can later name the phase that actually produced its bytes.
  defp do_encode(q, phase, ctx) do
    case ctx.encode_fun.(q) do
      {:ok, binary} ->
        iterations = ctx.iterations + 1

        ctx = %{
          ctx
          | encode_memo: Map.put(ctx.encode_memo, q, binary),
            iterations: iterations,
            probe_log: Map.put(ctx.probe_log, q, %{phase: phase, index: iterations})
        }

        {:ok, maybe_score(q, binary, ctx)}

      {:error, _} = err ->
        err
    end
  end

  defp ensure_encoded_raw(q, phase, ctx) do
    if Map.has_key?(ctx.encode_memo, q), do: {:ok, ctx}, else: do_encode(q, phase, ctx)
  end

  defp maybe_score(_q, _binary, %Ctx{score_fun: nil} = ctx), do: ctx

  defp maybe_score(q, binary, %Ctx{score_fun: score_fun} = ctx) do
    %{ctx | score_memo: Map.put(ctx.score_memo, q, score_fun.(binary))}
  end

  defp set_factor(ctx, factor), do: %{ctx | limiting_factor: factor}

  # Stop metadata for an objective/cap probe: the encode + (estimate) score it just
  # produced. `:tiles_scored`/nil `:score` are stripped by the telemetry layer, so
  # the full-frame and :size/:none paths carry only the fields they populate.
  defp objective_probe_meta(q, ctx) do
    %{
      bytes: byte_size(Map.fetch!(ctx.encode_memo, q)),
      index: ctx.iterations,
      score: Map.get(ctx.score_memo, q),
      scorer: ctx.scorer,
      tiles_scored: ctx.scorer_tiles
    }
  end

  # Stop metadata for a confirm/bump probe. Production crop scoring no longer wires
  # a confirm (#369); this remains for `search/3` callers that pass a `confirm_fun`
  # (the `mix autoquality.bench` crop+confirm baseline). `:score` is the
  # authoritative full-frame score; `:crop_estimate` (the offset-corrected estimate)
  # and `:full_frame_score` + `:passed?` expose the crop→full residual — the
  # real-world accuracy of the correction.
  defp confirm_probe_meta(q, ctx) do
    full = Map.fetch!(ctx.confirm_memo, q)

    %{
      bytes: byte_size(Map.fetch!(ctx.encode_memo, q)),
      index: ctx.iterations,
      score: full,
      scorer: ctx.scorer,
      tiles_scored: ctx.scorer_tiles,
      crop_estimate: Map.get(ctx.score_memo, q),
      full_frame_score: full,
      passed?: full >= ctx.confirm_band
    }
  end

  defp outcome_for(nil), do: :best_effort
  defp outcome_for(_best), do: :hit

  defp max_q(nil, q), do: q
  defp max_q(best, q), do: max(best, q)

  # --- result assembly ------------------------------------------------------

  defp build_result(final_q, final_outcome, ctx) do
    binary = Map.fetch!(ctx.encode_memo, final_q)
    ctx = ensure_winner_scored(final_q, binary, ctx)

    emit_chosen(final_q, binary, ctx)

    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: result_score(final_q, ctx),
      confirm_passes: ctx.confirm_passes,
      scorer: ctx.scorer,
      tiles_scored: ctx.scorer_tiles,
      limiting_factor: limiting_factor_for(final_outcome, ctx)
    }

    {:ok, binary, meta}
  end

  # One-shot marker naming the delivered probe. The winning quality's encode IS the
  # bytes we ship — produced during the search and reused via memoization, with no
  # post-search re-encode — so there is no span of its own to tag as the winner.
  # Probe spans also close before the winner is known, so this is emitted once at
  # resolution rather than as an attribute on the (already-closed) probe span; it
  # folds onto the enclosing `[:encode, :search]` span. `:phase` names the phase
  # that actually encoded the delivered bytes (objective/cap, or bump when the
  # winner was first encoded during the confirm bump). All product-neutral; nils
  # (`:score`/`:tiles_scored` on the :size/:none/full-frame paths) are stripped by
  # the telemetry layer, matching the probe-span metadata.
  defp emit_chosen(final_q, binary, ctx) do
    probe = Map.get(ctx.probe_log, final_q, %{})

    Telemetry.execute(
      ctx.telemetry_opts,
      [:encode, :search, :probe, :chosen],
      %{},
      %{
        quality: final_q,
        bytes: byte_size(binary),
        phase: probe[:phase],
        index: probe[:index],
        score: result_score(final_q, ctx),
        scorer: ctx.scorer,
        tiles_scored: ctx.scorer_tiles
      }
    )
  end

  # The limiting factor is meaningful only for a degraded result; a `:hit` (or
  # `:skipped`) carries none, regardless of any factor a superseded phase staged.
  defp limiting_factor_for(:best_effort, ctx), do: ctx.limiting_factor
  defp limiting_factor_for(_outcome, _ctx), do: nil

  # meta.score must reflect the DELIVERED quality, never a different one. The cap
  # phase (byte-only predicate) can relocate the winner to a quality the objective
  # search never scored; score it now from its already-memoized buffer. This keys
  # off the injected closures (not the objective), so the core stays objective-neutral.

  # Crop mode (confirm_fun present): the authoritative score lives in confirm_memo;
  # a cap-relocated winner may not be there yet — confirm-score it so meta.score is
  # the true full-frame score, never the crop estimate in score_memo. `final_q` is
  # always already in encode_memo (build_result Map.fetch!es it first), so
  # confirm_score's ensure_probed never re-encodes/errors here, and a score-computation
  # failure throws {:image_pipe_score_error, _} (caught by run/3) rather than returning
  # an error tuple. Assert success rather than swallow an impossible error into a silent
  # estimate fallback.
  defp ensure_winner_scored(final_q, _binary, %Ctx{confirm_fun: fun} = ctx)
       when not is_nil(fun) do
    {:ok, ctx} = confirm_score(final_q, :confirm, ctx)
    ctx
  end

  # Full-frame scoring mode (score_fun present, no confirm): score a cap-relocated
  # winner from its already-memoized buffer so the reported score is the delivered q.
  defp ensure_winner_scored(final_q, binary, %Ctx{score_fun: fun} = ctx)
       when not is_nil(fun) do
    if Map.has_key?(ctx.score_memo, final_q), do: ctx, else: maybe_score(final_q, binary, ctx)
  end

  # No scoring objective (:size / :none).
  defp ensure_winner_scored(_final_q, _binary, ctx), do: ctx

  # Prefer the authoritative confirm score (crop mode); fall back to score_memo
  # (full-frame mode); nil when neither memo holds the q (:size / :none). A `case`
  # (not `||`) so a genuine score of 0.0 in confirm_memo is not treated as falsy.
  defp result_score(final_q, ctx) do
    case ctx.confirm_memo do
      %{^final_q => score} -> score
      _ -> Map.get(ctx.score_memo, final_q)
    end
  end

  # --- run/3 helpers --------------------------------------------------------

  # Build the objective score_fun (crop estimate or full-frame) for the resolved
  # objective and the chosen scorer. Returns extra search/3 opts. The score
  # closures emit the `:decode`/`:metric` cost legs; the core only sees an opaque
  # float-returning closure, never the decode/metric structure.
  defp score_opts(_image, %Resolved{quality_search: :none}, _scorer, _telemetry_opts),
    do: {:ok, []}

  defp score_opts(_image, %Resolved{quality_search: %RQS.Size{}}, _scorer, _t),
    do: {:ok, []}

  # Ssimulacra2 full-frame mode: one whole-frame reference; candidate scored whole.
  defp score_opts(image, %Resolved{quality_search: %RQS.Ssimulacra2{} = rqs}, :full, t) do
    full_frame_opts(Metric.runtime(rqs), image, t)
  end

  # Crop mode (above the crossover): crop score_fun (estimate) only — no full-frame
  # confirm/bump (#369). The per-`{format, content-class}` offset (resolved into
  # `rqs.quality_search_offsets`, #380) baked into the estimate replaces the confirm
  # as the crop→full correction; the content class is classified here once, lazily,
  # from the finalized pixels. The objective walk's verdict ships as-is, bounding the
  # large-image search to a flat ~4.2 MP metric sample. No whole-frame reference is
  # built — `crop_estimate` references per-tile via `CropScore.p10/2`, so the
  # O(pixels) full-frame reference (the very cost this path avoids) never runs; a
  # per-tile reference failure surfaces through the score closure's throw.
  defp score_opts(image, %Resolved{quality_search: %RQS.Ssimulacra2{} = rqs}, :crop, t) do
    tiles = CropScore.tile_count(Image.width(image), Image.height(image))
    offset = classify_offset(image, rqs.quality_search_offsets, t)
    crop = fn bytes -> crop_estimate(image, bytes, tiles, offset, t) end
    {:ok, [score_fun: crop, scorer_tiles: tiles]}
  end

  # Butteraugli: external-measure, full-frame only this cycle (the scorer is forced
  # to :full by Encoder.crop?/2, which only lets the Ssimulacra2 strategy crop).
  defp score_opts(image, %Resolved{quality_search: %RQS.Butteraugli{} = rqs}, _scorer, t) do
    full_frame_opts(Metric.runtime(rqs), image, t)
  end

  defp full_frame_opts(metric, image, t) do
    case metric.reference(image) do
      {:ok, ref} ->
        {:ok, [score_fun: fn bytes -> full_frame_score(metric, ref, bytes, nil, t) end]}

      {:error, reason} ->
        {:error, {:encode, reason}}
    end
  end

  # Classify the finalized image once and select its per-class offset, as a span
  # (#380). Emitted from `run/3`'s setup, before `search/3` opens `[:encode,
  # :search]`, so it is a sibling of the search under `[:encode]` — hence
  # `[:encode, :classify]`, not `…:search:classify`. `fetch!` trusts the resolver,
  # which always stamps both :photo and :graphic for an :ssim2 search (the only
  # objective reaching this path). The classifier is total — never raises — so the
  # span emits start/stop only.
  defp classify_offset(image, offsets, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:encode, :classify], %{}, fn ->
      {class, features} = ContentClassifier.classify(image)
      offset = Map.fetch!(offsets, class)

      {offset,
       %{
         result: :ok,
         content_class: class,
         applied_offset: offset,
         palette_ent: features.palette_ent,
         nat_var: features.nat_var
       }}
    end)
  end

  # The score_fun contract is float-returning, but Image.from_binary and
  # `metric.score/2` can fail. We surface such failures by throwing a tagged
  # tuple that run/3 catches around the search/3 call, mapping it to
  # {:error, {:encode, reason}}. A throw propagates through the leg span (→
  # `:exception`) and the enclosing probe span before reaching the catch.

  # Decode the candidate once and score the whole frame against the reference via
  # the metric runtime, each as a cost leg nested under the active probe span.
  defp full_frame_score(metric, ref, bytes, tiles, telemetry_opts) do
    candidate = decode_leg(bytes, telemetry_opts)

    metric_leg(telemetry_opts, tiles, fn ->
      case metric.score(ref, candidate) do
        {:ok, score} -> score
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end

  # Decode the candidate once; crop-score its tiles vs the base; subtract the
  # conservative confirm-skipped offset so the objective's walk-to-target band
  # comparison reproduces the full-frame decision without a full-frame confirm.
  defp crop_estimate(base, bytes, tiles, offset, telemetry_opts) do
    candidate = decode_leg(bytes, telemetry_opts)

    metric_leg(telemetry_opts, tiles, fn ->
      case CropScore.p10(base, candidate) do
        {:ok, p10} -> p10 - offset
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end

  # --- cost legs (emitted from run/3's closures; the pure core never sees them) -

  # The codec encode, as a leg nested under the active probe span. Method-neutral:
  # it fires for every objective (:size/:ssim2/:none), so unlike the scoring legs
  # it carries no metric-method name segment.
  defp encode_leg(image, resolved, quality, telemetry_opts) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, :encode],
      %{quality: quality},
      fn ->
        case Encoder.encode_to_buffer(image, resolved, quality) do
          {:ok, binary} = ok -> {ok, %{result: :ok, bytes: byte_size(binary)}}
          {:error, reason} = err -> {err, %{result: :processing_error, error: reason}}
        end
      end
    )
  end

  # Candidate decode, as an ssim2-namespaced leg. The metric method qualifies the
  # scoring legs (`:ssim2`) so a future metric (e.g. dssim) gets distinct span
  # names a backend can group by; a decode failure throws and surfaces as the
  # leg's `:exception`.
  defp decode_leg(bytes, telemetry_opts) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, :ssim2, :decode],
      %{bytes: byte_size(bytes)},
      fn ->
        case Image.from_binary(bytes) do
          {:ok, candidate} -> {candidate, %{result: :ok}}
          {:error, reason} -> throw({:image_pipe_score_error, reason})
        end
      end
    )
  end

  # One aggregate SSIMULACRA2 metric leg per probe (the crop path scores K tiles
  # internally; `:tiles_scored` records how many, but no per-tile span is emitted —
  # that detail lives in `mix autoquality.bench`).
  defp metric_leg(telemetry_opts, tiles, fun) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, :ssim2, :metric],
      %{tiles_scored: tiles},
      fn ->
        score = fun.()
        {score, %{result: :ok, score: score}}
      end
    )
  end

  defp base_quality(%Resolved{quality: {:quality, v}}), do: v

  defp base_quality(%Resolved{
         quality: :default,
         quality_search: %mod{max_quality: max_quality}
       })
       when mod in [RQS.Size, RQS.Ssimulacra2, RQS.Butteraugli],
       do: max_quality

  defp base_quality(%Resolved{quality: :default}), do: @max_bytes_alone_base
end
