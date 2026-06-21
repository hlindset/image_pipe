defmodule ImagePipe.Output.EncodeSearch do
  @moduledoc """
  Best-effort binary search over encoder quality.

  Given a resolved quality-search objective (`:size` or `:ssim2`) and/or a hard
  `max_bytes` budget, probe candidate qualities within `[min_quality,
  max_quality]` and return the already-encoded buffer for the winning quality,
  alongside `meta` describing the outcome.

  Two public entry points:

    * `search/3` — the pure core. Encoding and scoring are injected as closures
      (`:encode_fun`, `:score_fun`), so the loop is fully testable without real
      images. It owns memoization, the iteration cap, the objective phase, and
      the `max_bytes` cap phase.
    * `run/3` — the production wrapper. It extracts the objective and budget from
      a `%ImagePipe.Output.Resolved{}`, builds the real encode/score closures
      from `ImagePipe.Output.Encoder` and `ImagePipe.Output.Ssim2Metric`, and
      delegates to `search/3`.

  ## Monotonicity contract

  The binary search assumes encoded byte size is non-decreasing in quality and
  the SSIMULACRA2 score is non-decreasing in quality. Real encoders can violate
  this locally. The consequence is bounded — the result may be a step or two off
  the true optimum — and acceptable for a best-effort search: the winning
  quality is always one that was actually probed and re-measured, and is always
  within `[min_quality, max_quality]`. Do not "fix" a real-encoder flake by
  replacing the search.
  """

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Telemetry

  @default_max_iterations 6
  @default_max_bump_passes 2
  @max_bytes_alone_floor 10
  @max_bytes_alone_base 90

  # Crop-scoring p10→full-frame correction (offset = tile_p10 − full_frame_score).
  # Subtracted from the tile p10 so the unchanged objective predicate
  # (score >= target-allowed_error) reproduces the full-frame decision. Calibrated
  # for #354 on the codec-corpus (`mix autoquality.bench --part e`): the `clic` split
  # gives +0.29 and the held-out `clic_holdout` split −0.03 — their disagreement
  # shows a photo-only constant would overfit, so we use the content-diverse
  # macro-average (+0.22) across photographic/screen/large/web content. The
  # confirm/bump phase absorbs the per-image residual (spread ~±2–4 q). See
  # `docs/autoquality_benchmark.md` (Part E).
  @crop_macro_offset 0.22

  @type outcome :: :hit | :best_effort | :skipped

  @type meta :: %{
          quality: 1..100,
          bytes: non_neg_integer(),
          iterations: non_neg_integer(),
          outcome: outcome(),
          score: float() | nil,
          confirm_passes: non_neg_integer(),
          scorer: :full | :crop,
          tiles_scored: pos_integer() | nil
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
              confirm_passes: 0,
              iterations: 0,
              max_iterations: 0,
              telemetry_opts: []
  end

  @doc """
  Pure search core. See the module doc for `:encode_fun`/`:score_fun`/
  `:base_quality`/`:max_iterations` semantics.
  """
  @spec search(:none | RQS.t(), nil | pos_integer(), keyword()) ::
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
           objective_phase(quality_search, ctx, opts),
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
  defp search_start_meta(%RQS{} = rqs, max_bytes) do
    %{
      objective: rqs.objective,
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
      confirm_passes: meta.confirm_passes
    }
  end

  defp search_stop_meta(quality_search, {:error, reason}) do
    %{result: :processing_error, objective: objective_of(quality_search), error: reason}
  end

  defp objective_of(:none), do: :none
  defp objective_of(%RQS{objective: objective}), do: objective

  @doc """
  Production wrapper. Builds the real encode/score closures from an already
  finalized image plus its `%Resolved{}`, then delegates to `search/3`.
  """
  @spec run(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, binary(), meta()} | {:error, term()}
  def run(finalized_image, %Resolved{} = resolved, opts) do
    encode_fun = fn quality -> Encoder.encode_to_buffer(finalized_image, resolved, quality) end
    scorer = Keyword.get(opts, :scorer, :full)

    # The confirm/bump phase does up to @default_max_bump_passes + 1 MANDATORY
    # encodes (1 confirm + the bump steps). Give crop mode that much headroom over
    # the objective-search cap so confirm/bump never starve the objective search or
    # the max_bytes cap-descent of their probe budget.
    max_iterations =
      Keyword.get(opts, :max_iterations, @default_max_iterations) + bump_headroom(scorer)

    with {:ok, search_opts} <- score_opts(finalized_image, resolved, scorer) do
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
            telemetry_opts: Keyword.get(opts, :telemetry_opts, [])
          ] ++ search_opts
        )
      catch
        {:image_pipe_score_error, reason} -> {:error, {:encode, reason}}
      end
    end
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

  defp objective_phase(%RQS{objective: :size} = rqs, ctx, _opts) do
    # Highest q in [min, max] with byte_size <= target.
    predicate = fn bytes, _score -> bytes <= rqs.target end

    case search_highest_satisfying(rqs.min_quality, rqs.max_quality, predicate, ctx) do
      {:error, _} = err ->
        err

      {best, outcome, ctx} ->
        # None fit → floor (min_quality), best-effort.
        chosen = best || rqs.min_quality
        with {:ok, ctx} <- ensure_probed(chosen, ctx), do: {:ok, chosen, outcome, nil, ctx}
    end
  end

  defp objective_phase(%RQS{objective: :ssim2} = rqs, ctx, _opts) do
    band = rqs.target - rqs.allowed_error
    # Lowest q in [min, max] with score >= band.
    predicate = fn _bytes, score -> score >= band end

    case search_lowest_satisfying(rqs.min_quality, rqs.max_quality, predicate, ctx) do
      {:error, _} = err ->
        err

      {best, outcome, ctx} ->
        # None clear → ceiling (max_quality), best-effort.
        chosen = best || rqs.max_quality

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
        with {:ok, ctx} <- ensure_probed(floor, ctx),
             do: {:ok, floor, :best_effort, ctx}

      {best, outcome, ctx} ->
        {:ok, best, outcome, ctx}
    end
  end

  defp cap_floor(:none), do: @max_bytes_alone_floor
  defp cap_floor(%RQS{min_quality: min_quality}), do: min_quality

  # --- confirm phase (objective-neutral re-validation) ----------------------

  # No confirm closure: the objective's verdict stands (full-frame ssim2, :size,
  # :none paths are byte-identical to before this feature).
  defp confirm_phase(objective_q, objective_outcome, %Ctx{confirm_fun: nil} = ctx),
    do: {:ok, objective_q, objective_outcome, ctx}

  # The objective ran on an ESTIMATE; re-validate the winner against the
  # authoritative measure and linear-bump on undershoot (cap @max_bump_passes).
  defp confirm_phase(objective_q, _objective_outcome, ctx) do
    with {:ok, ctx} <- confirm_score(objective_q, ctx) do
      if Map.fetch!(ctx.confirm_memo, objective_q) >= ctx.confirm_band do
        {:ok, objective_q, :hit, ctx}
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
    do: {:ok, best_q, :best_effort, ctx}

  defp do_bump(try_q, last_q, _best_q, ctx) do
    case confirm_score(try_q, ctx) do
      {:error, _} = err ->
        err

      {:ok, ctx} ->
        if Map.fetch!(ctx.confirm_memo, try_q) >= ctx.confirm_band,
          do: {:ok, try_q, :hit, ctx},
          else: do_bump(try_q + 1, last_q, try_q, ctx)
    end
  end

  # Ensure q is encoded, then authoritatively score it once (memoized), counting
  # the pass. Encode is forced even past the iteration cap: the confirm MUST run.
  defp confirm_score(q, ctx) do
    with {:ok, ctx} <- ensure_probed(q, ctx) do
      if Map.has_key?(ctx.confirm_memo, q) do
        {:ok, ctx}
      else
        score = ctx.confirm_fun.(Map.fetch!(ctx.encode_memo, q))

        {:ok,
         %{
           ctx
           | confirm_memo: Map.put(ctx.confirm_memo, q, score),
             confirm_passes: ctx.confirm_passes + 1
         }}
      end
    end
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

  # Find the LOWEST q in [lo, hi] satisfying `predicate`. Monotone-increasing
  # predicate (holds at q ⇒ holds at every higher q). `best_q` is the lowest
  # such q.
  defp search_lowest_satisfying(lo, hi, predicate, ctx) do
    do_lowest(lo, hi, predicate, ctx, nil)
  end

  defp do_lowest(lo, hi, _predicate, ctx, best) when lo > hi do
    {best, outcome_for(best), ctx}
  end

  defp do_lowest(lo, hi, predicate, ctx, best) do
    mid = div(lo + hi, 2)

    case probe(mid, predicate, ctx) do
      {:error, _} = err ->
        err

      {:capped, ctx} ->
        {best, outcome_for(best), ctx}

      {:satisfied, ctx} ->
        # mid clears; try to go lower.
        do_lowest(lo, mid - 1, predicate, ctx, min_q(best, mid))

      {:unsatisfied, ctx} ->
        # mid too low; go higher.
        do_lowest(mid + 1, hi, predicate, ctx, best)
    end
  end

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

  # Ensure q is encoded (and scored when a score_fun is present), memoized.
  # Returns {:ok, byte_size, score | nil, ctx} | :capped | {:error, _}.
  defp materialize(q, ctx) do
    cond do
      Map.has_key?(ctx.encode_memo, q) ->
        bytes = byte_size(Map.fetch!(ctx.encode_memo, q))
        {:ok, bytes, Map.get(ctx.score_memo, q), ctx}

      ctx.iterations >= ctx.max_iterations ->
        :capped

      true ->
        case ctx.encode_fun.(q) do
          {:ok, binary} ->
            ctx = %{
              ctx
              | encode_memo: Map.put(ctx.encode_memo, q, binary),
                iterations: ctx.iterations + 1
            }

            ctx = maybe_score(q, binary, ctx)
            emit_probe(q, binary, ctx)
            {:ok, byte_size(binary), Map.get(ctx.score_memo, q), ctx}

          {:error, _} = err ->
            err
        end
    end
  end

  # One probe event per NEW distinct encode (memo hits never reach here).
  # `:index` is the distinct-encode ordinal (`iterations` after the increment);
  # `:score` is the scored value when an ssim2 score_fun ran, else nil. All
  # product-neutral numbers.
  defp emit_probe(q, binary, %Ctx{telemetry_opts: telemetry_opts} = ctx) do
    Telemetry.execute(
      telemetry_opts,
      [:encode, :search, :probe],
      %{},
      %{
        quality: q,
        bytes: byte_size(binary),
        index: ctx.iterations,
        score: Map.get(ctx.score_memo, q)
      }
    )
  end

  defp maybe_score(_q, _binary, %Ctx{score_fun: nil} = ctx), do: ctx

  defp maybe_score(q, binary, %Ctx{score_fun: score_fun} = ctx) do
    %{ctx | score_memo: Map.put(ctx.score_memo, q, score_fun.(binary))}
  end

  # Encode a specific quality (e.g. the chosen boundary) without requiring the
  # predicate, so its buffer/score is in the memo for the final result. Respects
  # the cap only when a NEW encode is needed; if capped and already absent, we
  # force the encode anyway because the result MUST carry a real buffer.
  defp ensure_probed(q, ctx) do
    case Map.has_key?(ctx.encode_memo, q) do
      true ->
        {:ok, ctx}

      false ->
        case ctx.encode_fun.(q) do
          {:ok, binary} ->
            ctx = %{
              ctx
              | encode_memo: Map.put(ctx.encode_memo, q, binary),
                iterations: ctx.iterations + 1
            }

            {:ok, maybe_score(q, binary, ctx)}

          {:error, _} = err ->
            err
        end
    end
  end

  defp outcome_for(nil), do: :best_effort
  defp outcome_for(_best), do: :hit

  defp max_q(nil, q), do: q
  defp max_q(best, q), do: max(best, q)

  defp min_q(nil, q), do: q
  defp min_q(best, q), do: min(best, q)

  # --- result assembly ------------------------------------------------------

  defp build_result(final_q, final_outcome, ctx) do
    binary = Map.fetch!(ctx.encode_memo, final_q)
    ctx = ensure_winner_scored(final_q, binary, ctx)

    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: result_score(final_q, ctx),
      confirm_passes: ctx.confirm_passes,
      scorer: ctx.scorer,
      tiles_scored: ctx.scorer_tiles
    }

    {:ok, binary, meta}
  end

  # meta.score must reflect the DELIVERED quality, never a different one. The cap
  # phase (byte-only predicate) can relocate the winner to a quality the objective
  # search never scored; score it now from its already-memoized buffer. This keys
  # off the injected closures (not the objective), so the core stays objective-neutral.

  # Crop mode (confirm_fun present): the authoritative score lives in confirm_memo;
  # a cap-relocated winner may not be there yet — confirm-score it so meta.score is
  # the true full-frame score, never the crop estimate in score_memo.
  defp ensure_winner_scored(final_q, _binary, %Ctx{confirm_fun: fun} = ctx)
       when not is_nil(fun) do
    case confirm_score(final_q, ctx) do
      {:ok, ctx} -> ctx
      {:error, _} -> ctx
    end
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

  defp bump_headroom(:crop), do: @default_max_bump_passes + 1
  defp bump_headroom(:full), do: 0

  # Build the objective score_fun (+ confirm closures for crop mode) for the
  # resolved objective and the chosen scorer. Returns extra search/3 opts.
  defp score_opts(_image, %Resolved{quality_search: :none}, _scorer), do: {:ok, []}

  defp score_opts(_image, %Resolved{quality_search: %RQS{objective: :size}}, _scorer),
    do: {:ok, []}

  # Full-frame mode: one whole-frame reference; candidate scored whole. (No `= rqs`
  # binding — the bracket/target is consumed by the search, not here — so there is
  # no unused-variable warning under --warnings-as-errors.)
  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2}}, :full) do
    case Ssim2Metric.reference(image) do
      {:ok, ref} -> {:ok, [score_fun: fn bytes -> full_frame_score(ref, bytes) end]}
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  # Crop mode: crop score_fun (estimate) + full-frame confirm closure + the
  # deterministic tile count for telemetry.
  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2} = rqs}, :crop) do
    case Ssim2Metric.reference(image) do
      {:ok, ref} ->
        confirm = fn bytes -> full_frame_score(ref, bytes) end
        crop = fn bytes -> crop_estimate(image, bytes) end

        {:ok,
         [
           score_fun: crop,
           confirm_fun: confirm,
           confirm_band: rqs.target - rqs.allowed_error,
           confirm_max_quality: rqs.max_quality,
           scorer_tiles: CropScore.tile_count(Image.width(image), Image.height(image))
         ]}

      {:error, reason} ->
        {:error, {:encode, reason}}
    end
  end

  # The score_fun contract is float-returning, but Image.from_binary and
  # Ssim2Metric.score can fail. We surface such failures by throwing a tagged
  # tuple that run/3 catches around the search/3 call, mapping it to
  # {:error, {:encode, reason}}.

  # Decode the candidate once and score the whole frame against the reference.
  defp full_frame_score(ref, bytes) do
    with {:ok, candidate} <- Image.from_binary(bytes),
         {:ok, score} <- Ssim2Metric.score(ref, candidate) do
      score
    else
      {:error, reason} -> throw({:image_pipe_score_error, reason})
    end
  end

  # Decode the candidate once; crop-score its tiles vs the base; subtract the macro
  # offset so the unchanged objective predicate reproduces the full-frame decision.
  defp crop_estimate(base, bytes) do
    with {:ok, candidate} <- Image.from_binary(bytes),
         {:ok, p10} <- CropScore.p10(base, candidate) do
      p10 - @crop_macro_offset
    else
      {:error, reason} -> throw({:image_pipe_score_error, reason})
    end
  end

  defp base_quality(%Resolved{quality: {:quality, v}}), do: v

  defp base_quality(%Resolved{quality: :default, quality_search: %RQS{max_quality: max_quality}}),
    do: max_quality

  defp base_quality(%Resolved{quality: :default}), do: @max_bytes_alone_base
end
