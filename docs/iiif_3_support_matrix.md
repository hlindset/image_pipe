# IIIF Image API 3.0 support matrix

`ImagePipe.Parser.IIIF` targets **IIIF Image API 3.0, Level 2 conformance**. It is a compatibility *parser* that translates the IIIF positional request grammar `…/{identifier}/{region}/{size}/{rotation}/{quality}.{format}` (and `…/{identifier}/info.json`) into a product-neutral `ImagePipe.Plan`, then runs the same core transform/output pipeline as every other dialect. The IIIF processing order **Region → Size → Rotation → Quality (→ Format)** maps onto the fixed native pipeline order.

Spec: <https://iiif.io/api/image/3.0/> · Compliance: <https://iiif.io/api/image/3.0/compliance/> · Validator: <https://github.com/IIIF/image-validator>

## How to read this

Each row tracks one of three axes (same discipline as `docs/imgproxy_support_matrix.md`):

| Axis | Question | Where |
| --- | --- | --- |
| **Surface** | Do we parse the same URL grammar / config? | the grammar tables below |
| **Stage / order** | Do we run compatible processing stages in IIIF order? | "Processing order" + the shared native pipeline (`docs/imgproxy_support_matrix.md`) |
| **Behavioral / pixel** | Does a matching request produce conformant output? | the wire tests (`test/parser/iiif_wire_test.exs`) + the official `image-validator` gate + the "Diverges" notes |

Status legend: ✅ supported · ➖ deliberately deferred (an optional `extraFeature`) · ⚠️ supported with a documented divergence.

## Compliance level

We implement **Level 2**: all of Level 0/1 plus the Level-2-required `regionByPx`, `regionByPct`, `sizeByW`, `sizeByH`, `sizeByWh`, `sizeByConfinedWh`, `sizeByPct`, `rotationBy90s`, and the `color`/`gray`/`bitonal` qualities. A handful of `extraFeatures` are implemented beyond Level 2 (`regionSquare`, `sizeUpscaling`, `rotationArbitrary`, `mirroring`, `webp`/`avif` formats); the rest are deferred (see "Deferred extraFeatures").

## Region (→ crop op; `full` emits no op)

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `full` | — | ✅ | No crop operation. |
| `square` | `regionSquare` (extra) | ✅ | `Plan.Operation.CropGuided` with `aspect_ratio: {:ratio, 1, 1}`, centered (`{:anchor, :center, :center}`). The validator's `region_square` checks only that the result is square; centered is the chosen (recommended) placement. |
| `x,y,w,h` | `regionByPx` | ✅ | `Plan.Operation.CropRegion{x: {:px,x}, y: {:px,y}, width: {:px,w}, height: {:px,h}}`. Out-of-bounds is clipped to the image; a region wholly outside, or with `w`/`h` = 0, is a **400**. |
| `pct:x,y,w,h` | `regionByPct` | ✅ | `CropRegion` with `{:ratio, n, d}` coordinates; decimal percents become exact integer ratios (e.g. `10.5` → `{:ratio, 105, 1000}`). |

## Size (→ `Resize`)

A leading `^` enables upscaling. Without `^`, an explicit-size form that would upscale is a **400** (`enlargement: :reject`); `max` clamps (`:deny`); `^` forms allow (`:allow`). See "Status mapping" for the 400 path.

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `max` / `^max` | — | ✅ | `Resize{mode: :fit, width: :auto, height: :auto}`; `max` → `:deny` (never upscales), `^max` → `:allow`. Bounded by `maxWidth`/`maxHeight`/`maxArea` when configured. |
| `w,` | `sizeByW` | ✅ | `Resize{mode: :fit, width: {:px,w}, height: :auto, enlargement: :reject/:allow}`. |
| `,h` | `sizeByH` | ✅ | `Resize{mode: :fit, width: :auto, height: {:px,h}}`. |
| `w,h` | `sizeByWh` | ✅ | `Resize{mode: :stretch, …}` — **exact dimensions, may distort** (IIIF `w,h` is not aspect-preserving). |
| `!w,h` | `sizeByConfinedWh` | ✅ | `Resize{mode: :fit, …}` — fit within the box, preserve aspect. Upscale without `^` → **400** (`:reject`); a fit-*down* returns 200. |
| `pct:n` | `sizeByPct` | ✅ | `Resize{mode: :fit, zoom_x: n/100, zoom_y: n/100}`. The IIIF "`n` ≤ 100" rule is lifted under `^` (`^pct:200` is a valid upscale; bare `pct:200` is a 400). |
| `^…` | `sizeUpscaling` (extra) | ✅ | Any `^` form → `enlargement: :allow`. The pixel-verifying `size_up.py` is a Level-3 validator test (not run at the Level-2 gate); our own wire tests exercise `^` forms. |

