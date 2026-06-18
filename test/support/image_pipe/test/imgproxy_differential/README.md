# imgproxy differential conformance — fixtures

Reference fixtures generated from a pinned `darthsim/imgproxy` container. The
comparison test (`test/image_pipe/imgproxy_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no Docker in the hot path. It decodes both
imgproxy's committed output and ImagePipe's live output and compares pixels.

## Regenerate (requires Docker)

After adding or editing a constellation in `constellations.ex`, run:

```shell
mise run diff:bake
```

It bakes every fixture + `manifest.exs` + `REPORT.md` against the pinned container and
restores the default-lane build — no manual `IMGPROXY_DIFF` / Ryuk / recompile juggling.
A parse gate validates every constellation's path first and aborts (listing the
offenders) before the container starts, so a typo or unsupported option fails fast rather
than after a bake. (A `:triage`-quarantined constellation is skipped by the gate — see
*Quarantine mechanism* — so a known parser gap can sit in the suite without blocking the
bake.)

Then review the `REPORT.md` diff (not the binary PNGs) for what moved, run
`mix imgproxy.diagnose` on any failures (see below), and commit the changed `fixtures/`,
`manifest.exs`, and `REPORT.md`.

For a `tol` tweak or a `:diverges`→`:equal` flip (no pixels change), skip the bake and
refresh the manifest's authored hashes: `mix imgproxy.reauthor`. Rebuild the source
images only deliberately (a libvips bump must not silently change inputs):
`mix imgproxy.gen_sources`.

> **`gen_sources` rewrites EVERY source file**, not just the one you changed — so a
> libvips bump on your machine can silently alter `marker.png`, the `exif_*` set, etc.
> After running it, **`git status sources/` and confirm only the files you intended
> changed**; revert any incidental drift (`git checkout -- sources/<file>`). Then
> **re-bake** (changed source bytes ⇒ stale fixtures + a stale manifest source-hash).

(`imgproxy.reauthor`, `imgproxy.gen_sources`, `imgproxy.gen_report`, and
`imgproxy.diagnose` auto-select `MIX_ENV=test` via `mix.exs` `preferred_envs` — no prefix
needed; the Docker bake goes through `mise run diff:bake`.)

## Source inventory (keep it in sync)

Every committed source in `sources/` is catalogued in
[`source_inventory.ex`](source_inventory.ex)
(`ImagePipe.Test.ImgproxyDifferential.SourceInventory`) — its dims, bands, format,
interpretation, embedded-profile presence, **how it's produced, who consumes it, and
the invariant it must preserve**. That module is the single source of truth; there is
no separate Markdown table to drift.

- **It is drift-checked.** `test/image_pipe/imgproxy_source_inventory_test.exs` decodes
  every file and fails if the inventory and the bytes disagree, if a source is
  added/removed without an entry, or if a `Constellations` source isn't inventoried.
  **Adding, removing, or regenerating a source means updating its entry** — the test
  enforces it. (Byte-level drift of an *unchanged* source is separately caught by the
  conformance test's "committed sources match the manifest's recorded hashes" check.)
- **Sources are shared beyond the bake.** Several sources are also consumed by unit
  tests — above all the color-management suite, which depends on a source carrying an
  embedded ICC profile (`cmyk.jpg`, `icc_p3.png`) or a specific bit depth / alpha
  (`rgb16`/`rgba16`). The `consumers` field flags these; **a source change can break a
  test outside the differential suite**, so check the consumers before regenerating.
- **All sources are now produced by `mix imgproxy.gen_sources`** — none are
  hand-committed. If you add one, add it to the task *and* the inventory.

## Visual-diff report (no Docker)

Generate a self-contained `report.html` for eyeball triage — imgproxy vs ImagePipe
side by side, a comparison slider, two diff heatmaps (banded over the case threshold,
and raw amplified), and the live-recomputed metric/verdict/triage per constellation:

```shell
mise exec -- mix imgproxy.gen_report          # writes report.html here
mise exec -- mix imgproxy.gen_report --out /tmp/r.html
```

It renders ImagePipe live and reads the committed fixtures — no Docker, no fixture or
manifest changes. The default `report.html` is gitignored (it inlines ImagePipe PNGs as
base64; regenerate on demand). Cases needing attention (over-budget, quarantined,
dims-mismatch, a `:diverges` case that now matches, or authored-hash drift) sort to the
top, and a top-of-page counts line summarizes them. The slider and Geist fonts load from
a CDN; with no network the side-by-side panels remain the source of truth.

The end-to-end smoke test that renders the report across every constellation
(`ImagePipeGenReportTest`'s full-render case) is tagged `:imgproxy_report` and excluded by
default in `test/test_helper.exs` (it bakes every constellation + inlines PNGs — slow, and
not unit coverage). The `mix imgproxy.gen_report` task above is unaffected; to run the test
itself: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs --include imgproxy_report`.

## Triage a bake (no Docker)

When a freshly baked case fails the conformance lane, `mix imgproxy.diagnose` prints a
one-line summary per constellation — output dims, band layout, the maximum per-sample
delta, a `>Δ2`/`>Δ16`/`>Δ32` histogram, and PASS/over-budget against the authored tol —
by rendering ImagePipe live against the committed fixture (the same `Harness` the
conformance test uses):

```shell
mise exec -- mix imgproxy.diagnose exif_extend_south trim_resize_high_freq   # specific cases
mise exec -- mix imgproxy.diagnose                                           # whole suite
mise exec -- mix imgproxy.diagnose --undiscriminating                        # only near-uniform fixtures
```

**Discrimination — `contrast=N`.** Each transform line also reports the imgproxy
fixture's largest per-band *spatial* range (`PixelCompare.spatial_contrast/1`, 0..255
levels). A near-zero value (`⚠ near-uniform`) means the fixture is spatially flat, so a
placement/crop error would move the window within a uniform field and yield identical
pixels — the case passes at `maxΔ=0` but cannot *catch* a regression (the marker
dead-region crops, [#239](https://github.com/hlindset/image_pipe/issues/239)). The flag
is informational, not a gate: a dims-based test (`trim`) can be legitimately uniform
inside, since its signal is the output dimensions. `--undiscriminating` lists only the
flagged cases — a separate axis from `--failing` (correctness). It measures per-band
*spatial* range, not band-byte range, so a uniform `[200,180,60]` fill reads 0, not 140.

**Reading it — skew vs structural.** Each comparable line ends with a
`structural=N (r1) → …` field, the neighborhood-aware
`PixelCompare.structural_outliers/3` count (radius 1): differing band-samples whose value
is **not** explainable by the reference's local range. It makes the call below
quantitative rather than eyeballing `maxΔ` alone:

- **Diffuse resampling skew** (a libvips-version difference, not a bug) keeps `maxΔ` low —
  tens of levels — and `structural` a small minority of the Δ2 diff (`→ resampling/phase`).
  Absorb it with a tolerance.
- **A placement/crop/scale shift** misaligns high-contrast edges, pushing `maxΔ` toward
  ~255 and making `structural` the *majority* of the diff (`→ geometry shift`). That is a
  real divergence — never widen a tol to hide it; quarantine (`:triage` + a tracking
  issue) or fix.
- **A band/dim mismatch** prints `FINDING` (not pixel-comparable) — itself a divergence
  (e.g. an extend that adds a spurious alpha channel, #220).

`structural_outliers` is a triage aid only — it is **not** asserted by the conformance
test. (For an accepted, permanent divergence rather than a bug, a `verdict: :diverges`
case asserts the diff inside an expected two-sided band on the lane instead of being
excluded — the shared mechanism is wired here, though no imgproxy case uses it yet.)

**Tolerance conventions** (`tol: %{threshold, budget}` on the constellation; default
`Δ2 / budget 64`):

- Sharp-edge sources (`marker`/`border`) with a small AA seam at one edge: keep the
  **strict Δ2** threshold and widen only the **budget** just above the measured seam —
  more sensitive than raising the threshold, since a structural shift blows the budget.
- Zone-plate / heavy-downscale sources (`high_freq`, rotated EXIF blocks): the skew is
  diffuse and higher-amplitude, so set the **threshold just above the measured `maxΔ`**
  with a tight budget (Δ32 is typical; the worst cells need more).
- 16-bit (HDR) sources (`rgb16`/`rgba16`): the comparison reconstructs each 16-bit
  sample and normalizes deltas to **8-bit-equivalent levels**, so the same `Δ2`/budget
  vocabulary applies across bit depths — author a 16-bit fixture's tol in levels, not in
  raw 16-bit units. (Comparing raw bytes would split a sample into hi/lo halves and read
  a hair of 16-bit noise as a low-byte blow-out.)

After changing only a `tol`, refresh the authored hashes with `mix imgproxy.reauthor`
(no Docker) rather than re-baking.

## Choosing constellations — oracle-branch boundary testing

Black-box combinatorics (pairwise, random interior values) burns bake budget on
PASS-confirmations — they tend to land at `maxΔ=0` and tell you nothing you didn't
already trust. The high-yield approach is grey-box, because we *have* imgproxy's source (a local
`darthsim/imgproxy` checkout): **the oracle's source is the test-selection spec.** Three
moves:

1. **Enumerate imgproxy's parameter-relationship branches.** Every `if` in
   `processing/prepare.go` / `gravity.go` / `crop.go` / `extendImage` that turns on a
   *relationship between parameters* (not a constant) is a regime boundary. A branch is
   the one place two implementations can disagree about which side to take — and every
   structural divergence found so far was exactly one: #200 (`calcPosition` offset
   clamp), #220 (`extendImage` early return `w<=imgW && h<=imgH`), #233 (fill-vs-fit
   `sign(W−H)` bucket), #236 (`minShrink < wshrink`, mw/mh vs target), #237 (`DprScale`
   cap with no resize).

