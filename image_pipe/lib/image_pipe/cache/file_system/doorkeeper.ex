defmodule ImagePipe.Cache.FileSystem.Doorkeeper do
  @moduledoc false
  # Bloom filter in front of Admission's count-min sketch. A key's first
  # sighting only sets its doorkeeper bits; later sightings increment the
  # sketch.
  #
  # Talan's default hashes are pure-Elixir Murmur3, which dominated the cost of
  # an Admission hit. Keys are already uniform SHA-256 hex digests, so
  # `:erlang.phash2/2` gives the same false-positive rate at a fraction of the
  # cost. The hashes are unseeded, like `Sketch`'s: the filter is rebuilt from
  # traffic and never persisted.

  @hash_range 4_294_967_296

  def new(cardinality, false_positive_probability) do
    hash_functions =
      for index <- 1..Talan.BloomFilter.required_hash_function_count(false_positive_probability) do
        fn key -> :erlang.phash2({index, key}, @hash_range) end
      end

    Talan.BloomFilter.new(cardinality,
      false_positive_probability: false_positive_probability,
      hash_functions: hash_functions
    )
  end
end
