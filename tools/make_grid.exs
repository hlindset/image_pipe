# Standalone colour-grid PNG generator (no deps — pure Elixir stdlib).
#
#   elixir tools/make_grid.exs [out.png]
#   GRID=4x4 CELL=100x100 elixir tools/make_grid.exs grid.png
#
# Each cell (col,row) is a flat colour encoding its position:
#   [round(col*255/(cols-1)), round(row*255/(rows-1)), 255]
# so sampling any output pixel decodes back to the source cell. This is the same
# encoding tools/twicpics_focus_probe.exs reads, so the two stay in sync.

defmodule MakeGrid do
  def main(argv) do
    out = List.first(argv) || "grid.png"
    {cols, rows} = pair(System.get_env("GRID", "4x4"))
    {cw, ch} = pair(System.get_env("CELL", "100x100"))
    {w, h} = {cols * cw, rows * ch}

    raw = scanlines(w, h, cw, ch, cols, rows)
    File.write!(out, png(w, h, raw))
    IO.puts("wrote #{out}  (#{w}x#{h}, #{cols}x#{rows} cells of #{cw}x#{ch})")
  end

  # Raw RGB pixel data with a 0 (None) filter byte prefixing each scanline.
  defp scanlines(w, h, cw, ch, cols, rows) do
    for y <- 0..(h - 1), into: <<>> do
      row = for x <- 0..(w - 1), into: <<>>, do: pixel(x, y, cw, ch, cols, rows)
      <<0>> <> row
    end
  end

  defp pixel(x, y, cw, ch, cols, rows) do
    <<channel(div(x, cw), cols), channel(div(y, ch), rows), 255>>
  end

  defp channel(_i, 1), do: 0
  defp channel(i, n), do: round(i * 255 / (n - 1))

  # Minimal PNG: signature + IHDR + IDAT (zlib) + IEND. Colour type 2 = RGB, 8-bit.
  defp png(w, h, raw) do
    sig = <<137, 80, 78, 71, 13, 10, 26, 10>>
    ihdr = <<w::32, h::32, 8, 2, 0, 0, 0>>
    sig <> chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    type = :erlang.iolist_to_binary(type)
    <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
  end

  defp pair(s) do
    [a, b] = String.split(s, "x", parts: 2)
    {String.to_integer(a), String.to_integer(b)}
  end
end

MakeGrid.main(System.argv())
