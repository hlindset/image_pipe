defmodule ImagePipe.Transform.Operation.Bitonal do
  @moduledoc """
  Executable bitonal (black-and-white threshold) operation. Converts to grayscale
  (`:bw` colourspace), then applies a `>= 128` threshold so each luminance value
  becomes either 0 (black) or 255 (white). Any **alpha band is preserved
  untouched** (the threshold runs only on the colour band, so soft transparency is
  not hard-quantized). Per-pixel point op: sequential-safe.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation, as: VixOperation

  defstruct []

  @type t :: %__MODULE__{}

  @threshold 128

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :bitonal

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case to_bitonal(state.image) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Strip any alpha, threshold the luminance band, then rejoin the original alpha
  # (`without_alpha_band` is a no-op wrapper when there is no alpha band).
  # Dialyzer can't see through Vix's generated Operation typings (relational_const).
  @dialyzer {:no_fail_call, to_bitonal: 1}
  defp to_bitonal(image) do
    Image.without_alpha_band(image, fn colour ->
      with {:ok, gray} <- Image.to_colorspace(colour, :bw) do
        VixOperation.relational_const(gray, :VIPS_OPERATION_RELATIONAL_MOREEQ, [@threshold])
      end
    end)
  end
end
