defmodule ImagePipe.Plan.Request.Group do
  @moduledoc """
  One group's transform intent.

  `-` splits a request into ordered groups; each group is one pass of
  the fixed stage order (`rotate → flip → trim → region/crop → resize →
  cover result crop → blur → … → pad → bg`). The executor applies this order
  independently of option order in the URL.
  """

  @type length :: {:px, number()} | {:pct, number()}
  @type color :: {0..255, 0..255, 0..255}
  @type named_anchor ::
          :center
          | :top
          | :bottom
          | :left
          | :right
          | :top_left
          | :top_right
          | :bottom_left
          | :bottom_right

  @type resize :: %{
          w: :auto | pos_integer(),
          h: :auto | pos_integer(),
          min_w: pos_integer() | nil,
          min_h: pos_integer() | nil,
          fit: :contain | :cover | :cover_down | :stretch | :auto,
          enlarge: boolean(),
          zoom: {float(), float()}
        }

  @type guide ::
          {:anchor, named_anchor()}
          | {:anchor_smart}
          | {:focus, float(), float()}
          | {:smart, :face_assist}
          | {:detect, {:all | [String.t()], %{optional(:default | String.t()) => float()}}}

  defstruct rotate: nil,
            flip: nil,
            gray: false,
            bitonal: false,
            dpr: 1.0,
            trim: nil,
            trim_symmetry: nil,
            region: nil,
            crop: nil,
            crop_ratio: nil,
            crop_ratio_enlarge: false,
            guide: nil,
            anchor_offset: nil,
            resize: nil,
            canvas: nil,
            blur: nil,
            progressive_blur: nil,
            sharpen: nil,
            pixelate: nil,
            monochrome: nil,
            duotone: nil,
            brightness: nil,
            contrast: nil,
            saturation: nil,
            colorize: nil,
            gradient: nil,
            pad: nil,
            bg: nil

  @type t :: %__MODULE__{
          rotate: nil | number(),
          flip: nil | :horizontal | :vertical | :both,
          gray: boolean(),
          bitonal: boolean(),
          dpr: float(),
          trim: nil | :auto | {color(), number()},
          trim_symmetry: nil | :horizontal | :vertical | :both,
          region: nil | {length(), length(), length(), length()},
          crop: nil | {length(), length()},
          crop_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          crop_ratio_enlarge: boolean(),
          guide: nil | guide(),
          anchor_offset: nil | {length(), length()},
          resize: nil | resize(),
          canvas:
            nil
            | %{
                mode: :box | :ratio,
                at: named_anchor(),
                offset: {length(), length()}
              },
          blur: nil | float(),
          progressive_blur:
            nil | %{sigma: float(), angle: float(), start: float(), stop: float()},
          sharpen: nil | float(),
          pixelate: nil | pos_integer(),
          monochrome: nil | %{intensity: float(), color: color()},
          duotone: nil | %{intensity: float(), shadow: color(), highlight: color()},
          brightness: nil | integer(),
          contrast: nil | float(),
          saturation: nil | float(),
          colorize: nil | %{opacity: float(), color: color(), keep_alpha: boolean()},
          gradient:
            nil
            | %{
                opacity: float(),
                color: color(),
                angle: float(),
                start: float(),
                stop: float()
              },
          pad: nil | {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          bg: nil | {0..255, 0..255, 0..255, float()}
        }
end
