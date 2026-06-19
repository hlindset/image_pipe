defmodule ImagePipe.Parser.Imgproxy.Effects do
  @moduledoc false

  @type t() :: %__MODULE__{
          blur: float() | nil,
          sharpen: float() | nil,
          pixelate: non_neg_integer() | nil,
          monochrome: keyword() | nil,
          duotone: keyword() | nil,
          brightness: number() | nil,
          contrast: number() | nil,
          saturation: number() | nil,
          colorize: keyword() | nil
        }

  defstruct blur: nil,
            sharpen: nil,
            pixelate: nil,
            monochrome: nil,
            duotone: nil,
            brightness: nil,
            contrast: nil,
            saturation: nil,
            colorize: nil
end
