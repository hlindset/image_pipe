# TwicPics differential conformance — fixtures

Reference fixtures generated from the live hosted TwicPics Image API. The
comparison test (`test/image_pipe/twicpics_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no network in the hot path. It decodes both
TwicPics' committed output and one live `ImagePipe.Dialect.TwicPics` render per
constellation, then compares pixels.

TwicPics is **libvips-based** — the same engine ImagePipe renders with — so per-pixel
comparison is the right, stricter gate, not the foreign-engine mismatch the suite
originally assumed. The initial 30-fixture spike found 19 byte-identical outputs. The
suite now contains 39 fixtures, all on the default lane: five accepted divergences
remain inside two-sided bands and the other 34 are asserted `:equal`. The five
monitored cases are the two fractional `cover=2:3` renders and the three transparent
letterbox-under-shrink renders listed under *Verdicts*.

## Bake (requires network)

After adding or editing a constellation in `constellations.ex`, run:

```shell
mise run twic:bake
```

It bakes every fixture + `manifest.exs` + `REPORT.md` against the live hosted
TwicPics API (incremental — unchanged cases are skipped with zero requests). A parse
gate validates every non-triaged constellation's chain first and aborts (listing the
offenders) before any oracle call, so a typo or unsupported chain fails fast. A
`triage`-quarantined constellation is skipped by the gate but still baked — see
*Quarantine mechanism*.

Then review the `REPORT.md` diff, run `mix twicpics.diagnose` on any failures (see
below), and commit the changed `fixtures/`, `manifest.exs`, and `REPORT.md`.

For a `tol` tweak or a verdict-only edit (no pixels change), skip the bake and
refresh the manifest's authored hashes: `mix twicpics.reauthor`.

```
mise run twic:bake                           # incremental
mix twicpics.gen_fixtures --force            # re-bake all cases
mix twicpics.gen_fixtures --only id1,id2     # re-bake specific cases
```

(`twicpics.gen_fixtures`, `twicpics.diagnose`, `twicpics.gen_report`, and
`twicpics.reauthor` auto-select `MIX_ENV=test` via `mix.exs` `preferred_envs` — no
prefix needed; the network bake goes through `mise run twic:bake`.)

## Determinism pins

Every constellation pins `output=png`. `dpr` is intentionally omitted: the live
TwicPics default DPR is already 1x — verified byte-identical output with and without
`dpr=1` — and the ImagePipe dialect does not implement `dpr`, so pinning it
would break the local render path with no determinism gain. No path-default
manipulation.

## libvips provenance — record both, compare anyway

TwicPics renders with libvips. Its responses carry a `Server: TwicPics/1.8.2` header,
recorded as `twicpics_version` in `manifest.exs`. Fixtures are baked by TwicPics'
libvips; ImagePipe runs its own (`Vix.Vips.version()`, recorded as
`pipe_libvips_at_gen` at bake time). The two are independent libvips builds, so a
pixel diff can be a kernel-version skew rather than an ImagePipe regression.

The conformance test therefore makes no version-match claim: it always runs the pixel
comparison and emits a `libvips_drift_hint` when the runtime libvips differs from the
recorded `pipe_libvips_at_gen`, so a failure can be read as version skew vs a real
divergence — read the hint when triaging. The `:equal` tolerances absorb minor
resampling skew between libvips versions.

## Source inventory (keep it in sync)

Every committed source in `sources/` is catalogued in
[`source_inventory.ex`](source_inventory.ex)
(`ImagePipe.Test.TwicpicsDifferential.SourceInventory`) — its dims, bands, format,
interpretation, embedded-profile presence, how it is produced, who consumes it, and
the invariant it must preserve. That module is the single source of truth.

- **It is drift-checked.** `test/image_pipe/twicpics_source_inventory_test.exs`
  decodes every file and fails if the inventory and the bytes disagree (dims, bands,
  format, interpretation, profile?), or if a source is added or removed without an
  entry. The complementary "every constellation source is inventoried" check lives in
  `test/image_pipe/twicpics_differential/constellations_test.exs` (it needs
  `Constellations`). Adding, removing, or regenerating a source means updating its
  entry — the tests enforce it.

### Source-hosting handshake (catbox)

Sources are hosted on catbox and served to the live oracle through the
`imagepipe.twic.pics` catch-all path. The committed source bytes **must equal the
hosted bytes**: TwicPics renders the hosted file, not the local one, so a mismatch
means ImagePipe and TwicPics are rendering different inputs.

The bake verifies this automatically before selecting a fixture: for each source it
downloads the bytes from the `source_bytes_url` recorded in `SourceInventory` and
compares their SHA-256 to the committed file. It then requests the recorded
`hosted_url` with `?twic=v1/output=png`, decodes that TwicPics identity render, and
requires its dimensions, bands, and pixels to equal the decoded committed source. An
encoded-byte comparison would be wrong here because the committed source can be WebP
while the identity response is pinned PNG.

The seed source (`grid_4x4.png`) is a 400x400 RGBA colour grid from the #321 focus
probe, uploaded to catbox and served via
`https://imagepipe.twic.pics/b7g72c.png`.

Adding a source is a fail-closed two-run handshake:

1. Add the source file and an inventory entry with both `source_bytes_url` and
   `hosted_url` set to `nil`, then run the bake. It uploads once, prints both exact
   values, and aborts before any fixture request or write.
2. Record both values in `SourceInventory` and run the bake again. The second run
   verifies the direct Catbox bytes and the TwicPics identity render before the first
   fixture transformation.

An entry with only one URL is invalid, and a URL remembered by an older manifest never
completes inventory metadata. Any direct-byte or identity-render mismatch stops the
bake before fixture writes, report generation, or orphan pruning.

## Incremental bake

The oracle signature is `{chain, output suffix, source-byte identity}`. A case is
skipped (zero requests) when all three hold:

1. The signature matches the prior manifest entry.
2. The committed reference PNG is present.
3. The PNG's SHA-256 matches the manifest's recorded hash.

A no-op re-bake (nothing changed) is idempotent: `baked_at` is preserved and no git
churn is produced. `--force` re-bakes everything; `--only id1,id2` re-bakes specific
cases and keeps all others from the prior manifest (no requests for unlisted cases).

The bake prunes orphaned manifest entries and reference PNGs when a constellation is
deleted — run it after removing a case to clean up.

## Visual-diff report (no network)

Generate a self-contained `report.html` for eyeball triage — TwicPics vs ImagePipe
side by side, a comparison slider, and three diff heatmaps (banded over the case
threshold, raw amplified, and normalized), with the live-recomputed
metric/verdict/triage per case:

```shell
mise exec -- mix twicpics.gen_report             # writes report.html here
mise exec -- mix twicpics.gen_report --out /tmp/r.html
```

It renders ImagePipe live and reads the committed fixtures — no network, no fixture or
manifest changes. The default `report.html` is gitignored (it inlines ImagePipe PNGs
as base64; regenerate on demand). Cases needing attention sort to the top
(attention-sort, flagged first) and a top-of-page counts line summarizes them; status
and group filter axes narrow the view. Triaged/quarantined cases are included in the
report (they are the ones most worth eyeballing).

The end-to-end smoke test that renders the report across every constellation is tagged
`:twicpics_report` and excluded by default in `test/test_helper.exs` (it bakes every
constellation + inlines PNGs — slow, and not unit coverage). The
`mix twicpics.gen_report` task above is unaffected; to run the test itself:
`mise exec -- mix test test/image_pipe/twicpics_gen_report_test.exs --include twicpics_report`.

## Triage a bake (no network)

When a freshly baked case fails the conformance lane, `mix twicpics.diagnose` prints a
one-line summary per constellation — output dims, band layout, the maximum per-sample
delta (`maxΔ`), a `>Δ2`/`>Δ16`/`>Δ32` histogram, and PASS/over-budget against the
authored tol — by rendering ImagePipe live against the committed fixture (the same
`Harness` the conformance test uses). It includes triaged cases.

```shell
mise exec -- mix twicpics.diagnose cover_wide contain_tall   # specific cases
mise exec -- mix twicpics.diagnose                            # whole suite
```

**Reading it — skew vs structural.** Each comparable line ends with a
`structural=N (r1) → …` field, the neighborhood-aware
`PixelCompare.structural_outliers/3` count (radius 1): differing band-samples whose
value is **not** explainable by the reference's local range, i.e. not a blend of its
neighborhood. It makes the skew-vs-structural call quantitative rather than
eyeballing `maxΔ`:

- **Diffuse resampling/sub-pixel skew** (a libvips-version difference or fractional-area
  phase, not a bug) keeps `maxΔ` low — tens of levels — and `structural` a small
  minority of the Δ2 diff (the line reads `→ resampling/phase`). Absorb with a tolerance,
  or — for an accepted permanent difference — a `:diverges` band (see *Verdicts*).
- **A placement/crop/scale shift** misaligns high-contrast edges, pushing `maxΔ`
  toward ~255 and making `structural` the *majority* of the diff (`→ geometry shift`).
  That is a real divergence — never widen a tol to hide it; fix it, or quarantine
  (`:triage` + a tracking issue) while investigating.
- **A band/dim mismatch** prints `FINDING` (not pixel-comparable) — itself a
  divergence.

`structural_outliers` is a triage aid only — it is **not** asserted by the conformance
test (it has tuning knobs: `radius`, `value_tol`, `overshoot`).

### Verdicts

- **`:equal`** (default) → assert ImagePipe matches TwicPics within the per-case `tol`
  budget. On the lane.
- **`:diverges`** → an *accepted, monitored* divergence: assert the live diff sits inside
  an expected two-sided band (`divergence: %{reason, max_delta: lo..hi, outliers: lo..hi,
  issue}`, evaluated by `PixelCompare.classify_divergence/3`). Stays **on the lane** — it
  fails if the divergence *grows* (regression, above the ceiling) or *shrinks/vanishes*
  (promote signal, below the floor → consider returning the case to `:equal`). Use it for
  a real, understood, permanent difference, not one under active investigation. The five
  current cases are `cover_ratio_tall` and `focus_bottomright_cover_ratio` for fractional
  `cover=2:3` resampling, plus `inside_ratio_cover_shrink`,
  `inside_ratio_focus_anchor_cover_shrink`, and `inside_ratio_focus_px_cover_shrink` for
  invisible RGB-under-alpha differences in transparent letterboxes during shrink-on-load.
  `:divergence` is an authored field, so editing a band needs `mix twicpics.reauthor` (no
  re-bake — bands don't change pixels).
- **`:triage`** → a divergence *under investigation*: `@tag :twicpics_triage`, **excluded**
  from the default lane (see *Quarantine mechanism*).

**Tolerance conventions** (`tol: %{threshold, budget}` on the constellation; default
`Δ2 / budget 64`):

- The 8 focus-cover skew cases use `Δ16 / 64` — threshold just above the measured
  maxΔ=12, with a tight budget so a structural shift still blows it.

After changing only a `tol`, refresh the authored hashes with `mix twicpics.reauthor`
(no network) rather than re-baking.

## Quarantine mechanism

A constellation can be quarantined while a discrepancy is being triaged: set a
`:triage` key on its constellation map (a short reason + tracking issue). The
comparison test tags it `:twicpics_triage`, which `test/test_helper.exs` excludes by
default, so a plain `mix test` stays green and the case shows as skipped rather than
failed. Run the quarantined cases with:

```shell
MIX_ENV=test mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs --include twicpics_triage --only twicpics_triage
```

`:triage` is not an authored field, so quarantining or un-quarantining alone does not
require a manifest reauthor. The bake still fetches oracle output for triaged cases
(the parse gate skips them, but the bake runs them — only the conformance comparison
is quarantined).

**Current quarantined cases (0).**

Phase 2B closed the last one: [#464](https://github.com/hlindset/image_pipe/issues/464)
(`resize_shadow_relative_then_absolute`, `resize=50p/resize=340`). TwicPics discards the
shadowed relative resize and returns the same 340×340 bytes as direct `resize=340`;
`ImagePipe.Dialect.TwicPics.Shadow` now reproduces that, so the case is an asserted
`:equal` case against the unchanged committed fixture rather than a quarantine.

**Current monitored divergences (5).**

- `cover_ratio_tall` (`cover=2:3`) and `focus_bottomright_cover_ratio`
  (`focus=bottom-right/cover=2:3`) are tracked by
  [#331](https://github.com/hlindset/image_pipe/issues/331). The largest 2:3 area on the
  400×400 source is
  266.667-wide (fractional). TwicPics sub-pixel-resamples that float area to the rounded
  267-wide output, antialiasing the cropped-axis cell edges; ImagePipe does a sharp
  integer crop. Placement matches to sub-pixel — only the boundary lines differ
  (`structural` ≈ a small minority of the diff) — so this is a resampling divergence,
  not a placement bug. It is **not** absorbed by widening tolerance: the haloing spans
  whole boundary lines (~thousands of band-bytes over Δ2), so a tolerance large enough to
  pass would also mask a real half-cell shift — hence a two-sided `:diverges` band, which
  rejects both a growing shift and a now-byte-identical match. The integer-area direction
  (`cover=16:9` → `cover_ratio_wide`) stays a live `:equal` case and is byte-identical.
  See the `cover=W:H` "Diverges" note in `docs/twicpics_support_matrix.md`.

- [#434](https://github.com/hlindset/image_pipe/issues/434) tracks
  `inside_ratio_cover_shrink`, `inside_ratio_focus_anchor_cover_shrink`, and
  `inside_ratio_focus_px_cover_shrink`. A later cover triggers 2×
  WebP shrink-on-load through the transparent `inside=<ratio>` letterbox. TwicPics and
  ImagePipe resample the RGB stored beneath alpha=0 differently; the difference is
  invisible, and opaque content matches. The two-sided band still catches a placement
  shift because that would dirty the opaque gradient rather than only transparent pixels.

The third originally-quarantined case, `crop_region_reset`, was a real ImagePipe bug,
not a sub-pixel skew: `crop=WxH@XxY` was **resetting** the carried focus to the
crop-result centre, but live TwicPics **carries** the focus through the region crop
(translated + clamped). Fixed to carry; it is replaced by the discriminating
`crop_region_carry_far` / `crop_region_carry_near` pair (same region crop, different
pre-region focus → the carried point steers the trailing crop to a different cell
boundary; a reset would center both identically).

## Reauthor does not prune

`mix twicpics.reauthor` refreshes the `authored_sha256` for every manifest entry from
the current constellation list. It does **not** prune orphaned entries or reference
PNGs. If you delete a constellation, re-bake (`mise run twic:bake`) to remove its
manifest entry and PNG.

(`reauthor` raises with a clear message if an entry has no matching constellation, so
you cannot silently accumulate orphaned entries.)

## Source discrimination (caveats)

The flat colour-grid source has high discriminating power for *placement* but low for
*resampling*: only the cell edges carry signal, so a sub-cell resampling difference is
nearly invisible. A few small crops land entirely inside a single uniform cell
(`contrast=0` in diagnose) — they pin output colour + dims but cannot catch a sub-cell
placement error. TwicPics *default* processing has so far only been characterized on
PNG downscales and crops; upscale, non-PNG output, and quality/chroma divergences are
unexplored and out of scope for this suite.

## Negative-focus rejection is out of scope

TwicPics 404s on negative-coordinate focus (`focus=-1x-1`); ImagePipe 400s. There is
no usable output to decode from either response, so this contract cannot be exercised
by the differential suite. It is covered by the dialect error and wire tests
(`test/image_pipe/twic_pics_wire_conformance_test.exs`).
