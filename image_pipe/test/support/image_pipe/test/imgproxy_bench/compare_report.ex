defmodule ImagePipe.Test.ImgproxyBench.CompareReport do
  @moduledoc """
  Renders `mix imgproxy.bench --compare` results: for each `--against` image,
  the candidate's ratio to it per operation family, as an HTML page and as a
  Markdown summary for a pull request comment or a job summary.

  Each case's value for an image is the median of its rounds. A family's
  ratio is the geometric mean of its cases' ratios, and its spread is the
  lowest and highest of the same ratio computed round by round. A family is
  marked when every round has it more than 10% worse.
  """
  use Boundary, top_level?: true, deps: []

  @threshold 1.10

  # Each metric, where higher is worse, and how to read it from one round's
  # timings of a case.
  @metrics [
    {:latency, &__MODULE__.latency/1},
    {:load_time, &__MODULE__.load_time/1},
    {:memory, &__MODULE__.memory/1}
  ]

  @spec page(map()) :: String.t()
  def page(results) do
    env = results["environment"]

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>image_pipe_server comparison</title>
    <style>
      :root { --fg: #111; --bg: #fff; --muted: #555; --line: #ddd; --worse: #b00020; --better: #0a7a32; }
      @media (prefers-color-scheme: dark) {
        :root { --fg: #eee; --bg: #161616; --muted: #aaa; --line: #333; --worse: #ff7a8a; --better: #5fd38a; }
      }
      body { font: 14px/1.4 system-ui, sans-serif; margin: 16px; background: var(--bg); color: var(--fg); }
      h2 { font-size: 16px; margin: 24px 0 6px; }
      p { max-width: 72ch; }
      .scroll { overflow-x: auto; }
      table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
      th, td { border-bottom: 1px solid var(--line); padding: 3px 8px; text-align: right; white-space: nowrap; }
      td:first-child, th:first-child { text-align: left; }
      .muted { color: var(--muted); }
      .worse { color: var(--worse); font-weight: 600; }
      .better { color: var(--better); }
    </style>
    </head>
    <body>
    <h1>image_pipe_server comparison</h1>
    <p>#{escape(intro(results))}</p>
    <p class="muted">#{escape(environment(env))}</p>
    #{Enum.map_join(results["against"], "\n", &against_html(results, &1))}
    #{mismatches_html(results["mismatches"])}
    </body>
    </html>
    """
  end

  @spec summary(map()) :: String.t()
  def summary(results) do
    tables =
      Enum.map_join(results["against"], "\n", fn against ->
        rows =
          Enum.map_join(families(results, against), "\n", fn {family, count, cells} ->
            "| #{family} | #{count} | " <>
              Enum.map_join(cells, " | ", &markdown_cell/1) <> " |"
          end)

        """
        **Against `#{against}`** (#{image(results, against)})

        | Family | Cases | p50 latency | Time under load | Peak memory |
        | --- | ---: | ---: | ---: | ---: |
        #{rows}
        """
      end)

    mismatches =
      case results["mismatches"] do
        [] ->
          ""

        list ->
          "\n#{length(list)} case(s) weren't timed because the images' responses differed.\n"
      end

    """
    ### image_pipe_server performance

    #{intro(results)}

    #{tables}#{mismatches}
    <sub>#{environment(results["environment"])}</sub>
    """
  end

  defp intro(results) do
    "Ratios are the candidate (#{image(results, "candidate")}) ÷ each other image, " <>
      "geometric means per family, with the lowest and highest round in brackets. " <>
      "Time under load is the inverse of throughput at the full worker count. " <>
      "Above 1 is worse for every column. A family in bold was more than 10% worse " <>
      "in every round."
  end

  defp environment(env) do
    "#{env["host"]}, #{env["docker"]}, servers on CPUs #{env["server_cpus"]} " <>
      "with #{env["concurrency"]} workers, #{env["rounds"]} round(s) of " <>
      "#{env["duration_s"]}s measurements, #{env["date"]}."
  end

  defp image(results, key), do: results["environment"]["servers"][key]["label"]

  defp against_html(results, against) do
    family_rows =
      Enum.map_join(families(results, against), "\n", fn {family, count, cells} ->
        "<tr><td>#{family}</td><td>#{count}</td>" <>
          Enum.map_join(cells, "", &html_cell/1) <> "</tr>"
      end)

    case_rows =
      results["cases"]
      |> Enum.map(&{&1, case_ratios(&1, against)})
      |> Enum.sort_by(fn {_c, ratios} -> -(ratios[:latency] || 0) end)
      |> Enum.map_join("\n", fn {c, ratios} ->
        "<tr><td title=\"#{escape(c["native"])}\">#{escape(c["id"])}</td>" <>
          "<td>#{escape(c["family"])}</td>" <>
          Enum.map_join(@metrics, "", fn {name, _fun} ->
            "<td>#{format(ratios[name])}</td>"
          end) <> "</tr>"
      end)

    """
    <h2>Against #{escape(against)}: #{escape(image(results, against))}</h2>
    <div class="scroll"><table>
    <tr><th>Family</th><th>Cases</th><th>p50 latency</th><th>Time under load</th><th>Peak memory</th></tr>
    #{family_rows}
    </table></div>
    <details><summary>Cases, slowest first</summary>
    <div class="scroll"><table>
    <tr><th>Case</th><th>Family</th><th>p50 latency</th><th>Time under load</th><th>Peak memory</th></tr>
    #{case_rows}
    </table></div>
    </details>
    """
  end

  defp mismatches_html([]), do: ""

  defp mismatches_html(mismatches) do
    rows =
      Enum.map_join(mismatches, "\n", fn m ->
        "<tr><td>#{escape(m["id"])}</td><td>#{escape(inspect(m["responses"]))}</td></tr>"
      end)

    """
    <h2>Not timed</h2>
    <p class="muted">The images' responses differed in status, content type or dimensions.</p>
    <div class="scroll"><table>#{rows}</table></div>
    """
  end

  # One row per family: its case count and, for each metric, the ratio of
  # medians and the per-round spread.
  defp families(results, against) do
    results["cases"]
    |> Enum.group_by(& &1["family"])
    |> Enum.sort()
    |> Enum.map(fn {family, cases} ->
      cells =
        for {name, fun} <- @metrics do
          ratio = geomean(Enum.map(cases, &case_ratios(&1, against)[name]))
          per_round = round_ratios(cases, against, fun)
          {ratio, per_round}
        end

      {family, length(cases), cells}
    end)
  end

  defp case_ratios(c, against) do
    candidate = c["rounds"]["candidate"]
    other = c["rounds"][against]

    Map.new(@metrics, fn {name, fun} ->
      {name, ratio(median(Enum.map(candidate, fun)), median(Enum.map(other, fun)))}
    end)
  end

  defp round_ratios(cases, against, fun) do
    rounds = cases |> hd() |> Map.fetch!("rounds") |> Map.fetch!("candidate") |> length()

    for round <- 0..(rounds - 1) do
      cases
      |> Enum.map(fn c ->
        ratio(
          fun.(Enum.at(c["rounds"]["candidate"], round)),
          fun.(Enum.at(c["rounds"][against], round))
        )
      end)
      |> geomean()
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  # Higher is worse for each metric, so throughput is inverted into the time
  # each request takes under load.
  def latency(timings), do: get_in(timings, ["1", "latency_ms", "p50"])

  @doc false
  def load_time(timings) do
    case timings |> high_level() |> get_in(["requests_per_sec"]) do
      rps when is_number(rps) and rps > 0 -> 1 / rps
      _other -> nil
    end
  end

  @doc false
  def memory(timings) do
    timings
    |> Map.values()
    |> Enum.map(& &1["peak_memory_mib"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp high_level(timings),
    do: timings |> Enum.max_by(fn {level, _run} -> String.to_integer(level) end) |> elem(1)

  defp ratio(a, b) when is_number(a) and is_number(b) and b > 0, do: a / b
  defp ratio(_a, _b), do: nil

  defp median(values) do
    sorted = values |> Enum.reject(&is_nil/1) |> Enum.sort()
    count = length(sorted)

    cond do
      count == 0 -> nil
      rem(count, 2) == 1 -> Enum.at(sorted, div(count, 2))
      true -> (Enum.at(sorted, div(count, 2) - 1) + Enum.at(sorted, div(count, 2))) / 2
    end
  end

  defp geomean(values) do
    case Enum.filter(values, &(is_number(&1) and &1 > 0)) do
      [] -> nil
      values -> :math.exp(Enum.sum(Enum.map(values, &:math.log/1)) / length(values))
    end
  end

  defp worse?({_ratio, []}), do: false
  defp worse?({_ratio, per_round}), do: Enum.min(per_round) > @threshold

  defp spread({_ratio, []}), do: ""

  defp spread({_ratio, per_round}),
    do: " (#{format(Enum.min(per_round))}–#{format(Enum.max(per_round))})"

  defp markdown_cell({ratio, _per_round} = cell) do
    text = format(ratio) <> spread(cell)
    if worse?(cell), do: "**#{text}**", else: text
  end

  defp html_cell({ratio, _per_round} = cell) do
    class =
      cond do
        worse?(cell) -> " class=\"worse\""
        is_number(ratio) and ratio < 1 / @threshold -> " class=\"better\""
        true -> ""
      end

    "<td#{class}>#{format(ratio)}<span class=\"muted\">#{spread(cell)}</span></td>"
  end

  defp format(nil), do: "–"
  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp escape(nil), do: ""

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
