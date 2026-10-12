# Compares ImagePipe.SVG.cost/3's work estimate with real render time, to
# calibrate the render budget (`max_render_work`) on the machine it runs on.
#
#     python3 bench/render_budget/gen.py /tmp/cases
#     mix run bench/render_budget/calibrate.exs /tmp/cases
#
# Prints a Markdown table and summary. Renders estimated over @max_work are
# skipped, so a run takes a few minutes.

defmodule Calibrate do
  alias ImagePipe.SVG

  @widths [1000, 4000]
  # About 15 s at the rates measured so far.
  @max_work 3_000_000_000
  # Smaller renders are dominated by fixed overhead, not per-unit cost.
  @min_work_for_rate 10_000_000

  def main([dir]) do
    {:ok, fonts} = SVG.load_fonts([])

    rows =
      for path <- Enum.sort(Path.wildcard(Path.join(dir, "*.svg"))), width <- @widths do
        measure(Path.basename(path, ".svg"), File.read!(path), fonts, width)
      end

    IO.puts("| Case | Width | Work (M) | Peak (M px) | Render (ms) | ms per M work |")
    IO.puts("| --- | ---: | ---: | ---: | ---: | ---: |")
    Enum.each(rows, &IO.puts(row(&1)))

    rates = for %{ms: ms, work: work} <- rows, ms, work >= @min_work_for_rate, do: ms / (work / 1.0e6)
    summary(Enum.sort(rates))
  end

  defp measure(name, data, fonts, width) do
    case SVG.parse(data, fonts, max_elements: 2_000_000, max_image_pixels: 100_000_000) do
      {:ok, document} ->
        height = max(1, round(width * document.height / document.width))
        cost = SVG.cost(document, width, height)

        ms =
          if cost.work <= @max_work do
            {us, _rgba} = :timer.tc(fn -> SVG.render(document, width, height) end)
            us / 1000
          end

        %{name: name, width: width, work: cost.work, peak: cost.peak, ms: ms}

      {:error, reason} ->
        %{name: name, width: width, error: reason}
    end
  end

  defp row(%{error: reason} = r), do: "| #{r.name} | #{r.width} | rejected: `#{inspect(reason)}` | | | |"

  defp row(r) do
    rate = if r.ms && r.work >= @min_work_for_rate, do: fmt(r.ms / (r.work / 1.0e6)), else: ""
    ms = if r.ms, do: fmt(r.ms), else: "skipped"
    "| #{r.name} | #{r.width} | #{fmt(r.work / 1.0e6)} | #{fmt(r.peak / 1.0e6)} | #{ms} | #{rate} |"
  end

  defp summary([]), do: IO.puts("\nNo render was large enough to measure a rate.")

  defp summary(rates) do
    median = Enum.at(rates, div(length(rates), 2))
    p90 = Enum.at(rates, min(length(rates) - 1, round(length(rates) * 0.9)))

    IO.puts("""

    #{length(rates)} renders of at least #{div(@min_work_for_rate, 1_000_000)}M work units.
    ms per million work units: median #{fmt(median)}, p90 #{fmt(p90)}, max #{fmt(List.last(rates))}.
    Work for one second at the p90 rate: #{fmt(1000 / p90)}M units (default `max_render_work`: 100M).
    """)
  end

  defp fmt(number) when is_integer(number), do: Integer.to_string(number)
  defp fmt(number), do: :erlang.float_to_binary(number / 1, decimals: 1)
end

Calibrate.main(System.argv())
