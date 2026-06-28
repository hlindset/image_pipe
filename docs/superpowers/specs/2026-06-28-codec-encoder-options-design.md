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

## Core principle: the neutral core speaks libvips

The product-neutral core exposes **libvips-native** encoder params — libvips field names, libvips value semantics, libvips ranges. libvips is the actual encoder, so it is the natural neutral vocabulary for encoder knobs (it is the engine, not a dialect). Each compatibility parser keeps its **own** vocabulary at the URL surface and *translates* into the libvips-native core; dialect-specific names/values/quirks stay isolated in the parser. We deliberately **diverge from imgproxy's defaults** where libvips differs (notably AVIF) — the core does not replicate imgproxy's documented defaults; a host that wants imgproxy parity sets the libvips knob explicitly.

The tables below give the **neutral (libvips) field** and, in the last column, the **imgproxy URL token + value** that translates to it (§7 owns the translation). imgproxy's flags are **Pro** — not in the OSS checkout; verified against the imgproxy docs checkout (`/Users/hlindset/src/imgproxy-docs`, `usage/processing.mdx` + `configuration/options.mdx`) and the OSS `vips/vips.c` save wrappers (authoritative for the libvips mapping), plus live libvips 8.18.2 introspection.

### JPEG — libvips `jpegsave`

| neutral field (libvips) | type / range | imgproxy URL translation (`jpgo:%progressive:%no_subsample:%trellis_quant:%overshoot_deringing:%optimize_scans:%quant_table`) |
| --- | --- | --- |
| `interlace` | bool | `progressive` (bool) |
| `subsample_mode` | `:auto`/`:on`/`:off` | `no_subsample` (bool): `true` ⇒ `:off` |
| `trellis_quant` | bool | `trellis_quant` (bool) |
| `overshoot_deringing` | bool | `overshoot_deringing` (bool) |
| `optimize_scans` | bool | `optimize_scans` (bool) |
| `quant_table` | int 0–8 | `quant_table` (int) |

### PNG — libvips `pngsave` (8.18.2, **pinned**)

| neutral field (libvips) | type / range | imgproxy URL translation (`pngo:%interlaced:%quantize:%quantization_colors`) |
| --- | --- | --- |
| `interlace` | bool | `interlaced` (bool) |
| `palette` | bool | `quantize` (bool) |
| `bitdepth` | `1`/`2`/`4`/`8`/`16` | `quantization_colors` (int 2–256) → bucket (below) |
| `filter` | `:none`/`:sub`/`:up`/`:avg`/`:paeth`/`:all` | set `:none` when imgproxy `quantize` is on |

**`quantization_colors` → `bitdepth`, not `colours`.** libvips 8.18.2 `pngsave` has **no `colours` param**; palette size is `bitdepth ∈ {1,2,4,8,16}`. The neutral field is `bitdepth` directly. The **imgproxy parser** buckets `quantization_colors` exactly as imgproxy does (`vips/vips.c` `vips_pngsave_go`): `>16 → 8`, `5–16 → 4`, `3–4 → 2`, `≤2 → 1` (so the imgproxy path never emits `16`). imgproxy also sets `filter: none` when quantizing; the imgproxy parser sets the neutral `filter: :none` in that path (a host can set `filter` directly via the neutral core). imgproxy's *auto*-quantize path (source already ≤8-bit palette) is imgproxy-internal and **out of scope** — we quantize only on explicit `quantize`. PNG quantization needs libvips built with Quantizr or libimagequant (a deployment dependency, not a no-op).

### WebP — libvips `webpsave`

| neutral field (libvips) | type / range | imgproxy URL translation (`webpo:%compression:%smart_subsample:%preset`) |
| --- | --- | --- |
| `lossless` | bool | from `compression` enum (below) |
| `near_lossless` | bool | from `compression` enum (below) |
| `smart_subsample` | bool | `smart_subsample` (bool) |
| `preset` | `:default`/`:photo`/`:picture`/`:drawing`/`:icon`/`:text` | `preset` (same names) |
| `effort` | int 0–6 | *(no URL token — host config only; was imgproxy env `WEBP_EFFORT`)* |

