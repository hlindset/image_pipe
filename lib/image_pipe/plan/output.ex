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
            max_bytes: nil

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
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
          max_bytes: nil | pos_integer()
        }
end
