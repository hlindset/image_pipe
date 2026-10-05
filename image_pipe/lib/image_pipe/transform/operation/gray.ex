defmodule ImagePipe.Transform.Operation.Gray do
  # Executable true grayscale (desaturation) operation. Converts to the `:bw`
  # colourspace, discarding hue and saturation; alpha is preserved.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gray

  @impl ImagePipe.Transform
  # A tagged image converts through its profile first, since a gray result
  # can't keep an RGB profile.
  def execute(%__MODULE__{}, %State{} = state) do
    with {:ok, state} <- WorkingColor.to_srgb_frame(state),
         {:ok, image} <- to_gray(state.image) do
      {:ok, set_image(state, image)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # 16-bit images stay 16-bit.
  defp to_gray(image) do
    target =
      if VipsImage.format(image) == :VIPS_FORMAT_USHORT,
        do: :VIPS_INTERPRETATION_GREY16,
        else: :VIPS_INTERPRETATION_B_W

    Operation.colourspace(image, target)
  end
end
