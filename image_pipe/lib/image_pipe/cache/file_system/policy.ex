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

  Both queues must be enumerables ordered LRU-first. They are consumed lazily,
  so only the entries the walk reaches are read.

  The probationary walk is unbounded: Admission evicts the first `limit`
  victims at once and lets reconciliation evict the rest, which it reaches
  in the same LRU order. Reconciliation evicts probationary before protected,
  so it would reach the newly admitted entry before any protected victim. A
  walk that extends into protected therefore stays within `limit` victims in
  total.

  Returns:
  - `{:ok, victims}` — enough bytes can be freed
  - `{:error, :no_evictable_victims}` — both queues combined cannot
    free enough bytes
  - `{:error, :victim_limit_exceeded}` — the walk extends into protected
    and needs more than `limit` victims in total
  """
  @spec victim_walk(
          Enumerable.t(descriptor()),
          Enumerable.t(descriptor()),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, [descriptor()]}
          | {:error, :no_evictable_victims}
          | {:error, :victim_limit_exceeded}
  def victim_walk(probationary, protected, needed_bytes, limit)
      when is_integer(needed_bytes) and needed_bytes >= 0 and is_integer(limit) and limit > 0 do
    case take_until_bytes(probationary, needed_bytes) do
      {:done, victims} -> {:ok, victims}
      {:short, victims, still_needed} -> walk_protected(protected, victims, still_needed, limit)
    end
  end

  defp walk_protected(protected, victims, still_needed, limit) do
    case take_until_bytes(protected, still_needed) do
      {:done, more} when length(victims) + length(more) > limit ->
        {:error, :victim_limit_exceeded}

      {:done, more} ->
        {:ok, victims ++ more}

      {:short, _more, _remaining} ->
        {:error, :no_evictable_victims}
    end
  end

  # Returns {:done, victims} or {:short, victims, still_needed_bytes}, with
  # victims in walk order.
  defp take_until_bytes(_entries, needed_bytes) when needed_bytes <= 0, do: {:done, []}

  defp take_until_bytes(entries, needed_bytes) do
    entries
    |> Enum.reduce_while({:short, [], 0}, fn victim, {:short, victims, bytes} ->
      victims = [victim | victims]
      bytes = bytes + victim.size_bytes

      if bytes >= needed_bytes,
        do: {:halt, {:done, victims}},
        else: {:cont, {:short, victims, bytes}}
    end)
    |> case do
      {:done, victims} -> {:done, Enum.reverse(victims)}
      {:short, victims, bytes} -> {:short, Enum.reverse(victims), needed_bytes - bytes}
    end
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
