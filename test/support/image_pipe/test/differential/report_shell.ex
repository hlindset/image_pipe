defmodule ImagePipe.Test.Differential.ReportShell do
  @moduledoc """
  Shared HTML chrome for differential visual-diff reports: document skeleton, the
  img-comparison-slider CDN includes, and HTML-escaping. Each suite supplies its
  own CSS, controls, per-card bodies, and counts; this assembles the page.
  """

  use Boundary, top_level?: true, deps: []

  @slider_css "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/styles.css"
  @slider_js "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/index.js"

  @doc """
  Assemble the full HTML document from suite-supplied fragments.

  Required keys: `title`, `css`, `script`, `header`, `cards`.
  Optional keys:
  - `head_extras` — raw HTML inserted into `<head>` after the slider stylesheet
    (use for suite-specific font or icon links).
  - `body_attrs` — extra attributes appended verbatim to the `<body>` tag,
    e.g. `~s| data-heat="banded"` (include the leading space).
  """
  @spec page(%{
          required(:title) => String.t(),
          required(:css) => String.t(),
          required(:script) => String.t(),
          required(:header) => String.t(),
          required(:cards) => String.t(),
          optional(:head_extras) => String.t(),
          optional(:body_attrs) => String.t()
        }) :: String.t()
  def page(%{title: title, css: css, script: script, header: header, cards: cards} = parts) do
    head_extras = Map.get(parts, :head_extras, "")
    body_attrs = Map.get(parts, :body_attrs, "")

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(title)}</title>
    <link rel="stylesheet" href="#{@slider_css}">
    #{head_extras}<script defer src="#{@slider_js}"></script>
    <style>#{css}</style>
    </head>
    <body data-status="all" data-type="all"#{body_attrs}>
    #{header}
    <main class="cards">
    #{cards}
    </main>
    #{script}
    </body>
    </html>
    """
  end

  @doc "HTML-escape a value (coerces to string first)."
  @spec esc(term()) :: String.t()
  def esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
