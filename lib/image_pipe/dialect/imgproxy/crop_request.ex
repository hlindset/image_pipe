defmodule ImagePipe.Dialect.Imgproxy.CropRequest do
  @moduledoc false

  @type dimension() :: :auto | {:scale, number()} | ImagePipe.imgp_pixels()

  @type gravity() ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:fp, float(), float()}
          | {:obj, [String.t()]}
          | {:objw, [{String.t(), float()}]}
          | :sm
          | nil

  @type offset() :: {:pixels, float()} | {:scale, float()}

  @type t() :: %__MODULE__{
          width: dimension(),
          height: dimension(),
          gravity: gravity(),
          x_offset: offset(),
          y_offset: offset()
        }

  defstruct width: :auto,
            height: :auto,
            gravity: nil,
            x_offset: {:pixels, 0.0},
            y_offset: {:pixels, 0.0}
end
