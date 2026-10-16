defmodule ImagePipe.Transform.WorkLimits do
  @moduledoc false

  alias ImagePipe.Transform.State

  @max_axis 2_147_483_647
  @max_embed_axis 1_000_000_000
  @max_resize_scale 10_000_000

  def check(%State{image: image, max_intermediate_pixels: limit}), do: pixels(image, limit)

  def pixels(image, limit), do: dimensions({Image.width(image), Image.height(image)}, limit)

  def dimensions({width, height}, limit) do
    pixels = width * height

    case pixels <= limit do
      true -> :ok
      false -> {:error, {:intermediate_pixel_limit, pixels, limit}}
    end
  end

  # A Gaussian blur's cost grows with the pixels and, measured, with about the
  # 1.7th power of the sigma. The square bounds it from above.
  def blur(%State{image: image, max_blur_work: limit}, sigma) do
    work = Image.width(image) * Image.height(image) * sigma * sigma

    case work <= limit do
      true -> :ok
      false -> {:error, {:blur_work_limit, work, limit}}
    end
  end

  def resize(%State{image: image} = state, width, height) do
    with :ok <- resize_axes(image, width, height) do
      case width < Image.width(image) or height < Image.height(image) do
        true -> check(state)
        false -> :ok
      end
    end
  end

  def resize_axes(image, width, height) do
    case width <= @max_axis and height <= @max_axis and
           width / Image.width(image) <= @max_resize_scale and
           height / Image.height(image) <= @max_resize_scale do
      true -> :ok
      false -> {:error, {:native_geometry_limit, {width, height}}}
    end
  end

  def embed(width, height), do: axes(width, height, @max_embed_axis)
  def axes(width, height), do: axes(width, height, @max_axis)

  defp axes(width, height, maximum) do
    case width <= maximum and height <= maximum do
      true -> :ok
      false -> {:error, {:native_geometry_limit, {width, height}}}
    end
  end
end
