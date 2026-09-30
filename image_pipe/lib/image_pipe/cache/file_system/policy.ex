defmodule ImagePipe.Cache.FileSystem.Policy do
  @moduledoc false

  @type descriptor :: %{
          key_hash: binary(),
          size_bytes: non_neg_integer(),
          body_sha256: binary(),
          cost_us: non_neg_integer()
        }

  @doc """
  Compute the cost-aware score for an entry given its frequency.

  score = freq × effective_cost / max(size_bytes, 1)

  effective_cost = cost_us when cost_us > 0, else size_bytes (size-neutral
  fallback that collapses scoring to freq alone).
  """
  @spec score(descriptor(), non_neg_integer()) :: float()
  def score(%{cost_us: cost_us, size_bytes: size_bytes}, freq) do
    effective_cost = if cost_us > 0, do: cost_us, else: size_bytes
    freq * effective_cost / max(size_bytes, 1)
  end

  @doc """
  Compute the weighted-average value-per-byte across a list of victim
  descriptors. Weighting is by size_bytes. Returns 0.0 for empty input.

  freq_fn maps a descriptor's key_hash to its current frequency.
  """
  @spec weighted_avg_score([descriptor()], (binary() -> non_neg_integer())) :: float()
  def weighted_avg_score([], _freq_fn), do: 0.0

  def weighted_avg_score(victims, freq_fn) when is_list(victims) do
    {numerator, denominator} =
      Enum.reduce(victims, {0, 0}, fn v, {num, den} ->
        freq = freq_fn.(v.key_hash)
        effective_cost = if v.cost_us > 0, do: v.cost_us, else: v.size_bytes
        {num + freq * effective_cost, den + v.size_bytes}
      end)

    if denominator == 0, do: 0.0, else: numerator / denominator
  end

  @doc """
  Walk probationary LRU outward, then protected LRU outward, collecting
  victims until cumulative size_bytes >= needed_bytes.

  Probationary and protected lists must be ordered LRU-first. The
  `limit` parameter caps the number of victims collected — if more
  would be needed to free enough bytes, returns
  `{:error, :victim_limit_exceeded}`.

  Returns:
  - `{:ok, victims}` — enough bytes can be freed within the limit
  - `{:error, :no_evictable_victims}` — both queues combined cannot
    free enough bytes
  - `{:error, :victim_limit_exceeded}` — freeing enough bytes would
    require more than `limit` victims
  """
  @spec victim_walk([descriptor()], [descriptor()], non_neg_integer(), pos_integer()) ::
          {:ok, [descriptor()]}
          | {:error, :no_evictable_victims}
          | {:error, :victim_limit_exceeded}
  def victim_walk(probationary, protected, needed_bytes, limit)
      when is_list(probationary) and is_list(protected) and
             is_integer(needed_bytes) and needed_bytes >= 0 and
             is_integer(limit) and limit > 0 do
    case take_until_bytes(probationary, needed_bytes, [], 0, limit) do
      {:done, victims} -> {:ok, Enum.reverse(victims)}
      {:short, victims, still_needed} -> walk_protected(protected, victims, still_needed, limit)
      :limit_exceeded -> {:error, :victim_limit_exceeded}
    end
  end

  # `victims` is pre-loaded with the probationary victims, and take_until_bytes
  # clause 3 counts `length(victims)` against `limit` — so the ORIGINAL limit is
  # passed here to cap the TOTAL victim count across both queues. Subtracting
  # length(victims) would double-count the probationary victims already in the
  # accumulator.
  defp walk_protected(protected, victims, still_needed, limit) do
    case take_until_bytes(protected, still_needed, victims, 0, limit) do
      {:done, all_victims} -> {:ok, Enum.reverse(all_victims)}
      {:short, _all_victims, _remaining} -> {:error, :no_evictable_victims}
      :limit_exceeded -> {:error, :victim_limit_exceeded}
    end
  end

  # Returns one of: {:done, victims}, {:short, victims, still_needed_bytes},
  # or :limit_exceeded.
  # NOTE: the acc >= remaining check must precede the empty-list check so
  # that processing the final item and meeting the threshold in one step
  # returns {:done} rather than {:short}.
  defp take_until_bytes(_list, remaining, victims, acc, _limit) when acc >= remaining,
    do: {:done, victims}

  defp take_until_bytes([], remaining, victims, acc, _limit),
    do: {:short, victims, remaining - acc}

  defp take_until_bytes(_list, _remaining, victims, _acc, limit)
       when length(victims) >= limit,
       do: :limit_exceeded

  defp take_until_bytes([v | rest], remaining, victims, acc, limit) do
    take_until_bytes(rest, remaining, [v | victims], acc + v.size_bytes, limit)
  end

  @doc """
  Decide whether a candidate should be admitted given the victims it would
  displace. Empty victim list (free space available) always admits.

  freq_fn maps a key_hash to its current frequency estimate.
  """
  @spec admit?(descriptor(), [descriptor()], (binary() -> non_neg_integer())) :: boolean()
  def admit?(_candidate, [], _freq_fn), do: true

  def admit?(candidate, victims, freq_fn) do
    candidate_freq = freq_fn.(candidate.key_hash)
    score(candidate, candidate_freq) > weighted_avg_score(victims, freq_fn)
  end
end
