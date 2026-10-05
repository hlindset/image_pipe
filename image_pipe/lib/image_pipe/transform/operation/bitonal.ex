defmodule ImagePipe.Transform.Operation.Bitonal do
  # Converts to grayscale (`:bw`), then thresholds luminance at 128.
  #
  # Values below 128 become black (0); others become white (255). Alpha is preserved,
  # keeping soft transparency. This per-pixel operation is sequential-safe.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
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
  # (`without_alpha_band` is a no-op wrapper when there is no alpha band). A
  # 16-bit image stays 16-bit, so the result matches its alpha's scale.
  # Dialyzer can't see through Vix's generated Operation typings (relational_const),
  # so it also reports to_format/2 as unreachable.
  @dialyzer [{:no_fail_call, to_bitonal: 1}, {:no_unused, to_format: 2}]
  defp to_bitonal(image) do
    Image.without_alpha_band(image, fn colour ->
      with {:ok, colour} <- WorkingColor.to_srgb(colour),
           {:ok, gray} <- Image.to_colorspace(colour, :bw),
           {:ok, bitonal} <-
             VixOperation.relational_const(gray, :VIPS_OPERATION_RELATIONAL_MOREEQ, [@threshold]) do
        to_format(bitonal, VipsImage.format(colour))
      end
    end)
  end

  defp to_format(bitonal, :VIPS_FORMAT_USHORT) do
    with {:ok, scaled} <- VixOperation.linear(bitonal, [257.0], [0.0]),
         {:ok, ushort} <- VixOperation.cast(scaled, :VIPS_FORMAT_USHORT) do
      VixOperation.copy(ushort, interpretation: :VIPS_INTERPRETATION_GREY16)
    end
  end

  defp to_format(bitonal, _format), do: {:ok, bitonal}
end
