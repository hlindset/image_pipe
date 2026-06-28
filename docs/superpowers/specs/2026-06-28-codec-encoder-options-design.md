# Codec-specific encoder options as neutral config (#343)

**Date:** 2026-06-28
**Issue:** [#343](https://github.com/hlindset/image_pipe/issues/343) — imgproxy advanced codec-specific encoder options (`jpeg_options`, `png_options`, `webp_options`, `avif_options`)

## Problem

imgproxy Pro exposes per-format encoder tuning via the `jpgo`/`pngo`/`webpo`/`avifo` URL options (and matching env config). ImagePipe currently passes only an explicit quality to the encoder; the "Output and encoding" rows in `docs/imgproxy_support_matrix.md` are all ⭕ Missing.

Issue #343 predates the neutral-config boundary (`ImagePipe.Config`, PR #418/#419) and proposes imgproxy-*specific* `Plan.Output` fields. We instead model these as **neutral, host-tunable encoder knobs** — the same kind of declarative `Plan.Output` config as the already-landed `jxl_effort` — with imgproxy's URL tokens layering per-request overrides on top. Any dialect (IIIF, TwicPics) inherits the host defaults for free; only imgproxy gets the per-request URL surface.

## Goal

End-to-end, all five codec families:

- Five typed per-format option structs under `ImagePipe.Plan.Output.*`.
- Neutral `ImagePipe.Config` schema keys + defaults + range checks.
- Threading through `Plan.Output` → `Output.Policy` → `Output.Resolved` → `Encoder`.
- `Cache.Key` + ETag inclusion (these change stored bytes).
- imgproxy URL tokens (`jpgo`/`pngo`/`webpo`/`avifo`) + sparse per-field override merge.
- Fiddle controls + URL state for the URL-token flags.
- `docs/imgproxy_support_matrix.md` surface-axis update.

## Source-of-truth semantics (imgproxy docs)

These are imgproxy **Pro** options — **not** in the local OSS checkout. Verified against the imgproxy docs checkout (`/Users/hlindset/src/imgproxy-docs`), `usage/processing.mdx` + `configuration/options.mdx` (Advanced * compression). The compatibility reviewer verifies the mappings below against those documented semantics, not Pro source.

### JPEG — `jpeg_options:%progressive:%no_subsample:%trellis_quant:%overshoot_deringing:%optimize_scans:%quant_table`

| imgproxy flag | type / default | libvips `jpegsave` param |
| --- | --- | --- |
| `progressive` | bool / false | `interlace` |
| `no_subsample` | bool / false | `subsample_mode: :off` |
| `trellis_quant` | bool / false | `trellis_quant` |
| `overshoot_deringing` | bool / false | `overshoot_deringing` |
| `optimize_scans` | bool / false (requires `progressive`) | `optimize_scans` |
| `quant_table` | int 0–8 / 0 | `quant_table` |

### PNG — `png_options:%interlaced:%quantize:%quantization_colors`

| imgproxy flag | type / default | libvips `pngsave` param |
| --- | --- | --- |
| `interlaced` | bool / false | `interlace` |
| `quantize` | bool / false | `palette` |
| `quantization_colors` | int 2–256 / 256 | `colours` |

PNG quantization needs libvips built with Quantizr or libimagequant (same constraint imgproxy documents) — a deployment dependency, not a no-op.

### WebP — `webp_options:%compression:%smart_subsample:%preset`

| imgproxy flag | type / default | libvips `webpsave` param |
| --- | --- | --- |
| `compression` | enum `lossy`/`near_lossless`/`lossless` / `lossy` | `lossless` + `near_lossless` |
| `smart_subsample` | bool / false | `smart_subsample` |
| `preset` | enum default/photo/picture/drawing/icon/text / `default` | `preset` |
| `effort` (config-only) | int 1–6 / 4 | `effort` |

`compression` mapping: `lossy` ⇒ neither; `lossless` ⇒ `lossless: true`; `near_lossless` ⇒ `near_lossless: true` (libvips treats near-lossless as a lossless variant).

### AVIF — `avif_options:%subsample`

| imgproxy flag | type / default | libvips `heifsave` param |
| --- | --- | --- |
| `subsample` | enum `auto`/`on`/`off` / `auto` | `subsample_mode` (`:auto`/`:on`/`:off`) |
| `speed` (config-only) | int 0–9 / 8 | encode effort/speed param |

`subsample: auto` already means "subsample when Q<90" in both imgproxy and libvips `heifsave`. The libvips `heifsave` param name for AVIF speed/effort (and its direction vs. imgproxy's 0=slow/9=fast `speed`) **must be confirmed against the deployed libvips during implementation** — the byte-neutral default (below) means this only matters when `speed` is explicitly set.

### JXL — config-only `effort` (already landed as flat `jxl_effort`)

imgproxy has no `jxl_options` URL token; `IMGPROXY_JXL_EFFORT` (1–9, default 4; libvips default 7) is env-only. Migrated from the flat `jxl_effort` config key / `Plan.Output` field into `JxlOptions{effort}` for uniformity.

## Design

### 1. Typed per-format structs (`plan` boundary)

```
ImagePipe.Plan.Output.JpegOptions{progressive, no_subsample, trellis_quant,
                                   overshoot_deringing, optimize_scans, quant_table}
ImagePipe.Plan.Output.PngOptions{interlaced, quantize, quantization_colors}
ImagePipe.Plan.Output.WebpOptions{compression, smart_subsample, preset, effort}
ImagePipe.Plan.Output.AvifOptions{subsample, speed}
ImagePipe.Plan.Output.JxlOptions{effort}
```

- Plain typed `defstruct` + `@type t`. **Every field defaults to `nil`.**
- Each module exposes `merge/2` — sparse per-field override, where a non-`nil` field in the override wins and `nil` keeps the base. (The only logic; otherwise dumb data containers.)
- No token/encoding logic here — that lives in the encoder (`output` boundary owns libvips).

**Byte-neutral default principle.** `nil` ⇒ the encoder emits no libvips suffix token for that field, leaving the libvips `*save` default. Therefore *default output is byte-identical to today*. Consequences:

- **No imgproxy differential-fixture rebake.** Existing wire conformance is preserved bit-for-bit.
- The `webp effort` (libvips default 4 = imgproxy default 4) and `avif speed`↔libvips-param ambiguity only bite when a value is explicitly set.
- `Config.default/1` still reports imgproxy's documented defaults *as data* for introspection; resolution emits a token only when a value is set.

### 2. `Plan.Output`

- **Add** `encoder_options :: %{optional(format) => JpegOptions.t | PngOptions.t | WebpOptions.t | AvifOptions.t | JxlOptions.t}` (default `%{}`).
- **Remove** the `jxl_effort` field (migrated into `encoder_options[:jpeg_xl]`).
- One map field (not five siblings): threads through Policy/Resolved/Cache as a single value and mirrors the existing `format_qualities` map.

### 3. `ImagePipe.Config`

- Add five map-valued neutral keys: `jpeg_options`, `png_options`, `webp_options`, `avif_options`, `jxl_options`. Remove the flat `jxl_effort` key.
- Per-field validation (types + enums + ranges): `quant_table` 0–8, `quantization_colors` 2–256, `compression ∈ {lossy,near_lossless,lossless}`, `preset ∈ {default,photo,picture,drawing,icon,text}`, `subsample ∈ {auto,on,off}`, webp `effort` 1–6, avif `speed` 0–9, jxl `effort` 1–9.
- `@map_defaults`/`@scalar_defaults` carry imgproxy's documented defaults as data (for `default/1` introspection).
- `apply_to_output/2` stamps the resolved structs into `Plan.Output.encoder_options` — gives **IIIF/TwicPics** host defaults for free (no URL surface).
- The existing `jxl_effort` resolution in `Output.Policy` (`output.jxl_effort || Config.default(:jxl_effort)`) becomes the `jxl_options`/`JxlOptions.effort` equivalent.

### 4. Precedence / layering

Two-slot model, identical to how `quality` already works:

```
config default struct   ← imgproxy URL token override (sparse, per-field present-wins)
```

- **imgproxy:** `apply_request_defaults` builds the config-default structs from the resolved `defaults`, then `merge/2`s the URL-token override structs over them, sets `output.encoder_options`.
- **IIIF / TwicPics:** inherit config defaults via `Config.apply_to_output/2`; no tokens.

Result: the model is dialect-neutral; imgproxy is the only dialect carrying a per-request override surface.

### 5. Threading: Policy → Resolved → Encoder

- `Output.Policy` carries the full `encoder_options` map (pre-negotiation — output format not yet chosen).
- `resolve/2` picks `Map.get(encoder_options, negotiated_format)` ⇒ `Output.Resolved.encoder_options` is the **single** negotiated struct (replaces `Resolved.jxl_effort`). Mirrors `format_qualities` map → `quality` scalar resolution.
- `Encoder` builds libvips suffix tokens from that struct per format, folded into the existing suffix-option mechanism the JXL path already uses, e.g.:
  - `.jpg[Q=80,interlace=true,trellis_quant=true,quant_table=3]`
  - `.webp[Q=79,lossless=true,smart_subsample=true,preset=photo,effort=6]`
  - `.png[interlace=true,palette=true,colours=128]`
  - the current `jxl_effort` token path reads `JxlOptions.effort`.

### 6. Cache key + ETag

Encoder options change stored bytes ⇒ they **must** compose:

- `Cache.Key` — replace the three `jxl_effort` entries with the resolved `encoder_options` (or the negotiated per-format struct, matching where the key is built).
- The ETag byte-identity seed — same inputs.

This is identity, **not** a generation gate (no interaction with `max_body_bytes`/pixel limits). Greenfield: reshape the canonical key data in place; no data-version bump.

### 7. imgproxy parser surface

- New URL tokens + aliases in the option grammar: `jpeg_options`/`jpgo`, `png_options`/`pngo`, `webp_options`/`webpo`, `avif_options`/`avifo`.
- Each colon-positional per the imgproxy signature, **all args optional** — an empty/omitted arg means "omit, keep the config default" (per-field sparse override; matches imgproxy "redefine only the args present").
- Parser translates to sparse `*Options` structs (no token ⇒ all-`nil`) in `parsed_request`; `apply_request_defaults` merges them over config defaults.
- `webp effort` / `avif speed` get **no** URL token (config-only, matching imgproxy).

### 8. Fiddle + docs

- `fiddle/assets/` Svelte: controls + URL state for the URL-token flags (not the two config-only knobs).
- `docs/imgproxy_support_matrix.md`: flip the four "Output and encoding" rows to supported (**surface axis**). Note: PNG-quantize libvips-build dependency; the two config-only knobs (`webp effort`, `avif speed`) with no URL surface.

## Boundaries

All directions already permitted by existing `Boundary` deps:

- `Plan.Output.*` structs live in `plan`.
- `output` (encoder, policy, resolved) → `plan` ✓.
- `ImagePipe.Config` (top-level, `deps: [Plan]`) builds structs ✓.
- imgproxy parser (`parser` → `plan`) builds structs ✓.
- `cache` → `plan` ✓.

No new namespace; no boundary-rule change.

## Testing

These options change encoded *bytes*, not decoded *pixels*, so the PNG pixel-differential cannot compare them (per #343). Acceptance:

- **Wire/header tests** (real `ImagePipe.call/2`): content-type, valid/decodable output, smaller-or-valid where a flag should shrink.
- **libvips-param unit coverage** per flag: assert the encoder emits the expected suffix token from a given struct.
- **Byte-neutral-default assertion:** unset encoder options ⇒ output byte-identical to the current baseline (guards the no-rebake claim).
- **Cache-key + ETag inclusion:** two requests differing only in an encoder option get distinct keys/ETags; identical options ⇒ identical.
- **imgproxy grammar:** order-insensitivity / alias equivalence / sparse-override merge (config default kept when arg omitted).
- **Config validation/range tests:** enum + range rejection at the boundary.

Out of scope for tests: combinatorial flag coverage (leave to focused unit/property tests), and the silent-buffering memory claim (not relevant here).

## Out of scope / follow-ups

- No new compatibility target.
- Animated/multi-page encoder interactions unchanged.
- The exact libvips `heifsave` AVIF speed param name/direction is confirmed at implementation time against the deployed libvips.
