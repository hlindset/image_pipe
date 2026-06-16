defmodule ImagePipe.Test.ImgproxyDifferential.ReportHtml do
  @moduledoc """
  Pure renderer: card data + provenance → a single self-contained HTML string for
  the imgproxy differential visual-diff report. All images arrive pre-encoded as
  `data:` URIs; the only view-time network deps are the img-comparison-slider CDN
  and Google Fonts (both degrade: the side-by-side panels are the source of truth,
  fonts fall back to system stacks). Card-data shape is documented in the plan and
  produced by `Mix.Tasks.Imgproxy.GenReport`.
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Test.Differential.ReportShell]

  alias ImagePipe.Test.Differential.ReportShell

  @fonts "https://fonts.googleapis.com/css2?family=Geist+Mono:wght@100..900&family=Geist:wght@100..900&display=swap"
  @issue_base "https://github.com/hlindset/image_pipe/issues/"

  @spec render(%{provenance: map(), cards: [map()]}) :: String.t()
  def render(%{provenance: prov, cards: cards}) do
    ordered = Enum.sort_by(cards, fn c -> if(c.flagged?, do: 0, else: 1) end)

    head_extras =
      ~s(<link rel="preconnect" href="https://fonts.googleapis.com">\n) <>
        ~s(<link rel="stylesheet" href="#{@fonts}">\n)

    ReportShell.page(%{
      title: "imgproxy differential — visual diff",
      css: css(),
      script: script(),
      header: header(prov, cards),
      cards: Enum.map_join(ordered, "\n", &card/1),
      head_extras: head_extras,
      body_attrs: ~s| data-heat="banded"|
    })
  end

  defp header(prov, cards) do
    """
    <header class="report-header">
      <div class="title-row">
        <h1>imgproxy differential — visual diff</h1>
        <button id="theme-toggle">theme: auto</button>
      </div>
      <p class="provenance">imgproxy <code>#{esc(prov.imgproxy_digest)}</code> · imgproxy libvips <code>#{esc(prov.imgproxy_libvips)}</code> (.so ABI soname) · ImagePipe libvips <code>#{esc(prov.pipe_libvips_at_gen)}</code> (release, at gen) · runtime <code>#{esc(prov.runtime_libvips)}</code> (release) — schemes differ, not directly comparable</p>
      <p class="counts">#{counts(cards)}</p>
      <div class="controls">
        <span class="control-group" role="group" aria-label="type filter">
          type:
          <button data-type-set="all">all <span class="btn-count"></span></button>
          <button data-type-set="transform">transform <span class="btn-count"></span></button>
          <button data-type-set="known_divergence">known divergence <span class="btn-count"></span></button>
          <button data-type-set="lossy">lossy <span class="btn-count"></span></button>
        </span>
        <span class="control-group" role="group" aria-label="status filter">
          status:
          <button data-status-set="all">all <span class="btn-count"></span></button>
          <button data-status-set="flagged">flagged <span class="btn-count"></span></button>
          <button data-status-set="failing">failing <span class="btn-count"></span></button>
          <button data-status-set="quarantined">quarantined <span class="btn-count"></span></button>
        </span>
        <span class="control-group" role="group" aria-label="heatmap mode">
          heatmap:
          <button data-heat-set="banded">banded</button>
          <button data-heat-set="raw">raw</button>
          <button data-heat-set="normalized">normalized</button>
        </span>
      </div>
    </header>
    """
  end

  defp counts(cards) do
    by_group = Enum.frequencies_by(cards, & &1.group)
    flagged = Enum.count(cards, & &1.flagged?)
    failing = Enum.count(cards, & &1.failing?)
    quarantined = Enum.count(cards, &(&1.triage != nil))
    drift = Enum.count(cards, & &1.hash_drift?)

    "#{Map.get(by_group, :transform, 0)} transform · " <>
      "#{Map.get(by_group, :known_divergence, 0)} known divergence · " <>
      "#{Map.get(by_group, :lossy, 0)} lossy — " <>
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

  defp triage(%{triage: %{reason: reason, issue: issue}}) do
    n = String.trim_leading(issue, "#")

    ~s(<p class="triage-note">⚠ quarantined: #{esc(reason)} — <a href="#{@issue_base}#{esc(n)}">#{esc(issue)}</a></p>)
  end

  defp drift_banner(%{hash_drift?: true}),
    do:
      ~s(<p class="banner drift">authored fields changed since generation — run <code>mix imgproxy.reauthor</code> or regenerate.</p>)

  defp drift_banner(_), do: ""

  defp metric_class(c) do
    if c.status in [:pass, :diverges_ok, :contract_ok], do: "ok", else: "bad"
  end

  # Lossy: ImagePipe render alone (no imgproxy fixture to compare).
  defp visuals(%{group: :lossy} = c) do
    """
    <div class="visuals">
      #{panel(c.pipe_img, "ImagePipe (contract only — no imgproxy reference)")}
    </div>
    """
  end

  # Dims mismatch: the two renders side by side; no slider/heatmap (the mismatch is
  # the finding).
  defp visuals(%{status: :dims_mismatch} = c) do
    """
    <div class="visuals">
      #{panel(c.imgproxy_img, "imgproxy #{fmt(c.fixture_dims)}")}
      #{panel(c.pipe_img, "ImagePipe #{fmt(c.pipe_dims)}")}
    </div>
    """
  end

  # All panels flow in one wrapping row: imgproxy, ImagePipe, slider, and the
  # active heatmap (the toggle hides the other two).
  defp visuals(c) do
    """
    <div class="visuals">
      #{panel(c.imgproxy_img, "imgproxy #{fmt(c.fixture_dims)}")}
      #{panel(c.pipe_img, "ImagePipe #{fmt(c.pipe_dims)}")}
      <figure class="panel slider" style="width:#{min(elem(c.pipe_dims, 0), 280)}px">
        <img-comparison-slider>
          <img slot="first" src="#{c.imgproxy_img}" alt="imgproxy">
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

  defp script do
    """
    <script>
    (function () {
      var root = document.documentElement, body = document.body;
      var cards = Array.prototype.slice.call(document.querySelectorAll(".card"));

      function statusMatch(c, s) { return s === "all" || c.classList.contains(s); }
      function typeMatch(c, t) { return t === "all" || c.classList.contains("group-" + t); }
      function countWhere(pred) { return cards.filter(pred).length; }

      // Live counts: each button shows how many cards it would leave visible, given
      // the OTHER axis's current selection. Also marks the active button per axis.
      function refresh() {
        var st = body.getAttribute("data-status");
        var ty = body.getAttribute("data-type");
        var ht = body.getAttribute("data-heat");
        document.querySelectorAll("[data-status-set]").forEach(function (b) {
          var s = b.getAttribute("data-status-set");
          setCount(b, countWhere(function (c) { return statusMatch(c, s) && typeMatch(c, ty); }));
          b.classList.toggle("active", s === st);
        });
        document.querySelectorAll("[data-type-set]").forEach(function (b) {
          var t = b.getAttribute("data-type-set");
          setCount(b, countWhere(function (c) { return statusMatch(c, st) && typeMatch(c, t); }));
          b.classList.toggle("active", t === ty);
        });
        document.querySelectorAll("[data-heat-set]").forEach(function (b) {
          b.classList.toggle("active", b.getAttribute("data-heat-set") === ht);
        });
      }

      function setCount(b, n) {
        var s = b.querySelector(".btn-count");
        if (s) s.textContent = "(" + n + ")";
      }

      function bind(attr, setAttr) {
        document.querySelectorAll("[" + setAttr + "]").forEach(function (b) {
          b.addEventListener("click", function () {
            body.setAttribute(attr, b.getAttribute(setAttr));
            refresh();
          });
        });
      }
      bind("data-heat", "data-heat-set");
      bind("data-status", "data-status-set");
      bind("data-type", "data-type-set");

      // theme: auto → light → dark, persisted across regenerations
      var THEMES = ["auto", "light", "dark"], KEY = "imgproxy-report-theme";
      var themeBtn = document.getElementById("theme-toggle");
      function applyTheme(mode) {
        if (mode === "auto") root.removeAttribute("data-theme");
        else root.setAttribute("data-theme", mode);
        themeBtn.textContent = "theme: " + mode;
      }
      var saved = null;
      try { saved = localStorage.getItem(KEY); } catch (e) {}
      applyTheme(THEMES.indexOf(saved) >= 0 ? saved : "auto");
      themeBtn.addEventListener("click", function () {
        var cur = root.getAttribute("data-theme") || "auto";
        var next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
        applyTheme(next);
        try { localStorage.setItem(KEY, next); } catch (e) {}
      });

      refresh();
    })();
    </script>
    """
  end

  defp css do
    """
    /* dark is the base; `data-theme` (set by the toggle) overrides, and with no
       explicit choice the auto media-query below follows the OS preference */
    :root {
      color-scheme: dark;
      --surface-app:#0b0d10; --surface-bar:#0d1015; --surface-control:#202733;
      --border-subtle:#242b36; --text-primary:#f6f1e7; --text-muted:#8fa0b3;
      --accent:#ffb84d; --accent-text:#0b0d10; --danger:#ff6b6b; --checker-square:#1b222b;
      --image-shadow:0 22px 80px rgb(0 0 0 / 38%);
    }
    :root[data-theme="light"] {
      color-scheme: light;
      --surface-app:#f4f6f8; --surface-bar:#fff; --surface-control:#eef2f7;
      --border-subtle:#d9e0ea; --text-primary:#11151b; --text-muted:#687586;
      --accent:#d48100; --accent-text:#fff; --danger:#c62828; --checker-square:#dfe5ee;
      --image-shadow:0 22px 80px rgb(10 16 24 / 18%);
    }
    @media (prefers-color-scheme: light) {
      :root:not([data-theme="dark"]) {
        color-scheme: light;
        --surface-app:#f4f6f8; --surface-bar:#fff; --surface-control:#eef2f7;
        --border-subtle:#d9e0ea; --text-primary:#11151b; --text-muted:#687586;
        --accent:#d48100; --accent-text:#fff; --danger:#c62828; --checker-square:#dfe5ee;
        --image-shadow:0 22px 80px rgb(10 16 24 / 18%);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin:0; background:var(--surface-app); color:var(--text-primary);
      font-family:"Geist",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;
    }
    code, .url, .metric { font-family:"Geist Mono",ui-monospace,"SFMono-Regular","Menlo",monospace; }
    .report-header { position:sticky; top:0; z-index:2; padding:16px 24px;
      background:var(--surface-bar); border-bottom:1px solid var(--border-subtle); }
    .title-row { display:flex; align-items:center; justify-content:space-between; gap:12px; }
    .report-header h1 { margin:0 0 6px; font-size:18px; }
    #theme-toggle { font-size:12px; padding:3px 8px; border:1px solid var(--border-subtle);
      background:var(--surface-control); color:var(--text-primary); border-radius:5px; cursor:pointer; }
    .provenance, .counts { margin:4px 0; color:var(--text-muted); font-size:12px; }
    .counts { color:var(--text-primary); font-weight:600; }
    .banner { margin:8px 0; padding:8px 10px; border-radius:6px; font-size:12px; }
    .banner.drift { background:color-mix(in srgb, var(--danger) 18%, transparent); }
    .controls { display:flex; gap:18px; flex-wrap:wrap; align-items:baseline; margin-top:10px; }
    .control-group { font-size:12px; color:var(--text-muted); }
    .controls button { margin-left:4px; padding:3px 8px; border:1px solid var(--border-subtle);
      background:var(--surface-control); color:var(--text-primary); border-radius:5px; cursor:pointer; }
    .controls button.active { background:var(--accent); border-color:var(--accent); color:var(--accent-text); font-weight:600; }
    .btn-count { opacity:0.7; font-variant-numeric:tabular-nums; }
    .cards { padding:24px; display:flex; flex-direction:column; gap:24px; }
    .card { background:var(--surface-bar); border:1px solid var(--border-subtle);
      border-radius:10px; padding:16px; }
    .card.flagged { border-color:var(--danger); }
    .card-head { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
    .card-head h2 { margin:0; font-size:15px; }
    .badge { font-size:11px; padding:2px 7px; border-radius:999px;
      background:var(--surface-control); color:var(--text-muted); }
    .badge.triage { background:color-mix(in srgb, var(--danger) 25%, transparent); color:var(--text-primary); }
    .summary { margin:8px 0 2px; }
    .url { margin:0 0 8px; color:var(--text-muted); font-size:12px; word-break:break-all; }
    .triage-note { font-size:12px; color:var(--text-primary); margin:6px 0; }
    .metric { font-weight:600; }
    .metric.ok { color:var(--accent); }
    .metric.bad { color:var(--danger); }
    /* all panels (imgproxy, ImagePipe, slider, the active heatmap) flow in one
       wrapping row at a consistent width so nothing is stranded or stacked */
    .visuals { display:flex; flex-wrap:wrap; gap:14px; align-items:flex-start; margin-top:14px; }
    .panel { margin:0; }
    /* checker backs each rendered image INDIVIDUALLY (static panel imgs + the slider
       host as a fallback). The slotted slider images get their own checker below, so
       each composites over its own opaque backing: the top (second) image then fully
       occludes the first beneath it, instead of two transparent images stacking into a
       doubled, more-opaque blend on the second's side of the divider */
    .panel > img, .panel img-comparison-slider {
      display:block; max-width:280px; border-radius:6px;
      background:repeating-conic-gradient(var(--checker-square) 0 25%, transparent 0 50%) 50% / 20px 20px;
    }
    figcaption { font-size:11px; color:var(--text-muted); margin-top:4px; }
    /* slider wrapper is capped to the render width (inline style); kept flush with the
       other panels (no shadow). The divider/handle use the accent colour so they stay
       visible over a light, checkered image */
    .panel.slider { max-width:100%; }
    .panel.slider img, .panel.slider img-comparison-slider { width:100%; max-width:100%; }
    .panel.slider img { display:block; border-radius:6px;
      background:repeating-conic-gradient(var(--checker-square) 0 25%, transparent 0 50%) 50% / 20px 20px; }
    .panel.slider img-comparison-slider {
      --divider-width:3px; --divider-color:var(--accent);
      --default-handle-color:var(--accent); --default-handle-opacity:1;
    }
    body[data-heat="banded"] .heat-raw, body[data-heat="banded"] .heat-normalized { display:none; }
    body[data-heat="raw"] .heat-banded, body[data-heat="raw"] .heat-normalized { display:none; }
    body[data-heat="normalized"] .heat-banded, body[data-heat="normalized"] .heat-raw { display:none; }
    /* status and type are independent axes — a card hidden by either stays hidden,
       so the two filters intersect (e.g. status=failing + type=transform) */
    body[data-status="flagged"] .card:not(.flagged) { display:none; }
    body[data-status="failing"] .card:not(.failing) { display:none; }
    body[data-status="quarantined"] .card:not(.quarantined) { display:none; }
    body[data-type="transform"] .card:not(.group-transform) { display:none; }
    body[data-type="known_divergence"] .card:not(.group-known_divergence) { display:none; }
    body[data-type="lossy"] .card:not(.group-lossy) { display:none; }
    """
  end
end
