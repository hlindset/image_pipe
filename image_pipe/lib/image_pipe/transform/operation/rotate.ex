defmodule ImagePipe.Transform.Operation.Rotate do
  # Clockwise arbitrary-angle rotation with transparent corners.
  #
  # Non-alpha output formats flatten the corners onto
  # `Output.Policy.flatten_background` at encoding.
  #
  # Rotation reads pixels out of row order, so `requires_materialization?: true`
  # makes `ImagePipe.Transform.run/3` copy the input to RAM first. The executor
  # flushes pending orientation before this operation so it sees display-frame pixels.
  # The result stays lazy until a downstream resize buffers it, avoiding repeated
  # affine evaluation while allowing crop-only requests to evaluate a small region.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.State

  @enforce_keys [:angle]
  defstruct [:angle]

  @type t :: %__MODULE__{angle: number()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case rotate(state.image, angle) do
      {:ok, image} ->
        {:ok, %{set_image(state, image) | buffer_before_resize?: true}}

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  # Add alpha for transparent corners: without a background, `Image.rotate/3`
  # fills with zeros, which is transparent once the image has alpha. Bicubic
  # keeps edges slightly crisper than libvips' default bilinear.
  defp rotate(image, angle) do
    with {:ok, with_alpha} <- Alpha.ensure(image) do
      Image.rotate(with_alpha, angle, interpolate: :bicubic)
    end
  end
end
