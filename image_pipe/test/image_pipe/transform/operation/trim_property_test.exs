defmodule ImagePipe.Transform.Operation.TrimPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  defp fill(width, height, color) do
    {:ok, block} = Operation.black(width, height, bands: 3)
    {:ok, block} = Operation.linear(block, [1.0, 1.0, 1.0], color)
    {:ok, block} = Operation.cast(block, :VIPS_FORMAT_UCHAR)
    block
  end

  defp insert(canvas, {x, y, width, height, color}) do
    {:ok, canvas} = Operation.insert(canvas, fill(width, height, color), x, y)
    canvas
  end

  # A border color, a content block, and marks in the border: lines and dots
  # thinner than the 8x preview, which its median filter erases.
  defp bordered_image do
    gen all width <- integer(260..900),
            height <- integer(260..900),
            background <- list_of(integer(0..255), length: 3),
            content <- list_of(integer(0..255), length: 3),
            left <- integer(1..div(width, 3)),
            top <- integer(1..div(height, 3)),
            right <- integer(1..div(width, 3)),
            bottom <- integer(1..div(height, 3)),
            mark_count <- integer(0..3),
            marks <- list_of(mark(width, height), length: mark_count),
            noise <- member_of([0.0, 3.0, 12.0]) do
      canvas =
        width
        |> fill(height, background)
        |> insert({left, top, width - left - right, height - top - bottom, content})

      canvas = Enum.reduce(marks, canvas, &insert(&2, &1))
      add_noise(canvas, noise)
    end
  end

  defp mark(width, height) do
    gen all thickness <- integer(1..20),
            vertical? <- boolean(),
            x <- integer(1..(width - 21)),
            y <- integer(1..(height - 21)),
            length <- integer(1..200),
            color <- list_of(integer(0..255), length: 3) do
      if vertical?,
        do: {x, y, thickness, min(length, height - y), color},
        else: {x, y, min(length, width - x), thickness, color}
    end
  end

  defp add_noise(image, 0.0), do: image

  defp add_noise(image, sigma) do
    {:ok, noise} = Operation.gaussnoise(Image.width(image), Image.height(image), sigma: sigma)
    {:ok, noisy} = Operation.add(image, noise)
    {:ok, noisy} = Operation.cast(noisy, :VIPS_FORMAT_UCHAR)
    {:ok, noisy} = VixImage.copy_memory(noisy)
    noisy
  end

  # Plain full-resolution find_trim, as Trim ran it before the preview pass.
  defp full_resolution_trim(image, threshold) do
    {:ok, background} = Image.get_pixel(image, 0, 0)

    case Operation.find_trim(image, background: background, threshold: threshold) do
      {:ok, {_left, _top, 0, _height}} -> image
      {:ok, {_left, _top, _width, 0}} -> image
      {:ok, {left, top, width, height}} -> Image.crop!(image, left, top, width, height)
    end
  end

  defp pixels(image) do
    {:ok, binary} = VixImage.write_to_binary(image)
    {Image.width(image), Image.height(image), :crypto.hash(:sha256, binary)}
  end

  property "finds the same box as a full-resolution search" do
    check all image <- bordered_image(),
              threshold <- member_of([10.0, 30.0]),
              max_runs: 150 do
      op = %Trim{threshold: threshold, background: :auto, equal_hor: false, equal_ver: false}
      assert {:ok, %State{image: trimmed}} = Trim.execute(op, %State{image: image})
      assert pixels(trimmed) == pixels(full_resolution_trim(image, threshold))
    end
  end
end
