# Differential suites: `:diverges` verdict + structural-outlier triage signal — design

**Issue:** [#331](https://github.com/hlindset/image_pipe/issues/331)
**Date:** 2026-06-18
**Status:** approved (pre-implementation)

## Motivation

The differential conformance suites (imgproxy, TwicPics) classify each case as
`:equal` (assert pixels match within a tolerance budget) or quarantine it with
`:triage` (a known divergence under investigation, **excluded** from the default
lane). `:triage` has a blind spot: an excluded case is *unmonitored* — if its
divergence later **grows** (a regression) or **shrinks/vanishes** (a libvips update
makes it match, so it should be promoted back to `:equal`), the default lane never
notices. You only see it by running `--include …_triage` by hand.

That is the wrong treatment for a divergence that is **accepted and permanent** (not
under active investigation) — e.g. TwicPics' `cover=W:H` fractional-area resampling
(#331): TwicPics sub-pixel-resamples the largest matching-ratio area when its width is
fractional (`cover=2:3` on 400×400 → 266.667w), antialiasing the cropped-axis cell
edges, where ImagePipe does a sharp integer crop. Placement matches to sub-pixel; only
the boundary lines differ. This is real, understood, and won't change — it should be
*monitored within an expected band*, not excluded.

Widening the `:equal` tolerance to absorb it is not an option: the haloing spans whole
boundary lines (~3,800 band-bytes over Δ2 for `cover_ratio_tall`), and the gate only
checks *outlier-count ≤ budget*, so any budget loose enough to pass the haloing also
passes a 1px sharp shift (~3,600 outliers at maxΔ=255). The count metric alone cannot
tell them apart.

This design adds two things:

1. **A `:diverges` verdict** — a third case state (alongside `:equal` and `:triage`)
   that **stays on the default lane** and asserts the divergence sits in an expected
   two-sided band, failing if it grows (regression) or shrinks (promote signal).
2. **A `structural_outliers` triage signal** — a generic, neighborhood-aware metric
   that distinguishes resampling/phase artifacts from genuine geometry shifts,
   surfaced in the `diagnose` tasks. It is a **human triage aid, not a gate.**

Both build on the shared `ImagePipe.Test.Differential` layer so imgproxy and TwicPics
get them uniformly.

## Current architecture (what's shared vs per-suite)

- **Shared** (`ImagePipe.Test.Differential.*`): `PixelCompare` (incl. `diagnose`,
  `outliers`, `max_delta`, `over`), `ManifestTerm` (the `authored_sha256`
  canonicalizer), the report renderers (`report_ui`, `report_shell`, `heatmap`,
  base `harness`).
- **Per-suite, parallel** (`*_differential/`): `constellations`, `manifest` (each
  defines its own `@authored_keys`; **both already list `:divergence`**),
  `source_inventory`, `report_html`, the thin harness wrapper, the `gen_fixtures`
  bake task, and the conformance test (`*_differential_conformance_test.exs`).

The `:divergence` authored key + the imgproxy manifest round-trip test
(`%{metric: :fraction_over, threshold: 2, floor: 0.01, issue: "#124"}`) are
**dormant scaffolding** — no constellation populates `:divergence`, and neither
conformance test asserts it. This design **activates** it, **extends** the dormant
`floor`-only sketch to a two-sided band, and puts the evaluation in the shared layer
so both suites share the *behavior*, not just the primitives.

## Part 1 — the `:diverges` verdict (conformance gate)

### Constellation shape

A case opts in with `verdict: :diverges` + a `divergence:` map:

```elixir
c("cover_ratio_tall", "cover=2:3", :cover,
  verdict: :diverges,
  divergence: %{
    reason:
      "Largest 2:3 area is fractional (266.667w); TwicPics sub-pixel-resamples it to " <>
        "the integer output (cell-edge antialiasing), ImagePipe integer-crops. Placement " <>
        "matches to sub-pixel. Permanent — see cover=W:H Diverges note.",
    max_delta: 60..160,
    outliers: 3_000..4_600,
    issue: 331
  }
)
```

- `reason` (required, string): free-text justification — why this divergence is
  accepted/permanent.
- `max_delta` (required, `Range`): the per-sample maxΔ (from `PixelCompare.diagnose`)
  must fall in this band.
- `outliers` (required, `Range`): the count of band-samples over the default Δ2
  threshold (`diagnose.over[2]`) must fall in this band.
- `issue` (optional, integer): tracking reference.

`:divergence` is already an authored key in both manifests, so editing a band trips
the existing `authored_sha256` "run reauthor" guard — no re-bake needed (bands don't
change pixels), exactly like `tol`. `verdict`, `:triage`, and `:divergence` are
mutually exclusive per case: `:equal` (default) → tolerance; `:diverges` → band (on
the lane); `:triage` → excluded.

### Shared evaluator

A pure function in the shared layer (`PixelCompare`), the single definition of "is
this divergence within its expected band," usable by any suite:

```elixir
@spec classify_divergence(VipsImage.t(), VipsImage.t(), divergence_map()) ::
        :ok
        | {:error, :below_floor | :above_ceiling,
           %{metric: :max_delta | :outliers, value: non_neg_integer(), band: Range.t()}}
def classify_divergence(out, fixture, %{max_delta: md_band, outliers: ol_band}) do
  diag = diagnose(out, fixture, [2])
  # check diag.max_delta ∈ md_band and diag.over[2] ∈ ol_band; return the first
  # bound crossed with enough detail for an actionable failure message.
end
```

Returns `:ok` when both metrics are in band. On a miss it reports *which* metric and
*which* bound (floor vs ceiling) was crossed, so the conformance failure message can
say whether this is a regression (above ceiling → investigate) or a promote signal
(below floor → consider returning the case to `:equal`).

### Conformance test wiring (both suites)

Each `*_differential_conformance_test.exs` dispatches on verdict:

- `:equal` → unchanged: `PixelCompare.outliers(out, fixture, tol.threshold) ≤ tol.budget`.
- `:diverges` → `PixelCompare.classify_divergence(out, fixture, c.divergence)`, asserted
  `== :ok`; on `{:error, …}` flunk with the bound/metric detail + the `libvips_drift_hint`
  (a band miss on a different runtime libvips may be version skew).
- `:triage` → unchanged: `@tag`-excluded.

imgproxy has no `:diverges` constellations yet; wiring its dispatch is a behavioral
no-op there but makes the mechanism uniformly available the moment an imgproxy case
needs it. The imgproxy manifest_test's sample `divergence` map is updated to the
unified two-sided shape (it only feeds the hasher — no behavioral change).

### Band calibration principle

Mirror the `:equal` skew philosophy ("just above measured, tight enough that a
structural shift blows it"): bands wide enough to absorb cross-libvips-version
resampling skew (the `:equal` skew cases drift ~±12), tight enough that a 1px sharp
shift (maxΔ→~255) or a half-cell shift (outliers → tens of thousands) falls outside,
and a now-byte-identical render (maxΔ→~0/12) drops below the floor. Exact band numbers
are measured at implementation against the committed fixtures and the bake-time
libvips.

### Migration

The two TwicPics `cover=2:3` cases currently quarantined with `:triage`
(`cover_ratio_tall`, `focus_bottomright_cover_ratio`) move from `:triage` →
`verdict: :diverges` with calibrated bands. They go back onto the default lane,
monitored. No other case changes.

## Part 2 — `structural_outliers` triage signal (informational)

### The principle

A differing pixel is a **resampling artifact** (haloing/ringing) iff its value is a
blend of its local neighborhood — it lies within `[local_min − ε, local_max + ε]` of
the corresponding neighborhood (radius `r`) in the reference image (ε absorbs Lanczos
overshoot, e.g. the `91 > 85` / `79 < 85` ringing). A **geometry difference**
(placement/crop/scale shift) moves an edge, producing pixels whose values fall
**outside** that local range (a displaced edge > `r` px away, or a flat region that is
wholly the wrong colour). This is the same idea as `pixelmatch`'s anti-aliasing
detector.

### Shared primitive

```elixir
@spec structural_outliers(VipsImage.t(), VipsImage.t(), keyword()) :: non_neg_integer()
# opts: radius (default 1), value_tol (default 2 levels), overshoot (ε, default ~8 levels)
```

Counts band-samples that differ by > `value_tol` **and** fall outside
`[local_min − ε, local_max + ε]` of the reference within `radius`. Pure, in the shared
`Differential` layer (so both suites' tools use it). Computed only over the differing
pixels.

Verified against the real `cover=2:3` data: with `radius=1`, `ε≈8`, every haloed
boundary pixel (incl. overshoot) is neighborhood-explainable → `structural_outliers ≈ 0`;
a ≥2px shift produces out-of-range pixels → non-zero.

### Surfaced in `diagnose`

`mix twicpics.diagnose` / `mix imgproxy.diagnose` print one extra field per case
alongside `maxΔ` and the `>Δ` histogram, e.g.:

```
cover_ratio_tall   dims 267×400  maxΔ=92  >Δ2=3869 …  structural=0 (r1)  → resampling/phase
crop_region_shift  dims …        maxΔ=85  >Δ2=3200 …  structural=2400    → geometry shift
```

This makes the README's "Reading it — skew vs structural" guide quantitative instead
of eyeballing maxΔ: `structural≈0` → candidate for `:diverges`/tolerance; `structural`
high → real geometry shift, fix or `:triage`.

### Not a gate

`structural_outliers` is **not** asserted in the conformance test. It is a heuristic
with tuning knobs (radius, ε); it informs human triage and the choice between
`:equal` / `:diverges` / `:triage`, but does not gate CI.

## Docs & tooling updates

- **Suite READMEs** (`*_differential/README.md`): document `:diverges` as a third
  state (monitored accepted divergence) next to `:equal`/`:triage`; make the
  "skew vs structural" reading-guide reference the new `structural=` field.
- **TwicPics support matrix / README**: the `cover=2:3` cases are now `:diverges`
  (monitored), not `:triage` (excluded) — update the quarantine wording accordingly;
  the `cover=W:H` "Diverges" note stays.
- **Report UI**: wire `:diverges` cases to the existing `known_divergence` data-type
  axis so the report's status/type filters reflect the new state.
- **`gen_report` test**: the quarantine-render assertion currently lists the two
  `cover=2:3` ids; they are now `:diverges`, not `:triage` — keep them asserted to
  render, under the right status.

## Testing strategy

- **Shared `PixelCompare`** (`test/.../differential/` unit tests, or the existing
  PixelCompare test): `classify_divergence/3` returns `:ok` in band, `:below_floor` /
  `:above_ceiling` with detail outside; `structural_outliers/3` returns ~0 for a
  synthetic haloed edge and non-zero for a synthetic ≥2px shift (hand-built small
  buffers, not baked fixtures — these are pure-primitive tests).
- **Conformance dispatch** (both suites): a `:diverges` case asserts via the band and
  is on the default lane (the two TwicPics `cover=2:3` cases exercise this live);
  `:equal` and `:triage` behavior unchanged.
- **Manifest**: `:divergence` map round-trips through `authored_sha256` regardless of
  key order (extend/keep the existing imgproxy manifest_test; add the TwicPics
  equivalent if absent).
- Use a private `telemetry_prefix` only where telemetry is asserted (N/A here).

## Scope / non-goals

- Activate `:diverges` constellations in **TwicPics only** (the two `cover=2:3`
  cases). imgproxy gets the shared evaluator + dispatch wiring (no-op until it has a
  `:diverges` case) and the updated manifest_test sample.
- `structural_outliers` is **triage-only** — not a conformance gate, not folded into
  the `:diverges` band.
- No change to ImagePipe's rendering behavior. This is test-infra + docs only. (The
  #331 focus-carry rendering fix is separate, already landed in the same branch.)

## Limitations (structural_outliers)

- `radius` *defines* "negligible geometry difference": a ≤`r`-px hard shift is
  indistinguishable from sub-pixel resampling (spatially identical). Pick `r` small
  (1–2) so only phase/sub-pixel is absorbed and ≥2px shifts are flagged.
- `ε` must absorb kernel overshoot without masking small real diffs (a few levels).
- It is a triage heuristic, deliberately not authoritative — hence informational only.
