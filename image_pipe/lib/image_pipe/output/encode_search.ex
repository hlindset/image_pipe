defmodule ImagePipe.Output.EncodeSearch do
  # Best-effort binary search over encoder quality.
  #
  # Given a resolved SSIMULACRA2 quality target and/or a hard `max_bytes` budget, probe candidate qualities
  # within `[min_quality, max_quality]` and return the already-encoded buffer for
  # the winning quality, alongside `meta` describing the outcome.
  #
  # Two public entry points:
  #
  #   * `search/3` — the core, with injected `:encode_fun` and `:score_fun`
  #     closures. It owns memoization, the iteration cap, and objective and
  #     `max_bytes` phases.
  #   * `run/3` — the production wrapper. It extracts the objective and budget from
  #     a `%ImagePipe.Output.Resolved{}`, builds the real encode/score closures
  #     from `ImagePipe.Output.Encoder` and the metric runtime under
  #     `ImagePipe.Output.Metric.*`, and delegates to `search/3`.
  #
  # ## Monotonicity contract
  #
  # The binary search assumes encoded byte size and the SSIMULACRA2 score are
  # non-decreasing in quality. Real encoders can violate monotonicity locally, so the result may
  # miss the true optimum. The winning quality is always probed, re-measured,
  # and within `[min_quality, max_quality]`.
  @moduledoc false

  alias ImagePipe.Error
  alias ImagePipe.Output.ContentClassifier
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Metric
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Telemetry

  @default_max_iterations 6

  # Target search tuning (bench/autoquality.md, Part O): accept a score up to
  # this far above the target, assume this score gain per quality step until two
  # probes measure it, and step at most this many qualities at once.
  @accept_above 1.0
  @default_slope 1.0
  @min_slope 0.05
  @max_step 20
  @max_bytes_alone_floor 10
  @max_bytes_alone_base 90

  @type outcome :: :hit | :best_effort

  # Why a `:best_effort` result fell short of the objective/budget. `nil` on a
  # `:hit`. `:ceiling` — the objective never cleared its band and pinned to the
  # bracket ceiling; `:max_bytes` — the hard budget could not be met even at the
  # floor.
  @type limiting_factor :: :ceiling | :max_bytes

  @type meta :: %{
          quality: 0..100,
          bytes: non_neg_integer(),
          iterations: non_neg_integer(),
          outcome: outcome(),
          score: float() | nil,
          scorer: :full | :crop,
          tiles_scored: pos_integer() | nil,
          limiting_factor: limiting_factor() | nil
        }

  # Search context threaded through the loop.
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:encode_fun]
    defstruct encode_fun: nil,
              score_fun: nil,
              scorer: :full,
              scorer_tiles: nil,
              encode_memo: %{},
              score_memo: %{},
              probe_log: %{},
              iterations: 0,
              max_iterations: 0,
              phase: nil,
              limiting_factor: nil,
              telemetry_opts: []
  end

  @doc """
  Searches with injected encoding/scoring callbacks and a bounded iteration count.
  """
  @spec search(
          :none | RQS.Ssimulacra2.t(),
          nil | pos_integer(),
          keyword()
        ) ::
          {:ok, binary(), meta()} | {:error, term()}
  def search(quality_search, max_bytes, opts) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])

    ctx = %Ctx{
      encode_fun: Keyword.fetch!(opts, :encode_fun),
      score_fun: Keyword.get(opts, :score_fun),
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
    with {:ok, objective_q, objective_outcome, ctx} <-
           objective_phase(quality_search, %{ctx | phase: :objective}, opts),
         {:ok, final_q, final_outcome, ctx} <-
           cap_phase(quality_search, max_bytes, objective_q, objective_outcome, ctx) do
      build_result(final_q, final_outcome, ctx)
    end
  end

  # Product-neutral search descriptor for the span start: objective + bracket +
  # target/budget. `:none` (max_bytes-alone) carries nils for the objective-only
  # fields. No URLs/secrets — derived from the resolved descriptor and budget.
  defp search_start_meta(%RQS.Ssimulacra2{} = rqs, max_bytes) do
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
      limiting_factor: meta.limiting_factor
    }
  end

  defp search_stop_meta(quality_search, {:error, reason}) do
    %{
      result: :processing_error,
      objective: objective_of(quality_search),
      error: Error.tag(reason)
    }
  end

  defp objective_of(:none), do: :none
  defp objective_of(%RQS.Ssimulacra2{}), do: :ssimulacra2

  @doc """
  Production wrapper. Builds the real encode/score closures from an already
  finalized image plus its `%Resolved{}`, then delegates to `search/3`.
  """
  @spec run(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, binary(), meta()} | {:error, term()}
  def run(finalized_image, %Resolved{} = resolved, opts) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])
    encode_fun = fn quality -> encode_leg(finalized_image, resolved, quality, telemetry_opts) end
    scorer = Keyword.get(opts, :scorer, :full)

    with {:ok, search_opts} <- score_opts(finalized_image, resolved, scorer, telemetry_opts) do
      base_quality = base_quality(resolved)

      try do
        search(
          resolved.quality_search,
          resolved.max_bytes,
          [
            encode_fun: encode_fun,
            base_quality: base_quality,
            scorer: scorer,
            telemetry_opts: telemetry_opts
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
  caller then encodes once at the resolved quality.
  """
  @spec skip?(%{max_resolution: non_neg_integer()}, number()) :: boolean()
  def skip?(%{max_resolution: max_resolution}, megapixels),
    do: max_resolution > 0 and megapixels > max_resolution

  # --- objective phase ------------------------------------------------------

  # No objective: the caller is running a max_bytes-alone search. The "objective
  # quality" upper bound is the supplied base_quality (or a sane default).
  defp objective_phase(:none, ctx, opts) do
    base = Keyword.get(opts, :base_quality, @max_bytes_alone_base)
    {:ok, base, :none, ctx}
  end

  defp objective_phase(%RQS.Ssimulacra2{} = rqs, ctx, _opts),
    do: quality_objective_phase(rqs, ctx)

  defp quality_objective_phase(rqs, ctx) do
    case search_to_target(rqs, ctx) do
      {:error, _} = err ->
        err

      {chosen, outcome, factor, ctx} ->
        ctx = set_factor(ctx, factor)

        with {:ok, ctx} <- ensure_probed(chosen, ctx) do
          {:ok, chosen, outcome, ctx}
        end
    end
  end

  # --- cap (max_bytes) phase ------------------------------------------------

  # No hard byte budget: the objective's result stands.
  defp cap_phase(_quality_search, nil, objective_q, objective_outcome, ctx),
    do: {:ok, objective_q, objective_outcome, ctx}

  defp cap_phase(quality_search, max_bytes, objective_q, objective_outcome, ctx) do
    floor = min(cap_floor(quality_search), objective_q)
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
  defp cap_floor(%RQS.Ssimulacra2{min_quality: min_quality}), do: min_quality

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

  # Search toward the target: accept the first probe scoring in
  # `[target - allowed_error, target + @accept_above]`. The first probe is
  # `start_quality` (a calibrated guess, else the bracket midpoint). Each later
  # probe interpolates score(q) between the highest failing and lowest passing
  # qualities seen, or extrapolates from the nearest probes when only one side
  # is known, so a good start converges in two or three probes.
  #
  # Without an in-band probe the search stops when the failing and passing
  # qualities are adjacent, a bracket edge is reached, or the iteration cap hits.
  # It then ships the lowest passing quality (a `:hit`), or the ceiling as a
  # `:best_effort`/`:ceiling` result when nothing passed. Returns
  # {chosen_q, :hit | :best_effort, limiting_factor | nil, ctx}.
  defp search_to_target(rqs, ctx) do
    start = rqs.start_quality || div(rqs.min_quality + rqs.max_quality, 2)
    do_target(start, rqs, %{}, ctx)
  end

  defp do_target(q, rqs, seen, ctx) do
    case probe_score(q, ctx) do
      {:error, _} = err ->
        err

      {:capped, ctx} ->
        ship_target(seen, rqs, ctx)

      {:ok, score, ctx} ->
        seen = Map.put(seen, q, score)
        accept_lo = rqs.target - rqs.allowed_error

        cond do
          score >= accept_lo and score <= rqs.target + @accept_above ->
            {q, :hit, nil, ctx}

          converged?(failing(seen, accept_lo), passing(seen, accept_lo), rqs) ->
            ship_target(seen, rqs, ctx)

          true ->
            next = next_quality(failing(seen, accept_lo), passing(seen, accept_lo), seen, rqs)
            do_target(next, rqs, seen, ctx)
        end
    end
  end

  # Highest quality scoring below the band, and lowest scoring at or above it.
  defp failing(seen, accept_lo),
    do: seen |> Enum.filter(fn {_q, s} -> s < accept_lo end) |> Enum.max(fn -> nil end)

  defp passing(seen, accept_lo),
    do: seen |> Enum.filter(fn {_q, s} -> s >= accept_lo end) |> Enum.min(fn -> nil end)

  defp converged?({fail_q, _}, {pass_q, _}, _rqs), do: pass_q - fail_q <= 1
  defp converged?(nil, {pass_q, _}, rqs), do: pass_q <= rqs.min_quality
  defp converged?({fail_q, _}, nil, rqs), do: fail_q >= rqs.max_quality

  defp ship_target(seen, rqs, ctx) do
    case passing(seen, rqs.target - rqs.allowed_error) do
      nil -> {rqs.max_quality, :best_effort, :ceiling, ctx}
      {pass_q, _} -> {pass_q, :hit, nil, ctx}
    end
  end

  defp next_quality({fail_q, fail_s}, {pass_q, pass_s}, _seen, rqs) do
    q = fail_q + (rqs.target - fail_s) / (pass_s - fail_s) * (pass_q - fail_q)
    q |> round() |> max(fail_q + 1) |> min(pass_q - 1)
  end

  defp next_quality(nil, {pass_q, pass_s}, seen, rqs) do
    step = clamp_step((pass_s - rqs.target) / slope(seen))
    (pass_q - step) |> max(rqs.min_quality) |> min(pass_q - 1)
  end

  defp next_quality({fail_q, fail_s}, nil, seen, rqs) do
    step = clamp_step((rqs.target - fail_s) / slope(seen))
    (fail_q + step) |> min(rqs.max_quality) |> max(fail_q + 1)
  end

  # Score gained per quality step, from the two highest probed qualities.
  defp slope(seen) when map_size(seen) < 2, do: @default_slope

  defp slope(seen) do
    [{q1, s1}, {q2, s2}] = seen |> Enum.sort() |> Enum.take(-2)
    slope = (s2 - s1) / (q2 - q1)
    if slope > @min_slope, do: slope, else: @default_slope
  end

  defp clamp_step(step), do: step |> round() |> max(1) |> min(@max_step)

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
          {:error, reason} = err -> {err, %{result: :processing_error, error: Error.tag(reason)}}
        end
      end
    )
  end

  # Raw encode + memoize + estimate-score, WITHOUT a probe span: encode_probe owns
  # the span. `phase` is the enclosing probe span's phase, logged per distinct
  # encode so the delivered quality can later name the phase that produced its
  # bytes.
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

  defp maybe_score(_q, _binary, %Ctx{score_fun: nil} = ctx), do: ctx

  defp maybe_score(q, binary, %Ctx{score_fun: score_fun} = ctx) do
    %{ctx | score_memo: Map.put(ctx.score_memo, q, score_fun.(binary))}
  end

  defp set_factor(ctx, factor), do: %{ctx | limiting_factor: factor}

  # Stop metadata for an objective/cap probe: the encode + (estimate) score it just
  # produced. `:tiles_scored`/nil `:score` are stripped by the telemetry layer, so
  # the full-frame and :none paths carry only the fields they populate.
  defp objective_probe_meta(q, ctx) do
    %{
      bytes: byte_size(Map.fetch!(ctx.encode_memo, q)),
      index: ctx.iterations,
      score: Map.get(ctx.score_memo, q),
      scorer: ctx.scorer,
      tiles_scored: ctx.scorer_tiles
    }
  end

  defp outcome_for(nil), do: :best_effort
  defp outcome_for(_best), do: :hit

  defp max_q(nil, q), do: q
  defp max_q(best, q), do: max(best, q)

  # --- result assembly ------------------------------------------------------

  defp build_result(final_q, final_outcome, ctx) do
    binary = Map.fetch!(ctx.encode_memo, final_q)

    emit_chosen(final_q, binary, ctx)

    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: Map.get(ctx.score_memo, final_q),
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
  # that actually encoded the delivered bytes (objective or cap). All
  # product-neutral; nils
  # (`:score`/`:tiles_scored` on the :none/full-frame paths) are stripped by
  # the telemetry layer, matching the probe-span metadata.
  defp emit_chosen(final_q, binary, ctx) do
    probe = Map.fetch!(ctx.probe_log, final_q)

    Telemetry.execute(
      ctx.telemetry_opts,
      [:encode, :search, :probe, :chosen],
      %{},
      %{
        quality: final_q,
        bytes: byte_size(binary),
        phase: probe.phase,
        index: probe.index,
        score: Map.get(ctx.score_memo, final_q),
        scorer: ctx.scorer,
        tiles_scored: ctx.scorer_tiles
      }
    )
  end

  # The limiting factor is meaningful only for a degraded result; a `:hit` carries
  # none, regardless of any factor a superseded phase staged.
  defp limiting_factor_for(:best_effort, ctx), do: ctx.limiting_factor
  defp limiting_factor_for(_outcome, _ctx), do: nil

  # --- run/3 helpers --------------------------------------------------------

  # Build the objective score_fun (crop estimate or full-frame) for the resolved
  # objective and the chosen scorer. Returns extra search/3 opts. The score
  # closures emit the `:decode`/`:metric` cost legs; the core only sees an opaque
  # float-returning closure, never the decode/metric structure.
  defp score_opts(_image, %Resolved{quality_search: :none}, _scorer, _telemetry_opts),
    do: {:ok, []}

  # Crop mode (above the crossover): crop score_fun (estimate) only (#369). The
  # per-`{format, content-class}` offset (resolved into
  # `rqs.quality_search_offsets`, #380) baked into the estimate is the crop→full
  # correction; the content class is classified here once, lazily,
  # from the finalized pixels. The objective walk's verdict ships as-is, bounding the
  # large-image search to a flat ~4.2 MP metric sample. No whole-frame reference is
  # built: the per-tile references are built once here and every probe's
  # `crop_estimate` reuses them, so the O(pixels) full-frame reference (the very
  # cost this path avoids) never runs.
  defp score_opts(image, %Resolved{quality_search: %RQS.Ssimulacra2{} = rqs}, :crop, t) do
    case CropScore.references(image) do
      {:ok, refs} ->
        tiles = length(refs)
        offset = classify_offset(image, rqs.quality_search_offsets, t)
        crop = fn bytes -> crop_estimate(refs, bytes, tiles, offset, t) end
        {:ok, [score_fun: crop, scorer_tiles: tiles]}

      {:error, reason} ->
        {:error, {:encode, reason}}
    end
  end

  # Below the crop crossover the metric scores the full frame, through its runtime
  # (`Output.Metric.runtime/1`). `:none` is matched above and never reaches here.
  defp score_opts(image, %Resolved{quality_search: qs}, _scorer, t) do
    full_frame_opts(Metric.runtime(qs), image, t)
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
    leg = metric.leg_name()
    candidate = decode_leg(leg, bytes, telemetry_opts)

    metric_leg(leg, telemetry_opts, tiles, fn ->
      case metric.score(ref, candidate) do
        {:ok, score} -> score
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end

  # Decode the candidate once; crop-score its tiles vs the base; subtract the
  # conservative offset so the objective's walk-to-target band comparison
  # reproduces the full-frame decision.
  defp crop_estimate(refs, bytes, tiles, offset, telemetry_opts) do
    # Crop scoring is SSIMULACRA2-only (Encoder.crop?/2 lets only the Ssimulacra2
    # strategy crop), so the legs carry the `:ssimulacra2` segment.
    leg = Metric.Ssimulacra2.leg_name()
    candidate = decode_leg(leg, bytes, telemetry_opts)

    metric_leg(leg, telemetry_opts, tiles, fn ->
      case CropScore.p10(refs, candidate) do
        {:ok, p10} -> p10 - offset
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end

  # --- cost legs (emitted from run/3's closures; the pure core never sees them) -

  # The codec encode, as a leg nested under the active probe span. Method-neutral:
  # it fires for every objective (:ssim2/:none), so unlike the scoring legs
  # it carries no metric-method name segment.
  defp encode_leg(image, resolved, quality, telemetry_opts) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, :encode],
      %{quality: quality},
      fn ->
        case Encoder.encode_to_buffer(image, resolved, quality) do
          {:ok, binary} = ok -> {ok, %{result: :ok, bytes: byte_size(binary)}}
          {:error, reason} = err -> {err, %{result: :processing_error, error: Error.tag(reason)}}
        end
      end
    )
  end

  # Candidate decode, as a metric-namespaced leg. The `leg` segment (the metric's
  # `leg_name/0`) names the scoring legs; a decode failure throws and surfaces as
  # the leg's `:exception`.
  defp decode_leg(leg, bytes, telemetry_opts) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, leg, :decode],
      %{bytes: byte_size(bytes)},
      fn ->
        case Image.from_binary(bytes) do
          {:ok, candidate} -> {candidate, %{result: :ok}}
          {:error, reason} -> throw({:image_pipe_score_error, reason})
        end
      end
    )
  end

  # One aggregate metric leg per probe, segmented by `leg` (the crop path scores K
  # tiles internally; `:tiles_scored` records how many, but no per-tile span is
  # emitted — that detail lives in `mix autoquality.bench`).
  defp metric_leg(leg, telemetry_opts, tiles, fun) do
    Telemetry.span(
      telemetry_opts,
      [:encode, :search, :probe, leg, :metric],
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
         quality_search: %RQS.Ssimulacra2{max_quality: max_quality}
       }),
       do: max_quality

  defp base_quality(%Resolved{quality: :default}), do: @max_bytes_alone_base
end
