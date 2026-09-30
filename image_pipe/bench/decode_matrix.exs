# Decode-mode matrix runner: runs bench/decode_modes.exs across a handpicked corpus, one
# isolated OS process per (file, mode[, access]), and collates the rows into a CSV plus a
# streaming-vs-buffered comparison table.
#
# Why a separate process per case: the per-case benchmark's memory signals (OS peak RSS, and
# libvips tracked high-water) are process-global, monotonic, and non-resettable. The only way
# to get a clean per-file, per-mode peak is to isolate each case in its own process. This
# orchestrator does exactly that, then aggregates the machine-readable rows each run emits
# (via `decode_modes.exs --csv`).
#
# Run with mise so tool versions match:
#   mise exec -- mix run bench/decode_matrix.exs
#
# Positional args (with defaults):
#   <manifest> <access> <width> <iters> <out_csv>
#   manifest : corpus manifest (default: bench/corpus.txt) — one image per line, '#' comments,
#              blank lines skipped, optional per-line "<path> <width>" override.
#   access   : sequential | random | both   (default: sequential)
#   width    : default target width px       (default: 400)
#   iters    : timed iters per case          (default: 5)
#   out_csv  : collated output CSV           (default: bench/results/decode_matrix.csv)
#
# Expect many BEAM boots (files x modes x access) — each case is a fresh `mix run`. Keep iters
# modest. libvips_peak (tracked high-water, the clean libvips working-set peak) and rss_peak
# (whole-process) are both reliable; libvips_peak needs a Vix that fixed the high-water NIF
# (older Vix reports ~0).

