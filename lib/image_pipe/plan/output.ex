defmodule ImagePipe.Plan.Output do
  @moduledoc """
  Output value types and quality-search defaults shared by request parsing,
  output policy, and encoding. Per-format encoder options and quality-search
  parameters live in the nested modules.
  """

  # The confirm-skipped crop-estimate correction per `{format, content-class}`
  # (#380). Above the 6 MP crop crossover the `:ssim2` search ships the crop verdict
  # minus this offset (the full-frame confirm #369 removed); a larger offset biases
  # the estimate down so the search climbs to higher quality. AVIF × `:graphic`
  # (dense graphic content) overshoots full-frame by ~6 and draws the big offset;
  # every other cell stays at the lean 2.4 default. A defaulted seam (like
  # `flatten_background`): no parser overrides it today.
  @default_quality_search_offsets %{default: 2.4, overrides: %{{:avif, :graphic} => 6.0}}

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
  @type content_class :: :photo | :graphic
  @type quality_search_offsets :: %{
          default: number(),
          overrides: %{optional({format(), content_class()}) => number()}
        }

  @doc "The built-in confirm-skipped crop-offset policy (bench Part M / #380)."
  @spec default_quality_search_offsets() :: quality_search_offsets()
  def default_quality_search_offsets, do: @default_quality_search_offsets

  @doc "Resolve the offset for a `{format, content_class}` cell, defaulting per policy."
  @spec offset_for(quality_search_offsets(), format(), content_class()) :: number()
  def offset_for(%{overrides: overrides, default: default}, format, class),
    do: Map.get(overrides, {format, class}, default)
end