2. **Flip each branch to its MINORITY side and check whether any fixture sits there.**
   ImagePipe almost always ports the common side correctly (it's what the demo and the
   obvious tests exercise); the rare side is where a port is missing or subtly wrong. The
   hot cell is a branch whose minority side **no existing constellation occupies**. #236's
   tell: every cover fixture had `mw/mh ≤ target` (inert side); none crossed to
   `mw/mh > target`, so the missing crop-back logic was invisible.

3. **Cross two independent minority-side branches.** ImagePipe realizes the pipeline
   *differently* from imgproxy — deferred orientation, a separate result-crop op, the
   single-round scale fold — so when two branch conditions are simultaneously on their
   minority side, ImagePipe's different *order/frame of evaluation* is where an error
   compounds. The whole #182 family is `orientation-pending` × `frame-sensitive op`.

Then **push the numeric boundary inside the hot cell**: odd-vs-even surplus, square
(`D==0`), sub-pixel, an offset that clamps *exactly* at the edge, a focal fraction at 0/1.
That is where `RoundToEven` / `ShrinkToEven` / sign-bucket mistakes hide.

**Two yield categories — tag them, and don't conflate the triage effort:**

- **Bug-hunt** (branch-boundary crossings) — structural divergences live here; high
  triage cost, high value.
