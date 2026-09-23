defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Clockwise arbitrary-angle rotation with transparent corners.

  Uses affine `vips_rotate`. Non-alpha output formats flatten the corners onto
  `Output.Policy.flatten_background` at encoding.

  Rotation reads pixels out of row order, so `requires_materialization?: true`
  makes `ImagePipe.Transform.run/3` copy the input to RAM first. The executor
  flushes pending orientation before this operation so it sees display-frame pixels.
  The result stays lazy until a downstream resize buffers it, avoiding repeated
  affine evaluation while allowing crop-only requests to evaluate a small region.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @enforce_keys [:angle]
  defstruct [:angle]

  @type t :: %__MODULE__{angle: number()}

  # Float RGBA: vips_rotate's `background` is an array of doubles; a 4-element
  # value fills the exposed corners fully transparent on an alpha image.
  @transparent [0.0, 0.0, 0.0, 0.0]

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

  # Dialyzer can't see through Vix's generated Operation typings (rotate).
  @dialyzer {:no_fail_call, rotate: 2}

  # Add alpha for transparent corners. vips_rotate handles premultiplication;
  # doing it here too would distort semi-transparent colors. Call Vix directly
  # because Image.rotate/3 rejects a four-component RGBA background.
  defp rotate(image, angle) do
    with {:ok, rgba} <- ensure_alpha(image) do
      Operation.rotate(rgba, angle * 1.0, background: @transparent)
    end
  end

  defp ensure_alpha(image) do
    if Image.has_alpha?(image), do: {:ok, image}, else: Image.add_alpha(image, :opaque)
  end
end
