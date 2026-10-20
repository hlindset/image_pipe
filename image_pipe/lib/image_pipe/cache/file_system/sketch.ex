defmodule ImagePipe.Cache.FileSystem.Sketch do
  # The counters are 4 bits, packed sixteen to an `:atomics` word and updated
  # in place, so the admission process that owns the sketch neither copies
  # them on each update nor on each garbage collection. Only that process
  # updates them. A counter stops at 15, so an increment never carries into
  # the next one. As in TinyLFU, the doorkeeper takes first sightings and
  # aging halves the counts, so 15 is enough to separate frequent keys from
  # the rest.
  @moduledoc false

  import Bitwise

  @per_word 16
  # Each counter's low three bits, so a word shifted right by one halves
  # every counter without the next one's low bit moving into it.
  @halve_mask 0x7777777777777777

  @enforce_keys [:depth, :width, :sample_size, :counters, :increments_since_reset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          depth: pos_integer(),
          width: pos_integer(),
          sample_size: pos_integer(),
          counters: :atomics.atomics_ref(),
          increments_since_reset: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    depth = Keyword.fetch!(opts, :depth)
    width = Keyword.fetch!(opts, :width)

    # `sample_size` is the number of CMS increments between aging passes.
    # It is DELIBERATELY decoupled from `width`: width is sized for counter
    # accuracy (collision rate), while the aging cadence tracks how many
    # distinct accesses constitute a sampling window — a cardinality
    # concept, not an accuracy one. The `width * 10` value here is only a
    # convenience default so pure-Sketch unit tests need not specify it;
    # production always passes an explicit `:sample_size` computed by the
    # config layer (`:aging_sample_size`, Task 25) from estimated cache
    # cardinality, so tuning `:sketch_width` for accuracy never silently
    # changes how fast frequencies decay.
    sample_size = Keyword.get(opts, :sample_size, width * 10)

    %__MODULE__{
      depth: depth,
      width: width,
      sample_size: sample_size,
      counters: :atomics.new(div(depth * width + @per_word - 1, @per_word), signed: false),
      increments_since_reset: 0
    }
  end

  @spec increment(t(), binary()) :: t()
  def increment(%__MODULE__{counters: counters} = sketch, key) when is_binary(key) do
    positions = positions_for(sketch, key)
    current_values = Enum.map(positions, &get(counters, &1))
    min_value = Enum.min(current_values)

    if min_value < 15 do
      for {pos, ^min_value} <- Enum.zip(positions, current_values),
          do: :atomics.add(counters, word(pos), bsl(1, shift(pos)))
    end

    %{sketch | increments_since_reset: sketch.increments_since_reset + 1}
  end

  @spec estimate(t(), binary()) :: non_neg_integer()
  def estimate(%__MODULE__{counters: counters} = sketch, key) when is_binary(key) do
    sketch
    |> positions_for(key)
    |> Enum.map(&get(counters, &1))
    |> Enum.min()
  end

  @spec age(t()) :: t()
  def age(%__MODULE__{counters: counters} = sketch) do
    Enum.each(1..:atomics.info(counters).size, fn index ->
      :atomics.put(counters, index, bsr(:atomics.get(counters, index), 1) &&& @halve_mask)
    end)

    %{sketch | increments_since_reset: 0}
  end

  @spec should_age?(t()) :: boolean()
  def should_age?(%__MODULE__{sample_size: s, increments_since_reset: n}), do: n >= s

  defp positions_for(%__MODULE__{depth: depth, width: width}, key) do
    for row <- 0..(depth - 1) do
      hash = :erlang.phash2({row, key}, width)
      row * width + hash
    end
  end

  defp get(counters, pos), do: bsr(:atomics.get(counters, word(pos)), shift(pos)) &&& 15

  defp word(pos), do: div(pos, @per_word) + 1
  defp shift(pos), do: rem(pos, @per_word) * 4
end