- **Realization coverage** (ImagePipe code written-to-match-imgproxy but never
  differentially checked — e.g. fp-coordinate rotation under EXIF) — mostly PASS, but a
  wrong port is otherwise *invisible*. Cheap insurance; author `:equal` and don't
  over-triage.

**The sharpest signature so far** (both #236 and #237): *a cap or box computed inside the
resize handler and silently skipped on a sibling path* — the `mw/mh > target` cover crop
in #236, the no-resize padding DPR cap in #237. "No resize present" is itself a minority
branch for any quantity whose scaling is derived during resize handling (padding,
extend-canvas scale, zoom fold, clamp). Any resize-derived value consumed on a
no-resize or boundary path is a prime suspect.

**Anti-patterns:** random interior-value combos (≈all `maxΔ=0`); exhaustive crossing
(combinatorial blow-up, and most cells redundantly hit the same branch); widening a `tol`
to bury a structural shift (`maxΔ ≪ 255` is the skew tell — a real placement shift is
~255; see *Triage a bake*). PASS-confirmations are worth keeping as regression pins, but
they are cheap insurance, not the bug-hunt.

## The per-PR loop (driving rules)

The bake is the oracle: `gen_fixtures` runs the pinned container, so imgproxy's output
can't be authored wrong — only a constellation's `verdict` and `tol` are. Treat any
DIVERGE/PASS prediction (e.g. in a backlog issue) as a **triage prior**, not arithmetic to
re-derive by hand. A fixture-only change (adding or retuning constellations, no `lib/`
change) needs no written plan or review cycle.

**Batch size is not capped.** One regen bakes every changed fixture at once and no human
gates the `REPORT.md` diff, so a PR may add as many fixtures as is coherent to land
together. The only cost that doesn't amortize across a single bake is per-divergence
triage, which concentrates in genuine bug-hunts — the PASS-confirmation bulk is nearly
free.

1. Translate each backlog item into a `constellations.ex` entry (real parser forms;
   `verdict: :equal` by default, `:diverges` only for a known algorithmic divergence).
2. `mise run diff:bake` — one regen covers every changed fixture.
3. `mix imgproxy.diagnose` the failures and sort each: PASS at default → keep; skew over
   budget → set `tol` + a one-line rationale, `mix imgproxy.reauthor`; genuine divergence
   → quarantine (`:triage` + a tracking issue) or fix. Never widen a tol to hide a
   structural shift (`maxΔ` ≪ ~255 is the skew signal — see *Triage a bake*).
4. Green the default lane (`mix test`) + the precommit gate.
5. Sync docs (`docs/imgproxy_support_matrix.md` if a coverage/divergence claim moved).

## libvips provenance — record both, compare anyway

Fixtures are baked by the container's libvips, recorded as `imgproxy_libvips` in
`manifest.exs`. That value is the bundled `.so` **ABI soname** (e.g. `42.20.2`): the
darthsim image exposes no libvips *release* string and ships no `vips` CLI. ImagePipe's
own libvips reports only its **release** (`Vix.Vips.version()`, e.g. `8.18.2`). The two
are different version schemes with no clean conversion, so they cannot be compared
directly — and ImagePipe tracks a bleeding-edge libvips (via the custom Vix fork) while
imgproxy lags, so they would differ regardless.

The harness therefore makes no version-match claim: it always runs the pixel comparison
and emits a one-time provenance note carrying both versions, each tagged with its scheme
(the `:equal` tolerances absorb minor libvips-version resampling differences). A failure
may still reflect a libvips-version difference rather than an ImagePipe regression — read
the note's two versions when triaging. (`:diverges` constellations pin an algorithmic
divergence, not a kernel-version one, so they are unaffected.)

## Quarantine mechanism

A constellation can be quarantined while a discrepancy it surfaced is triaged: set a
`:triage` key on its constellation map (a short reason + tracking issue). The
comparison test then tags it `:imgproxy_triage`, which `test/test_helper.exs` excludes
by default, so a plain `mix test` stays green and the case shows as skipped rather than
failed. Run the quarantined cases with:

```shell
MIX_ENV=test mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs --include imgproxy_triage
```

`:triage` is not an authored field, so quarantining or un-quarantining alone does not
require a manifest reauthor. The current set of quarantined cases (and the tracking issue
each points to) lives in `constellations.ex`, not here — read the `:triage` keys there.

Quarantine also covers a **parser gap**: a combination that *should* parse (imgproxy
accepts it) but ImagePipe's parser does not yet. Mark it `:triage` (reason + tracking
issue) and the pre-bake parse gate skips it, so it stays in the suite as a tracked gap —
imgproxy still bakes its fixture — without aborting the bake. Drop the `:triage` to light
it up once the parser supports the option.