imgproxy `compression` enum → the two libvips bools: `lossy` ⇒ neither; `lossless` ⇒ `lossless: true`; `near_lossless` ⇒ `near_lossless: true`.

### AVIF — libvips `heifsave` (8.18.2, **pinned**)

| neutral field (libvips) | type / range | imgproxy URL translation (`avifo:%subsample`) |
| --- | --- | --- |
| `subsample_mode` | `:auto`/`:on`/`:off` | `subsample` (same names) |
| `effort` | int 0–9 | *(no URL token — host config only; imgproxy env `AVIF_SPEED` translates as `effort = 9 - speed`)* |

`subsample: auto` ≈ "subsample when Q<90" (imgproxy-documented; libvips heifsave decides the exact threshold internally). The neutral core uses libvips `effort` directly (default 4); we **do not** replicate imgproxy's `speed 8` default. imgproxy's env `AVIF_SPEED` is mapped by `effort = 9 - speed` (pinned: `vips/vips.c:1285` `"effort", 9 - opts.AvifSpeed`; libvips 8.18.2 `heifsave` has **no `speed` param**, only `effort`).

### JXL — libvips `jxlsave` (migrating the already-landed `jxl_effort`)

| neutral field (libvips) | type / range | imgproxy URL translation |
| --- | --- | --- |
| `effort` | int 1–9 (unset ⇒ libvips default 7) | *(no URL token; imgproxy env `JXL_EFFORT` is config-only)* |

Migrated from the flat `jxl_effort` config key / `Plan.Output` field into `JxlOptions{effort}` for uniformity. The existing 7-vs-4 divergence (libvips default 7, imgproxy default 4) is the precedent for this whole "neutral core tracks libvips" posture.

## Design

### 1. Typed per-format structs (`plan` boundary)

