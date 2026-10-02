defmodule ImagePipe.Transform.Operation.Colorize do
  # Executable solid-color overlay: out = src·(1−o) + color·o.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
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
    case Image.split_alpha(image) do
      {rgb, nil} -> blend_rgb(rgb, o, color)
      {rgb, alpha} -> blend_with_alpha(rgb, alpha, o, color, keep_alpha)
    end
  end

  defp blend_with_alpha(rgb, alpha, o, color, keep_alpha) do
    with {:ok, blended} <- blend_rgb(rgb, o, color) do
      if keep_alpha, do: Image.join_bands([blended, alpha]), else: {:ok, blended}
    end
  end

  defp blend_rgb(rgb, o, [cr, cg, cb]) do
    with {:ok, blended} <-
           Operation.linear(rgb, [1.0 - o, 1.0 - o, 1.0 - o], [cr * o, cg * o, cb * o]) do
      Operation.cast(blended, VipsImage.format(rgb))
    end
  end
end
