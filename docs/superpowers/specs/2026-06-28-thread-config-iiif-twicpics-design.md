# Thread neutral config into the IIIF and TwicPics parsers

**Date:** 2026-06-28
**Status:** Design (brainstormed, pending review)
**Follows:** #418/#419 (Split plan/output config into a neutral `ImagePipe.Config` boundary)

## Goal

After #418/#419 lifted the product-neutral plan/output tunables into
`ImagePipe.Config`, the imgproxy adapter routes its host config through that
boundary. The IIIF and TwicPics adapters do not yet. This change threads the
neutral config into both, *in the same way*, so a host configuring `quality`,
`format_quality`, `strip_metadata`, `color_profile`/HDR policy, `jxl_effort`, or
autoquality gets it honored by IIIF and TwicPics — not just imgproxy. Both
dialects become host-tunable from the one neutral schema and inherit its
defaults.

This is **full functional threading**: the resolved config genuinely changes the
output bytes, not merely "accepted and validated".

## Background — current state

**imgproxy (the template, post-#418).** `validate_options!` splits its opts into
neutral keys (`Config.keys()`) vs dialect keys, validates only the dialect keys
against its own schema, delegates the neutral keys to `Config.resolve!/2` with a
(currently empty) parity overlay, and merges. A direct-parse `request_defaults/1`
path routes the neutral subset through `Config.resolve!/2` too. The resolved
neutral values are threaded onto `Plan.Output` in `Options.ex`
(`apply_request_defaults/2` → `resolve_metadata_defaults`,
`resolve_quality_defaults`, `resolve_quality_search_defaults`, `jxl_effort`).

**IIIF (`lib/image_pipe/parser/iiif.ex`).** Has its own dialect schema:
`resolver`, `formats`, `qualities`, `tile_size`, `max_width/height/area` (all
genuinely dialect) **plus `auto_rotate`** — which overlaps the neutral Config
key. Its plan builder emits a bare `%Output{mode: {:explicit, fmt}}` for image
requests; no neutral config is threaded. (info.json requests build no `Output` —
they use a custom renderer.)

**TwicPics (`lib/image_pipe/parser/twic_pics.ex`).** Empty dialect schema. Its
`Output.build/1` sets `mode` plus a URL-level `quality`; every other `Output`
field is left at its struct default. `parse/2` currently ignores `opts`.

**Key architectural fact.** `Output.Policy.from_output_plan/3` reads *every*
neutral field directly off the `Plan.Output` struct (`quality`,
`format_qualities`, `default_quality`, `strip_metadata`, `keep_copyright`,
`color_profile`, `hdr` via `supports_hdr?`, `quality_search`, `max_bytes`,
`jxl_effort`). So the entire downstream — negotiation, encode-search, encoder —
already consumes whatever the parser stamps onto `Plan.Output`. **The whole job
is populating `Plan.Output` from the resolved config; nothing downstream
changes.**

## Decisions (from brainstorming)

1. **Full functional threading** — resolved config changes output.
2. **IIIF `auto_rotate`** — drop it from the IIIF dialect schema and source it
   from neutral Config (default `true`, identical effective value today). One
   owner per key; shrinks the duplicated surface.
3. **TwicPics URL `quality`** — URL `quality=N` stays top precedence
   (`output.quality`); config `quality` becomes `default_quality` and config
   `format_quality` becomes `format_qualities` (the base used when no URL
   quality). Mirrors imgproxy's precedence exactly.
4. **Autoquality is in scope**, achieved by finishing the neutralization that
   #418 deferred (see next section), not by a parallel builder.

## Architecture

### 1. Finish moving autoquality resolution into the neutral core

#418 moved the autoquality *schema, defaults, and validation* into
`ImagePipe.Config`, but left two things imgproxy-private in
`parser/imgproxy/options.ex`:

- The per-metric fallback constants: `@default_ssim2_target 78` /
  `@default_butteraugli_target 1.0` (target) and `default_allowed_error/1`
  (ssimulacra2 `1.0` / butteraugli `0.1`).
- The struct builder `build_quality_search/3` + `resolve_quality_search_target/3`
  that turns resolved config (merged with URL autoquality fields) into a
  `%Plan.Output.QualitySearch.{Size,Ssimulacra2,Butteraugli}{}`.

**1a. Fallback constants become config map defaults.** Promote both fallbacks
into `Config`'s `@map_defaults`:

```elixir
autoquality_target:        %{ssimulacra2: 78,  butteraugli: 1.0},
autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1}
```

`Config.layer/2` already merges map-valued keys (`Map.merge(default, override)`),
so a host configuring just one metric keeps the other's default. Config
validation already range-checks every entry. This is **behavior-identical**:
today the empty-map lookup misses and falls to the private constant returning the
same value; with the populated map the lookup hits and returns the same value one
step earlier. `:size` deliberately gets **no** default entry (a byte budget must
be explicit); the "missing `:size` target → error" path is preserved. This
deletes imgproxy's `@default_ssim2_target`, `@default_butteraugli_target`, the
ssimulacra2/butteraugli clauses of `default_target/1`, and `default_allowed_error/1`.

**1b. Promote the one builder to the neutral core.** Move the builder to a new
module `ImagePipe.Plan.Output.QualitySearch` (the namespace has no parent module
today; the three structs + `Metric` live under it). The builder's only URL
coupling is the `fields` keyword (`:min_quality`/`:max_quality`/`:target`/
`:allowed_error`); with `fields = []` it builds purely from the resolved config.
Public surface:

```elixir
# Build a QualitySearch struct for an already-decided metric.
@spec build(metric :: :size | :ssimulacra2 | :butteraugli, url_fields :: keyword(), config :: keyword())
        :: {:ok, struct()} | {:error, term()}

# Config-only convenience: select metric from config and build (no URL surface).
# :none short-circuits to {:ok, :none}.
@spec from_config(config :: keyword()) :: {:ok, struct() | :none} | {:error, term()}
```

`build/3` keeps the URL-target range re-check (imgproxy's URL path needs it;
`Metric.target_range/1` is already neutral and under `Plan`). The reachability is
correct: every parser's boundary deps include `Plan`.

**Metric selection stays at the edges** — it is the one genuinely
dialect-specific piece. imgproxy keeps `effective_quality_search_method`
(URL `au` blended with config) and passes its extracted URL `fields` to `build/3`.
IIIF/TwicPics have no URL autoquality surface, so they use `from_config/1`
(metric = config `autoquality_method`, `fields = []`).

**imgproxy after this:** `resolve_quality_search_defaults` in `Options.ex` calls
`Plan.Output.QualitySearch.build/3` with its URL fields instead of its private
builder. Same struct, same values → observably unchanged. This is the only
imgproxy touch and is what mandates the imgproxy-compatibility reviewer.

### 2. A shared neutral "stamp config onto Output" seam

IIIF and TwicPics need the identical ~8-field mapping from resolved config onto
`Plan.Output`. To avoid duplicating it between them, add one neutral helper:

```elixir
# ImagePipe.Config
@spec apply_to_output(base :: Plan.Output.t(), resolved :: keyword())
        :: {:ok, Plan.Output.t()} | {:error, term()}
```

`Config` already deps `[Plan]` (the only dep; no boundary/architecture-test
change). It stamps:

- `default_quality` ← config `quality` (as `{:quality, n}`).
- `format_qualities` ← config `format_quality`, each value normalized to
  `{:quality, n}`.
- `strip_metadata` ← config `strip_metadata`; `keep_copyright` ←
  `strip_metadata and keep_copyright` (the canonical-cache-key rule: copyright is
  only meaningful when stripping).
- `color_profile` ← `strip_color_profile` (`true → :strip`, `false →
  :preserve_source`).
- `hdr` ← `preserve_hdr` (`true → :preserve`, `false → :tone_map`).
- `jxl_effort` ← config `jxl_effort`.
- `quality_search` ← `Plan.Output.QualitySearch.from_config(resolved)`,
  propagating its `{:error, _}` (e.g. `autoquality_method: :size` with no
  `:size` target — a real host misconfig that must surface).

It **never touches `output.quality`** — the dialect's base `Output` carries the
URL quality (or `:default`), which gives "URL wins, config is the base" for free
and matches imgproxy's `resolve_quality_defaults`.

This helper is config-only and is **not** used by imgproxy (which resolves the
same fields inline because it must merge URL precedence). The genuinely shared
code between all three dialects is the autoquality builder (§1b); the simple
field mapping is shared only between the two config-only dialects, which is why
it lives in `Config.apply_to_output` rather than being forced onto imgproxy.

### 3. Surfacing unsupported config (the `reject_unsupported!/3` seam)

**Invariant:** a host-configured setting that a dialect won't act on must fail
loudly at the config boundary — never be silently accepted and ignored. There
are three "not supported" cases, surfaced at two layers:

| Case | Layer | Surface |
| --- | --- | --- |
| Unknown key (typo / wrong-dialect key) | host config (init) | `ArgumentError` at `validate_options!` (already: NimbleOptions / the `{dialect, unknown}` split) |
| Known neutral key this dialect can't honor | host config (init) | `ArgumentError` via `Config.reject_unsupported!/3` (below) |
| Known key whose *value* needs an absent capability (e.g. `autoquality_method: :size` with no target) | host config (init) **or** per-request (URL) | `ArgumentError` for config; tagged `{:error, {:unsupported_*, ...}}` → 4xx via `handle_error` for URL |

The neutral core must never name a dialect (`Config → [Plan]` boundary), so the
*capability knowledge* lives in the adapter and is passed **into** Config; Config
owns only the mechanism and the message:

```elixir
# ImagePipe.Config
@spec reject_unsupported!(neutral :: keyword(), supported :: [atom()] | :all, dialect :: String.t())
        :: keyword()
```

It raises a uniform, dialect-named `ArgumentError` for any neutral key outside
the declared `supported` set and returns the rest untouched. It never decides
*what* is supported — the adapter declares that via a `@supported_neutral`
attribute beside its `@dialect_keys`. This keeps the split symmetric: `Config.keys()`
(which neutral keys exist — core's business) vs. `@dialect_keys` /
`@supported_neutral` (what *this* adapter accepts and honors — adapter's business).

**Under this design every adapter declares `:all`** (the full neutral surface is
uniformly honored across imgproxy/IIIF/TwicPics), so `reject_unsupported!/3` is a
no-op seam today. It exists so that a *future* neutral key a given dialect
genuinely cannot map onto produces a clear "the `<dialect>` parser does not
support config: `[...]`" error at boot instead of a silent no-op. Preferring to
*eliminate* the unsupported case (uniform threading) over erroring on it is the
first choice; the helper is the fallback for when a hole is unavoidable.

### 4. IIIF adapter changes

- **`validate_options!`**: split `opts[:iiif]` into neutral (`Config.keys()`) vs
  the rest; validate the rest against the IIIF dialect schema (now *without*
  `auto_rotate`); reject unknown keys; pass the neutral subset through
  `Config.reject_unsupported!(neutral, @supported_neutral, "IIIF")`
  (`@supported_neutral` is `:all` under this design); resolve via
  `Config.resolve!/2` with an (empty) `iiif_overlay/0`; merge resolved-neutral
  back into `opts[:iiif]`. Keep `validate_max_bounds!`.
- **`PlanBuilder.image_plan/3`**: source the top-level `Plan.auto_rotate` from the
  neutral `auto_rotate` (resolved into `opts`); build the base `Output` as today
  (`{:explicit, fmt}`), then run it through `Config.apply_to_output/2` with the
  resolved-neutral config. The IIIF URL "quality" (default/color/gray/bitonal) is
  a transform op (`Gray`/`Bitonal`), unrelated to encode quality, and is
  untouched.
- **`PlanBuilder.info_plan/3`**: unchanged. info.json builds no `Output`; the
  neutral keys are simply unused there. `auto_rotate: false` stays (no pixels).

### 5. TwicPics adapter changes

- **`validate_options!`**: split `opts[:twicpics]` into neutral vs rest; the
  dialect schema stays empty, so any non-neutral key is unknown → reject; pass
  the neutral subset through
  `Config.reject_unsupported!(neutral, @supported_neutral, "TwicPics")`
  (`@supported_neutral` is `:all`); resolve via `Config.resolve!/2` with an
  (empty) `twicpics_overlay/0`; store the resolved-neutral config back in
  `opts[:twicpics]`.
- **`parse/2`**: read `opts[:twicpics]` (was `_opts`) and pass the resolved
  config into `PlanBuilder.to_plan/3`.
- **`PlanBuilder.to_plan/3`**: source `Plan.auto_rotate` from neutral config
  (default `true`, unchanged); build the base `Output` (URL `format`/`quality`)
  via `Output.build/1` as today, then run it through `Config.apply_to_output/2`.
  URL `quality` precedence is preserved because `apply_to_output` leaves
  `output.quality` alone.

### 6. Boundaries, cache, ETag — no changes

- **Boundaries**: both adapters already inherit `ImagePipe.Config` via the
  `ImagePipe.Parser` ancestor boundary (imgproxy does the same — its own deps do
  not list `Config`). The architecture test's per-adapter dep lists stay as-is.
  `Config` keeps `deps: [Plan]`. The new `Plan.Output.QualitySearch` module is
  within the `Plan` boundary.
- **Cache key / ETag**: every threaded field already participates (it lives on
  `Plan.Output`, and `auto_rotate` on `Plan`). Populating them from config for
  IIIF/TwicPics flows into the key/ETag automatically — no cache code changes.

## Observable behavior changes

Because IIIF/TwicPics previously left these `Output` fields at struct defaults,
threading the *neutral config defaults* changes some outputs even with no host
config set:

- `default_quality`: was the struct default `:default` (encoder built-in) → now
  `{:quality, 80}` (Config default). **Output bytes change** for formats that
  take a numeric default.
- `format_qualities`: was `%{}` → now `%{webp: 79, avif: 63, jpeg_xl: 77}`.
  **Output bytes change** for those formats.
- `strip_metadata`/`keep_copyright`/`color_profile`/`hdr`/`jxl_effort`: the
  Config defaults equal the prior struct defaults (`true`/`true`/`:strip`/
  `:tone_map`/`7` resolved by Policy), so **no change** absent host config.
- `quality_search`: stays `:none` unless a host sets `autoquality_method`.

These are intended (the point of host-tunable defaults) but are real
pixel/byte-level changes for IIIF and TwicPics, so:

**Conformance docs (per project rules).** Update `docs/twicpics_support_matrix.md`
and `docs/iiif_3_support_matrix.md` in this change: note the new host-config
surface (the neutral tunables now apply), the quality-default behavior
(`default_quality`/`format_qualities` base under any URL quality), and any
divergence the new defaults introduce vs the target. Axes touched: **surface**
(config now honored) and **behavioral/pixel** (default quality). The
imgproxy-compatibility reviewer confirms the imgproxy refactor (§1) is
behavior-preserving against the upstream source; a TwicPics-parity check confirms
the new quality defaults are acceptable for that target (TwicPics renders with
libvips, so pixel comparison is meaningful).

## Error handling

- Unknown host keys: rejected at `validate_options!` per dialect (as imgproxy).
- Known-but-unsupported neutral key: `Config.reject_unsupported!/3` raises a
  dialect-named `ArgumentError` (init-time). No-op today (`@supported_neutral`
  is `:all` everywhere); the seam for future per-dialect holes (see §3).
- Invalid neutral config: `Config.resolve!/2` raises `ArgumentError` (init-time,
  as today).
- `autoquality_method: :size` with no `:size` target: `from_config/1` returns
  `{:error, _}`, surfaced from `apply_to_output/2` at plan-build time. (Config
  validation cannot catch this — it's a cross-key constraint between the chosen
  method and the target map.)

## Testing

Following the existing wire-level + unit discipline:

- **`Plan.Output.QualitySearch` (new unit test)**: `build/3` and `from_config/1`
  produce the expected structs from config; `:size`-missing-target errors; the
  populated-map fallbacks return 78/1.0/1.0/0.1.
- **imgproxy regression**: existing imgproxy autoquality tests must pass
  unchanged (proves §1 is behavior-preserving). Spot-check one bake/wire case.
- **`Config.apply_to_output/2` (new unit test)**: field mapping incl. the
  `keep_copyright`-forced-false rule, `format_quality` normalization, and that
  `output.quality` is left untouched.
- **`Config.reject_unsupported!/3` (new unit test)**: `:all` passes everything
  through; a declared subset raises a dialect-named `ArgumentError` for an
  out-of-subset key and returns the rest. (A focused example test, not a
  per-dialect pin — every dialect declares `:all` today.)
- **IIIF wire tests**: a host-config `quality`/`format_quality` visibly changes
  decoded output (decode the response body, compare against the prior default);
  `auto_rotate` sourced from neutral; a configured `autoquality_method`
  round-trips; info.json unaffected.
- **TwicPics wire tests**: URL `quality` still wins over config; config
  `default_quality`/`format_quality` apply when URL omits quality; a configured
  neutral tunable (e.g. `strip_metadata: false`) is honored.
- **Cache**: a semantically equivalent IIIF/TwicPics request reuses the cache;
  changing a threaded config field changes the key (covered by the existing
  key-data tests once the fields are populated — no new key fields).

## Out of scope / non-goals

- **`autoquality_max_iterations` plumbing.** This Config key is defined and
  validated but is **not** currently fed into `Output.EncodeSearch` for *any*
  dialect (the search loop uses its own hardcoded default of 6, which matches the
  Config default). This is a pre-existing gap shared with imgproxy; it is neither
  introduced nor fixed here. Flag as a possible separate cleanup.
- **imgproxy field-mapping refactor.** imgproxy keeps resolving the simple
  metadata/quality/color-profile/HDR fields inline (it needs URL precedence). The
  only imgproxy change is routing autoquality through the relocated builder.
- **New URL surface for IIIF/TwicPics.** No new URL options; this is host-config
  threading only.
- **Per-dialect parity overlays with content.** Both `iiif_overlay/0` and
  `twicpics_overlay/0` ship empty (parity == neutral defaults), mirroring
  imgproxy's empty overlay; they exist as the seam for future divergence.

## File-by-file change list

**Neutral core**
- `lib/image_pipe/config.ex` — populate `autoquality_target` /
  `autoquality_allowed_error` map defaults; add `apply_to_output/2` and
  `reject_unsupported!/3`; moduledoc note.
- `lib/image_pipe/plan/output/quality_search.ex` *(new)* — `build/3` +
  `from_config/1` (moved from imgproxy `Options.ex`).

**imgproxy (behavior-preserving)**
- `lib/image_pipe/parser/imgproxy/options.ex` — delete the private fallback
  constants + `default_target`/`default_allowed_error`; call
  `Plan.Output.QualitySearch.build/3` from `resolve_quality_search_defaults`.

**IIIF**
- `lib/image_pipe/parser/iiif.ex` — neutral/dialect split in
  `validate_options!`; `@supported_neutral :all` + `reject_unsupported!/3` call;
  drop `auto_rotate` from the dialect schema; add `iiif_overlay/0`.
- `lib/image_pipe/parser/iiif/plan_builder.ex` — `image_plan` sources
  `auto_rotate` from neutral and runs the base `Output` through
  `Config.apply_to_output/2`.

**TwicPics**
- `lib/image_pipe/parser/twic_pics.ex` — neutral/dialect split in
  `validate_options!`; `@supported_neutral :all` + `reject_unsupported!/3` call;
  pass resolved config through `parse/2`; add `twicpics_overlay/0`.
- `lib/image_pipe/parser/twic_pics/plan_builder.ex` — `to_plan/3` sources
  `auto_rotate` from neutral and runs the base `Output` through
  `Config.apply_to_output/2`.

**Docs**
- `docs/twicpics_support_matrix.md`, `docs/iiif_3_support_matrix.md` — surface +
  behavioral updates.

**Tests** — as enumerated above.
