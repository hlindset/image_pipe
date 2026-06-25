defmodule ImagePipe.Debug.Info do
  @moduledoc """
  Aggregated, non-sensitive facts about how one response was produced, used to
  render the opt-in `X-ImagePipe-*` debug headers. Product-neutral: populated by
  request orchestration from values the source/output/transform layers already
  return. Every field is optional so partial collection degrades gracefully.
  """

  defstruct source_format: nil,
            source_bytes: nil,
            source_width: nil,
            source_height: nil,
            source_color_space: nil,
            source_icc?: nil,
            source_bit_depth: nil,
            source_alpha?: nil,
            source_orientation: nil,
            shrink: nil,
            output_format: nil,
            output_negotiated?: nil,
            output_width: nil,
            output_height: nil,
            output_quality: nil,
            output_stripped?: nil,
            output_color_profile: nil,
            output_distance: nil,
            aq: nil,
            pipeline: [],
            timings: %{}

  @type aq :: %{
          optional(:metric) => :ssimulacra2 | :butteraugli | :size,
          optional(:score) => float() | nil,
          optional(:target) => number() | nil,
          optional(:min) => 1..100,
          optional(:max) => 1..100,
          optional(:iterations) => non_neg_integer(),
          optional(:outcome) => atom(),
          optional(:limiting_factor) => atom() | nil,
          optional(:scorer) => :full | :crop,
          optional(:tiles) => pos_integer() | nil
        }

  @type t :: %__MODULE__{
          source_format: atom() | nil,
          source_bytes: non_neg_integer() | nil,
          source_width: pos_integer() | nil,
          source_height: pos_integer() | nil,
          source_color_space: atom() | nil,
          source_icc?: boolean() | nil,
          source_bit_depth: pos_integer() | nil,
          source_alpha?: boolean() | nil,
          source_orientation: 1..8 | nil,
          shrink: %{w: float(), h: float()} | nil,
          output_format: atom() | nil,
          output_negotiated?: boolean() | nil,
          output_width: pos_integer() | nil,
          output_height: pos_integer() | nil,
          output_quality: 1..100 | :default | nil,
          output_stripped?: boolean() | nil,
          output_color_profile: atom() | nil,
          output_distance: float() | nil,
          aq: aq() | nil,
          pipeline: [String.t()],
          timings: %{optional(atom()) => non_neg_integer()}
        }
end
