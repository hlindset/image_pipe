defmodule ImagePipe.Native.Request do
  @moduledoc """
  Canonical, pre-negotiation request data for the native URL dialect
  [native §Canonical form and identity].

  Produced by `ImagePipe.Native.Parser.parse/2` from Task 4's lexed
  path data. Pure data — no PIDs, refs, or conn state [pipelines §Design
  principles 2]. Within a group, option order is semantically irrelevant:
  any permutation of a group's segments produces an equal `%Request{}`
  [native §Canonical form and identity] (property-tested in
  `canonical_property_test.exs`).
  """

  alias ImagePipe.Native.Request.Group
  alias ImagePipe.Native.Request.Output

  @enforce_keys [:groups, :output, :source]
  defstruct groups: [],
            output: nil,
            source: nil,
            orient: :auto,
            filename: nil,
            attachment?: false,
            cachebuster: nil,
            expires: nil,
            debug?: false

  @type t :: %__MODULE__{
          groups: [Group.t()],
          output: Output.t(),
          source: String.t(),
          orient: :auto | :none,
          filename: String.t() | nil,
          attachment?: boolean(),
          cachebuster: String.t() | nil,
          expires: pos_integer() | nil,
          debug?: boolean()
        }
end

defmodule ImagePipe.Native.Request.Group do
  @moduledoc """
  One pipeline-group's worth of transform intent [native §Pipeline groups].

  `then` splits a request into ordered groups; each group is one pass of
  the fixed stage order (`rotate → flip → trim → region/crop → resize →
  cover result crop → blur → … → pad → bg`) — normative for this dialect,
  not option order in the URL.
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

defmodule ImagePipe.Native.Request.Output do
  @moduledoc """
  Terminal selection and output policy [native §Output & delivery,
  §Terminal contracts].
  """

  defstruct terminal: :image,
            format: nil,
            quality: nil,
            metadata: nil,
            color_profile: nil,
            hdr: nil,
            format_qualities: %{},
            autoquality: nil,
            max_bytes: nil,
            encoder_options: %{}

  @type t :: %__MODULE__{
          terminal: :image | :blurhash | :info,
          format: nil | :avif | :webp | :jpeg | :png | :jpeg_xl,
          quality: nil | 1..100,
          metadata: nil | :strip | :copyright | :keep,
          color_profile:
            nil
            | :strip
            | :preserve_source
            | {:convert, :srgb | :display_p3 | :adobe_rgb},
          hdr: nil | :tone_map | :preserve,
          format_qualities: %{optional(atom()) => {:quality, 1..100}},
          autoquality:
            nil
            | :none
            | {:size | :ssimulacra2 | :butteraugli, keyword(pos_integer() | float())},
          max_bytes: nil | pos_integer(),
          encoder_options: %{optional(atom()) => struct()}
        }
end
