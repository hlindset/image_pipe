defmodule ImagePipe.Cache.FileSystem.Policy do
  @moduledoc false

  @type descriptor :: %{
          required(:key_hash) => binary(),
          required(:size_bytes) => non_neg_integer(),
          required(:cost_us) => non_neg_integer(),
          optional(atom()) => term()
        }

  @block 4096

  @doc """
  The bytes an entry counts against the cap: its body rounded up to whole
  4 KiB blocks, plus one block for its metadata file. Filesystems allocate
  whole blocks, so a 30-byte BlurHash takes as much disk as a 4 KiB body,
  and the charge also bounds how many tiny entries a cap holds. Erlang can't
  read a filesystem's block size, so 4 KiB, the default on ext4, XFS, and
  APFS, is assumed.
  """
  @spec charged_bytes(non_neg_integer()) :: pos_integer()
  def charged_bytes(size_bytes), do: div(size_bytes + @block - 1, @block) * @block + @block

  @doc """
  Compute the cost-aware score for an entry given its frequency.

  score = freq × effective_cost / charged_bytes

  effective_cost = cost_us when cost_us > 0, else charged_bytes (size-neutral
  fallback that collapses scoring to freq alone).
  """
  @spec score(descriptor(), non_neg_integer()) :: float()
  def score(%{cost_us: cost_us, size_bytes: size_bytes}, freq) do
    charged = charged_bytes(size_bytes)
    effective_cost = if cost_us > 0, do: cost_us, else: charged
    freq * effective_cost / charged
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
  descriptors. Weighting is by charged bytes. Returns 0.0 for empty input.

  freq_fn maps a descriptor's key_hash to its current frequency.
  """
  @spec weighted_avg_score([descriptor()], (binary() -> non_neg_integer())) :: float()
  def weighted_avg_score([], _freq_fn), do: 0.0

  def weighted_avg_score(victims, freq_fn) when is_list(victims) do
    {numerator, denominator} =
      Enum.reduce(victims, {0, 0}, fn v, {num, den} ->
        freq = freq_fn.(v.key_hash)
        charged = charged_bytes(v.size_bytes)
        effective_cost = if v.cost_us > 0, do: v.cost_us, else: charged
        {num + freq * effective_cost, den + charged}
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
