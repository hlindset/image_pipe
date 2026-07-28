defmodule ImagePipe.Dialect.IIIF.Tiling do
  @moduledoc """
  Computes the IIIF Image API 3.0 `tiles` scheme and `sizes` ladder for an
  info.json from a source image's display dimensions and a chosen tile size.

  Mirrors the de-facto reference server (Cantaloupe): a power-of-two scale-factor
  ladder whose depth is bounded by the short side dropping below `@min_size`
  (64px), one derivative size per scale factor (`round/1` per axis, smallest-first,
  full size last), and a single tile entry clamped to the source dimensions.

  Returns product-neutral atom-keyed data; `ImagePipe.Dialect.IIIF.Info` owns the
  IIIF JSON string-key vocabulary.
  """

  # Short-side floor for the scale-factor ladder (Cantaloupe's DEFAULT_MIN_SIZE).
  @min_size 64

  @type size :: %{width: pos_integer(), height: pos_integer()}
  @type t :: %{scale_factors: [pos_integer(), ...], tile: size(), sizes: [size(), ...]}

  @spec tiles_and_sizes(pos_integer(), pos_integer(), pos_integer()) :: t()
  def tiles_and_sizes(width, height, tile_size)
      when is_integer(width) and width > 0 and
             is_integer(height) and height > 0 and
             is_integer(tile_size) and tile_size > 0 do
    factors = scale_factors(width, height)

    %{
      scale_factors: factors,
      tile: %{width: min(tile_size, width), height: min(tile_size, height)},
      sizes: sizes(width, height, factors)
    }
  end

  # Power-of-two ladder [1, 2, …, 2^maxRF]. `maxRF` = halvings of the short side
  # until it drops below @min_size (Cantaloupe ImageInfoUtil.maxReductionFactor:
  # halve, then test).
  defp scale_factors(width, height) do
    max_rf = max_reduction_factor(min(width, height), 0)
    for i <- 0..max_rf, do: Integer.pow(2, i)
  end

  defp max_reduction_factor(short_side, i) do
    next = short_side / 2.0
    if next < @min_size, do: i, else: max_reduction_factor(next, i + 1)
  end

  # One derivative size per scale factor, smallest-first (largest factor first).
  # `round/1` rounds half away from zero, identical to Java Math.round half-up for
  # positive dimensions (matches Cantaloupe).
  defp sizes(width, height, factors) do
    factors
    |> Enum.reverse()
    |> Enum.map(fn sf -> %{width: round(width / sf), height: round(height / sf)} end)
  end
end
