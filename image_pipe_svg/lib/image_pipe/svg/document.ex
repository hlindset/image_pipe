defmodule ImagePipe.SVG.Document do
  @moduledoc """
  A parsed SVG and its intrinsic size in pixels at 96 DPI.
  """

  @enforce_keys [:ref, :width, :height]
  defstruct [:ref, :width, :height]

  @type t :: %__MODULE__{ref: reference(), width: float(), height: float()}
end
