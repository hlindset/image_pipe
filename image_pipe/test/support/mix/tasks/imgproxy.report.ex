defmodule Mix.Tasks.Imgproxy.Report do
  @shortdoc "Build an HTML report of failing imgproxy reference cases"
  @moduledoc """
  Collects the failures `ImagePipe.APIImgproxyReferenceTest` wrote to
  `tmp/imgproxy_reference/` into one self-contained HTML page: per case, the
  native request, the failure message, and the imgproxy reference, ImagePipe's
  output and the amplified difference side by side.

      MIX_ENV=test mise exec -- mix imgproxy.report [--output PATH]

  The default output is `tmp/imgproxy_reference/index.html`. When
  `GITHUB_STEP_SUMMARY` is set, it also appends a table of failing cases to the
  GitHub Actions job summary.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.ImgproxyReference.Cases

  @failures "tmp/imgproxy_reference"
  @fixtures "test/support/image_pipe/test/imgproxy_reference/fixtures"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [output: :string])
    output = opts[:output] || Path.join(@failures, "index.html")

    failures =
      for c <- Cases.all(), File.exists?(Path.join(@failures, "#{c.id}.actual.png")) do
        %{case: c, message: read(Path.join(@failures, "#{c.id}.txt"))}
      end

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, page(failures))
    summarize(failures, System.get_env("GITHUB_STEP_SUMMARY"))
    Mix.shell().info("Wrote #{length(failures)} failing case(s) to #{output}")
  end

  defp page(failures) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>imgproxy reference failures</title>
    <style>
      body { font: 14px/1.4 system-ui, sans-serif; margin: 16px; background: #fff; color: #111; }
      section { border-top: 1px solid #ccc; padding: 12px 0; }
      code { background: #f2f2f2; padding: 1px 4px; border-radius: 3px; word-break: break-all; }
      .row { display: flex; flex-wrap: wrap; gap: 12px; }
      figure { margin: 0; }
      figcaption { font-size: 12px; color: #555; }
      img { image-rendering: pixelated; max-width: 100%; border: 1px solid #ddd;
            background: repeating-conic-gradient(#eee 0 25%, #fff 0 50%) 0 0 / 16px 16px; }
    </style>
    </head>
    <body>
    <h1>imgproxy reference failures (#{length(failures)})</h1>
    #{Enum.map_join(failures, "\n", &section/1)}
    </body>
    </html>
    """
  end

  defp section(%{case: c, message: message}) do
    images =
      [
        {"imgproxy reference", Path.join(@fixtures, "#{c.id}.png")},
        {"ImagePipe", Path.join(@failures, "#{c.id}.actual.png")},
        {"difference ×8", Path.join(@failures, "#{c.id}.diff.png")}
      ]
      |> Enum.filter(fn {_label, path} -> File.exists?(path) end)
      |> Enum.map_join("\n", fn {label, path} ->
        "<figure><img src=\"data:image/png;base64,#{Base.encode64(File.read!(path))}\" " <>
          "alt=\"#{label}\"><figcaption>#{label}</figcaption></figure>"
      end)

    """
    <section>
    <h2 id="#{c.id}">#{c.id}</h2>
    <p>#{escape(message)}</p>
    <p>ImagePipe <code>#{escape(c.native)}</code> on <code>#{escape(c.source)}</code><br>
    imgproxy <code>#{escape(c.imgproxy)}</code></p>
    <div class="row">#{images}</div>
    </section>
    """
  end

  defp summarize(_failures, nil), do: :ok

  defp summarize(failures, path) do
    rows =
      Enum.map_join(failures, "\n", fn %{case: c, message: message} ->
        "| `#{c.id}` | `#{c.native}` | #{message} |"
      end)

    File.write!(
      path,
      """
      ### imgproxy reference failures (#{length(failures)})

      | Case | Native request | Failure |
      | --- | --- | --- |
      #{rows}

      Images are in the job's imgproxy reference report artifact.
      """,
      [:append]
    )
  end

  defp read(path), do: if(File.exists?(path), do: File.read!(path), else: "")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
