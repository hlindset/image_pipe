defmodule ImagePipe.Cache.FileSystem.Policy do
  @moduledoc false

  @type descriptor :: %{
          required(:key_hash) => binary(),
          required(:size_bytes) => non_neg_integer(),
          required(:cost_us) => non_neg_integer(),
          optional(atom()) => term()
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
  Ranks an entry for eviction, lowest first. Counting one more sighting than
  the sketch holds keeps cost in the ranking for entries not seen since a
  restart, whose frequency is 0.
  """
  @spec victim_score(descriptor(), non_neg_integer()) :: float()
  def victim_score(descriptor, freq), do: score(descriptor, freq + 1)

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
