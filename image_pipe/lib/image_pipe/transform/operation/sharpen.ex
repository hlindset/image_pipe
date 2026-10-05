defmodule ImagePipe.Transform.Operation.Sharpen do
  # Executable sharpen operation.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :sharpen

  @impl ImagePipe.Transform
  def execute(%__MODULE__{sigma: sigma}, %State{} = state) do
    case AlphaPremultiply.with_alpha_premultiplied(state.image, &sharpen(&1, sigma)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # libvips sharpens in LabS and converts back to the input interpretation, so a
  # float premultiplied 8-bit image would come back as uchar with its low-alpha
  # colours truncated. Sharpen it as 16-bit instead and scale back to float.
  defp sharpen(image, sigma) do
    case wide_interpretation(image) do
      nil ->
        Image.sharpen(image, sigma: sigma)

      wide ->
        with {:ok, scaled} <- Operation.linear(image, [257.0], [0.0]),
             {:ok, ushort} <- Operation.cast(scaled, :VIPS_FORMAT_USHORT),
             {:ok, ushort} <- Operation.copy(ushort, interpretation: wide),
             {:ok, sharpened} <- Image.sharpen(ushort, sigma: sigma),
             {:ok, float} <- Operation.linear(sharpened, [1 / 257], [0.0]) do
          Operation.copy(float, interpretation: VipsImage.interpretation(image))
        end
    end
  end

  defp wide_interpretation(image) do
    case {VipsImage.format(image), VipsImage.interpretation(image)} do
      {:VIPS_FORMAT_FLOAT, :VIPS_INTERPRETATION_sRGB} -> :VIPS_INTERPRETATION_RGB16
      {:VIPS_FORMAT_FLOAT, :VIPS_INTERPRETATION_B_W} -> :VIPS_INTERPRETATION_GREY16
      _other -> nil
    end
  end
end
