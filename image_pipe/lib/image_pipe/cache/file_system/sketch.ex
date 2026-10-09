defmodule ImagePipe.Cache.FileSystem.Sketch do
  @moduledoc false

  import Bitwise

  @enforce_keys [:depth, :width, :sample_size, :counters, :increments_since_reset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          depth: pos_integer(),
          width: pos_integer(),
          sample_size: pos_integer(),
          counters: :array.array(non_neg_integer()),
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
      counters: :array.new(depth * width, default: 0, fixed: true),
      increments_since_reset: 0
    }
  end

  @spec increment(t(), binary()) :: t()
  def increment(%__MODULE__{} = sketch, key) when is_binary(key) do
    positions = positions_for(sketch, key)
    current_values = Enum.map(positions, &:array.get(&1, sketch.counters))
    min_value = Enum.min(current_values)

    new_counters =
      positions
      |> Enum.zip(current_values)
      |> Enum.reduce(sketch.counters, fn {pos, value}, counters ->
        if value == min_value and value < 255 do
          :array.set(pos, value + 1, counters)
        else
          counters
        end
      end)

    %{sketch | counters: new_counters, increments_since_reset: sketch.increments_since_reset + 1}
  end

  @spec estimate(t(), binary()) :: non_neg_integer()
  def estimate(%__MODULE__{} = sketch, key) when is_binary(key) do
    sketch
    |> positions_for(key)
    |> Enum.map(&:array.get(&1, sketch.counters))
    |> Enum.min()
  end

  @spec age(t()) :: t()
  def age(%__MODULE__{} = sketch) do
    new_counters = :array.map(fn _idx, value -> bsr(value, 1) end, sketch.counters)

    %{
      sketch
      | counters: new_counters,
        increments_since_reset: 0
    }
  end

  @spec should_age?(t()) :: boolean()
  def should_age?(%__MODULE__{sample_size: s, increments_since_reset: n}), do: n >= s

  defp positions_for(%__MODULE__{depth: depth, width: width}, key) do
    for row <- 0..(depth - 1) do
      hash = :erlang.phash2({row, key}, width)
      row * width + hash
    end
  end
end
