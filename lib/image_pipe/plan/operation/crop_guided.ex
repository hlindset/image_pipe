defmodule ImagePipe.Plan.Operation.CropGuided do
  @moduledoc """
  Semantic crop operation that crops to a size using a guide.
  """

  @enforce_keys [:width, :height, :guide]
  defstruct @enforce_keys ++
              [
                x_offset: {:pixels, 0.0},
                y_offset: {:pixels, 0.0},
                aspect_ratio: nil,
                enlarge: false
              ]

  @type dimension :: :full_axis | {:px, pos_integer()} | {:ratio, pos_integer(), pos_integer()}
  @type anchor ::
          :center
          | :top_left
          | :top
          | :top_right
          | :left
          | :right
          | :bottom_left
          | :bottom
          | :bottom_right
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}
  @type guide ::
          anchor()
          | {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:focal, {:ratio, non_neg_integer(), pos_integer()},
             {:ratio, non_neg_integer(), pos_integer()}}
          | :smart
          | {:smart, :face_assist}
          | {:detect, {:all, weights()}}
          | {:detect, {nonempty_list(String.t()), weights()}}
  @type offset :: number() | {:pixels, number()} | {:scale, number()}

  @type t :: %__MODULE__{
          width: dimension(),
          height: dimension(),
          guide: guide(),
          x_offset: offset(),
          y_offset: offset(),
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean()
        }
end