defmodule DecodeMatrix do
  @modes ~w(streaming buffered)
  @per_case "bench/decode_modes.exs"
  @columns ~w(file fmt megapixels mode access width iters median_ms min_ms max_ms libvips_peak_bytes rss_peak_bytes out_w out_h)

  def main(argv) do
    {manifest, accesses, width, iters, out_csv} = parse(argv)
    corpus = read_manifest(manifest, width)

    if corpus == [] do
      err("no images in manifest: #{manifest}")
      System.halt(1)
    end

    cases =
      for {path, w} <- corpus, access <- accesses, mode <- @modes, do: {path, w, access, mode}

    total = length(cases)

    err(
      "running #{total} cases (#{length(corpus)} files x #{length(@modes)} modes x #{length(accesses)} access)\n"
    )

    rows =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, w, access, mode}, i} ->
        err("[#{i}/#{total}] #{mode} #{access} #{Path.basename(path)} (#{w}px)")
        run_case(path, w, access, mode, iters)
      end)

    write_csv(out_csv, rows, accesses, iters)
    print_comparison(corpus, accesses, rows)
  end

  # One isolated OS process per case; parse the single CSV row it prints on stdout.
  defp run_case(path, width, access, mode, iters) do
    args = [mode, access, path, to_string(width), to_string(iters), "--csv"]

    {out, status} =
      System.cmd("mix", ["run", @per_case | args], stderr_to_stdout: false)

    row = parse_csv_row(out)

    cond do
      status != 0 ->
        %{file: path, mode: mode, access: access, width: width, error: "exit #{status}"}

      row == nil ->
        %{file: path, mode: mode, access: access, width: width, error: "no CSV row"}

      true ->
        row
    end
  end

  # Pick the one valid data line out of stdout (ignores any log noise): 14 fields, known mode.
  defp parse_csv_row(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ","))
    |> Enum.find_value(fn
      fields when length(fields) == length(@columns) ->
        row = @columns |> Enum.map(&String.to_atom/1) |> Enum.zip(fields) |> Map.new()
        if row.mode in @modes, do: row, else: nil

      _ ->
        nil
    end)
  end

  # --- collation ---

  defp write_csv(out_csv, rows, accesses, iters) do
    File.mkdir_p!(Path.dirname(out_csv))

    preamble = [
      "# decode matrix — access=#{Enum.join(accesses, "+")} iters=#{iters}",
      "# libvips_peak_bytes = libvips tracked high-water (working-set peak); rss_peak_bytes = whole-process peak.",
      Enum.join(@columns, ",")
    ]

    body =
      Enum.map(rows, fn row ->
        Enum.map_join(@columns, ",", fn col ->
          Map.get(row, String.to_atom(col), row[:error] || "")
        end)
      end)

    File.write!(out_csv, Enum.join(preamble ++ body, "\n") <> "\n")
    err("\nwrote #{length(rows)} rows -> #{out_csv}")
  end

  defp print_comparison(corpus, accesses, rows) do
    index = Map.new(rows, fn r -> {{r[:file], r[:access], r[:mode]}, r} end)

    IO.puts(
      "\n" <>
        cell("file", 22) <>
        cell("access", 11) <>
        cell("MP", 6) <>
        cell("strm ms", 9) <>
        cell("buf ms", 9) <>
        cell("b/s", 7) <>
        cell("strm vips", 11) <>
        cell("buf vips", 11) <> cell("strm RSS", 11) <> cell("buf RSS", 11)
    )

    ratios =
      for {path, _w} <- corpus, access <- accesses do
        s = index[{path, to_string(access), "streaming"}]
        b = index[{path, to_string(access), "buffered"}]
        ratio = time_ratio(s, b)

        IO.puts(
          cell(Path.basename(path), 22) <>
            cell(access, 11) <>
            cell(mp(s, b), 6) <>
            cell(num(s[:median_ms]), 9) <>
            cell(num(b[:median_ms]), 9) <>
            cell(ratio_cell(ratio), 7) <>
            cell(mib(s[:libvips_peak_bytes]), 11) <>
            cell(mib(b[:libvips_peak_bytes]), 11) <>
            cell(mib(s[:rss_peak_bytes]), 11) <> cell(mib(b[:rss_peak_bytes]), 11)
        )

        ratio
      end
      |> Enum.reject(&is_nil/1)

    print_summary(ratios)
  end

  defp print_summary([]), do: IO.puts("\nno comparable cases.")

  defp print_summary(ratios) do
    faster = Enum.count(ratios, &(&1 < 0.98))
    slower = Enum.count(ratios, &(&1 > 1.02))
    tied = length(ratios) - faster - slower
    geomean = :math.exp(Enum.sum(Enum.map(ratios, &:math.log/1)) / length(ratios))

    IO.puts("""

    summary (buffered vs streaming time, lower = buffered faster):
      geometric-mean ratio: #{Float.round(geomean, 3)}x
      buffered faster: #{faster}   slower: #{slower}   tied: #{tied}   (of #{length(ratios)} cases)
    """)
  end

  # --- helpers ---

  defp time_ratio(%{median_ms: s}, %{median_ms: b}) do
    with {sf, _} <- Float.parse(s), {bf, _} <- Float.parse(b), true <- sf > 0 do
      bf / sf
    else
      _ -> nil
    end
  end

  defp time_ratio(_, _), do: nil

  defp ratio_cell(nil), do: "-"
  defp ratio_cell(r), do: "#{Float.round(r, 2)}x"

  defp mp(%{megapixels: m}, _) when m not in ["", nil], do: m
  defp mp(_, %{megapixels: m}) when m not in ["", nil], do: m
  defp mp(_, _), do: "-"

  defp num(nil), do: "-"
  defp num("ERR"), do: "ERR"
  defp num(v), do: v

  defp mib(nil), do: "-"
  defp mib(""), do: "-"

  defp mib(v) do
    case Integer.parse(to_string(v)) do
      {n, _} when n > 0 -> "#{Float.round(n / 1_048_576, 1)} MiB"
      _ -> "-"
    end
  end

  defp cell(v, w), do: String.pad_trailing(to_string(v), w)

  defp read_manifest(manifest, default_width) do
    manifest
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [path, w] -> {path, String.to_integer(w)}
        [path] -> {path, default_width}
      end
    end)
    |> Enum.filter(fn {path, _w} ->
      File.regular?(path) or (err("  skipping missing file: #{path}") && false)
    end)
  end

  defp parse(argv) do
    manifest = Enum.at(argv, 0, "bench/corpus.txt")
    accesses = argv |> Enum.at(1, "sequential") |> to_accesses()
    width = argv |> Enum.at(2, "400") |> String.to_integer()
    iters = argv |> Enum.at(3, "5") |> String.to_integer()
    out_csv = Enum.at(argv, 4, "bench/results/decode_matrix.csv")
    {manifest, accesses, width, iters, out_csv}
  end

  defp to_accesses("both"), do: ["sequential", "random"]
  defp to_accesses("sequential"), do: ["sequential"]
  defp to_accesses("random"), do: ["random"]

  defp to_accesses(o),
    do: raise(ArgumentError, "access must be sequential|random|both, got #{inspect(o)}")

  defp err(msg), do: IO.puts(:stderr, msg)
end

DecodeMatrix.main(System.argv())