## Rotation (→ `Rotate`)

| Token | Feature | Status | Notes |
| --- | --- | --- | --- |
| `0` | — | ✅ | No op. |
| `90` / `180` / `270` | `rotationBy90s` | ✅ | `Plan.Operation.Rotate{angle: …}`. Applied *after* the region crop (see "auto_rotate" below). |
| `!n` (mirroring), arbitrary angle | `mirroring`, `rotationArbitrary` (extra) | ✅ | `!` mirrors (horizontal flip) before rotating; any `[0,360]` angle (360 folds to 0). Right-angle non-mirrored rotation uses the lossless deferred `vips_rot` path; arbitrary or mirrored rotation runs as a materializing `Transform.Operation.Rotate` chain op. |

**Arbitrary/mirrored rotation (stage/order + behavioral, [#257](https://github.com/hlindset/image_pipe/issues/257)):** runs as a materializing `Transform.Operation.Rotate` chain op *after* resize, *before* quality. Because it is `requires_materialization?: true`, `Chain`/`Materializer` flushes the pending EXIF orientation first, so rotation lands in the display frame. Right-angle multiples (incl. when mirrored) use the lossless `vips_rot` primitive (no #211 seam); other angles use the affine `vips_rotate` with premultiplied alpha and a transparent background. (`!0` — mirror with zero angle — is the exception: it emits a standalone horizontal `Flip` folded into `pending_orientation` via the deferred path, not a `Rotate` chain op.) Exposed corners are transparent; for a non-alpha output format the encoder flattens onto `Plan.Output.flatten_background` (IIIF defines no per-request fill knob). No imgproxy parity reference — imgproxy `rot` is right-angle only, so arbitrary rotation is IIIF-driven (IIIF spec is ground truth). Validator-checked by the official `rot_full_non90` / `rot_region_non90` / `rot_mirror` / `rot_mirror_180` tests, run by name in the validator gate (see "Official validator gate" below).

## Quality (→ `gray` op or no-op)

| Token | Feature | Status | Notes |
| --- | --- | --- | --- |
| `default` / `color` | — | ✅ | No op (full color). |
| `gray` | `gray` quality | ✅ | `Plan.Operation.Gray` — **true desaturation** via `Image.to_colorspace(:bw)` (luminance only), *not* a color tint (`Monochrome`). Preserves alpha for alpha-capable output formats. |
| `bitonal` | `bitonal` quality (Level 2 required) | ✅ | `Plan.Operation.Bitonal` — `:bw` colourspace + a `>= 128` threshold (each band → 0/255). The validator's `quality_bitonal` is a **Level-2** test (same level as `color`/`gray`), so it is required for the gate. |

> Note: `default` is the implicit baseline quality and is **not** listed in `extraQualities`; `color`/`gray`/`bitonal` are listed there (qualities supported in addition to `default`, per the spec).

## Format

| Token | Status | Output |
| --- | --- | --- |
| `jpg` | ✅ | `{:explicit, :jpeg}` (Level 2 required) |
| `png` | ✅ | `{:explicit, :png}` (Level 2 required) |
| `webp` | ✅ (extra) | `{:explicit, :webp}` |
| `avif` | ✅ (extra) | `{:explicit, :avif}` |
| `jp2` / `gif` / `tif` / `pdf` | ➖ | Deferred (extra). An unsupported but valid format token → **400** (the validator accepts `[400, 415, 503]`). |

## info.json

Served via the cross-dialect render mechanism (`render: {:custom, ImagePipe.Parser.IIIF.InfoRenderer, params}`; the source header is decoded but the transform pipeline never runs).

| Field | Status | Notes |
| --- | --- | --- |
| `@context`, `type` (`ImageService3`), `protocol`, `profile` (`"level2"`) | ✅ | Exact strings per the 3.0 spec; `info_json` validator-checked. |
| `id` | ✅ | Absolute base URI reconstructed from the request (`scheme://host[:port]/{mount}/{identifier}`), no spurious default-port suffix. |
| `width` / `height` | ✅ | **Display** dimensions (post-EXIF-orientation) via `ImagePipe.Plan.SourceInfo.display_dimensions/1` — a quarter-turn source (EXIF 5–8) reports swapped dims. |
| `maxWidth` / `maxHeight` / `maxArea` | ➖ | **Not advertised** — server-side size limits aren't enforced in the size pipeline yet, so emitting the fields would be a conformance lie (and `maxHeight` without `maxWidth` is spec-invalid). The config surface was removed rather than advertised unenforced; a future change can wire them through the `max`/`^max` size mapping + add the cross-field validation. |
| `extraQualities` / `extraFormats` / `extraFeatures` | ✅ | List what is supported **beyond the baseline** (`default` quality; `jpg`/`png` formats at Level 2), spelled per the IIIF feature registry. |
| **Content negotiation** | ✅ | `Accept: application/ld+json` → `Content-Type: application/ld+json;profile="…/context.json"` with `Vary: Accept`; otherwise `application/json`. Body is byte-identical (cache identity stays Accept-independent). Validator-checked by `jsonld`. |

### Tiling (`tiles` / `sizes`)

Emitted from the **display** dimensions (`SourceInfo.display_dimensions/1`, so EXIF 5–8 sources use swapped dims) by `ImagePipe.Parser.IIIF.Tiling`:

- **`scaleFactors`** — power-of-two ladder `1,2,4,…,2^maxRF`, where `maxRF` = halvings of the **short side** until it drops below **64px** (Cantaloupe's `minSize`). Dimension-only; independent of `tile_size`.
- **`sizes`** — one `{round(W/sf), round(H/sf)}` per scale factor, `round`-half-up (matches Java `Math.round` for positive dims), **smallest-first, full-size last**.
- **`tiles`** — a single entry `{width: min(tile_size, W), height: min(tile_size, H), scaleFactors}`.

**Config:** `iiif: [tile_size: 512]` (default 512). Worked example — 1500×1200/512 → `scaleFactors [1,2,4,8,16]`, `tiles [{512,512,…}]`, `sizes [94×75 … 1500×1200]`.

**Divergence (mechanism, not pixels):** Cantaloupe derives the tile dimension from a separate request-independent `minTileSize`; we use one `tile_size` knob that sets the advertised tile dim directly. Numbers coincide at the 512 default. The IIIF implementation-notes edge round-up (`(width−xr+s−1)/s`) is an equivalent formulation of OpenSeadragon's edge math for power-of-two scale factors; the viewer-sim gate follows OpenSeadragon (the binding client). Granular tiling config (tile_width/height, explicit scale_factors/sizes, configurable minSize) is deferred (follow-up).

## HTTP behavior

| Feature | Status | Notes |
| --- | --- | --- |
| `baseUriRedirect` | ✅ | `{identifier}` (bare) → **303** to `{identifier}/info.json`. Short-circuits before any source fetch (`{:redirect, 303, location}` parse outcome). |
| `cors` | ✅ | `Access-Control-Allow-Origin: *` on every IIIF response (image, info.json, redirect, errors) + `OPTIONS` preflight → 200, applied by the mount-level `ImagePipe.Parser.IIIF.CORS` plug (the parser's `parse/2` returns a tuple, not a conn, so CORS *must* be mount-level). |
| Percent-encoded path segments | ✅ | Every token (`{identifier}`/`{region}`/`{size}`/`{rotation}`/`{quality}`/`{format}`) is percent-decoded per RFC 3986, so e.g. `^` sent as `%5E` or `:` as `%3A` is treated identically to its literal form (`ImagePipe.Parser.IIIF.Path.classify/1`). |
| `jsonldMediaType` | ✅ | See info.json negotiation. |
| Canonical `Link` header (`rel="canonical"`) | ➖ | Optional (`may` per spec); not implemented. Computing the canonical-spelling URL and threading a per-request response header is deferred; the validator does not require it. |

- **Tiled region extraction** — tiled `{x,y,w,h}/{w,h}` requests reuse the existing region-crop + resize path (`regionByPx` + `sizeByWh` → `:stretch`); there is no IIIF-specific tiling stage. Shrink-on-load **engages** for the crop+downscale tile shape (verified: a deep-scale-factor tile decodes the source at reduced resolution — `DecodePlanner` returns `shrink: 4` for a 4096-region→512 tile from a 6000×4000 source; see `test/image_pipe/transform/iiif_tile_decode_test.exs`). End-to-end memory high-water + info/derivative caching are tracked as a follow-up.

## Status mapping (validator-checked)

| Case | Status | Where |
| --- | --- | --- |
| Malformed/unsupported region/size/rotation/quality/format token | **400** | parse → `handle_error/2` |
| Region `w`/`h` = 0; size computes to 0 | **400** | parse |
| Region wholly out of bounds; explicit-size upscale without `^` | **400** | runtime `{:transform_error, {:bad_request, _}}` → `Sender` (the minimal slice of the customizable error→status mechanism, [#267](https://github.com/hlindset/image_pipe/issues/267)) |
| Region partial overlap | **200** (clip) | runtime |
| Unknown identifier (resolver miss); `path_info` shape mismatch (incl. unescaped-slash `a/b`) | **404** | resolver / exact-segment-count dispatch |

## Identifier → Source

The opaque IIIF `{identifier}` is resolved by a host-configured `ImagePipe.Parser.IIIF.Resolver` behaviour (`resolve/2`). A `Resolver.Static` built-in maps identifiers to `Plan.Source` structs from a static map (opaque IDs, no source-structure leakage). A source-string resolver (URL-in-identifier) is deferred.

## Diverges / intentional notes

- **`auto_rotate` defaults `true`** (configurable via `iiif: [auto_rotate: …]`). IIIF region/size/rotation and the info.json dimensions are defined in the **displayed** (post-EXIF-orientation) coordinate system. This is the more correct behavior, not a divergence: an absolute-coordinate `CropRegion` is made display-correct by flushing the EXIF pending orientation *before* the crop (rescaling against the orientation-swapped `decode_shrink`); the IIIF rotation param folds into `pending_orientation` (right-angle, non-mirrored) and is applied after the region crop; an arbitrary or mirrored rotation instead runs as a materializing chain op (see Rotation). The validator reference image is orientation-1, so the gate is unaffected.
- **Upscale-without-`^` returns the spec-recommended 400** via the `{:bad_request, _}` transform reason. The *general*, host-customizable error→status mapping is tracked by [#267](https://github.com/hlindset/image_pipe/issues/267).
- **`gray` on a non-alpha output format (e.g. `gray.jpg`) with an alpha source flattens onto the background** (valid output) via the encoder's format-driven flatten ([#269](https://github.com/hlindset/image_pipe/pull/269)); `gray` preserves alpha for alpha-capable formats (`gray.png`/`gray.webp`/`gray.avif`).

## Deferred extraFeatures

All optional at every compliance level; tracked separately if a consumer needs them: `jp2`/`gif`/`tif`/`pdf` output formats.

## Verification

- **Wire tests:** `test/parser/iiif_wire_test.exs` — real `ImagePipe.call/2` end-to-end (status, headers, `Vary`, CORS, decoded dimensions, gray pixel checks incl. the RGBA→JPEG flatten, info.json + ld+json negotiation, 303 redirect, the 400/404 status mapping).
- **Official validator gate:** the Python `image-validator` runs against a live IIIF endpoint serving the canonical `67352ccc-…` reference image via the Static resolver, at `--version=3.0 --level 2` (see `validator/`). The `--level 2` flag is mandatory — the tool defaults to Level 1 and would otherwise silently skip the Level-2 tests. The gate then runs the arbitrary-rotation + mirroring extraFeatures tests by name (`--test rot_full_non90 --test rot_region_non90 --test rot_mirror --test rot_mirror_180`); `--test` ignores `--level`, so these level-3 tests run without opting into full Level-3 conformance (which would pull in tests for unimplemented features such as `size_up`). All pass (Level 2: 33 tests; rotation/mirror: 4 tests; 0 failures).
- **Tiling unit/property:** `test/parser/iiif/tiling_test.exs` — Cantaloupe reference values, universal invariants with a tautology self-check, OSD `levelSizes` adoption on representative sources.
- **Viewer-simulation gate:** `test/parser/iiif/openseadragon_sim_test.exs` — replicates OpenSeadragon's `getTileUrl` to drive a full tile traversal through `ImagePipe.call/2`, asserting status + decoded dims for every tile and an independent gradient-derived pixel oracle for interior/edge/corner tiles at multiple scale factors.
