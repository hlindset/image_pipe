defmodule ImagePipe.Plan.Output do
  @moduledoc """
  Requested output intent before runtime format negotiation.

  `strip_metadata`, `keep_copyright`, `color_profile`, `hdr`, and
  `flatten_background` are resolved values (never `nil`): a parser resolves its
  config defaults / URL options into concrete values before building a plan (the
  imgproxy parser does this in `apply_request_defaults/2`). They drive the
  encoder's metadata finalize and the transform's HDR working-space decision.

  `flatten_background` is the color an alpha-bearing image is composited onto when
  the resolved output format can't carry alpha (the encoder's format-driven
  flatten — imgproxy's `flatten` onto `po.Background()`). It defaults to opaque
  white, matching imgproxy's `color.White`; a per-request background (e.g. the
  imgproxy `bg`/`bga` option) is a separate transform-chain operation and does not
  set this field. No parser overrides it today — it is the declarative seam for a
  future dialect/host default.

  `quality_search` and `max_bytes` are resolved defaults (`:none`/`nil` = off).
  """

  alias ImagePipe.Plan.Color

  # The confirm-skipped crop-estimate correction per `{format, content-class}`
  # (#380). Above the 6 MP crop crossover the `:ssim2` search ships the crop verdict
  # minus this offset (the full-frame confirm #369 removed); a larger offset biases
  # the estimate down so the search climbs to higher quality. AVIF × `:graphic`
  # (dense graphic content) overshoots full-frame by ~6 and draws the big offset;
  # every other cell stays at the lean 2.4 default. A defaulted seam (like
  # `flatten_background`): no parser overrides it today.
  @default_quality_search_offsets %{default: 2.4, overrides: %{{:avif, :graphic} => 6.0}}

  @enforce_keys [:mode]
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            strip_metadata: true,
            keep_copyright: true,
            color_profile: :strip,
            hdr: :tone_map,
            flatten_background: Color.white(),
            quality_search: :none,
            max_bytes: nil,
            quality_search_offsets: @default_quality_search_offsets

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
  @type content_class :: :photo | :graphic
  @type quality_search_offsets :: %{
          default: number(),
          overrides: %{optional({format(), content_class()}) => number()}
        }
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: color_profile(),
          hdr: hdr(),
          flatten_background: Color.t(),
          quality_search: :none | ImagePipe.Plan.Output.QualitySearch.t(),
          max_bytes: nil | pos_integer(),
          quality_search_offsets: quality_search_offsets()
        }

  @doc "The built-in confirm-skipped crop-offset policy (bench Part M / #380)."
  @spec default_quality_search_offsets() :: quality_search_offsets()
  def default_quality_search_offsets, do: @default_quality_search_offsets

  @doc "Resolve the offset for a `{format, content_class}` cell, defaulting per policy."
  @spec offset_for(quality_search_offsets(), format(), content_class()) :: number()
  def offset_for(%{overrides: overrides, default: default}, format, class),
    do: Map.get(overrides, {format, class}, default)
end
