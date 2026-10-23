defmodule ImagePipe.Test.ImgproxyBench.CompareReport do
  @moduledoc """
  Renders `mix imgproxy.bench --compare` results: for each `--against` image,
  the candidate's ratio to it per operation family, as an HTML page and as a
  Markdown summary for a pull request comment or a job summary.

  Each case's value for an image is the median of its rounds. A family's
  ratio is the geometric mean of its cases' ratios, and its spread is the
  lowest and highest of the same ratio computed round by round. Ratios are
  shown as the percentage change from the compared image. A value is marked
  worse when every round has it more than 10% worse, and better when every
  round has it more than 10% better.

  Bursts of concurrent requests get a table of their own: each image's median
  time to the last response, and the downloads, generations and dropped cache
  writes a burst took.
  Those counts don't vary between runs, so a candidate count above or below
  every compared image's is marked.
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
    <h1>Performance comparison</h1>
    <p>#{Enum.map_join(["candidate" | results["against"]], "<br>", &"<strong>#{if &1 == "candidate", do: "Candidate", else: "Against " <> escape(&1)}:</strong> #{escape(describe(results, &1))}")}</p>
    <p>#{escape(intro())}</p>
    <p class="muted">#{escape(environment(env))}</p>
    #{Enum.map_join(timed_against(results), "\n", &against_html(results, &1))}
    #{bursts_html(results)}
    #{mismatches_html(results["mismatches"])}
    </body>
    </html>
    """
  end

  @spec summary(map()) :: String.t()
  def summary(results) do
    tables =
      Enum.map_join(timed_against(results), "\n", fn against ->
        rows =
          Enum.map_join(families(results, against), "\n", fn {family, count, cells} ->
            "| #{family} | #{count} | " <>
              Enum.map_join(cells, " | ", &markdown_cell/1) <> " |"
          end)

        """
        #### Against `#{against}`

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
    ### Performance comparison

    #{subjects(results)}

    #{intro()}

    #{tables}#{bursts_markdown(results)}#{mismatches}
    <sub>#{environment(results["environment"])}</sub>
    """
  end

  # The images to give a family table, none when only bursts ran.
  defp timed_against(%{"cases" => []}), do: []
  defp timed_against(results), do: results["against"]

  # What each image is, one line each, as Markdown.
  defp subjects(results) do
    against =
      Enum.map_join(results["against"], "  \n", fn key ->
        "**Against `#{key}`:** #{describe(results, key)}"
      end)

    "**Candidate:** #{describe(results, "candidate")}  \n" <> against
  end

  defp intro do
    "Each value is the candidate's change from the image it's compared against, so " <>
      "a positive change is worse: slower, or more memory. Values are geometric means " <>
      "per family, with the lowest and highest round in brackets. Time under load is " <>
      "the inverse of throughput. 🔴 marks a value more than 10% worse in every round, " <>
      "🟢 one more than 10% better in every round."
  end

  defp describe(results, key) do
    server = results["environment"]["servers"][key]
    server["description"] || "`#{server["image"] || server["label"]}`"
  end

  defp environment(env) do
    "#{env["host"]}, #{env["docker"]}, servers on CPUs #{env["server_cpus"]} " <>
      "with #{env["concurrency"]} workers, #{env["rounds"]} round(s) of " <>
      "#{env["duration_s"]}s measurements, longer for slow cases#{machines(env)}, " <>
      "#{env["date"]}."
  end

  # A merged run's rounds came from several machines.
  defp machines(%{"shards" => [_, _ | _] = shards}), do: ", on #{length(shards)} machines"

  defp machines(_env), do: ""

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
            "<td>#{percent(ratios[name])}</td>"
          end) <> "</tr>"
      end)

    """
    <h2>Against #{escape(against)}</h2>
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

  defp bursts_html(results) do
    case Map.get(results, "bursts", []) do
      [] ->
        ""

      bursts ->
        keys = ["candidate" | results["against"]]

        head =
          Enum.map_join(keys, "", fn key ->
            "<th>#{escape(key)} time</th><th>downloads</th><th>generations</th><th>drops</th>" <>
              "<th>rejected</th><th>rejected after</th>"
          end)

        rows = Enum.map_join(bursts, "\n", &burst_row_html(&1, keys))

        """
        <h2>Concurrent requests</h2>
        <p class="muted">#{escape(bursts_intro())}</p>
        <div class="scroll"><table>
        <tr><th>Case</th><th>Requests</th>#{head}</tr>
        #{rows}
        </table></div>
        """
    end
  end

  defp bursts_markdown(results) do
    case Map.get(results, "bursts", []) do
      [] ->
        ""

      bursts ->
        keys = ["candidate" | results["against"]]

        head =
          Enum.map_join(
            keys,
            " | ",
            &"#{&1} time | downloads | generations | drops | rejected | rejected after"
          )

        align =
          Enum.map_join(keys, " | ", fn _key -> "---: | ---: | ---: | ---: | ---: | ---:" end)

        rows = Enum.map_join(bursts, "\n", &burst_row_markdown(&1, keys))

        """

        #### Concurrent requests

        #{bursts_intro()}

        | Case | Requests | #{head} |
        | --- | ---: | #{align} |
        #{rows}
        """
    end
  end

  defp burst_row_html(b, keys) do
    cells = Enum.map_join(burst_cells(b, keys), "", &burst_cell_html/1)

    "<tr><td title=\"#{escape(Enum.join(b["natives"], ", "))}\">#{escape(b["id"])}</td>" <>
      "<td>#{b["requests"]}</td>#{cells}</tr>"
  end

  defp burst_cell_html({text, nil}), do: "<td>#{text}</td>"
  defp burst_cell_html({text, mark}), do: "<td class=\"#{mark}\">#{text}</td>"

  defp burst_row_markdown(b, keys) do
    cells = Enum.map_join(burst_cells(b, keys), " | ", &burst_cell_markdown/1)
    "| #{b["id"]} | #{b["requests"]} | #{cells} |"
  end

  defp burst_cell_markdown({text, :worse}), do: "🔴 #{text}"
  defp burst_cell_markdown({text, :better}), do: "🟢 #{text}"
  defp burst_cell_markdown({text, nil}), do: text

  defp bursts_intro do
    "Each case sends its requests at once: burst_same, burst_same_wide and burst_sizes " <>
      "for one new original, which the origin sends slowly enough that they overlap its " <>
      "download, and burst_grid and burst_overload for a new original each. Times are the median " <>
      "time to the last response; counts are a burst's downloads from the origin, images " <>
      "generated, cache writes dropped, and requests rejected with 503, as the " <>
      "lowest–highest over every burst. Rejected after is the median time a rejected " <>
      "request waited for its 503. 🔴 marks a candidate count above every compared " <>
      "image's, 🟢 one below."
  end

  # Time, downloads, generations, drops and rejections for each image, with
  # the candidate's counts marked against the others'.
  defp burst_cells(b, keys) do
    Enum.flat_map(keys, fn key ->
      bursts = List.flatten(b["rounds"][key])
      time = "#{round(median(Enum.map(bursts, & &1["ms"])))} ms"

      counts =
        Enum.map(
          ["downloads", "generations", "drops", "rejected"],
          &count_cell(b, keys, key, bursts, &1)
        )

      [{time, nil} | counts] ++ [{rejected_after(bursts), nil}]
    end)
  end

  defp count_cell(b, keys, key, bursts, name) do
    mark = if marked?(b, name), do: count_mark(b, keys, key, name)
    {count_text(bursts, name), mark}
  end

  defp rejected_after(bursts) do
    case bursts |> Enum.flat_map(&(&1["rejected_ms"] || [])) |> median() do
      nil -> "–"
      ms -> "#{round(ms)} ms"
    end
  end

  # An overload burst serves what its queue admits, so more downloads and
  # generations there are better, and its rejections vary with each
  # runner's speed. Only a clear difference in rejections is marked.
  defp marked?(%{"id" => "burst_overload" <> _}, name), do: name == "rejected"
  defp marked?(_b, _name), do: true

  defp count_text(bursts, name) do
    case bursts |> Enum.map(&(&1[name] || 0)) |> Enum.min_max() do
      {same, same} -> "#{same}"
      {low, high} -> "#{low}–#{high}"
    end
  end

  defp count_mark(_b, _keys, key, _name) when key != "candidate", do: nil

  defp count_mark(b, keys, "candidate", name) do
    count =
      &(b["rounds"][&1]
        |> List.flatten()
        |> Enum.map(fn burst -> burst[name] || 0 end)
        |> median())

    candidate = count.("candidate")
    others = keys |> tl() |> Enum.map(count)
    margin = &(abs(candidate - &1) >= min_difference(b, &1))

    cond do
      Enum.all?(others, &(candidate > &1 and margin.(&1))) -> :worse
      Enum.all?(others, &(candidate < &1 and margin.(&1))) -> :better
      true -> nil
    end
  end

  # Overload counts move with the runner, so they need at least two requests
  # and a tenth of the other image's count. Other counts don't vary.
  defp min_difference(%{"id" => "burst_overload" <> _}, other), do: max(2, other / 10)
  defp min_difference(_b, _other), do: 0

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

  # :worse or :better when every round is past the threshold that way.
  defp verdict({_ratio, []}), do: nil

  defp verdict({_ratio, per_round}) do
    cond do
      Enum.min(per_round) > @threshold -> :worse
      Enum.max(per_round) < 1 / @threshold -> :better
      true -> nil
    end
  end

  defp spread({_ratio, []}), do: ""

  defp spread({_ratio, per_round}),
    do: " (#{change(Enum.min(per_round))}…#{change(Enum.max(per_round))})"

  defp markdown_cell({ratio, _per_round} = cell) do
    text = percent(ratio) <> spread(cell)

    case verdict(cell) do
      :worse -> "🔴 #{text}"
      :better -> "🟢 #{text}"
      nil -> text
    end
  end

  defp html_cell({ratio, _per_round} = cell) do
    class =
      case verdict(cell) do
        nil -> ""
        verdict -> " class=\"#{verdict}\""
      end

    "<td#{class}>#{percent(ratio)}<span class=\"muted\">#{spread(cell)}</span></td>"
  end

  defp percent(nil), do: "–"
  defp percent(ratio), do: change(ratio) <> "%"

  # The ratio as a signed whole-number percentage change.
  defp change(ratio) do
    case round((ratio - 1) * 100) do
      0 -> "±0"
      n when n > 0 -> "+#{n}"
      n -> "−#{-n}"
    end
  end

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
