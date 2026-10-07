defmodule AutoqualityFeatures do
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  # Native-resolution patches preserve edges that a thumbnail could erase.
  # This is a small inspired feature set, not a reproduction of the paper's ten.
  def extract(image) do
    w = Image.width(image)
    h = Image.height(image)
    coords = CropScore.sample_tiles(w, h, 128, 8)
    {:ok, matrix} = VipsImage.new_from_list([[0.299, 0.587, 0.114]])

    {:ok, chroma_matrix} =
      VipsImage.new_from_list([[-0.168736, -0.331264, 0.5], [0.5, -0.418688, -0.081312]])

    {:ok, checker} = VipsImage.new_from_list([[1.0, -1.0], [-1.0, 1.0]])

    samples =
      Enum.map(coords, fn {x, y, tw, th} ->
        {:ok, tile} = Image.crop(image, x, y, tw, th)
        {:ok, luma} = Operation.recomb(tile, matrix)
        {:ok, memory} = VipsImage.copy_memory(luma)
        {adjacent, squared} = gradient(memory)
        {:ok, coarse} = Operation.shrink(memory, 2.0, 2.0)
        {coarse_adjacent, _} = gradient(coarse)
        {:ok, response} = Operation.conv(memory, checker)
        {:ok, absolute} = Operation.abs(response)
        {:ok, high_frequency} = Operation.avg(absolute)
        {:ok, chroma} = Operation.recomb(tile, chroma_matrix)
        {:ok, chroma_coarse} = Operation.shrink(chroma, 2.0, 2.0)
        {chroma_activity, _} = gradient(chroma_coarse)
        [adjacent, squared, coarse_adjacent, high_frequency, chroma_activity]
      end)

    means = Enum.zip_with(samples, &(Enum.sum(&1) / length(&1)))
    spread = samples |> Enum.map(&hd/1) |> then(&(Enum.max(&1) - Enum.min(&1)))
    mp = w * h / 1_000_000

    crop =
      case mp > CropScore.crossover_megapixels() do
        true -> 1.0
        false -> 0.0
      end

    [:math.log(1 + mp), :math.log(w / h), crop | Enum.map(means ++ [spread], &:math.log(1 + &1))]
  end

  defp gradient(image) do
    w = Image.width(image)
    h = Image.height(image)
    {:ok, left} = Image.crop(image, 0, 0, w - 1, h - 1)
    {:ok, right} = Image.crop(image, 1, 0, w - 1, h - 1)
    {:ok, down} = Image.crop(image, 0, 1, w - 1, h - 1)
    {:ok, dx} = Operation.subtract(right, left)
    {:ok, dy} = Operation.subtract(down, left)
    {ax, sx} = moments(dx)
    {ay, sy} = moments(dy)
    {(ax + ay) / 2, (sx + sy) / 2}
  end

  defp moments(image) do
    {:ok, absolute} = Operation.abs(image)
    {:ok, squared} = Operation.multiply(image, image)
    {:ok, average} = Operation.avg(absolute)
    {:ok, mean_squared} = Operation.avg(squared)
    {average, mean_squared}
  end
end
