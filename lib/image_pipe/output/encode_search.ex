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

  @default_max_iterations 6
  @max_bytes_alone_floor 10
  @max_bytes_alone_base 90

  @type outcome :: :hit | :best_effort | :skipped

  @type meta :: %{
          quality: 1..100,
          bytes: non_neg_integer(),
          iterations: non_neg_integer(),
          outcome: outcome(),
          score: float() | nil
        }

  # Mutable-ish search context threaded through the loop as an immutable struct.
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:encode_fun]
    defstruct encode_fun: nil,
              score_fun: nil,
              encode_memo: %{},
              score_memo: %{},
              iterations: 0,
              max_iterations: 0
  end

  @doc """
  Pure search core. See the module doc for `:encode_fun`/`:score_fun`/
  `:base_quality`/`:max_iterations` semantics.
  """
  @spec search(:none | RQS.t(), nil | pos_integer(), keyword()) ::
          {:ok, binary(), meta()} | {:error, term()}
  def search(quality_search, max_bytes, opts) do
    ctx = %Ctx{
      encode_fun: Keyword.fetch!(opts, :encode_fun),
      score_fun: Keyword.get(opts, :score_fun),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations)
    }

    with {:ok, objective_q, objective_outcome, objective_score, ctx} <-
           objective_phase(quality_search, ctx, opts),
         {:ok, final_q, final_outcome, ctx} <-
           cap_phase(quality_search, max_bytes, objective_q, objective_outcome, ctx) do
      build_result(final_q, final_outcome, objective_q, objective_score, quality_search, ctx)
    end
  end

  @doc """
  Production wrapper. Builds the real encode/score closures from an already
  finalized image plus its `%Resolved{}`, then delegates to `search/3`.
  """
  @spec run(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, binary(), meta()} | {:error, term()}
  def run(finalized_image, %Resolved{} = resolved, opts) do
    encode_fun = fn quality -> Encoder.encode_to_buffer(finalized_image, resolved, quality) end
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    with {:ok, score_fun} <- build_score_fun(finalized_image, resolved.quality_search) do
      base_quality = base_quality(resolved)

      try do
        search(resolved.quality_search, resolved.max_bytes,
          encode_fun: encode_fun,
          score_fun: score_fun,
          base_quality: base_quality,
          max_iterations: max_iterations
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
        # Objective pick already fits the hard budget.
        {:ok, objective_q, objective_outcome, ctx}
      else
        cap_descend(floor, objective_q, max_bytes, ctx)
      end
    end
  end

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
            {:ok, byte_size(binary), Map.get(ctx.score_memo, q), ctx}

          {:error, _} = err ->
            err
        end
    end
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

  defp build_result(final_q, final_outcome, _objective_q, _objective_score, quality_search, ctx) do
    binary = Map.fetch!(ctx.encode_memo, final_q)
    ctx = ensure_winner_scored(final_q, binary, quality_search, ctx)

    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: result_score(final_q, quality_search, ctx)
    }

    {:ok, binary, meta}
  end

  # meta.score must reflect the DELIVERED quality, never a different one. For
  # ssim2 the cap phase (byte-only predicate) can relocate the winner to a
  # quality the objective search never scored; score it now from its already-
  # memoized buffer (no re-encode) so the reported score is honest. nil otherwise.
  defp ensure_winner_scored(final_q, binary, %RQS{objective: :ssim2}, ctx) do
    if Map.has_key?(ctx.score_memo, final_q), do: ctx, else: maybe_score(final_q, binary, ctx)
  end

  defp ensure_winner_scored(_final_q, _binary, _quality_search, ctx), do: ctx

  defp result_score(final_q, %RQS{objective: :ssim2}, ctx), do: Map.get(ctx.score_memo, final_q)
  defp result_score(_final_q, _quality_search, _ctx), do: nil

  # --- run/3 helpers --------------------------------------------------------

  defp build_score_fun(_image, :none), do: {:ok, nil}

  defp build_score_fun(_image, %RQS{objective: :size}), do: {:ok, nil}

  defp build_score_fun(image, %RQS{objective: :ssim2}) do
    case Ssim2Metric.reference(image) do
      {:ok, ref} -> {:ok, fn bytes -> ssim2_score(ref, bytes) end}
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  # The score_fun contract is float-returning, but Image.from_binary and
  # Ssim2Metric.score can fail. We surface such failures by throwing a tagged
  # tuple that run/3 catches around the search/3 call, mapping it to
  # {:error, {:encode, reason}}.
  defp ssim2_score(ref, bytes) do
    with {:ok, candidate} <- Image.from_binary(bytes),
         {:ok, score} <- Ssim2Metric.score(ref, candidate) do
      score
    else
      {:error, reason} -> throw({:image_pipe_score_error, reason})
    end
  end

  defp base_quality(%Resolved{quality: {:quality, v}}), do: v

  defp base_quality(%Resolved{quality: :default, quality_search: %RQS{max_quality: max_quality}}),
    do: max_quality

  defp base_quality(%Resolved{quality: :default}), do: @max_bytes_alone_base
end
