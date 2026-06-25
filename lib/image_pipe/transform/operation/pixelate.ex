defmodule ImagePipe.Transform.Operation.Pixelate do
  @moduledoc """
  Executable pixelation operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.Geometry
  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @enforce_keys [:size]
  defstruct [:size]

  @type t :: %__MODULE__{size: pos_integer()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :pixelate

  @impl ImagePipe.Transform
  def execute(%__MODULE__{size: size}, %State{} = state) do
    width = image_width(state)
    height = image_height(state)
    size = min(size, max(width, height))

    case pixelate_preserving_dimensions(state.image, width, height, size) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp pixelate_preserving_dimensions(image, width, height, size) do
    target_width = ceil(width / size) * size
    target_height = ceil(height / size) * size

    with {:ok, image} <- mirror_embed(image, width, height, target_width, target_height),
         {:ok, image} <- box_pixelate(image, size) do
      crop_to_original_dimensions(image, width, height, target_width, target_height)
    end
  end

  # imgproxy pixelates with vips_shrink (a pure box mean) then vips_zoom (nearest
  # enlarge) — `vips.c` `apply_filters`. The mirror-embed preamble already padded
  # to an exact integer multiple of `size`, which is vips_shrink's domain, so the
  # shrink is an exact integer factor. A box mean is bounded by [min_in, max_in]
  # per band, so it cannot overshoot the way libvips' default Lanczos resize kernel
  # rings at sharp edges (the #238 halo).
  defp box_pixelate(image, size) do
    with {:ok, shrunk} <- Operation.shrink(image, size * 1.0, size * 1.0) do
      Operation.zoom(shrunk, size, size)
    end
  end

  # Dialyzer can't see through Vix's generated Operation typings (embed).
  @dialyzer {:no_fail_call, mirror_embed: 5}
  defp mirror_embed(image, width, height, width, height), do: {:ok, image}

  defp mirror_embed(image, _width, _height, target_width, target_height) do
    Image.embed(image, target_width, target_height, %{
      x: 0,
      y: 0,
      background_color: [0, 0, 0],
      extend_mode: :VIPS_EXTEND_MIRROR
    })
  end

  defp crop_to_original_dimensions(image, width, height, width, height), do: {:ok, image}

  defp crop_to_original_dimensions(image, width, height, _target_width, _target_height) do
    Image.crop(image, 0, 0, width, height)
  end
end
