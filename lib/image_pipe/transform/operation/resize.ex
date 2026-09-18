defmodule ImagePipe.Transform.Operation.Resize do
  @moduledoc """
  Resizes the current image to concrete pixel dimensions resolved by the native
  executor. Cover requests use a separate crop after this operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.Geometry, only: [image_height: 1, image_width: 1]
  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State

  @enforce_keys [:width, :height]
  defstruct [:width, :height]

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :resize

  @impl ImagePipe.Transform
  def execute(%__MODULE__{width: width, height: height}, %State{} = state) do
    case resize_image(state, width, height) do
      {:ok, image} ->
        # The residual resize completes the downscale. Later groups use this
        # image's dimensions without the initial decode's preshrink factor.
        state = set_image(state, image)
        {:ok, %State{state | source_dimensions: nil, decode_shrink: nil}}

      {:error, reason} ->
        {:error, {__MODULE__, reason}}
    end
  end

  defp resize_image(%State{} = state, width, height) do
    source_width = image_width(state)
    source_height = image_height(state)

    case width == source_width and height == source_height do
      true ->
        {:ok, state.image}

      false ->
        Image.resize(state.image, width / source_width, vertical_scale: height / source_height)
    end
  end
end
