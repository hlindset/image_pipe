defmodule ImagePipe.Dialect.Imgproxy.Orientation do
  @moduledoc false

  defstruct auto_orient: false, rotate: 0, flip: nil

  @type flip() :: :horizontal | :vertical | :both

  @type t() :: %__MODULE__{
          auto_orient: boolean(),
          rotate: 0 | 90 | 180 | 270,
          flip: flip() | nil
        }
end
