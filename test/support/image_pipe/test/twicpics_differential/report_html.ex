defmodule ImagePipe.Test.TwicpicsDifferential.ReportHtml do
  @moduledoc """
  Pure renderer: card data + provenance → a single self-contained HTML string for
  the TwicPics differential visual-diff report. All images arrive pre-encoded as
  `data:` URIs; the only view-time network deps are the img-comparison-slider CDN
  and Google Fonts (both degrade: the side-by-side panels are the source of truth,
  fonts fall back to system stacks). Card-data shape is produced by
  `Mix.Tasks.Twicpics.GenReport`.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Test.Differential.ReportShell, ImagePipe.Test.Differential.ReportUI]

  alias ImagePipe.Test.Differential.ReportShell
  alias ImagePipe.Test.Differential.ReportUI

  @fonts "https://fonts.googleapis.com/css2?family=Geist+Mono:wght@100..900&family=Geist:wght@100..900&display=swap"
  @issue_base "https://github.com/hlindset/image_pipe/issues/"

  @spec render(%{provenance: map(), cards: [map()]}) :: String.t()
  def render(%{provenance: prov, cards: cards}) do
    ordered = Enum.sort_by(cards, fn c -> if(c.flagged?, do: 0, else: 1) end)

    head_extras =
      ~s(<link rel="preconnect" href="https://fonts.googleapis.com">\n) <>
        ~s(<link rel="stylesheet" href="#{@fonts}">\n)

    ReportUI.render(%{
      title: "TwicPics differential — visual diff",
      provenance_html: provenance_html(prov),
      counts_html: counts(cards),
      type_axis: %{
        label: "group",
        buttons: [
          %{set: "all", label: "all"},
          %{set: "focus", label: "focus"},
          %{set: "cover", label: "cover"},
          %{set: "contain", label: "contain"},
          %{set: "inside", label: "inside"},
          %{set: "crop", label: "crop"}
        ]
      },
      cards: Enum.map(ordered, &card/1),
      head_extras: head_extras
    })
  end

  defp provenance_html(prov) do
    "TwicPics <code>#{esc(prov.twicpics_version)}</code> · " <>
      "ImagePipe libvips <code>#{esc(prov.pipe_libvips_at_gen)}</code> (at gen) · " <>
      "runtime <code>#{esc(prov.runtime_libvips)}</code>"
  end

  defp counts(cards) do
    by_group = Enum.frequencies_by(cards, & &1.group)
    flagged = Enum.count(cards, & &1.flagged?)
    failing = Enum.count(cards, & &1.failing?)
    quarantined = Enum.count(cards, &(&1.triage != nil))
    drift = Enum.count(cards, & &1.hash_drift?)

    "#{Map.get(by_group, :focus, 0)} focus · " <>
      "#{Map.get(by_group, :cover, 0)} cover · " <>
      "#{Map.get(by_group, :contain, 0)} contain · " <>
      "#{Map.get(by_group, :inside, 0)} inside · " <>
      "#{Map.get(by_group, :crop, 0)} crop — " <>
      "#{flagged} flagged · #{failing} failing · " <>
      "#{quarantined} quarantined · #{drift} hash-drift"
  end

  defp card(c) do
    classes =
      ["card", "group-#{c.group}", "status-#{c.status}"] ++
        if(c.flagged?, do: ["flagged"], else: []) ++
        if(c.failing?, do: ["failing"], else: []) ++
        if(c.triage, do: ["quarantined"], else: [])

    """
    <section id="#{esc(c.id)}" class="#{Enum.join(classes, " ")}" data-group="#{c.group}">
      <div class="card-head">
        <h2>#{esc(c.id)}</h2>
        #{badges(c)}
      </div>
      <p class="summary">#{esc(c.summary)}</p>
      <p class="url"><code>#{esc(c.url)}</code></p>
      #{triage(c)}
      #{drift_banner(c)}
      <p class="metric #{metric_class(c)}">#{esc(c.metric_text)}</p>
      #{visuals(c)}
    </section>
    """
  end

  defp badges(c) do
    base = [
      ~s(<span class="badge verdict">#{c.verdict}</span>),
      ~s(<span class="badge group">#{c.group}</span>)
    ]

    tol =
      if c.tol,
        do: [~s(<span class="badge tol">tol Δ#{c.tol.threshold}/#{c.tol.budget}</span>)],
        else: []

    triage = if c.triage, do: [~s(<span class="badge triage">quarantined</span>)], else: []

    Enum.join(base ++ tol ++ triage, " ")
  end

  defp triage(%{triage: nil}), do: ""

  # Structured triage: reason + a clickable issue link.
  defp triage(%{triage: %{reason: reason, issue: issue}}) do
    n = issue |> to_string() |> String.trim_leading("#")

    ~s(<p class="triage-note">⚠ quarantined: #{esc(reason)} — <a href="#{@issue_base}#{esc(n)}">##{esc(n)}</a></p>)
  end

  defp drift_banner(%{hash_drift?: true}),
    do:
      ~s(<p class="banner drift">authored fields changed since generation — run <code>mix twicpics.reauthor</code> or regenerate.</p>)

  defp drift_banner(_), do: ""

  defp metric_class(c), do: if(c.status == :pass, do: "ok", else: "bad")

  # Dims mismatch: the two renders side by side; no slider/heatmap (the mismatch is
  # the finding).
  defp visuals(%{status: :dims_mismatch} = c) do
    """
    <div class="visuals">
      #{panel(c.oracle_img, "TwicPics #{fmt(c.fixture_dims)}")}
      #{panel(c.pipe_img, "ImagePipe #{fmt(c.pipe_dims)}")}
    </div>
    """
  end

  # All panels flow in one wrapping row: TwicPics, ImagePipe, slider, and the
  # active heatmap (the toggle hides the other two).
  defp visuals(c) do
    """
    <div class="visuals">
      #{panel(c.oracle_img, "TwicPics #{fmt(c.fixture_dims)}")}
      #{panel(c.pipe_img, "ImagePipe #{fmt(c.pipe_dims)}")}
      <figure class="panel slider" style="width:#{min(elem(c.pipe_dims, 0), 280)}px">
        <img-comparison-slider>
          <img slot="first" src="#{c.oracle_img}" alt="TwicPics">
          <img slot="second" src="#{c.pipe_img}" alt="ImagePipe">
        </img-comparison-slider>
        <figcaption>slider</figcaption>
      </figure>
      <figure class="panel heat-banded"><img src="#{c.heat_banded}" alt="banded diff"><figcaption>banded (Δ#{heat_threshold(c)})</figcaption></figure>
      <figure class="panel heat-raw"><img src="#{c.heat_raw}" alt="raw diff"><figcaption>raw ×8</figcaption></figure>
      <figure class="panel heat-normalized"><img src="#{c.heat_normalized}" alt="normalized diff"><figcaption>normalized (per-case)</figcaption></figure>
    </div>
    """
  end

  defp panel(img, caption) do
    ~s(<figure class="panel"><img src="#{img}" alt="#{esc(caption)}"><figcaption>#{esc(caption)}</figcaption></figure>)
  end

  defp heat_threshold(%{tol: %{threshold: t}}), do: t
  defp heat_threshold(_), do: 2

  defp fmt(nil), do: ""
  defp fmt({w, h}), do: "#{w}×#{h}"

  defp esc(value), do: ReportShell.esc(value)
end
