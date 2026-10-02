defmodule ImagePipe.Transform.Operation.Duotone do
  # Executable two-color luminance mapping operation.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.GrayFrame
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @luma_r 0.299
  @luma_g 0.587
  @luma_b 0.114

  @enforce_keys [:intensity, :shadow, :highlight]
  defstruct [:intensity, :shadow, :highlight]

  @type t :: %__MODULE__{
          intensity: float(),
          shadow: [0..255],
          highlight: [0..255]
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :duotone

  @impl ImagePipe.Transform
  def execute(
        %__MODULE__{intensity: intensity, shadow: shadow, highlight: highlight},
        %State{} = state
      ) do
    case apply_duotone(state.image, intensity, shadow, highlight) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_duotone(%VipsImage{} = image, intensity, shadow, highlight) do
    with {:ok, image} <- GrayFrame.promote(image) do
      Image.without_alpha_band(image, &tone(&1, intensity, shadow, highlight))
    end
  end

  # Shadow and highlight are sRGB; take their values in the image's own space
  # and depth, and scale the color deltas by its full range.
  defp tone(image, intensity, shadow, highlight) do
    full = Alpha.opaque(VipsImage.format(image))

    with {:ok, shadow} <- WorkingColor.values(image, shadow),
         {:ok, highlight} <- WorkingColor.values(image, highlight),
         {:ok, matrix} <-
           VipsImage.new_matrix_from_array(3, 3, matrix(intensity, shadow, highlight, full)),
         {:ok, recombined} <- Operation.recomb(image, matrix),
         {:ok, adjusted} <- Operation.linear(recombined, [1.0], addends(intensity, shadow)) do
      Operation.cast(adjusted, VipsImage.format(image))
    end
  end

  defp matrix(intensity, shadow, highlight, full) do
    [shadow_red, shadow_green, shadow_blue] = shadow
    [highlight_red, highlight_green, highlight_blue] = highlight

    [
      row(intensity, 0, highlight_red - shadow_red, full),
      row(intensity, 1, highlight_green - shadow_green, full),
      row(intensity, 2, highlight_blue - shadow_blue, full)
    ]
  end

  defp row(intensity, identity_band, color_delta, full) do
    color_scale = intensity * color_delta / full

    [
      identity(identity_band, 0, intensity) + @luma_r * color_scale,
      identity(identity_band, 1, intensity) + @luma_g * color_scale,
      identity(identity_band, 2, intensity) + @luma_b * color_scale
    ]
  end

  defp identity(current_band, current_band, intensity), do: 1.0 - intensity
  defp identity(_identity_band, _band, _intensity), do: 0.0

  defp addends(intensity, shadow), do: Enum.map(shadow, &(&1 * intensity))
end
