defmodule ImagePipe.Test.TwicpicsDifferential.ReportHtml do
  @moduledoc "Builds the TwicPics differential visual-diff report via the shared ReportShell."
  use Boundary, top_level?: true, deps: [ImagePipe.Test.Differential.ReportShell]

  alias ImagePipe.Test.Differential.ReportShell

  def render(%{baked_at: _baked_at, cards: cards} = doc) do
    ReportShell.page(%{
      title: "TwicPics differential",
      css: css(),
      script: "",
      header: header(doc),
      cards: Enum.map_join(cards, "\n", &card/1)
    })
  end

  defp header(%{baked_at: baked_at, cards: cards}) do
    mismatches = Enum.count(cards, &(&1.status == :mismatch))

    ~s|<header><h1>TwicPics differential</h1><p>baked #{ReportShell.esc(baked_at)} · #{length(cards)} cases · #{mismatches} mismatch</p></header>|
  end

  defp card(c) do
    quarantine_marker =
      if c.triaged?,
        do: ~s| <span class="quarantined">QUARANTINED</span>|,
        else: ""

    heat =
      if c.heat_banded,
        do:
          ~s|<figure class="panel"><img src="#{c.heat_banded}"><figcaption>banded diff — informational, not a gate</figcaption></figure>|,
        else: ""

    """
    <section class="card" data-status="#{c.status}">
      <h2>#{ReportShell.esc(c.id)} <small>#{c.verdict}/#{c.group}</small>#{quarantine_marker}</h2>
      <p>dims #{fmt(c.dims_pipe)} vs #{fmt(c.dims_oracle)} · bands #{c.bands_pipe}/#{c.bands_oracle} · #{c.status}</p>
      <div class="panels">
        <figure class="panel slider"><img-comparison-slider><img slot="first" src="#{c.oracle_png}"><img slot="second" src="#{c.pipe_png}"></img-comparison-slider><figcaption>oracle ↔ ImagePipe</figcaption></figure>
        <figure class="panel"><pre>#{cellmap(c.cells_oracle)}\n#{cellmap(c.cells_pipe)}</pre><figcaption>cell-map oracle / pipe</figcaption></figure>
        #{heat}
      </div>
    </section>
    """
  end

  defp cellmap(cells),
    do:
      Enum.map_join(cells, " ", fn
        {:cell, {x, y}} -> "#{x}#{y}"
        :padding -> "·"
        :ambiguous -> "?"
      end)

  defp fmt(nil), do: "—"
  defp fmt({w, h}), do: "#{w}×#{h}"

  defp css,
    do:
      ".card{margin:16px 0;border:1px solid #ccc;padding:8px}" <>
        ".panels{display:flex;flex-wrap:wrap;gap:12px}" <>
        ".panel img,.panel img-comparison-slider{max-width:240px}" <>
        ".quarantined{font-size:0.75em;font-weight:bold;color:#b45309;border:1px solid #b45309;padding:1px 4px;border-radius:3px;vertical-align:middle}"
end
