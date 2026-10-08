defmodule ImagePipe.Transform.Operation.Colorize do
  # Executable solid-color overlay: out = src·(1−o) + color·o.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.GrayFrame
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:opacity, :color, :keep_alpha]
  defstruct [:opacity, :color, :keep_alpha]

  @type t :: %__MODULE__{opacity: float(), color: [0..255], keep_alpha: boolean()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :colorize

  @impl ImagePipe.Transform
  def execute(%__MODULE__{opacity: o, color: color, keep_alpha: keep_alpha}, %State{} = state) do
    case apply_colorize(state.image, o, color, keep_alpha) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Split alpha explicitly: without_alpha_band/2 always restores it, but colorize
  # defaults to opaque output. Rejoin only when keep_alpha is true.
  defp apply_colorize(image, o, color, keep_alpha) do
    with {:ok, image} <- GrayFrame.for_color(image, color) do
      case Image.split_alpha(image) do
        {rgb, nil} -> blend_rgb(rgb, o, color)
        {rgb, alpha} -> blend_with_alpha(rgb, alpha, o, color, keep_alpha)
      end
    end
  end

  defp blend_with_alpha(rgb, alpha, o, color, true) do
    with {:ok, blended} <- blend_rgb(rgb, o, color), do: Image.join_bands([blended, alpha])
  end

  # Opaque output shows transparent pixels over white, as a non-alpha format
  # does, rather than the colors stored under them.
  defp blend_with_alpha(rgb, alpha, o, color, false) do
    with {:ok, image} <- Image.join_bands([rgb, alpha]),
         {:ok, white} <- WorkingColor.values(rgb, [255, 255, 255]),
         {:ok, flattened} <- Operation.flatten(image, background: white) do
      blend_rgb(flattened, o, color)
    end
  end

  # The color is sRGB; blend its value in the image's own space and depth.
  defp blend_rgb(rgb, o, color) do
    with {:ok, values} <- WorkingColor.values(rgb, color),
         {:ok, blended} <-
           Operation.linear(
             rgb,
             Enum.map(values, fn _ -> 1.0 - o end),
             Enum.map(values, &(&1 * o))
           ) do
      Operation.cast(blended, VipsImage.format(rgb))
    end
  end
end
