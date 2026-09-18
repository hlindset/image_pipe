defmodule ImagePipe.Transform.Operation.Background do
  @moduledoc """
  Executable background composition operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @enforce_keys [:color]
  defstruct @enforce_keys

  @type rgba :: [0..255]
  @type t :: %__MODULE__{color: rgba()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :background

  @impl ImagePipe.Transform
  def execute(%__MODULE__{color: [red, green, blue, 255]}, %State{} = state) do
    case Image.flatten(state.image, background: [red, green, blue]) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  def execute(%__MODULE__{color: color}, %State{} = state) do
    with {:ok, image} <- alpha_ready_image(state.image),
         {:ok, background} <- background_image(image, color),
         {:ok, composited} <- Image.compose(background, image) do
      {:ok, set_image(state, composited)}
    else
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  defp alpha_ready_image(image) do
    case Image.has_alpha?(image) do
      true -> {:ok, image}
      false -> Image.add_alpha(image, :opaque)
    end
  end

  defp background_image(image, color) do
    Image.new(Image.width(image), Image.height(image), color: color, bands: 4)
  end
end
