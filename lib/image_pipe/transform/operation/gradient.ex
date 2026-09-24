defmodule ImagePipe.Transform.Operation.Gradient do
  @moduledoc """
  Executable transparency→color gradient overlay.

  out = src·(1−m) + color·m, where m = opacity · clamp01((p − start)/(stop − start))
  and p is the normalized projection of each pixel onto the gradient direction.

  `angle` is canonical clockwise degrees (0=down, 90=left, 180=up, 270=right).
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.DirectionalMask
  alias ImagePipe.Transform.State
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
    width = VipsImage.width(image)
    height = VipsImage.height(image)

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
        Operation.cast(blended, VipsImage.format(rgb))
      end
    end)
  end

  defp blend(rgb, mask, [cr, cg, cb]) do
    with {:ok, mask3} <- Operation.bandjoin([mask, mask, mask]),
         {:ok, inv3} <- Operation.linear(mask3, [-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]),
         {:ok, src_term} <- Operation.multiply(rgb, inv3),
         {:ok, color_img} <- color_constant(rgb, [cr, cg, cb]),
         {:ok, col_term} <- Operation.multiply(color_img, mask3) do
      Operation.add(src_term, col_term)
    end
  end

  defp color_constant(ref, channels) do
    case Operation.black(VipsImage.width(ref), VipsImage.height(ref), bands: length(channels)) do
      {:ok, base} -> Operation.linear(base, [1.0], Enum.map(channels, &(&1 * 1.0)))
      error -> error
    end
  end
end
