# Autoquality `{format, content-class} → offset` policy

**Issue:** [#380](https://github.com/hlindset/image_pipe/issues/380)
**Date:** 2026-06-23
**Status:** design approved, pending spec review

## Problem

Above the 6 MP crop crossover (#369), the confirm-skipped `:ssim2` search ships the
crop verdict minus a single global offset, `@crop_confirm_skipped_offset` ≈ 2.4. That
offset was calibrated on photo-heavy content. For **large AVIF renders of dense screen
text** the crop estimate overshoots full-frame by ~6, so the search stops ~3.7 ssim2
**below** target — silent under-quality, because the full-frame confirm that would have
caught it is exactly what #369 removed for cost. A flat raise of the global offset to
~6 would over-inflate every AVIF photo to rescue one content slice.

Part M (#379, `docs/autoquality_benchmark.md` → Part M) proved a cheap libvips
classifier separates photographic from graphic content (`palette_ent` AUC 0.959 +
`nat_var` AUC 0.940, **zero** screen→photo errors on the 189-image cohort), and that the
residual the offset corrects is carried **only** by AVIF × graphic content (p90 6.07);
every other `{format, class}` cell's proper offset is already at or below today's 2.4.

This change replaces the single global offset with a `{format, content-class} → offset`
policy keyed on that classifier.

## Content classes

Two classes, named for the compression-relevant property they capture (tone
continuity), not a content guess:

- **`:photo`** — continuous-tone photographic content (gradients, sensor noise, soft
  edges).
- **`:graphic`** — discrete-tone synthetic content: screenshots, UI, text, charts,
  diagrams, line art. **This is the safe fallback.**

Misclassification is asymmetric: a photo read as graphic only inflates a file slightly;
a graphic read as photo gets the lean offset and ships visible text/edge damage. So the
classifier falls back to `:graphic`, and the **graphic→photo** error is the one that
must stay at zero.

(The Part M bench keeps its own corpus labels `:photo` / `:screen_or_other` — it is a
separate `test/support` measurement tool with its own labeled corpus and is **not**
renamed by this change.)

## Architecture decision: lazy at the crop boundary

The issue frames the class as self-managing `Transform.State` input conditioning (like
EXIF auto-orient). We instead classify **lazily, inside the encode path, only when the
`:ssim2` + >6 MP crop scorer is selected** — the single place the offset is consumed.

Rationale: the class is read in exactly one place (`crop_estimate`, on the finalized
image, only on the crop path), which is a tiny fraction of requests. Running the ~12 ms
classifier eagerly during transform would tax every thumbnail and every non-autoquality
request for a value almost none of them use. Lazy-at-boundary still honors "derived from
runtime image inspection, not a `Plan.Operation`," and the declarative table still lives
on `Plan.Output`. It avoids all `Transform.State` / metadata-carry plumbing and the
materialization-gate proof a transform-stage operation would require.

The finalized image is already materialized in RAM before encode
(`materialize_for_delivery`), so the classifier reads the in-RAM buffer — no re-decode.

## Components

### 1. `ImagePipe.Output.ContentClassifier` (new)

- **Boundary:** `Output.*` (consumed at the output/encode boundary).
- **Public:** `classify(finalized_image) :: {class, features}` where
  `class :: :photo | :graphic` and `features :: %{palette_ent: float, nat_var: float}`.
- **Features** (ported from the bench `m_features/2`): a **512 px** long-edge downsample
  → grayscale → Sobel gradient magnitude → `palette_ent` (luminance-histogram entropy ÷
  8) + `nat_var` (mid-band gradient fraction). 512 px is near-invariant with 1024 for
  separation at ~60 % the cost (Part M).
- **AND-rule:** `:photo` iff `palette_ent ≥ θ_palette` **and** `nat_var ≥ θ_nat`; else
  `:graphic`. Photos read high on both (cohort medians 0.909/0.411 vs 0.393/0.110).
- **Fail-safe:** any internal libvips error → `{:graphic, features_or_zeroes}`. The
  classifier never errors the request; the fallback *is* the safe class.
- **Thresholds** `θ_palette`, `θ_nat` are frozen module constants, derived from the
  bench re-run (Youden θ, validated at 0 graphic→photo on the cohort). Pinned values
  filled in during implementation (see "Empirical constants").

### 2. `ImagePipe.Plan.Output` — the declarative table (parser seam)

- New field `quality_search_offsets`, a defaulted policy struct/map:
  `%{default: 2.4, overrides: %{{:avif, :graphic} => 6.0}}` (offset values pinned by the
  bench). Named for what it belongs to — the autoquality quality-search — so it reads as
  an autoquality knob on `Plan.Output`, not image-crop geometry (the "crop" in the
  internal crop-scorer is misleading at this layer). Mirrors `flatten_background`: a
  built-in default that is the declarative seam a future dialect/host could override;
  **no parser overrides it today.**
- **Cache key / ETag:** the policy is a constant default (never request-varying), so it
  stays **out of** both the cache key and the ETag — identical to today's module
  constant `2.4`. The runtime-derived class is not a request input either (same request →
  same source → same finalized pixels → deterministically same class), so it is also not
  a key input.

### 3. `ImagePipe.Output.Policy.resolve` → `ResolvedQualitySearch`

- For the negotiated format, collapse the table into a per-class map
  `%{photo: offset, graphic: offset}` and stash it on a new `ResolvedQualitySearch`
  field (`quality_search_offsets`). Built **only** for `:ssim2` (crop scoring is
  `:ssim2`-only; `:size`/`:none` never see it).

### 4. `ImagePipe.Output.EncodeSearch` — consume lazily

- Remove the `@crop_confirm_skipped_offset` module constant (its 2.4 now lives as the
  policy `default`).
- The `:crop` clause of `score_opts/4` (the only path that fires): classify the
  finalized image once, look up `offset = quality_search_offsets[class]`, emit the
  classify telemetry span, and close the offset into the crop closure —
  `crop_estimate(base, bytes, tiles, offset, t)`.
- `:full`, `:size`, and `:none` clauses unchanged. The pure `search/3` core never sees
  the class — same pattern as the one-time reference build.

### 5. Telemetry

- New span `[:encode, :classify]` emitted from the `:crop` setup in `run/3`, stop
  metadata: `content_class`, `applied_offset`, `palette_ent`, `nat_var` — all
  product-neutral, non-sensitive (per the telemetry guidelines, fine to emit). Named
  `[:encode, :classify]` (not `…:search:classify`) because `score_opts` runs **before**
  `search/3` opens the `[:encode, :search]` span — classification is a sibling of the
  search under the `[:encode]` span, so the name reflects its true trace position.
  Start/stop only in practice (the classifier is total — it never raises — so the span's
  `:exception` leg is structurally unreachable).
- Wire **both** subscription surfaces in the same change:
  - Logger: add to `@group_span_events`, add a `message/3` clause that surfaces the class
    + offset (and still surfaces `:result`), add a `logger_test.exs` assertion.
  - OTel Capture: add the stage to `@span_stages`, add the new metadata keys to
    `@safe_keys`, add a capture test.
  - Update `docs/telemetry.md` for both surfaces.

## Data flow

```
request → transform → materialize_for_delivery (image in RAM)
  → Encoder.stream_output → search_output (megapixels > crossover, :ssim2)
    → EncodeSearch.run(finalized, %Resolved{quality_search: %RQS{quality_search_offsets}})
      → score_opts(:crop):
          {class, features} = ContentClassifier.classify(finalized)
          offset = quality_search_offsets[class]  # default 2.4, avif×graphic → 6.0
          emit [:encode, :classify]               # sibling of [:encode, :search] under [:encode]
          crop_fun = fn bytes -> crop_estimate(finalized, bytes, tiles, offset, t) end
      → search/3 (pure core, offset already baked into the closure)
```

## Empirical constants (derived during implementation)

The feature is only as good as three frozen numbers. Implementation re-runs
`mix autoquality.corpus` + `…capture` + `mix autoquality.bench --part m` on this machine
to derive and freeze:

1. `θ_palette` — `palette_ent` photo-side threshold (Youden split, AND-rule).
2. `θ_nat` — `nat_var` photo-side threshold.
3. `{:avif, :graphic}` offset — confirm/round the p90 6.07 (~6).

Acceptance for the constants: **0 graphic→photo misclassifications** on the labeled
cohort at the chosen thresholds; the avif×graphic offset covers the `web_sc` dense-text
worst case (~7) without over-covering charts more than the 2-class split inherently
must.

## Testing

The acceptance work splits along what each layer can honestly prove:

- The **bench (Part M)** owns the empirical claim that `6.0` is the right magnitude for
  `avif × graphic` on *real dense-text* content. The default test lane has no network and
  no committed dense-text source, so a lane test cannot reproduce that magnitude.
- The **lane tests** prove the user-visible *contract*: the `{format, class}` offset is
  plumbed end-to-end, classification works on real-ish content, and a larger offset
  materially raises the chosen quality (the correcting direction). They must **not**
  assert "hits target" off the offset-corrected estimate — the objective walk lands that
  estimate in-band *by construction* at any offset, so such an assertion is vacuous.

Tests:

- **`ContentClassifier` unit test:** a continuous-tone fixture → `:photo`, a hard-edged
  two-tone fixture → `:graphic`, a degenerate 1×1 input → `:graphic` fallback (no raise).
  Fixtures built so the verdict is robust to the exact pinned thresholds.
- **Offset-bites differential (focused, deterministic — the core proof):** drive
  `EncodeSearch.run/3` on one large `:graphic` finalized image with
  `quality_search_offsets` `%{graphic: 2.4}` vs `%{graphic: 6.0}`; assert the chosen
  quality at 6.0 is `>=` (and, on content with real overshoot, `>`) the quality at 2.4.
  This proves the offset bites in the under-quality-correcting direction without
  depending on reproducing the real-world overshoot magnitude.
- **Request-boundary contract test:** a large hard-edged AVIF render above the crossover,
  through `ImagePipe.call/2`, returns `200`/`image/avif`, and telemetry shows
  `content_class: :graphic`, `applied_offset: 6.0`, `scorer: :crop`. Classification is
  self-checking (if the synthetic classified `:photo`, the test fails loudly). A
  continuous-tone (`:photo`) AVIF / JPEG companion asserts `applied_offset: 2.4` — the
  lean offset is retained for the covered cells (no byte inflation vs today).
- **Resolution test:** `Output.Policy` collapses `Plan.Output.quality_search_offsets` to
  the per-class `ResolvedQualitySearch.quality_search_offsets` for the negotiated format.
- **Telemetry test:** with a private `telemetry_prefix`, assert the `[:encode, :classify]`
  span fires with `content_class` + `applied_offset` + features, at the base log level.
- **Encode-search behavior:** the existing crop-scoring test keeps its photo (2.4) case
  and `<=4` full-vs-crop bound; the pure `search/3` confirm-baseline tests are unaffected.

## Out of scope (YAGNI)

- No `Transform.State` / metadata-carry plumbing (lazy-at-boundary chosen).
- No 3-class (text vs chart) refinement; no continuous/sliding offset — Part M ruled
  both out (best feature↔residual r² ≈ 0.17; free tile-dispersion ≤ 7 %).
- No parser config surface for the table — the default policy suffices; it is a future
  declarative seam, like `flatten_background`.
- The Part M bench and its corpus labels are unchanged.
- The `max_quality` **cap** lever for ceiling-bound cells (`webp × *`, `jpeg × screen`,
  which an offset cannot rescue) is out of scope — tracked separately in
  [#381](https://github.com/hlindset/image_pipe/issues/381). The offset and the cap are
  orthogonal levers.

## Compatibility

No compatibility-target impact: this is native `:ssim2` autoquality, which imgproxy does
not implement (its `size`/`dssim`/`ml` search is Pro/closed-source). No
`docs/imgproxy_support_matrix.md` change. The plan-review compatibility reviewer is
therefore optional for this change.
