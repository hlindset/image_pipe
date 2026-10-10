defmodule ImagePipe.Test.ImgproxyBench.Report do
  @moduledoc """
  Renders `mix imgproxy.bench` results as one self-contained HTML page: the
  run's environment, a summary per operation family, the HTTP baseline, a
  table of timings per family, and the cases whose responses didn't match.
  """
  use Boundary, top_level?: true, deps: []

  @servers ["image_pipe", "imgproxy"]

  @spec page(map()) :: String.t()
  def page(results) do
    env = results["environment"]
    high = "#{env["concurrency"]}"
    families = Enum.group_by(results["cases"], & &1["family"])

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>imgproxy benchmark</title>
    <style>
      :root { --fg: #111; --bg: #fff; --muted: #555; --line: #ddd; --code: #f2f2f2;
              --better: #0a7a32; --worse: #b00020; }
      @media (prefers-color-scheme: dark) {
        :root { --fg: #eee; --bg: #161616; --muted: #aaa; --line: #333; --code: #262626;
                --better: #5fd38a; --worse: #ff7a8a; }
      }
      body { font: 14px/1.4 system-ui, sans-serif; margin: 16px; background: var(--bg); color: var(--fg); }
      h2 { font-size: 16px; margin: 24px 0 6px; }
      p, dl { max-width: 72ch; }
      .scroll { overflow-x: auto; }
      table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
      th, td { border-bottom: 1px solid var(--line); padding: 3px 8px; text-align: right; white-space: nowrap; }
      th { font-weight: 600; }
      td:first-child, th:first-child, td.text { text-align: left; }
      code { background: var(--code); padding: 1px 4px; border-radius: 3px; }
      .muted { color: var(--muted); }
      .better { color: var(--better); }
      .worse { color: var(--worse); }
      dt { font-weight: 600; float: left; clear: left; width: 12em; }
      dd { margin: 0 0 2px 12em; word-break: break-all; }
    </style>
    </head>
    <body>
    <h1>image_pipe_server vs imgproxy</h1>
    <p>Ratios are ImagePipe ÷ imgproxy. A latency ratio below 1, or a
    throughput ratio above 1, means ImagePipe was faster; coloured cells
    differ by more than 10%. Latency is measured with one client, throughput
    with #{high}. Absolute times depend on the host: compare ratios.</p>
    #{environment(env)}
    #{summary(families, high)}
    #{baseline(results["baseline"], high)}
    #{Enum.map_join(Enum.sort(families), "\n", fn {family, cases} -> family_table(family, cases, high) end)}
    #{mismatches(results["mismatches"])}
    </body>
    </html>
    """
  end

  defp environment(env) do
    servers =
      Enum.map_join(@servers, "", fn key ->
        server = env["servers"][key]

        "<dt>#{escape(key)}</dt><dd>#{escape(server["label"])}, libvips #{escape(server["libvips"])}, " <>
          "<code>#{escape(server["image_id"])}</code></dd>"
      end)

    """
    <h2>Environment</h2>
    <dl>
    <dt>Date</dt><dd>#{env["date"]}</dd>
    <dt>Host</dt><dd>#{escape(env["host"])}</dd>
    <dt>Docker</dt><dd>#{escape(env["docker"])}</dd>
    <dt>Server CPUs</dt><dd>#{env["server_cpus"]}, #{escape(env["memory"])} memory, #{env["concurrency"]} workers</dd>
    <dt>oha CPUs</dt><dd>#{env["oha_cpus"]}, #{env["duration_s"]}s per measurement</dd>
    #{servers}
    </dl>
    """
  end

  defp summary(families, high) do
    rows =
      families
      |> Enum.sort()
      |> Enum.map_join("\n", fn {family, cases} ->
        latency = geomean(Enum.map(cases, fn c -> ratio(c["timings"], "1", &latency_p50/1) end))

        throughput =
          geomean(Enum.map(cases, fn c -> ratio(c["timings"], high, &throughput/1) end))

        "<tr><td><a href=\"##{family}\">#{family}</a></td><td>#{length(cases)}</td>" <>
          "#{ratio_cell(latency, :latency)}#{ratio_cell(throughput, :throughput)}</tr>"
      end)

    """
    <h2>Summary</h2>
    <p class="muted">Geometric means of the per-case ratios.</p>
    <div class="scroll"><table>
    <tr><th>Family</th><th>Cases</th><th>p50 latency ratio</th><th>Throughput ratio</th></tr>
    #{rows}
    </table></div>
    """
  end

  defp baseline(baseline, high) do
    rows =
      Enum.map_join(@servers, "\n", fn key ->
        low = baseline[key]["1"]
        loaded = baseline[key][high]

        "<tr><td>#{key}</td><td>#{ms(latency_p50(low))}</td><td>#{ms(get_in(low, ["latency_ms", "p99"]))}</td>" <>
          "<td>#{rps(throughput(loaded))}</td></tr>"
      end)

    """
    <h2>HTTP baseline</h2>
    <p class="muted">The health endpoint, which does no image work. A case
    close to this is mostly HTTP overhead.</p>
    <div class="scroll"><table>
    <tr><th>Server</th><th>p50 ms</th><th>p99 ms</th><th>req/s at #{high}</th></tr>
    #{rows}
    </table></div>
    """
  end

  defp family_table(family, cases, high) do
    rows =
      cases
      |> Enum.sort_by(&(ratio(&1["timings"], "1", fn t -> latency_p50(t) end) || 0), :desc)
      |> Enum.map_join("\n", &case_row(&1, high))

    """
    <h2 id="#{family}">#{family}</h2>
    <div class="scroll"><table>
    <tr><th rowspan="2">Case</th><th rowspan="2">Source</th>
    <th colspan="3">p50 ms, 1 client</th><th colspan="2">p99 ms, 1 client</th>
    <th colspan="3">req/s, #{high} clients</th><th colspan="2">peak MiB</th></tr>
    <tr><th>ImagePipe</th><th>imgproxy</th><th>ratio</th><th>ImagePipe</th><th>imgproxy</th>
    <th>ImagePipe</th><th>imgproxy</th><th>ratio</th><th>ImagePipe</th><th>imgproxy</th></tr>
    #{rows}
    </table></div>
    """
  end

  defp case_row(c, high) do
    t = c["timings"]
    [ip_low, px_low] = Enum.map(@servers, &t[&1]["1"])
    [ip_high, px_high] = Enum.map(@servers, &t[&1][high])
    title = "ImagePipe: #{c["native"]}\nimgproxy: #{c["imgproxy"]}"
    errors = errors(t)

    ~s(<tr><td title="#{escape(title)}">#{escape(c["id"])}#{errors}</td>) <>
      ~s(<td class="text">#{escape(c["source"])}</td>) <>
      "<td>#{ms(latency_p50(ip_low))}</td><td>#{ms(latency_p50(px_low))}</td>" <>
      ratio_cell(ratio(t, "1", &latency_p50/1), :latency) <>
      "<td>#{ms(get_in(ip_low, ["latency_ms", "p99"]))}</td><td>#{ms(get_in(px_low, ["latency_ms", "p99"]))}</td>" <>
      "<td>#{rps(throughput(ip_high))}</td><td>#{rps(throughput(px_high))}</td>" <>
      ratio_cell(ratio(t, high, &throughput/1), :throughput) <>
      "<td>#{mib(peak(ip_low, ip_high))}</td><td>#{mib(peak(px_low, px_high))}</td></tr>"
  end

  # Any response other than 200, or a request oha gave up on, during a timed
  # run makes the case's numbers suspect.
  defp errors(timings) do
    bad =
      for {server, levels} <- timings,
          {_level, run} <- levels,
          Map.keys(run["statuses"] || %{}) -- ["200"] != [] or failed_requests?(run["errors"]),
          uniq: true,
          do: server

    if bad == [], do: "", else: " <span class=\"worse\">(errors: #{Enum.join(bad, ", ")})</span>"
  end

  defp failed_requests?(nil), do: false

  defp failed_requests?(errors),
    do: Enum.any?(errors, fn {reason, _count} -> reason != "aborted due to deadline" end)

  defp mismatches([]), do: ""

  defp mismatches(mismatches) do
    rows =
      Enum.map_join(mismatches, "\n", fn m ->
        ~s(<tr><td class="text">#{escape(m["id"])}</td>) <>
          ~s(<td class="text">#{escape(m["source"])}</td>) <>
          Enum.map_join(
            @servers,
            "",
            &~s(<td class="text">#{escape(describe(m["responses"][&1]))}</td>)
          ) <>
          "</tr>"
      end)

    """
    <h2>Not timed</h2>
    <p class="muted">The two servers' responses differed in status, content
    type or dimensions.</p>
    <div class="scroll"><table>
    <tr><th>Case</th><th>Source</th><th>ImagePipe</th><th>imgproxy</th></tr>
    #{rows}
    </table></div>
    """
  end

  defp describe(%{"status" => 200} = r), do: "#{r["content_type"]} #{r["width"]}×#{r["height"]}"
  defp describe(%{"status" => status}), do: "#{status}"

  defp latency_p50(run), do: get_in(run, ["latency_ms", "p50"])
  defp throughput(run), do: run && run["requests_per_sec"]

  defp peak(low, high) do
    [low, high]
    |> Enum.map(&(&1 && &1["peak_memory_mib"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp ratio(timings, level, metric) do
    with ip when is_number(ip) <- metric.(timings["image_pipe"][level]),
         px when is_number(px) and px > 0 <- metric.(timings["imgproxy"][level]) do
      ip / px
    else
      _ -> nil
    end
  end

  defp geomean(values) do
    case Enum.filter(values, &(is_number(&1) and &1 > 0)) do
      [] -> nil
      values -> :math.exp(Enum.sum(Enum.map(values, &:math.log/1)) / length(values))
    end
  end

  defp ratio_cell(nil, _kind), do: "<td>–</td>"

  defp ratio_cell(value, kind) do
    better? = if kind == :latency, do: value < 0.9, else: value > 1.1
    worse? = if kind == :latency, do: value > 1.1, else: value < 0.9

    class =
      cond do
        better? -> " class=\"better\""
        worse? -> " class=\"worse\""
        true -> ""
      end

    "<td#{class}>#{:erlang.float_to_binary(value * 1.0, decimals: 2)}</td>"
  end

  defp ms(nil), do: "–"
  defp ms(value) when value >= 100, do: "#{round(value)}"
  defp ms(value) when value >= 10, do: :erlang.float_to_binary(value * 1.0, decimals: 1)
  defp ms(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp rps(nil), do: "–"
  defp rps(value) when value >= 100, do: "#{round(value)}"
  defp rps(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp mib(nil), do: "–"
  defp mib(value), do: "#{round(value)}"

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
