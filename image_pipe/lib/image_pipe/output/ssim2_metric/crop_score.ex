defmodule ImagePipe.Output.Ssim2Metric.CropScore do
  # Crop-based (tiled) SSIMULACRA2 scoring for the autoquality search on large
  # outputs. Above an internal ~6 MP crossover the search scores `@subsample_k`
  # native-resolution 512px tiles of the full-res encode and takes their p10,
  # instead of scoring the whole frame — a flat ~4.2 MP metric sample regardless of
  # source size (issue #354, benchmark Part E).
  #
  # This module does tiling + `extract_area` only; **all** SSIMULACRA2 access is
  # delegated to `ImagePipe.Output.Metric.Ssimulacra2`, which stays the only
  # module touching the SSIMULACRA2 NIF.
  @moduledoc false

  alias ImagePipe.Output.Metric.Ssimulacra2, as: Ssim2Metric

  # Part E operating point. Internal constants, not host config (issue #354
  # forbids a second user-facing knob; dynamic-K selection is future work).
  @tile 512
  @subsample_k 16
  @crossover_megapixels 6

  @typedoc "A tile window paired with the SSIMULACRA2 reference of the base tile."
  @type tile_reference ::
          {{non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
           Ssim2Metric.ref()}

  @doc "Megapixel crossover above which the search uses crop scoring."
  @spec crossover_megapixels() :: pos_integer()
  def crossover_megapixels, do: @crossover_megapixels

  @doc """
  Tile windows covering a `w`×`h` frame with full-size `t`×`t` windows. The last
  row/col is clamped to the edge (slight overlap, never a gap) so every tile is
  full size and safe for SSIMULACRA2's multiscale downsamples. An axis `<= t`
  yields a single clamped tile on that axis.
  """
  @spec tile_coords(pos_integer(), pos_integer(), pos_integer()) ::
          [{non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}]
  def tile_coords(w, h, t \\ @tile) do
    tw = min(t, w)
    th = min(t, h)
    for y <- axis_positions(h, th), x <- axis_positions(w, tw), do: {x, y, tw, th}
  end

  defp axis_positions(size, t) when size <= t, do: [0]

  defp axis_positions(size, t) do
    (Enum.take_while(Stream.iterate(0, &(&1 + t)), &(&1 + t <= size)) ++ [size - t])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Up to `k` distinct windows from `tile_coords/3`, spread over both axes of the
  tile grid; every window when the grid has `k` or fewer. A Fibonacci lattice
  picks them: `k` even bands along the grid's longer axis, golden-ratio steps
  along the shorter one. Stepping through the row-major list instead aliases onto
  one column when the step is close to the row width.
  """
  @spec sample_tiles(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          [{non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}]
  def sample_tiles(w, h, t \\ @tile, k \\ @subsample_k) do
    tw = min(t, w)
    th = min(t, h)
    xs = List.to_tuple(axis_positions(w, tw))
    ys = List.to_tuple(axis_positions(h, th))

    if tuple_size(xs) * tuple_size(ys) <= k do
      tile_coords(w, h, t)
    else
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&lattice_cell(&1, tuple_size(xs), tuple_size(ys), k))
      |> Stream.uniq()
      |> Enum.take(k)
      |> Enum.sort_by(fn {col, row} -> {row, col} end)
      |> Enum.map(fn {col, row} -> {elem(xs, col), elem(ys, row), tw, th} end)
    end
  end

  @golden 0.6180339887498949

  # Point `i` of the lattice as a {column, row} cell. Points past `k` reuse the
  # bands with new golden-ratio offsets, so the sample still fills when two
  # points land on the same cell.
  defp lattice_cell(i, cols, rows, k) do
    band = (rem(i, k) + 0.5) / k
    step = frac(0.5 + i * @golden)

    if rows >= cols,
      do: {cell(step, cols), cell(band, rows)},
      else: {cell(band, cols), cell(step, rows)}
  end

  defp cell(fraction, count), do: min(count - 1, trunc(fraction * count))

  defp frac(x), do: x - Float.floor(x)

  @doc "Percentile `p` (0.0–1.0) of an already-sorted list, floor-indexed (nearest-rank-low)."
  @spec percentile([number()], float()) :: number()
  def percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(0, trunc(p * (n - 1)))))
  end

  @doc """
  Per-tile SSIMULACRA2 references for a finalized `base` image, one per
  sub-sampled tile (`<= @subsample_k`). The base and its tiles are fixed for the
  whole quality search, so the search builds these once and every probe reuses
  them through `p10/2`. Returns `{:error, reason}` on any `extract_area` or
  reference failure.
  """
  @spec references(Vix.Vips.Image.t()) :: {:ok, [tile_reference()]} | {:error, term()}
  def references(%Vix.Vips.Image{} = base) do
    base
    |> then(&sample_tiles(Image.width(&1), Image.height(&1)))
    |> each_tile(fn {x, y, w, h} = coord ->
      with {:ok, tile} <- Image.crop(base, x, y, w, h),
           {:ok, ref} <- Ssim2Metric.reference(tile),
           do: {:ok, {coord, ref}}
    end)
  end

  @doc """
  p10 of the per-tile SSIMULACRA2 scores between the tile `references/1` built
  from a finalized base image and a decoded `candidate` image. Returns
  `{:ok, score}` or `{:error, reason}` (any `extract_area`/score failure).
  """
  @spec p10([tile_reference()], Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def p10(references, %Vix.Vips.Image{} = candidate) do
    with {:ok, scores} <- tile_scores(references, candidate) do
      {:ok, percentile(Enum.sort(scores), 0.10)}
    end
  end

  defp tile_scores(references, candidate) do
    each_tile(references, fn {{x, y, w, h}, ref} ->
      with {:ok, tile} <- Image.crop(candidate, x, y, w, h),
           do: Ssim2Metric.score(ref, tile)
    end)
  end

  # Each tile is an independent single-threaded NIF call on a dirty CPU
  # scheduler, so the tiles run concurrently, capped at the dirty CPU scheduler
  # count. Results come back in completion order; callers don't depend on it.
  # The first error halts the stream, which shuts down the remaining tasks.
  # A crashed tile exits with its own reason, also when the caller traps exits.
  defp each_tile(items, fun) do
    items
    |> Task.async_stream(fun,
      max_concurrency: :erlang.system_info(:dirty_cpu_schedulers),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, value}}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:ok, {:error, _} = err}, _acc -> {:halt, err}
      {:exit, reason}, _acc -> exit(reason)
    end)
  end
end
