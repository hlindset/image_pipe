defmodule ImagePipe.Test.TwicpicsDifferential.StructureCompare do
  @moduledoc """
  The TwicPics structural comparator. Decodes a rendered colour-grid image to a
  structural record `%{dims, bands, cells}` and compares two records.

  The colour grid encodes content identity: cell (col,row) is
  `[chan(col,cols), chan(row,rows), 255]` with `chan(i,n) = round(i*255/(n-1))`.
  Sampling a fixed cell-centre lattice over the output and decoding each point to
  the nearest cell (or `:padding`/`:ambiguous`) yields a placement fingerprint
  that survives the foreign engine's resampling — so the gate is geometry, not
  pixels. Colour/alpha tolerance lives only here, inside the per-sample decode.
  """
  use Boundary, top_level?: true, deps: []

  @type cell :: {:cell, {non_neg_integer(), non_neg_integer()}} | :padding | :ambiguous
  @type t :: %{
          dims: {pos_integer(), pos_integer()},
          bands: pos_integer(),
          cols: pos_integer(),
          cells: [cell()]
        }

  # Default decode tolerances. `color_dist` is the max squared RGB distance (sum of
  # per-channel squared diffs, 0..3*255²) for a confident nearest-cell match; beyond
  # it a sample is :ambiguous. `alpha` is the max alpha (0..255) counted as padding.
  @default_tol %{color_dist: 1600, alpha: 16}
  def default_tol, do: @default_tol

  @doc """
  Extract the structural record from `image` for grid `spec` (%{cols, rows}). The
  record carries `cols` so `cell_at/3` can index the lattice for any grid shape.
  `compare/2` reads only dims/bands/cells, so the manifest stores those (not cols).
  """
  @spec extract(Vix.Vips.Image.t(), map(), map()) :: t()
  def extract(image, spec, tol \\ @default_tol) do
    w = Image.width(image)
    h = Image.height(image)
    bands = Image.bands(image)

    cells =
      Enum.map(lattice(spec), fn {fx, fy} ->
        {value, _dist} = decode(image, w, h, fx, fy, spec, tol)
        value
      end)

    %{dims: {w, h}, bands: bands, cols: spec.cols, cells: cells}
  end

  @doc """
  Lattice indices (0-based) of samples whose nearest-cell distance is past the
  half-way mark to the `:ambiguous` threshold — the low-confidence-margin guard. A
  clean grid returns `[]`; any flagged index is the bake's signal to consider
  pinning `truecolor` or nudging the lattice (it is a diagnostic, never a gate).
  """
  @spec low_confidence_samples(Vix.Vips.Image.t(), map(), map()) :: [non_neg_integer()]
  def low_confidence_samples(image, spec, tol \\ @default_tol) do
    w = Image.width(image)
    h = Image.height(image)

    spec
    |> lattice()
    |> Enum.map(fn {fx, fy} -> decode(image, w, h, fx, fy, spec, tol) end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{value, dist}, i} ->
      if match?({:cell, _}, value) and dist > div(tol.color_dist, 2), do: [i], else: []
    end)
  end

  @doc "Lattice index `(li, lj)` → decoded cell of `record` (row-major cols×rows)."
  @spec cell_at(t(), non_neg_integer(), non_neg_integer()) :: cell()
  def cell_at(%{cells: cells, cols: cols}, li, lj), do: Enum.at(cells, lj * cols + li)

  @doc """
  Compare two records. `:match` when dims, bands, and every cell agree; otherwise
  `{:mismatch, %{dims, bands, cells}}` where `cells` lists `{index, expected, got}`.
  """
  @spec compare(t(), t()) :: :match | {:mismatch, map()}
  def compare(expected, got) do
    cell_diffs =
      [expected.cells, got.cells]
      |> Enum.zip_reduce([], fn [e, g], acc -> [{e, g} | acc] end)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{e, g}, i} -> if e == g, do: [], else: [{i, e, g}] end)

    diff =
      %{}
      |> put_if(:dims, expected.dims != got.dims, {expected.dims, got.dims})
      |> put_if(:bands, expected.bands != got.bands, {expected.bands, got.bands})
      |> put_if(
        :cell_count,
        length(expected.cells) != length(got.cells),
        {length(expected.cells), length(got.cells)}
      )
      |> put_if(:cells, cell_diffs != [], cell_diffs)

    if diff == %{}, do: :match, else: {:mismatch, diff}
  end

  # cell-centre lattice derived from the grid: fractions (i+0.5)/n. Stored row-major
  # (rows outer, cols inner) so cell_at/3 indexing matches.
  defp lattice(%{cols: cols, rows: rows}) do
    fx = for i <- 0..(cols - 1), do: (i + 0.5) / cols
    fy = for j <- 0..(rows - 1), do: (j + 0.5) / rows
    for vy <- fy, vx <- fx, do: {vx, vy}
  end

  # Returns `{value, nearest_dist}` so the caller can both record the decoded value
  # and report decode confidence. Only `{:cell, _}` distances are meaningful;
  # `:padding`'s `0` and `:ambiguous`'s distance are not consumed as confidence
  # (only `low_confidence_samples/3` reads `{:cell, _}` distances).
  defp decode(image, w, h, fx, fy, spec, tol) do
    x = min(round(fx * w), w - 1)
    y = min(round(fy * h), h - 1)
    px = Image.get_pixel!(image, x, y) |> Enum.map(&round/1)

    if length(px) == 4 and List.last(px) <= tol.alpha do
      {:padding, 0}
    else
      nearest(Enum.take(px, 3), spec, tol)
    end
  end

  defp nearest([r, g, b], %{cols: cols, rows: rows}, tol) do
    {best, dist} =
      for(col <- 0..(cols - 1), row <- 0..(rows - 1), do: {col, row})
      |> Enum.map(fn {col, row} ->
        {cr, cg, cb} = {chan(col, cols), chan(row, rows), 255}
        {{col, row}, (cr - r) * (cr - r) + (cg - g) * (cg - g) + (cb - b) * (cb - b)}
      end)
      |> Enum.min_by(&elem(&1, 1))

    if dist <= tol.color_dist, do: {{:cell, best}, dist}, else: {:ambiguous, dist}
  end

  defp chan(_i, 1), do: 0
  defp chan(i, n), do: round(i * 255 / (n - 1))

  defp put_if(map, _key, false, _val), do: map
  defp put_if(map, key, true, val), do: Map.put(map, key, val)
end
