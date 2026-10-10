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

  defp draw(canvas, {:rect, x, y, width, height, color}) do
    {:ok, canvas} = Operation.insert(canvas, fill(width, height, color), x, y)
    canvas
  end

  defp draw(canvas, {:circle, x, y, radius, color}),
    do: Image.Draw.circle!(canvas, x, y, radius, color: color, fill: true)

  # A stroke `thickness` pixels wide, drawn as adjacent one-pixel lines.
  defp draw(canvas, {:line, x1, y1, x2, y2, thickness, color}) do
    Enum.reduce(0..(thickness - 1), canvas, fn offset, canvas ->
      Image.Draw.line!(canvas, x1 + offset, y1, x2 + offset, y2, color: color)
    end)
  end

  # Content inside the margins, as a block, a circle, or a diagonal band.
  defp content(width, height, {left, top, right, bottom}, color) do
    inner_width = width - left - right
    inner_height = height - top - bottom

    member_of([
      {:rect, left, top, inner_width, inner_height, color},
      {:circle, left + div(inner_width, 2), top + div(inner_height, 2),
       max(1, div(min(inner_width, inner_height), 2) - 1), color},
      {:line, left, top, left + inner_width - 30, top + inner_height - 1, 30, color}
    ])
  end

  # A border color, content, and marks: rectangles, dots, and diagonal strokes,
  # many thinner than the 8x preview, whose median filter erases them.
  defp bordered_image do
    gen all width <- integer(260..1500),
            height <- integer(260..1500),
            background <- list_of(integer(0..255), length: 3),
            content <- list_of(integer(0..255), length: 3),
            left <- integer(1..div(width, 3)),
            top <- integer(1..div(height, 3)),
            right <- integer(1..div(width, 3)),
            bottom <- integer(1..div(height, 3)),
            shape <- content(width, height, {left, top, right, bottom}, content),
            mark_count <- integer(0..4),
            marks <- list_of(mark(width, height), length: mark_count),
            noise <- member_of([0.0, 3.0, 12.0]) do
      canvas = width |> fill(height, background) |> draw(shape)
      canvas = Enum.reduce(marks, canvas, &draw(&2, &1))
      add_noise(canvas, noise)
    end
  end

  defp mark(width, height) do
    gen all kind <- member_of([:rect, :circle, :line]),
            thickness <- integer(1..20),
            vertical? <- boolean(),
            x <- integer(25..(width - 25)),
            y <- integer(25..(height - 25)),
            length <- integer(1..200),
            dx <- integer(-200..200),
            color <- list_of(integer(0..255), length: 3) do
      case kind do
        :rect when vertical? -> {:rect, x, y, thickness, min(length, height - y), color}
        :rect -> {:rect, x, y, min(length, width - x), thickness, color}
        :circle -> {:circle, x, y, div(thickness, 2) + 1, color}
        :line -> diagonal(x, y, dx, length, thickness, width, height, color)
      end
    end
  end

  # A stroke from (x, y) towards (x + dx, y + length), kept inside the image
  # and clear of the top-left pixel, which is the background sample.
  defp diagonal(x, y, dx, length, thickness, width, height, color) do
    x2 = min(max(x + dx, 1), width - thickness - 1)
    y2 = min(y + length, height - 1)
    {:line, min(x, width - thickness - 1), y, x2, y2, thickness, color}
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
