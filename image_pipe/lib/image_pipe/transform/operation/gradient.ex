defmodule ImagePipe.Transform.Operation.Gradient do
  # Executable transparency→color gradient overlay.
  #
  # out = src·(1−m) + color·m, where m = opacity · clamp01((p − start)/(stop − start))
  # and p is the normalized projection of each pixel onto the gradient direction.
  #
  # `angle` is canonical clockwise degrees (0=down, 90=left, 180=up, 270=right).
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.DirectionalMask
  alias ImagePipe.Transform.GrayFrame
  alias ImagePipe.Transform.Rounding
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:opacity, :color, :angle, :start, :stop]
  defstruct [:opacity, :color, :angle, :start, :stop]

  @type t :: %__MODULE__{
          opacity: float(),
          color: [0..255],
          angle: float(),
          start: float(),
          stop: float()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gradient

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    case apply_gradient(state.image, op) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Blend color bands, then restore the original alpha unchanged.
  defp apply_gradient(%VipsImage{} = image, %__MODULE__{} = op) do
    width = Image.width(image)
    height = Image.height(image)

    with {:ok, image} <- GrayFrame.for_color(image, op.color) do
      blend_bands(image, op, width, height)
    end
  end

  defp blend_bands(image, op, width, height) do
    Image.without_alpha_band(image, fn rgb ->
      with {:ok, mask} <-
             DirectionalMask.build(
               width,
               height,
               op.angle,
               op.start,
               op.stop,
               op.opacity
             ),
           {:ok, blended} <- blend(rgb, mask, op.color) do
        Rounding.cast(blended, VipsImage.format(rgb))
      end
    end)
  end

  # The color is sRGB; blend its value in the image's own space and depth.
  defp blend(rgb, mask, color) do
    with {:ok, values} <- WorkingColor.values(rgb, color),
         bands = length(values),
         {:ok, masks} <- Operation.bandjoin(List.duplicate(mask, bands)),
         {:ok, inverse} <-
           Operation.linear(masks, List.duplicate(-1.0, bands), List.duplicate(1.0, bands)),
         {:ok, src_term} <- Operation.multiply(rgb, inverse),
         {:ok, color_img} <- color_constant(rgb, values),
         {:ok, col_term} <- Operation.multiply(color_img, masks) do
      Operation.add(src_term, col_term)
    end
  end

  defp color_constant(ref, channels) do
    case Operation.black(Image.width(ref), Image.height(ref), bands: length(channels)) do
      {:ok, base} -> Operation.linear(base, [1.0], Enum.map(channels, &(&1 * 1.0)))
      error -> error
    end
  end
end
