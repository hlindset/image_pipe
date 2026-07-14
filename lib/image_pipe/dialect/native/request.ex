defmodule ImagePipe.Dialect.Native.Request do
  @moduledoc """
  Canonical, pre-negotiation request data for the native URL dialect
  [native §Canonical form and identity].

  Produced by `ImagePipe.Dialect.Native.Parser.parse/2` from Task 4's lexed
  path data. Pure data — no PIDs, refs, or conn state [pipelines §Design
  principles 2]. Within a group, option order is semantically irrelevant:
  any permutation of a group's segments produces an equal `%Request{}`
  [native §Canonical form and identity] (property-tested in
  `canonical_property_test.exs`).
  """

  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output

  @enforce_keys [:groups, :output, :source]
  defstruct groups: [], output: nil, source: nil, expires: nil

  @type t :: %__MODULE__{
          groups: [Group.t()],
          output: Output.t(),
          source: String.t(),
          expires: pos_integer() | nil
        }
end

defmodule ImagePipe.Dialect.Native.Request.Group do
  @moduledoc """
  One pipeline-group's worth of transform intent [native §Pipeline groups].

  `then` splits a request into ordered groups; each group is one pass of
  the fixed stage order (`rotate → flip → trim → region/crop → resize →
  cover result crop → blur → … → pad → bg`) — normative for this dialect,
  not option order in the URL.
  """

  @type length :: {:px, number()} | {:pct, number()}
  @type color :: {0..255, 0..255, 0..255}

  @type resize :: %{
          w: :auto | pos_integer(),
          h: :auto | pos_integer(),
          fit: :contain | :cover | :cover_down | :stretch | :auto,
          enlarge: boolean()
        }

  @type guide ::
          {:anchor, atom()}
          | {:anchor_smart}
          | {:focus, float(), float()}

  defstruct trim: nil,
            region: nil,
            crop: nil,
            guide: nil,
            resize: nil,
            blur: nil,
            pad: nil,
            bg: nil

  @type t :: %__MODULE__{
          trim: nil | :auto | {color(), number()},
          region: nil | {length(), length(), length(), length()},
          crop: nil | {length(), length()},
          guide: nil | guide(),
          resize: nil | resize(),
          blur: nil | float(),
          pad: nil | {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          bg: nil | {0..255, 0..255, 0..255, float()}
        }
end

defmodule ImagePipe.Dialect.Native.Request.Output do
  @moduledoc """
  Terminal selection and output policy [native §Output & delivery,
  §Terminal contracts].
  """

  defstruct terminal: :image, format: nil, quality: nil

  @type t :: %__MODULE__{
          terminal: :image | :blurhash,
          format: nil | :avif | :webp | :jpeg | :png | :jpeg_xl,
          quality: nil | 1..100
        }
end
