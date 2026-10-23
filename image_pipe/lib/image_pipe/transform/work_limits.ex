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
  # 1.7th power of the sigma. The square bounds it from above for large sigmas.
  # The constant term is the cost per pixel of a small blur, measured as about
  # a blur of sigma 80, and of a sharpen, about sigma 115, rounded to one
  # figure for both. The work of every blur and sharpen in the request counts
  # against one limit, so repeating them in more groups doesn't multiply it.
  @convolution_base 10_000

  # A progressive blur blends each pixel's two nearest of eight blur levels,
  # the larger up to the full sigma. Measured, it costs at most about twice a
  # blur of its sigma, plus a fixed cost per pixel of about five small blurs.
  @progressive_scale 2
  @progressive_base 50_000

  def convolution(state, sigma), do: charge(state, sigma * sigma + @convolution_base)

  def progressive_blur(state, sigma),
    do: charge(state, @progressive_scale * sigma * sigma + @progressive_base)

  defp charge(%State{image: image, max_blur_work: limit, blur_work: spent} = state, per_pixel) do
    work = spent + round(Image.width(image) * Image.height(image) * per_pixel)

    case within?(work, limit) do
      true -> {:ok, %State{state | blur_work: work}}
      false -> {:error, {:blur_work_limit, work, limit}}
    end
  end

  defp within?(_work, :infinity), do: true
  defp within?(work, limit), do: work <= limit

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
