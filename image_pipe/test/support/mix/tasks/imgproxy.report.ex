defmodule Mix.Tasks.Imgproxy.Report do
  @shortdoc "Build an HTML report of the imgproxy reference cases"
  @moduledoc """
  Collects the results `ImagePipe.APIImgproxyReferenceTest` wrote to
  `tmp/imgproxy_reference/` into one self-contained HTML page: failures first,
  then passing cases sorted by how close they came to their tolerance, each
  with the imgproxy reference, ImagePipe's output and the amplified difference
  side by side.

      MIX_ENV=test mise exec -- mix imgproxy.report [--output PATH]

  The default output is `tmp/imgproxy_reference/index.html`. When
  `GITHUB_STEP_SUMMARY` is set, it also appends counts, failures and the cases
  with the least headroom to the GitHub Actions job summary.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.ImgproxyReference.Cases

  @results "tmp/imgproxy_reference"
  @fixtures "test/support/image_pipe/test/imgproxy_reference/fixtures"
  @closest 10

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [output: :string])
    output = opts[:output] || Path.join(@results, "index.html")

    {pending, active} = Enum.split_with(Cases.all(), & &1[:pending])

    results =
      for c <- active, path = Path.join(@results, "#{c.id}.result"), File.exists?(path) do
        Map.put(path |> File.read!() |> :erlang.binary_to_term(), :case, c)
      end

    {failed, passed} = Enum.split_with(results, &(&1.status == :fail))
    passed = Enum.sort_by(passed, &budget_used/1, :desc)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, page(failed, passed, pending))
    summarize(failed, passed, pending, System.get_env("GITHUB_STEP_SUMMARY"))

    Mix.shell().info(
      "Wrote #{length(failed)} failed, #{length(passed)} passed, " <>
        "#{length(pending)} pending case(s) to #{output}"
    )
  end

  # Share of the outlier budget a case used; lossy cases have none.
  defp budget_used(%{outliers: outliers, budget: budget}), do: outliers / max(budget, 1)
  defp budget_used(_result), do: 0.0

  defp page(failed, passed, pending) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>imgproxy reference report</title>
    <style>
      body { font: 14px/1.4 system-ui, sans-serif; margin: 16px; background: #fff; color: #111; }
      section { border-top: 1px solid #ccc; padding: 12px 0; }
      h2 { font-size: 16px; margin: 0 0 4px; }
      .fail h2 { color: #b00020; }
      code { background: #f2f2f2; padding: 1px 4px; border-radius: 3px; word-break: break-all; }
      .row { display: flex; flex-wrap: wrap; gap: 12px; }
      figure { margin: 0; }
      figcaption { font-size: 12px; color: #555; }
      img { image-rendering: pixelated; max-width: 100%; border: 1px solid #ddd;
            background: repeating-conic-gradient(#eee 0 25%, #fff 0 50%) 0 0 / 16px 16px; }
    </style>
    </head>
    <body>
    <h1>imgproxy reference report</h1>
    <p>#{length(failed)} failed, #{length(passed)} passed, #{length(pending)} pending.
    Passing cases are sorted by how much of their outlier budget they used.</p>
    #{Enum.map_join(failed, "\n", &section(&1, "fail"))}
    #{Enum.map_join(passed, "\n", &section(&1, "pass"))}
    #{pending_list(pending)}
    </body>
    </html>
    """
  end

  defp section(%{case: c} = result, class) do
    images =
      [
        {"imgproxy reference", Path.join(@fixtures, "#{c.id}.png")},
        {"ImagePipe", Path.join(@results, "#{c.id}.actual.png")},
        {"difference ×8", Path.join(@results, "#{c.id}.diff.png")}
      ]
      |> Enum.filter(fn {_label, path} -> File.exists?(path) end)
      |> Enum.map_join("\n", fn {label, path} ->
        "<figure><img src=\"data:image/png;base64,#{Base.encode64(File.read!(path))}\" " <>
          "alt=\"#{label}\" loading=\"lazy\"><figcaption>#{label}</figcaption></figure>"
      end)

    """
    <section class="#{class}">
    <h2 id="#{c.id}">#{c.id}</h2>
    <p>#{escape(describe(result))}</p>
    <p>ImagePipe <code>#{escape(c.native)}</code> on <code>#{escape(c.source)}</code><br>
    imgproxy <code>#{escape(c.imgproxy)}</code></p>
    <div class="row">#{images}</div>
    </section>
    """
  end

  defp pending_list([]), do: ""

  defp pending_list(pending) do
    items =
      Enum.map_join(pending, "\n", fn c ->
        "<li><code>#{c.id}</code>: #{escape(c.pending)}</li>"
      end)

    "<section><h2>Pending</h2><ul>#{items}</ul></section>"
  end

  defp describe(%{status: :fail, message: message} = result),
    do: message <> metrics_suffix(result)

  defp describe(%{outliers: _} = result), do: String.trim_leading(metrics_suffix(result), "; ")
  defp describe(_result), do: "dimensions and content type match"

  defp metrics_suffix(%{
         outliers: outliers,
         threshold: threshold,
         budget: budget,
         max_delta: max
       }),
       do: "; #{outliers}/#{budget} samples over Δ#{threshold}, max Δ#{format(max)}"

  defp metrics_suffix(_result), do: ""

  defp summarize(_failed, _passed, _pending, nil), do: :ok

  defp summarize(failed, passed, pending, path) do
    failures =
      case failed do
        [] ->
          ""

        _ ->
          """

          **Failures**

          | Case | Native request | Result |
          | --- | --- | --- |
          #{Enum.map_join(failed, "\n", &row/1)}
          """
      end

    closest =
      passed
      |> Enum.filter(&Map.has_key?(&1, :outliers))
      |> Enum.take(@closest)
      |> Enum.map_join("\n", &row/1)

    File.write!(
      path,
      """
      ### imgproxy reference

      #{length(failed)} failed, #{length(passed)} passed, #{length(pending)} pending.
      #{failures}
      **Least headroom**

      | Case | Native request | Result |
      | --- | --- | --- |
      #{closest}

      Images for every case are in the imgproxy reference report artifact.
      """,
      [:append]
    )
  end

  defp row(%{case: c} = result), do: "| `#{c.id}` | `#{c.native}` | #{describe(result)} |"

  defp format(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp format(value), do: value

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
