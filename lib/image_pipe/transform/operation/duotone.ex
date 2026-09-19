defmodule ImagePipe.Transform.Operation.Duotone do
  @moduledoc """
  Executable two-color luminance mapping operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
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
    Image.without_alpha_band(image, fn image ->
      with {:ok, image} <- ensure_rgb(image),
           {:ok, matrix} <-
             VipsImage.new_matrix_from_array(3, 3, matrix(intensity, shadow, highlight)),
           {:ok, recombined} <- Operation.recomb(image, matrix),
           {:ok, adjusted} <- Operation.linear(recombined, [1.0], addends(intensity, shadow)) do
        Operation.cast(adjusted, VipsImage.format(image))
      end
    end)
  end

  defp ensure_rgb(%VipsImage{} = image) do
    case VipsImage.bands(image) do
      1 -> Image.to_colorspace(image, :srgb)
      3 -> {:ok, image}
    end
  end

  defp matrix(intensity, shadow, highlight) do
    [shadow_red, shadow_green, shadow_blue] = shadow
    [highlight_red, highlight_green, highlight_blue] = highlight

    [
      row(intensity, 0, highlight_red - shadow_red),
      row(intensity, 1, highlight_green - shadow_green),
      row(intensity, 2, highlight_blue - shadow_blue)
    ]
  end

  defp row(intensity, identity_band, color_delta) do
    color_scale = intensity * color_delta / 255

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
