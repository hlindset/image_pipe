defmodule ImagePipe.Transform.Operation.Colorize do
  @moduledoc """
  Executable solid-color overlay: out = src·(1−o) + color·o.
  """

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

  # IMPORTANT: do NOT use Image.without_alpha_band/2 here. It strips alpha, runs the
  # fn, and *unconditionally rejoins the original alpha* (see bitonal.ex:34-35). That
  # is wrong for colorize, whose DEFAULT (keep_alpha: false) must produce an OPAQUE
  # result. So split alpha explicitly (the input_color_management.ex alpha_split_at
  # pattern) and rejoin only when keep_alpha is true.
  defp apply_colorize(image, o, color, keep_alpha) do
    case Image.has_alpha?(image) do
      false ->
        blend_rgb(image, o, color)

      true ->
        color_bands = VipsImage.bands(image) - 1

        with {:ok, rgb} <- Operation.extract_band(image, 0, n: color_bands),
             {:ok, alpha} <- Operation.extract_band(image, color_bands, n: 1),
             {:ok, blended} <- blend_rgb(rgb, o, color) do
          if keep_alpha, do: Operation.bandjoin([blended, alpha]), else: {:ok, blended}
        end
    end
  end

  defp blend_rgb(rgb, o, [cr, cg, cb]) do
    with {:ok, blended} <-
           Operation.linear(rgb, [1.0 - o, 1.0 - o, 1.0 - o], [cr * o, cg * o, cb * o]) do
      Operation.cast(blended, VipsImage.format(rgb))
    end
  end
end
