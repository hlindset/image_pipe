defmodule ImagePipe.Transform.Operation.Background do
  # Executable background composition operation.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.GrayFrame
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

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

  def execute(%__MODULE__{color: [red, green, blue, alpha]}, %State{} = state) do
    case compose(state.image, [red, green, blue], alpha) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  # The color is sRGB: `WorkingColor` maps it into the image's values (its
  # profile, gray, 16-bit), and a non-neutral color promotes a gray image.
  defp flatten(image, rgb) do
    if Image.has_alpha?(image) do
      with {:ok, image} <- GrayFrame.for_color(image, rgb),
           {:ok, values} <- WorkingColor.values(image, rgb) do
        Operation.flatten(image, background: values)
      end
    else
      {:ok, image}
    end
  end

  # A translucent color goes on a canvas of the image's own space and format,
  # under the image.
  defp compose(image, rgb, alpha) do
    with {:ok, image} <- Alpha.ensure(image),
         {:ok, image} <- GrayFrame.for_color(image, rgb),
         {:ok, values} <- WorkingColor.values(image, rgb),
         opacity = alpha / 255 * Alpha.opaque(VipsImage.format(image)),
         {:ok, canvas} <- canvas(image, values ++ [opacity]),
         {:ok, composited} <-
           Operation.composite2(canvas, image, :VIPS_BLEND_MODE_OVER,
             "compositing-space": VipsImage.interpretation(image)
           ),
         {:ok, composited} <- Operation.cast(composited, VipsImage.format(image)) do
      keep_profile(composited, image)
    end
  end

  defp canvas(image, values) do
    with {:ok, black} <-
           Operation.black(Image.width(image), Image.height(image), bands: length(values)),
         {:ok, filled} <- Operation.linear(black, List.duplicate(1.0, length(values)), values),
         {:ok, cast} <- Operation.cast(filled, VipsImage.format(image)) do
      Operation.copy(cast, interpretation: VipsImage.interpretation(image))
    end
  end

  # The composite takes the canvas's metadata; carry over the image's profile.
  defp keep_profile(composited, image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) ->
        VipsImage.mutate(composited, fn mutable ->
          MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
        end)

      _untagged ->
        {:ok, composited}
    end
  end
end
