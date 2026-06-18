defmodule ImagePipe.Test.Differential.ReportUI do
  @moduledoc """
  Shared interactive chrome for differential visual-diff reports: the CSS design
  system, the filter/toggle/theme JavaScript, and the full `<header>` with three
  filter axes (a suite-supplied "type/group" axis plus the fixed status and heatmap
  axes). Identical across suites — each suite supplies only its title, head extras,
  provenance line, counts line, type-axis vocabulary, and pre-rendered card HTML.

  Cards arrive pre-rendered as HTML strings *in display order*; this module does no
  sorting (a suite that wants attention-first ordering sorts before rendering). The
  CSS keeps every generic axis rule (`group-transform`, `data-type="known_divergence"`,
  …) so a suite that never emits a given class is simply unaffected.
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Test.Differential.ReportShell]

  alias ImagePipe.Test.Differential.ReportShell

  @typedoc "A single button in the suite-supplied type/group filter axis."
  @type axis_button :: %{set: String.t(), label: String.t()}

  @doc """
  Assemble a full differential report document.

  Required keys:
  - `title` — the page + `<h1>` title.
  - `provenance_html` — raw HTML for the `<p class="provenance">` body.
  - `counts_html` — raw HTML for the `<p class="counts">` body.
  - `type_axis` — `%{label: String.t(), buttons: [%{set:, label:}]}`, the first
    (suite-specific) filter axis. The status and heatmap axes are fixed here.
  - `cards` — list of pre-rendered `<section class="card …">` HTML strings, in
    display order. Joined and placed in `<main>`.

  Optional keys:
  - `head_extras` — raw HTML passed through to `ReportShell.page` (e.g. font links).
  """
  @spec render(%{
          required(:title) => String.t(),
          required(:provenance_html) => String.t(),
          required(:counts_html) => String.t(),
          required(:type_axis) => %{label: String.t(), buttons: [axis_button()]},
          required(:cards) => [String.t()],
          optional(:head_extras) => String.t()
        }) :: String.t()
  def render(
        %{
          title: title,
          provenance_html: provenance_html,
          counts_html: counts_html,
          type_axis: type_axis,
          cards: cards
        } = parts
      ) do
    head_extras = Map.get(parts, :head_extras, "")

    ReportShell.page(%{
      title: title,
      css: css(),
      script: script(),
      header: header(title, provenance_html, counts_html, type_axis),
      cards: Enum.join(cards, "\n"),
      head_extras: head_extras,
      body_attrs: ~s| data-heat="banded"|
    })
  end

  defp header(title, provenance_html, counts_html, type_axis) do
    """
    <header class="report-header">
      <div class="title-row">
        <h1>#{ReportShell.esc(title)}</h1>
        <button id="theme-toggle">theme: auto</button>
      </div>
      <p class="provenance">#{provenance_html}</p>
      <p class="counts">#{counts_html}</p>
      <div class="controls">
        <span class="control-group" role="group" aria-label="#{ReportShell.esc(type_axis.label)} filter">
          #{ReportShell.esc(type_axis.label)}:
          #{type_buttons(type_axis.buttons)}
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

  defp type_buttons(buttons) do
    Enum.map_join(buttons, "\n      ", fn %{set: set, label: label} ->
      ~s(<button data-type-set="#{ReportShell.esc(set)}">#{ReportShell.esc(label)} <span class="btn-count"></span></button>)
    end)
  end

  @doc "The product-neutral CSS design system shared by every differential report."
  @spec css() :: String.t()
  def css do
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

  @doc "The axis-agnostic filter/toggle/theme JavaScript shared by every report."
  @spec script() :: String.t()
  def script do
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
      var THEMES = ["auto", "light", "dark"], KEY = "differential-report-theme";
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
end