Field names and value semantics are **libvips-native** (not imgproxy's):

```
ImagePipe.Plan.Output.JpegOptions{interlace, subsample_mode, trellis_quant,
                                   overshoot_deringing, optimize_scans, quant_table}
ImagePipe.Plan.Output.PngOptions{interlace, palette, bitdepth, filter}
ImagePipe.Plan.Output.WebpOptions{lossless, near_lossless, smart_subsample, preset, effort}
ImagePipe.Plan.Output.AvifOptions{subsample_mode, effort}
ImagePipe.Plan.Output.JxlOptions{effort}
```

- Plain typed `defstruct` + `@type t`. **Every field defaults to `nil`.**
- Each module exposes `merge/2` — sparse per-field override, where a non-`nil` field in the override wins and `nil` keeps the base. (The only logic; otherwise dumb data containers.)
- No token/encoding logic here — that lives in the encoder (`output` boundary owns libvips).

**Byte-neutral default principle.** The neutral default for *every* encoder-option field is **unset** (`nil`). `nil` ⇒ the encoder emits no libvips suffix token for that field, leaving the libvips `*save` default. Therefore *default output is byte-identical to today*, for **all** dialects. Consequences:

- **No imgproxy differential-fixture rebake.** Existing wire conformance is preserved bit-for-bit.
- **The neutral core tracks libvips, not imgproxy.** Defaults are unset (emit nothing ⇒ libvips' own default). We do **not** seed imgproxy's documented per-flag defaults; where libvips and imgproxy differ (AVIF effort 4 vs imgproxy speed-8/effort-1; JXL effort 7 vs imgproxy 4), the core follows libvips and the divergence is accepted (already the posture for the shipped `jxl_effort 7`). A host opts into imgproxy-like behavior by setting the libvips knob explicitly.
- `Config.default/1` reports the **unset** value for each `*_options` field (an all-`nil` struct), so introspection matches emitted behavior with no special-casing.

### 2. `Plan.Output`

- **Add** `encoder_options :: %{optional(format) => JpegOptions.t | PngOptions.t | WebpOptions.t | AvifOptions.t | JxlOptions.t}` (default `%{}`).
- **Remove** the `jxl_effort` field (migrated into `encoder_options[:jpeg_xl]`).
- One map field (not five siblings): threads through Policy/Resolved/Cache as a single value and mirrors the existing `format_qualities` map.

### 3. `ImagePipe.Config`

- Add five map-valued neutral keys (libvips-named): `jpeg_options`, `png_options`, `webp_options`, `avif_options`, `jxl_options`. Remove the flat `jxl_effort` key.
- Per-field validation uses **libvips** types/enums/ranges (not imgproxy's, which may be narrower): jpeg `quant_table` 0–8, `subsample_mode ∈ {auto,on,off}`; png `bitdepth ∈ {1,2,4,8,16}`, `filter ∈ {none,sub,up,avg,paeth,all}`; webp `preset ∈ {default,photo,picture,drawing,icon,text}`, `effort` 0–6; avif `subsample_mode ∈ {auto,on,off}`, `effort` 0–9; jxl `effort` 1–9; all bools as bool.
- `@map_defaults` seed **unset** structs (all-`nil` fields) for the five keys. `Config.default/1` returns the unset struct.
- `apply_to_output/2` stamps the resolved structs into `Plan.Output.encoder_options` — gives **IIIF/TwicPics** host defaults for free (no URL surface).
- `jxl_options.effort` keeps the existing late-resolution behavior: `resolve!/2` validates but does **not** default it; `Output.Policy` applies the libvips-aligned `7` when unset (today's `output.jxl_effort || Config.default(:jxl_effort)` becomes `JxlOptions.effort || 7`). Preserves byte-neutrality for JXL.

### 4. Precedence / layering

Two-slot model, identical to how `quality` already works:

```
config default struct   ← imgproxy URL token override (sparse, per-field present-wins)
```

- **imgproxy:** `apply_request_defaults` reads the resolved `*_options` structs from `defaults` (the same resolved neutral config `apply_to_output/2` would stamp), then `merge/2`s the URL-token override structs over them, sets `output.encoder_options`.
- **IIIF / TwicPics:** inherit config defaults via `Config.apply_to_output/2`; no tokens.

**Cross-dialect consistency is a requirement, not a freebie.** imgproxy's bespoke `apply_request_defaults` does **not** call `apply_to_output/2`, so it must fold the *same* resolved `*_options` from `defaults` that `apply_to_output/2` stamps — otherwise imgproxy and IIIF/TwicPics could diverge on host-configured defaults. Because §1 makes defaults all-`nil`, the no-config baseline is trivially identical across dialects; the requirement bites only when a host sets an encoder option. A test pins this (see Testing).

### 5. Threading: Policy → Resolved → Encoder

- `Output.Policy` carries the full `encoder_options` map (pre-negotiation — output format not yet chosen).
- `resolve/2` picks `Map.get(encoder_options, negotiated_format)` ⇒ `Output.Resolved.encoder_options` is the **single** negotiated struct (replaces `Resolved.jxl_effort`). Mirrors `format_qualities` map → `quality` scalar resolution.
- **New per-format suffix-token machinery (this is real new encoder work, not reuse).** Today only the JXL path builds a bracketed libvips suffix (`jxl_vix_suffix/2`, private); non-JXL formats encode via `Image.write(image, :memory, suffix: suffix, quality: quality)` and `output_options/2`, which emit only `[suffix:, quality:]` with **no** save-param machinery. We add a general per-format token builder that appends the option tokens to the libvips suffix (`.jpg[Q=80,interlace=true,…]`), reusing the existing `Enum.reject(&is_nil/1)` idiom. It must be threaded through **both** encode entry points the JXL path already special-cases: the streamed delivery path (`deliver`/`lazy_output`) **and** `encode_to_buffer/3` (the quality-search probe). Example tokens:
  - `.jpg[Q=80,interlace=true,trellis_quant=true,quant_table=3]`
  - `.webp[Q=79,lossless=true,smart_subsample=true,preset=photo,effort=6]`
  - `.png[interlace=true,palette=true,bitdepth=8,filter=none]` (quantize on: `quantization_colors 128 → bitdepth 8`, plus `filter=none`)
  - the current `jxl_effort` token path reads `JxlOptions.effort`.

### 6. Cache key + ETag

Encoder options change stored bytes ⇒ they **must** compose the cache key:

- `Cache.Key` — the key data carries the **whole `Plan.Output.encoder_options` map** (pre-negotiation), the exact structural analogue of how `output_plan_data`/`output_data` already carry the full `format_qualities` map (not the resolved scalar). The three `jxl_effort` literals (`output_plan_data` ×2 clauses + `output_data`) are replaced by `encoder_options`. `MaterialDigest.canonicalize/1` hashes structs deterministically via its generic map clause (the `__struct__` atom distinguishes formats), so no `Plan.KeyData` impl is needed.
- The ETag inherits **for free**: the ETag derives from `Key.plan_material/2` (minus `:cache`), so once `encoder_options` is in the key data it threads into both the key and the ETag — **no separate ETag edit**.

This is identity, **not** a generation gate (no interaction with `max_body_bytes`/pixel limits). Greenfield: reshape the canonical key data in place; no data-version bump.

### 7. imgproxy parser surface

The imgproxy parser keeps **imgproxy vocabulary** at the URL and **translates** into the libvips-native struct (per the "imgproxy URL translation" columns in the source-of-truth tables). All dialect quirks (the names, the `compression`→two-bool split, the `quantization_colors`→`bitdepth` bucket, `filter: none` on quantize) live **only** here.

- New URL tokens + aliases in the option grammar: `jpeg_options`/`jpgo`, `png_options`/`pngo`, `webp_options`/`webpo`, `avif_options`/`avifo`.
- No URL token for webp/avif/jxl `effort` (imgproxy exposes those only as env config; a host sets the neutral libvips `effort` directly).

**Translation map (imgproxy arg ⇒ libvips field/value):**

- jpeg: `progressive`⇒`interlace`; `no_subsample:true`⇒`subsample_mode: :off`; `trellis_quant`/`overshoot_deringing`/`optimize_scans`⇒same; `quant_table`⇒`quant_table`.
- png: `interlaced`⇒`interlace`; `quantize:true`⇒`palette: true` **and** `filter: :none`; `quantization_colors`⇒`bitdepth` via the imgproxy bucket (`>16→8, 5–16→4, 3–4→2, ≤2→1`).
- webp: `compression`⇒`{lossless, near_lossless}` (`lossy`⇒neither, `lossless`⇒`lossless: true`, `near_lossless`⇒`near_lossless: true`); `smart_subsample`⇒same; `preset`⇒`preset`.
- avif: `subsample`⇒`subsample_mode`.

**URL arg decoding (the omit-vs-false rule).** Each token is colon-positional per the imgproxy signature with **all args optional**, matching imgproxy's "redefine only the args present":

- An **empty / absent** positional ⇒ the translated libvips field stays `nil` ⇒ **no override**, the config default (host or unset) is kept. An empty positional is **not** decoded as `false`.
- A **present** positional sets the field (`1`/`t`/`true` ⇒ `true`, `0`/`f`/`false` ⇒ `false` for bools; the literal/translated value for ints/enums).
- Worked examples: `jpgo:::true` ⇒ only `optimize_scans: true` (positions 1–2 empty ⇒ `interlace`/`subsample_mode` stay `nil`); `jpgo:true` ⇒ only `interlace: true`. A host-configured `interlace: true` survives a `jpgo` token that omits position 1.

The parser produces sparse libvips-named `*Options` structs (absent token ⇒ struct absent / all-`nil`) in `parsed_request`; `apply_request_defaults` merges them over the config-default structs.

**`optimize_scans` requires `progressive` (imgproxy doc).** libvips `jpegsave` accepts `optimize_scans` without `interlace`. Decision: **accept and emit as-is** (no cross-field rejection) — the effective `interlace` may legitimately arrive from config while the URL sets only `optimize_scans`, so a parse/config-time rejection would wrongly fail valid post-merge states. libvips decides the interaction.

### 8. Fiddle + docs

- `fiddle/assets/` Svelte: the demo drives **imgproxy URLs**, so its controls use **imgproxy vocabulary** for the URL-token flags (the parser translates). Control types: **checkboxes** for the bools (`progressive`, `no_subsample`, `trellis_quant`, `overshoot_deringing`, `optimize_scans`, `interlaced`, `quantize`, `smart_subsample`); **selects** for the enums (`compression`, `preset`, `subsample`); **number inputs** for `quant_table` (0–8) and `quantization_colors` (2–256). The effort knobs (host-config only) get no control.
- `docs/imgproxy_support_matrix.md`:
  - **Surface axis:** flip the four "Output and encoding" / "Advanced encoder options" rows to supported, noting these are translated into the libvips-native neutral core.
  - **Behavioral/"Diverges" note:** add an AVIF default-effort divergence note (ImagePipe core uses libvips `effort` default 4; imgproxy default is speed 8 / effort 1), mirroring the existing `jxl_effort` 7-vs-4 divergence treatment.
  - **Reconcile existing JXL rows:** the migration of `jxl_effort` → `jxl_options` means the existing `IMGPROXY_JXL_EFFORT ⚠️` bullet and the `IMGPROXY_*` ⭕ encoder-config stub rows must be updated in the same change.
  - Note the PNG-quantize libvips-build dependency (Quantizr / libimagequant).

## Boundaries

Dependency *directions* are all already permitted; the **exports allowlist is not**:

- **Required export change:** the `plan` boundary (`lib/image_pipe/plan.ex`) uses an **explicit `exports:` allowlist** that enumerates each `Output.QualitySearch.*` submodule individually. The five new `Plan.Output.JpegOptions`/`PngOptions`/`WebpOptions`/`AvifOptions`/`JxlOptions` modules **must be added to that list**, or `output`/`cache`/`config`/`parser` referencing them is a compile-time Boundary error.
- `output` (encoder, policy, resolved) → `plan` ✓.
- `ImagePipe.Config` (top-level, `deps: [Plan]`) builds structs ✓.
- imgproxy parser (`parser` → `plan`) builds structs ✓.
- `cache` → `plan` ✓.

No new namespace; no dep-direction change — but the five export entries above are required.

## `jxl_effort → JxlOptions` migration checklist

Removing the flat `jxl_effort` field touches every current reference. The implementer must migrate **all** of these (the list is exhaustive as of this spec — verify none were added since):

- `lib/image_pipe/config.ex` — drop the `jxl_effort` schema key + `@default_jxl_effort`; add `jxl_options` (unset default); `apply_to_output/2` stamps `encoder_options`.
- `lib/image_pipe/plan/output.ex` — remove `jxl_effort` field/type; add `encoder_options`.
- `lib/image_pipe/output/policy.ex` — both `from_output_plan/3` clauses + the struct field; carry `encoder_options`, resolve to the negotiated struct in `resolve/2`; apply the `effort || 7` default for JXL.
- `lib/image_pipe/output/resolved.ex` — replace `jxl_effort` with the negotiated `encoder_options` struct.
- `lib/image_pipe/output/encoder.ex` — **three** sites, not one: `lazy_output` pattern-match on `jxl_effort:`, `encode_to_buffer/3` reading `resolved.jxl_effort`, and the `jxl_vix_suffix`/`encode_jxl_*` consumers. All read `JxlOptions.effort`.
- `lib/image_pipe/output/native_jxl_search.ex:37` — reads `resolved.jxl_effort`; must read `JxlOptions.effort` off the resolved struct. **(Easy to miss.)**
- `lib/image_pipe/cache/key.ex` — three literals (`output_plan_data` ×2 clauses + `output_data`) → `encoder_options` (whole map; see §6).
- `lib/image_pipe/parser/imgproxy.ex` — the `imgproxy_overlay/0` comment citing `jxl_effort: 4` as the byte-parity lever; reconcile the referent.
- `lib/image_pipe/parser/imgproxy/options.ex:329` — `Map.put(output, :jxl_effort, …)` replaced by encoder_options folding (config defaults + URL merge).
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — `jxl_effort: nil` in `@default_output` + the `output_request()` typespec.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — both `output_plan/1` clauses set `jxl_effort: request.jxl_effort`.

## Testing

These options change encoded *bytes*, not decoded *pixels*, so the PNG pixel-differential cannot compare them (per #343). Acceptance:

- **Wire/header tests** (real `ImagePipe.call/2`): content-type, valid/decodable output, smaller-or-valid where a flag should shrink.
- **libvips-param unit coverage** per flag: assert the encoder emits the expected suffix token from a given struct.
- **Byte-neutral-default assertion:** encode with `encoder_options: %{}` vs the pre-change encoder path on a fixed source, assert byte-equality (guards the no-rebake claim). Includes AVIF: unset ⇒ no `effort` token ⇒ libvips default 4 (the accepted divergence from imgproxy, which the baseline must not paper over).
- **Cross-dialect inheritance:** an IIIF (or TwicPics) request under a host-configured `jpeg_options: %{interlace: true}` produces output reflecting it — pins the §4 "imgproxy `apply_request_defaults` folds the same defaults as `apply_to_output`" requirement so dialects can't drift.
- **imgproxy translation:** assert the imgproxy arg→libvips field map (e.g. `jpgo` `progressive`⇒`interlace`, `no_subsample:true`⇒`subsample_mode: :off`; `webpo` `compression:near_lossless`⇒`near_lossless: true`; `pngo` `quantization_colors`→`bitdepth` bucket; `avifo` `subsample`⇒`subsample_mode`).
- **Sparse-override merge (omit-vs-false):** a focused parser test asserting a config-set neutral field (e.g. `interlace: true`) **survives** an omitted leading URL position (`jpgo::true`), and that a present `0`/`false` positional **does** override — pins the §7 decode contract.
- **Cache-key + ETag inclusion:** two requests differing only in an encoder option get distinct keys/ETags; identical options ⇒ identical.
- **imgproxy grammar:** order-insensitivity / alias equivalence.
- **Config validation/range tests:** enum + range rejection at the boundary.

Avoid the project's test anti-patterns: no hand-built-struct misuse tests, no name/existence policing; assert at the wire/config boundaries.

**Telemetry:** no telemetry surface change. Encoder options are non-sensitive product-neutral data but are **not** added to any event's metadata in this change, so the default Logger and the OTel `Capture` lists need no update. (If a future change surfaces them on the encode span, both subscription surfaces + `@safe_keys` must be updated together, with a `telemetry_prefix`-scoped test — out of scope here.)

Out of scope for tests: combinatorial flag coverage (leave to focused unit/property tests), and the silent-buffering memory claim (not relevant here).

## Out of scope / follow-ups

- No new compatibility target.
- Animated/multi-page encoder interactions unchanged.
- imgproxy's *auto*-quantize PNG path (source already ≤8-bit palette) — imgproxy-internal; we quantize only on explicit `quantize`.
