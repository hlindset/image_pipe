# TwicPics structural differential suite — design

**Issue:** [#323](https://github.com/hlindset/image_pipe/issues/323)
**Date:** 2026-06-16
**Status:** approved (pre-implementation)

> **⚠️ SUPERSEDED.** This design's central premise — that "TwicPics is a different
> rendering engine" and so the suite must assert a colour-grid cell-map instead of
> pixels — was empirically disproven: TwicPics renders with **libvips** (19/30 baked
> fixtures are byte-identical to ImagePipe's libvips output, including a non-integer
> zone-plate downscale). The suite was reworked to direct pixel comparison
> (`PixelCompare.outliers ≤ tol.budget` with per-case tolerances), which is the
> stricter, correct gate. See the do-over plan
> `docs/superpowers/plans/2026-06-17-twicpics-pixel-comparison-do-over.md` and the
> suite README (`test/support/image_pipe/test/twicpics_differential/README.md`) for
> the current model. The cell-map description below is retained only as a historical
> planning artifact.

## Motivation

Add a TwicPics conformance suite that uses the **hosted TwicPics Image API as a
reference oracle**, in the spirit of the imgproxy differential suite
(`test/support/image_pipe/test/imgproxy_differential/`). It verifies that
ImagePipe's `ImagePipe.Parser.TwicPics` parser/planner reproduces TwicPics'
**geometry and placement** behavior against the real product, not just against
our own reading of the docs. It is the standing, automated form of
`docs/twicpics_porting_reference.md`'s "confirm behavior with black-box TwicPics
requests" guidance, and it validates the [#321](https://github.com/hlindset/image_pipe/issues/321)
focus-carry model end-to-end.

It is seeded by the focus-placement probe built during #321:
`tools/twicpics_focus_probe.exs` + `tools/make_grid.exs`. That probe's
colour-grid "which content lands where" decode is the comparison technique; this
suite productizes it.

## The decisive difference from imgproxy: assert structure, not pixels

imgproxy is itself libvips-based, so its differential suite is libvips-vs-libvips
and can hold tight pixel-skew tolerances. **TwicPics is a different rendering
engine** — its own resampler, sharpening, encoder, and chroma — so pixel-level
parity is not a goal. Tight skew tolerances would fail on engine noise that isn't
a conformance bug.

So the suite asserts **geometry/placement** with **generous colour tolerance**:
output dimensions, which source region a crop extracts, where focus lands, and
cover/contain/inside fit math.

## Core model

### The case author writes the chain; the bake derives the oracle

Mirroring imgproxy's "the bake can't author the oracle wrong" discipline, a case
author writes only the request and the verdict:

```elixir
%{
  id: "cover_wide_focus_corner",
  chain: "focus=0x0/cover=200x100",     # the TwicPics manipulation under test
  verdict: :equal,                       # or :diverges (with a recorded divergence)
  group: :focus,                         # coarse grouping for the report
  tol: %{...},                           # optional; defaults apply
  triage: %{reason: "...", issue: 999}   # optional quarantine
}
```

The **bake** hits live TwicPics and derives the **expected structural record**
from TwicPics' actual output. The default `mix test` lane re-derives ImagePipe's
structure for the same chain and compares it to the committed record. The author
never hand-writes expected dimensions or cells — the oracle defines them.

### Structural record

The committed assertion target per case is a distilled structural record (a
**reference PNG rides along** for offline debug/eyeballing — the *hybrid* fixture
shape):

```elixir
%{
  dims: {w, h},          # exact
  bands: 3 | 4,          # exact
  cells: [ ... ]         # decoded sampling lattice (see below)
}
```

- **`dims`** — exact match. Covers cover/contain/inside/resize size & ratio math.
- **`bands`** — exact match. Catches spurious alpha; `inside` letterbox → RGBA.
- **`cells`** — a fixed **relative** sampling lattice over the output. Each point
  decodes to `{:cell, {col, row}}` | `:padding` (alpha below threshold) |
  `:ambiguous` (colour not within tolerance of any cell), via **nearest-cell**
  colour match against the grid's known cell colours.

The cell-map is one comparator that subsumes focus placement, which source region
a crop extracted, cover/contain fit, and inside letterbox geometry — because each
grid cell's colour encodes its *content identity*, a faithful placement decodes
back to the same cells no matter how the engine resamples. **Colour/alpha
tolerance lives only inside the per-sample decode** — that is the issue's
"generous colour tolerance."

The probe's "trailing tiny crop to isolate one cell" trick is dropped: the
lattice reads placement straight off the real consumer's full output.

### Why no libvips-provenance machinery

Because the gate is the cell-map and not pixels, **ImagePipe's libvips version is
irrelevant to the assertion** — a different resampler still lands content in the
same cell. So the imgproxy suite's libvips-soname-vs-release provenance note and
drift hints are **not** carried over. This is a real simplification. (The
informational pixel heatmaps in the report are exactly that — informational — and
make no version claim.)

### Sampling lattice (tuning detail)

The lattice fractions are an implementation tuning detail finalized during
implementation, not fixed by this spec. Constraints:

- Cell-centre-aligned fractions, to avoid sampling exactly on the source grid's
  internal cell boundaries (for a 4×4 grid those sit at 0.25/0.5/0.75).
- Both engines are sampled at identical relative positions and compared, so a
  placement divergence shifts which cell a sample decodes to and is caught.
- A low-confidence-margin guard: the bake records each sample's decode margin
  (distance to the nearest vs second-nearest cell). A near-boundary, low-margin
  oracle decode is flagged so the author can quarantine rather than ship a
  flaky probe.

## The bake

`mix twicpics.gen_fixtures` (network, **no Docker**, manual — never on the default
lane). Driven by `mise run twic:bake`. No env-gated dependency or recompile dance:
imgproxy needs that only for its `:testcontainers` dep; TwicPics uses `Req`, which
is already present.

### Incremental by default

For a network oracle, "don't hammer the API; bake once, commit, re-bake
intentionally" (the issue) is the correct default, not an optimization — a
deliberate divergence from imgproxy's `gen_fixtures`, which rewrites everything
against a free local container.

- For each case the task computes an **oracle signature** = a hash over the inputs
  that actually determine TwicPics' output: `(chain, pinned suffix,
  hosted-source identity)`. It hits the network **only** when the case is new, its
  signature changed, or its committed PNG is missing/corrupt. Unchanged cases are
  skipped with zero requests.
- The signature deliberately **excludes** `tol`/`verdict`/`group` (they don't
  change what TwicPics renders) and **includes** the source's hosted-byte
  identity (re-uploading a changed source invalidates its dependent cases).
- **Prunes** manifest entries + reference PNGs for cases deleted from
  `Constellations`, so the fixture set can't drift orphaned.
- Escape hatches: `--force` re-bakes all; `--only id1,id2` targets specific cases.
- `tol`/`verdict`-only edits never bake — that stays `mix twicpics.reauthor` (no
  network), same as imgproxy.

### Source hosting handshake

The oracle fetches its input over the network, so the committed source bytes must
be **byte-identical** to what TwicPics fetched, or the two render different
inputs.

1. For each catalogued source: if it has a recorded hosted URL, reuse it;
   otherwise **upload to catbox automatically** (anonymous `reqtype=fileupload`)
   and capture the returned URL. The `imagepipe.twic.pics` path is configured as a
   catch-all over `files.catbox.moe`, so an uploaded catbox file is reachable at
   `imagepipe.twic.pics/<id>.<ext>`.
2. **v1 reuses the already-hosted grid `b7g72c.png` as-is** — the 400×400 RGBA
   colour grid from the #321 probe (4×4 cells of 100px). The full initial scope
   (asymmetric targets, ratio forms, anchors, crop region) is exercised on this
   square source, so **no upload is needed for this branch**; the upload path is
   built for future sources (e.g. a non-square grid).
3. The bake downloads the bare hosted source bytes and commits them under
   `sources/`, recording sha256 + hosted URL. ImagePipe renders against these
   committed bytes via a local source plug (same as the imgproxy harness).
4. Determinism pins on every request: `output=png`, no path-default
   manipulation. (`dpr=1` from the probe's suffix was dropped during
   implementation: the live default DPR is already 1× — verified byte-identical
   with and without `dpr=1` — and ImagePipe's parser doesn't implement `dpr`, so
   pinning it would only break the shared render path with no determinism gain.)
   The grid's 16
   well-separated colours survive PNG palette quantization intact, and nearest-cell
   decode absorbs any residual encoder noise, so no `truecolor` pin is required.

### Source-identity verification

The default lane verifies committed sources match the manifest's recorded hashes
(as imgproxy does). The bake additionally **re-verifies the remote hosted bytes
still match** the committed hash before trusting any fixture, so a silently
changed hosted file surfaces as a clear error rather than a confusing mismatch.

## Shared `Differential` extraction

Both suites route through a new shared `test/support/.../differential/` namespace
(`ImagePipe.Test.Differential.*`). The imgproxy suite is refactored to use it —
a mechanical, contained change; its tests and tuned tolerances stay green.

Extracted (genuinely identical, stable):

- **`Differential.ManifestTerm`** — the stable Elixir-term serializer
  (`sorted_map_literal`, the `write!` formatter dance, `file_sha256`,
  `authored_sha256` with configurable authored-key list). Each suite keeps its own
  `validate!`/entry shape and delegates serialization here.
- **`Differential.Harness`** — the local-source render factory, parametrized by
  parser + sources spec + base dir + path fn. imgproxy's harness becomes a thin
  wrapper.
- **`Differential.ReportShell`** — HTML page chrome: skeleton, CSS, comparison
  slider, base64 PNG inlining, attention-sort + top-of-page counts. Each suite
  supplies its own per-case row body.
- **`Differential.Heatmap`** — generic two-same-dim-images → banded-over-threshold
  + raw-amplified diff-image renderer. (imgproxy's `PixelCompare` keeps its
  delta/outlier *metric* logic — that is its gate; only the image-rendering half
  is shared.)

Not shared (suite-specific): the comparator (pixel-delta metric vs cell-map),
record schema, constellation lists, per-case report body.

## TwicPics suite modules

Under `test/support/image_pipe/test/twicpics_differential/`, mirroring imgproxy:

- **`SourceInventory`** — catalogue of committed sources (dims/bands/format/
  interpretation/hosted URL/produced-by/consumers/invariant), drift-checked by a
  dedicated test (decode every file; fail if inventory and bytes disagree, a
  source is added/removed without an entry, or a constellation references an
  uninventoried source).
- **`Constellations`** — the case list. **Full initial scope:** `focus`
  (anchor/relative/pixel + carry-through), `crop` (guided + `@coords` region with
  focus reset), `cover` (size + ratio), `contain`, `inside` (letterbox).
- **`Manifest`** — own `validate!`/entry shape; serialization via
  `Differential.ManifestTerm`. Records: TwicPics API version (`v1`), bake
  timestamp, any TwicPics version response header (provenance), per-source hosted
  URL + sha256, per-case `{authored_sha256, oracle_signature, structural record,
  reference PNG filename + sha256}`.
- **`StructureCompare`** — the cell-map extractor/comparator (a productized probe
  `classify`): a `Vix.Vips.Image` + relative lattice + grid spec + tolerances →
  `%{dims, bands, cells}`; plus `equal?`/`diff` between two records.
- **`Harness`** — thin wrapper over `Differential.Harness` (parser
  `ImagePipe.Parser.TwicPics`, the committed grid source, TwicPics URL path fn).
- **Mix tasks** (in `test/support/mix/tasks/`, `preferred_envs: :test`):
  `twicpics.gen_fixtures` (incremental bake, above), `twicpics.diagnose`
  (per-case structural diff, no network), `twicpics.gen_report` (HTML report, no
  network), `twicpics.reauthor` (tol/verdict-only, no network).

### Conformance test

`test/image_pipe/twicpics_differential_conformance_test.exs`, `async: true`,
default `mix test` lane, **no network**:

- Iterate `Constellations.all/0`; per case assert `authored_sha256` unchanged
  (else: run `reauthor` or re-bake), render ImagePipe live, extract structure,
  compare to the committed record: **dims exact, bands exact, cell-map exact**
  (colour/alpha tolerance only inside the per-sample decode).
- `verdict: :diverges` compares against the recorded **ImagePipe-divergent**
  structure + rationale, so a regression in either direction is caught.
- `triage:` → `@tag :twicpics_triage`, excluded by default in
  `test/test_helper.exs`; runnable with `--include twicpics_triage`. Covers
  parser gaps (TwicPics accepts a chain ImagePipe's parser does not yet) and
  untriaged divergences.
- A `"committed sources match the manifest's recorded hashes"` test.

### Report

`mix twicpics.gen_report` writes a self-contained `report.html` (gitignored;
inlines PNGs as base64), no network. Per case: oracle-vs-ImagePipe PNG slider, the
decoded **cell-map overlay** (which cell each sampled point read), dims/bands and
verdict, and — where dims+bands match — the two **informational pixel heatmaps**
(banded + amplified). The heatmaps are explicitly labeled *informational, engine
differences expected, not a gate*; they exist for eyeballing how close the
foreign engine landed. Attention cases (over-tolerance, quarantined, dims/bands
mismatch, a `:diverges` case that now matches, authored-hash or source-hash drift)
sort to the top with a counts summary. The full-render smoke test is tagged and
excluded by default.

## Docs

- A suite `README.md` mirroring the imgproxy differential README: the
  bake → diagnose → tolerance → quarantine workflow, the mix-task conventions, and
  the TwicPics-specific notes (structural-not-pixel, the catbox source-hosting
  handshake, incremental bake, no libvips provenance).
- A note in `docs/twicpics_support_matrix.md` pointing to the standing
  differential suite (as imgproxy's matrix references its differential lane). Any
  divergence the bake surfaces updates the matrix per the conformance-doc rule in
  `AGENTS.md`.

## Boundaries

The shared and per-suite modules are test support: `use Boundary, top_level?:
true` (with `check: [out: false]` where they render through `ImagePipe.Plug`,
matching the existing imgproxy harness). `SourceInventory` carries `deps: []`.

## Out of scope (later expansion)

`zoom`, `turn`/`flip`, conditional `-min`/`-max`/`resize-max`/`resize-min`,
colour/alpha transforms, a non-square or alternate-resolution grid source
(exercising the catbox upload path), and any tight pixel compare for the rare
cases where TwicPics and libvips genuinely agree.

## Implementation notes for the plan

- The existing `tools/twicpics_focus_probe.exs` stays as an exploratory tool; this
  suite supersedes its ad-hoc role for the covered cases.
- The plan-review cycle must include a **TwicPics-compatibility reviewer** (per
  `AGENTS.md`), confirming the baked structural records and any `:diverges`
  entries reflect real live-TwicPics behavior, not just internal correctness.
- This branch's first bake fetches the full initial scope (all cases missing);
  thereafter the incremental bake is delta-only.
