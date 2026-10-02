defmodule ImagePipe.Transform.Operation.Background do
  # Executable background composition operation.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @gray [:VIPS_INTERPRETATION_B_W, :VIPS_INTERPRETATION_GREY16]

  @enforce_keys [:color]
  defstruct @enforce_keys

  @type rgba :: [0..255]
  @type t :: %__MODULE__{color: rgba()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :background

  @impl ImagePipe.Transform
  def execute(%__MODULE__{color: [red, green, blue, 255]}, %State{} = state) do
    case flatten(state.image, [red, green, blue]) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  def execute(%__MODULE__{color: color}, %State{} = state) do
    with {:ok, image} <- Alpha.ensure(state.image),
         {:ok, background} <- background_image(image, color),
         {:ok, composited} <- Image.compose(background, image) do
      {:ok, set_image(state, composited)}
    else
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  # Workaround for `image` (0.72, unchanged on main as of 2026-10): on a 1-band
  # gray image, `Image.flatten/2` resolves the background through
  # `Image.Pixel.to_pixel/3`, which maps an sRGB color to gray as Lab L*/100
  # scaled to the band range. libvips stores gray as relative luminance with
  # the sRGB transfer curve, so its own sRGB→B_W conversion turns #808080 into
  # 128 where `Image.Pixel` gives 137. Resolve the gray value with libvips and
  # flatten directly; other interpretations keep `Image.flatten/2`.
  defp flatten(image, rgb) do
    gray? = VipsImage.interpretation(image) in @gray

    if gray? and Image.has_alpha?(image) do
      with {:ok, background} <- gray_value(rgb, VipsImage.interpretation(image)) do
        Operation.flatten(image, background: background)
      end
    else
      Image.flatten(image, background: rgb)
    end
  end

  defp gray_value(rgb, interpretation) do
    with {:ok, pixel} <- Image.new(1, 1, color: rgb),
         {:ok, gray} <- Operation.colourspace(pixel, interpretation) do
      Operation.getpoint(gray, 0, 0)
    end
  end

  defp background_image(image, color) do
    Image.new(Image.width(image), Image.height(image), color: color, bands: 4)
  end
end
