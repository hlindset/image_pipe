defmodule ImagePipe.Test.TwicpicsDifferential.StructureCompareTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.StructureCompare, as: SC

  # cell (col,row) colour for a cols×rows grid: [chan(col,cols), chan(row,rows), 255]
  defp chan(_i, 1), do: 0
  defp chan(i, n), do: round(i * 255 / (n - 1))

  defp grid_image(cols, rows, cell) do
    base = Image.new!(cols * cell, rows * cell, color: [0, 0, 0])

    composed =
      for col <- 0..(cols - 1), row <- 0..(rows - 1), reduce: base do
        acc ->
          c = Image.new!(cell, cell, color: [chan(col, cols), chan(row, rows), 255])
          Image.compose!(acc, c, x: col * cell, y: row * cell)
      end

    # Image.compose! promotes to RGBA; flatten back to a genuine 3-band RGB grid.
    Image.flatten!(composed)
  end

  @spec_4x4 %{cols: 4, rows: 4}

  test "identity grid decodes to the full cell-map at cell-centre lattice" do
    img = grid_image(4, 4, 40)
    rec = SC.extract(img, @spec_4x4)
    assert rec.dims == {160, 160}
    assert rec.bands == 3
    assert rec.cols == 4
    # cell-centre lattice (4×4) over an identity grid → each sample its own cell
    assert SC.cell_at(rec, 0, 0) == {:cell, {0, 0}}
    assert SC.cell_at(rec, 3, 3) == {:cell, {3, 3}}
    assert SC.cell_at(rec, 2, 1) == {:cell, {2, 1}}
  end

  test "uniform single-cell image: every sample is that cell" do
    img = Image.new!(50, 50, color: [170, 85, 255])  # col 2, row 1 of a 4×4
    rec = SC.extract(img, @spec_4x4)
    assert Enum.all?(rec.cells, &(&1 == {:cell, {2, 1}}))
  end

  test "transparent pixels decode as :padding" do
    img = Image.new!(40, 40, color: [0, 0, 0, 0], bands: 4)
    rec = SC.extract(img, @spec_4x4)
    assert Enum.all?(rec.cells, &(&1 == :padding))
    assert rec.bands == 4
  end

  test "compare/2 returns :match for equal records, structural diff otherwise" do
    a = %{dims: {10, 10}, bands: 3, cells: [{:cell, {0, 0}}, {:cell, {1, 1}}]}
    assert SC.compare(a, a) == :match
    b = %{a | cells: [{:cell, {0, 0}}, {:cell, {2, 2}}]}
    assert {:mismatch, diff} = SC.compare(a, b)
    assert diff.cells == [{1, {:cell, {1, 1}}, {:cell, {2, 2}}}]
  end

  test "low_confidence_samples flags none for a clean grid" do
    img = grid_image(4, 4, 40)
    assert SC.low_confidence_samples(img, @spec_4x4) == []
  end
end
