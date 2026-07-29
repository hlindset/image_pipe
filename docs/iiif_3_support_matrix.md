# IIIF Image API 3.0 support matrix

`ImagePipe.Dialect.IIIF` targets **IIIF Image API 3.0, Level 2 conformance**. It is a **declarative** dialect (`use ImagePipe.Dialect.Declarative`): its `parse_plan/2` lowers the IIIF positional request grammar `…/{identifier}/{region}/{size}/{rotation}/{quality}.{format}` (and `…/{identifier}/info.json`) into a product-neutral `ImagePipe.Plan`, and the declarative base drives the rest of the lifecycle over `ImagePipe.Plug`'s shared runner — the same runner every other dialect mounts through. The IIIF processing order **Region → Size → Rotation → Quality (→ Format)** maps onto the fixed neutral pipeline order.

## Mounting

```elixir
plug ImagePipe.Plug,
  dialect: ImagePipe.Dialect.IIIF,
  resolver: {MyApp.Resolver, []},
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}],
  allow_origin: "*",
  http_cache: [mode: :enabled],
  tile_size: 512,
  max_width: 4000
```

Configuration is **one flat keyword list**. `ImagePipe.Plug` reads only `:dialect`; everything else goes to `ImagePipe.Dialect.IIIF.Config.validate!/1`, which splits it four ways and validates each layer with its owner:

| Layer | Keys |
| --- | --- |
| Shared runtime (`ImagePipe.Dialect.SharedConfig.keys/0`) | `:sources`, `:cache`, `:max_body_bytes`, `:max_input_pixels`, `:max_result_width`/`:max_result_height`/`:max_result_pixels`, `:telemetry_prefix`, `:auto_avif`/`:auto_webp`/`:auto_jpeg_xl`, `:format_order`, `:output_capabilities`, `:allow_origin`, `:allow_debug_headers` |
| Declarative base (`ImagePipe.Dialect.Declarative.config_keys/0`) | `:http_cache`, `:detector`, `:detector_required`, `:storage_inputs` |
| Neutral output (`ImagePipe.Config.keys/0`) | encode policy: qualities, metadata stripping, color-profile policy, HDR, per-format encoder options, the autoquality knobs, `:auto_rotate` |
| IIIF | `:resolver` (required), `:formats`, `:qualities`, `:tile_size`, `:max_width`, `:max_height`, `:max_area` |

Unknown keys raise at mount. Partitioning cache storage on request headers or cookies uses the mount-level `storage_inputs: [{:header, name}, {:cookie, name}]`; configured header names also enter `Vary`.

Spec: <https://iiif.io/api/image/3.0/> · Compliance: <https://iiif.io/api/image/3.0/compliance/> · Validator: <https://github.com/IIIF/image-validator>

## How to read this

Each row tracks one of three axes (same discipline as `docs/imgproxy_support_matrix.md`):

| Axis | Question | Where |
| --- | --- | --- |
| **Surface** | Do we parse the same URL grammar / config? | the grammar tables below |
| **Stage / order** | Do we run compatible processing stages in IIIF order? | the per-token operation mappings below + the fixed neutral pipeline (`docs/execution_flow.md`) |
| **Behavioral / pixel** | Does a matching request produce conformant output? | the wire tests (`test/image_pipe/dialect/iiif/wire_test.exs`) + the official `image-validator` gate + the "Diverges" notes |

Status legend: ✅ supported · ➖ deliberately deferred (an optional `extraFeature`) · ⚠️ supported with a documented divergence · ➕ ImagePipe extension (no IIIF counterpart).

## Compliance level

We implement **Level 2**: all of Level 0/1 plus the Level-2-required `regionByPx`, `regionByPct`, `sizeByW`, `sizeByH`, `sizeByWh`, `sizeByConfinedWh`, `sizeByPct`, `rotationBy90s`, and the `color`/`gray`/`bitonal` qualities. A handful of `extraFeatures` are implemented beyond Level 2 (`regionSquare`, `sizeUpscaling`, `rotationArbitrary`, `mirroring`, `webp`/`avif` formats); the rest are deferred (see "Deferred extraFeatures").

## Region (→ crop op; `full` emits no op)

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `full` | — | ✅ | No crop operation. |
| `square` | `regionSquare` (extra) | ✅ | `Plan.Operation.CropGuided` with `aspect_ratio: {:ratio, 1, 1}`, centered (`{:anchor, :center, :center}`). The validator's `region_square` checks only that the result is square; centered is the chosen (recommended) placement. |
| `x,y,w,h` | `regionByPx` | ✅ | `Plan.Operation.CropRegion{x: {:px,x}, y: {:px,y}, width: {:px,w}, height: {:px,h}, on_out_of_bounds: :reject}`. A partially overlapping region is clipped to the image (**200**). `w`/`h` = 0 is a parse-time **400**. A region **wholly** outside the image (origin at or past an edge) is a runtime **400** per IIIF — the IIIF builder sets `on_out_of_bounds: :reject` on `CropRegion`, so the shared `Crop` op rejects rather than clamps ([#427](https://github.com/hlindset/image_pipe/issues/427)); other dialects keep the default `:clamp`. See "Status mapping". |
| `pct:x,y,w,h` | `regionByPct` | ✅ | `CropRegion{…, on_out_of_bounds: :reject}` with `{:ratio, n, d}` coordinates; decimal percents become exact integer ratios (e.g. `10.5` → `{:ratio, 105, 1000}`). Same wholly-outside → **400** rule as `regionByPx` (an origin ≥ 100% is outside). |

## Size (→ `Resize`)

A leading `^` enables upscaling. Without `^`, an explicit-size form that would upscale is a **400** (`enlargement: :reject`); `max` clamps (`:deny`); `^` forms allow (`:allow`). See "Status mapping" for the 400 path.

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `max` / `^max` | — | ✅ | `Resize{mode: :fit, width: :auto, height: :auto}`; `max` → `:deny` (never upscales), `^max` → `:allow`. Bounded by `maxWidth`/`maxHeight`/`maxArea` when configured: `max` clamps *down* to the ceiling, `^max` *grows to* the ceiling (upscaling to fill it). Without a configured bound, `max` is source size and `^max` degrades to source size. |
| `w,` | `sizeByW` | ✅ | `Resize{mode: :fit, width: {:px,w}, height: :auto, enlargement: :reject/:allow}`. |
| `,h` | `sizeByH` | ✅ | `Resize{mode: :fit, width: :auto, height: {:px,h}}`. |
| `w,h` | `sizeByWh` | ✅ | `Resize{mode: :stretch, …}` — **exact dimensions, may distort** (IIIF `w,h` is not aspect-preserving). |
| `!w,h` | `sizeByConfinedWh` | ✅ | `Resize{mode: :fit, …}` — fit within the box, preserve aspect. Upscale without `^` → **400** (`:reject`); a fit-*down* returns 200. |
| `pct:n` | `sizeByPct` | ✅ | `Resize{mode: :fit, zoom_x: {:ratio, num, den}, zoom_y: {:ratio, num, den}}` — the `n/100` fraction carried as a **reduced exact ratio** (the constructor gcd-canonicalizes it), e.g. `pct:20.5` → `{:ratio, 41, 200}`. Carrying the ratio (rather than an `n/100` float) lets the derived axis multiply as `dim × num / den` and round half-away exactly at a tie — `pct:20.5` of a 200×300 source is `41×62` (`300 × 41/200 = 61.5 → 62`), where a lossy float gave `61` ([#317](https://github.com/hlindset/image_pipe/issues/317)). The IIIF "`n` ≤ 100" rule is lifted under `^` (`^pct:200` is a valid upscale; bare `pct:200` is a 400). |
| `^…` | `sizeUpscaling` (extra) | ✅ | Any `^` form → `enlargement: :allow`. The pixel-verifying `size_up.py` is a Level-3 validator test (not run at the Level-2 gate); our own wire tests exercise `^` forms. |

**Max bounds (surface + behavioral, [#257](https://github.com/hlindset/image_pipe/issues/257)):** `maxWidth`/`maxHeight`/`maxArea` are enforced as a **uniform output ceiling** on `Plan.Operation.Resize` (product-neutral `max_width`/`max_height`/`max_area` fields), resolved against the extracted-region dims at transform time. Every size form is clamped *down* to fit the ceiling (satisfying the spec's "for all requests … must not be greater than the server-imposed limits" MUST); `max` and `^max` additionally *grow to* the ceiling (`^max` upscales to fill it — previously inert). Effective `maxHeight = maxWidth` when only `maxWidth` is configured (the spec's client-inference, enforced server-side). `maxArea` is floored so `w·h ≤ maxArea` exactly. No imgproxy parity reference — imgproxy has no analogous ceiling; IIIF spec is ground truth.

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

`parse_plan/2` returns a plan with `output: nil` and `render: {:custom, ImagePipe.Dialect.IIIF.InfoRenderer, params}`. The declarative base turns that into a `%ImagePipe.Dialect.RenderTerminal{cache: :none, offers: …}`, whose `fun` opens the decode bracket deep enough for header facts and then calls the renderer through `ImagePipe.Renderer.run/3` (which owns the `[:render]` span). The transform pipeline never runs.

`cache: :none` means the **internal cache is neither read nor written** for `info.json` — the document has no internal cache identity at all, and every request regenerates it. Generated `ETag`/`Cache-Control` headers still apply on a mount with `http_cache: [mode: :enabled]`.

| Field | Status | Notes |
| --- | --- | --- |
| `@context`, `type` (`ImageService3`), `protocol`, `profile` (`"level2"`) | ✅ | Exact strings per the 3.0 spec; `info_json` validator-checked. |
| `id` | ✅ | Absolute base URI reconstructed from the request (`scheme://host[:port]/{mount}/{identifier}`), no spurious default-port suffix. |
| `width` / `height` | ✅ | **Display** dimensions (post-EXIF-orientation) via `ImagePipe.Plan.SourceInfo.display_dimensions/1` — a quarter-turn source (EXIF 5–8) reports swapped dims. |
| `maxWidth` / `maxHeight` / `maxArea` | ✅ | Advertised when configured (`max_width:`, `max_height:`, `max_area:`), only the configured values (never an inferred `maxHeight`). Cross-field validation: `maxHeight` requires `maxWidth`; `maxArea` standalone OK; `maxWidth` alone OK. Enforced as a **uniform output ceiling** on the size pipeline — see the Size section. |
| `extraQualities` / `extraFormats` / `extraFeatures` | ✅ | List what is supported **beyond the baseline** (`default` quality; `jpg`/`png` formats at Level 2), spelled per the IIIF feature registry. |
| **Content negotiation** | ✅ | Negotiated at **delivery** from the current request's `Accept` against the terminal's `offers`: `Accept: application/ld+json` → `Content-Type: application/ld+json;profile="…/context.json"`, otherwise `application/json`. `Vary: Accept` is stamped on both outcomes. The body is byte-identical either way. Validator-checked by `jsonld`. |

### Tiling (`tiles` / `sizes`)

Emitted from the **display** dimensions (`SourceInfo.display_dimensions/1`, so EXIF 5–8 sources use swapped dims) by `ImagePipe.Dialect.IIIF.Tiling`:

- **`scaleFactors`** — power-of-two ladder `1,2,4,…,2^maxRF`, where `maxRF` = halvings of the **short side** until it drops below **64px** (Cantaloupe's `minSize`). Dimension-only; independent of `tile_size`.
- **`sizes`** — one `{round(W/sf), round(H/sf)}` per scale factor, `round`-half-up (matches Java `Math.round` for positive dims), **smallest-first, full-size last**.
- **`tiles`** — a single entry `{width: min(tile_size, W), height: min(tile_size, H), scaleFactors}`.

**Config:** `tile_size: 512` (default 512). Worked example — 1500×1200/512 → `scaleFactors [1,2,4,8,16]`, `tiles [{512,512,…}]`, `sizes [94×75 … 1500×1200]`.

**Divergence (mechanism, not pixels):** Cantaloupe derives the tile dimension from a separate request-independent `minTileSize`; we use one `tile_size` knob that sets the advertised tile dim directly. Numbers coincide at the 512 default. The IIIF implementation-notes edge round-up (`(width−xr+s−1)/s`) is an equivalent formulation of OpenSeadragon's edge math for power-of-two scale factors; the viewer-sim gate follows OpenSeadragon (the binding client). Granular tiling config (tile_width/height, explicit scale_factors/sizes, configurable minSize) is deferred (follow-up).

## HTTP behavior

| Feature | Status | Notes |
| --- | --- | --- |
| `baseUriRedirect` | ✅ | `{identifier}` (bare) → **303** to `{identifier}/info.json`. Short-circuits before any source fetch (`{:redirect, 303, location}` parse outcome). |
| `cors` | ✅ | Host sets the neutral `allow_origin` mount option (the canonical IIIF mount uses `allow_origin: "*"`); `ImagePipe.Plug` then stamps `Access-Control-Allow-Origin` on every response (image, info.json, 303 redirect, errors, 304) and answers `OPTIONS` → `204` + `Allow: GET, HEAD` + `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`. CORS is a dialect-neutral core feature, not an IIIF-specific plug. The `cors` extraFeature is advertised statically (in `ImagePipe.Dialect.IIIF.Info`) and assumes the host configures `allow_origin` — it is not gated on the option. |
| Percent-encoded path segments | ✅ | Every token (`{identifier}`/`{region}`/`{size}`/`{rotation}`/`{quality}`/`{format}`) is percent-decoded per RFC 3986, so e.g. `^` sent as `%5E` or `:` as `%3A` is treated identically to its literal form (`ImagePipe.Dialect.IIIF.Path.classify/1`). |
| `jsonldMediaType` | ✅ | See info.json negotiation. |
| Generated `ETag` / `Cache-Control` | ➕ | **Opt-in.** The dialect's `%Resolved{}` carries `http_cache: :generated`, but `ImagePipe.Response.CachePolicy` emits nothing unless the mount also sets `http_cache: [mode: :enabled]`. When enabled and the resolved source has strong byte identity, responses carry `Cache-Control: public, max-age=31536000, immutable` and an `ETag`, and a matching `If-None-Match` returns `304` before any source fetch, decode, encode, or cache read. See [cdn-http-cache.md](cdn-http-cache.md). |
| `?debug=1` query param | ➕ | **No IIIF counterpart.** Opts a single image request into `X-ImagePipe-*` debug response headers, honored only under the `allow_debug_headers: true` mount flag. The IIIF path grammar has no free slot, so the trigger is an out-of-band query param, read **leniently** — only `1`/`true` enable it; any other value (absent, `0`, `false`, garbage) is ignored, never a 400. Sets `Plan.Response.debug?`, which `ImagePipe.Dialect.Declarative.Identity` deliberately excludes from **both** identity buckets, so it never affects produced bytes, the cache key, or the ETag. The `%ImagePipe.Debug.Info{}` facts are built on every generation regardless of the flag and stored with the cache entry, so flipping `allow_debug_headers: true` surfaces headers for already-cached items with no invalidation, and a cache hit replays the stored origin timings. Applies to image requests only (not `info.json`). Deliberately **not** advertised as an `extraFeature` in `info.json` (§4.9 says extensions *should* be listed, but advertising an unsigned disclosure trigger publicly is undesirable). **Unprotected:** IIIF has no request signing, so anyone reaching the mount can add it — see [debug_headers.md](debug_headers.md). |
| Canonical `Link` header (`rel="canonical"`) | ➖ | Optional (`may` per spec); not implemented. Computing the canonical-spelling URL and threading a per-request response header is deferred; the validator does not require it. |

- **Tiled region extraction** — tiled `{x,y,w,h}/{w,h}` requests reuse the existing region-crop + resize path (`regionByPx` + `sizeByWh` → `:stretch`); there is no IIIF-specific tiling stage. Shrink-on-load **engages** for the crop+downscale tile shape (verified: a deep-scale-factor tile decodes the source at reduced resolution — `DecodePlanner` returns `shrink: 4` for a 4096-region→512 tile from a 6000×4000 source; see `test/image_pipe/transform/iiif_tile_decode_test.exs`). End-to-end memory high-water + info/derivative caching are tracked as a follow-up.

## Status mapping (validator-checked)

Every error response is rendered by `ImagePipe.Dialect.IIIF.Errors` (the dialect's `c:ImagePipe.Dialect.render_error/3`) with `Content-Type: text/plain` and a terse body. A parse rejection is recognized structurally, by the `%ImagePipe.Dialect.Failure{phase: :parse}` envelope the declarative base wraps it in — never by a tag allowlist — so **any** unrecognized parse rejection stays a client error. Everything past parse routes through the shared `ImagePipe.Response.ErrorStatus` table.

| Case | Status | Body | Where |
| --- | --- | --- | --- |
| Malformed/unsupported region/size/rotation/quality/format token | **400** | `bad request` | parse → `Failure{phase: :parse}` → `Dialect.IIIF.Errors` |
| Region `w`/`h` = 0; size computes to 0 | **400** | `bad request` | parse → `Dialect.IIIF.Errors` |
| Explicit-size upscale without `^` | **400** | `upscaling requires the ^ prefix` | runtime `{:transform, {:bad_request, :upscale_required}}`, re-tagged as `{:transform_error, _}` by `Dialect.IIIF.Errors` → `ErrorStatus` (the customizable error→status mechanism, [#267](https://github.com/hlindset/image_pipe/issues/267)) |
| Region wholly out of bounds | **400** | `requested region is outside the image` | runtime `{:transform, {:bad_request, :region_out_of_bounds}}` → `Dialect.IIIF.Errors` → `ErrorStatus` ([#427](https://github.com/hlindset/image_pipe/issues/427)) |
| Region partial overlap | **200** (clip) | — | runtime |
| Unknown identifier (resolver miss); `path_info` shape mismatch (incl. unescaped-slash `a/b`) | **404** | `not found` | resolver / exact-segment-count dispatch, as a parse-phase `:not_found` |
| Requested output format the build can't write (e.g. `.avif` on a libvips without AVIF) | **501** | `requested output format is not supported by this server` | negotiation `{:unsupported_output_format, _}` → `ErrorStatus`. Raised **before** any cache access, and the response carries no `Vary: Accept` |
| Renderer failure whose inner reason `ErrorStatus` can't classify | **500** | `error rendering response` | `{:render, inner}` envelope → `Dialect.IIIF.Errors` |
| Delivery-session failure after negotiation (a raise in a shared post-transform stage) | **500** | `internal server error` | `{:session, _}` → `ErrorStatus` |
| Materialization failure | **415** | — | `{:transform, {:materialize_error, _}}`, re-tagged as `{:decode, _}` |
| `detector_required` gate with no detector available | **422** | — | `{:detector, :unavailable}`, re-tagged as `{:detector_unavailable, :unavailable}` |

> **Out-of-bounds region ([#427](https://github.com/hlindset/image_pipe/issues/427)):** a region wholly outside the image (origin at or past an edge) is **400** per IIIF (spec §4.1, spec.md:192). Because the `Transform.Operation.Crop` op is shared with TwicPics (whose region-OOB behavior is undocumented and clamps), the rejection is **IIIF-gated**: the IIIF plan builder sets `on_out_of_bounds: :reject` on `Plan.Operation.CropRegion`. The resolve-time lowering (`ImagePipe.Transform.Lowering`) then decides "wholly outside" in the **original source frame** (against the source shape, before the decode-shrink coordinate rescale, so a near-edge partial overlap can't be rounded into a spurious reject) and sets `Crop.reject_out_of_bounds`, which returns `{:bad_request, :region_out_of_bounds}` → 400. Every other dialect keeps the default `:clamp` (200), and a *partially* overlapping region always clips to the image (200). If a future deployment disables `^` upscaling, the correct status for a `^`-upscale request is **501** (Not Implemented, IIIF spec §size), not the `:bad_request` → 400 the no-`^` upscale path uses.

## Identifier → Source

The opaque IIIF `{identifier}` is resolved by a host-configured `ImagePipe.Dialect.IIIF.Resolver` behaviour (`resolve/2`), named by the required `resolver:` mount key. A `Resolver.Static` built-in maps identifiers to `Plan.Source` structs from a static map (opaque IDs, no source-structure leakage). A source-string resolver (URL-in-identifier) is deferred.

## Diverges / intentional notes

- **Host neutral config is honored** (surface + behavioral). The neutral
  `ImagePipe.Config` tunables — `quality`, `format_quality`, `strip_metadata`/
  `keep_copyright`, `strip_color_profile`, `preserve_hdr`, the per-format encoder
  options (`jpeg_options`/`png_options`/`webp_options`/`avif_options`/`jxl_options`),
  and the `autoquality_*` knobs — are accepted as flat mount keys, validated through
  `ImagePipe.Config`, and stamped onto `Plan.Output` (`auto_rotate` is one of these
  neutral keys). IIIF has no URL-level encode-quality surface (its `quality` token
  is `color`/`gray`/`bitonal`, not an encoder Q), so host config is the only way to
  set these. **Behavioral default:** absent host config, output now uses the neutral
  default quality — global `80`, per-format `webp 79 / avif 63 / jpeg_xl 77` — rather
  than the libvips encoder built-in. An invalid autoquality combination (e.g.
  `autoquality_method: :size` with no `:size` target) is rejected at mount time.
- **`auto_rotate` defaults `true`** (configurable via the neutral `auto_rotate:` mount key). IIIF region/size/rotation and the info.json dimensions are defined in the **displayed** (post-EXIF-orientation) coordinate system. This is the more correct behavior, not a divergence: an absolute-coordinate `CropRegion` is made display-correct by flushing the EXIF pending orientation *before* the crop (rescaling against the orientation-swapped `decode_shrink`); the IIIF rotation param folds into `pending_orientation` (right-angle, non-mirrored) and is applied after the region crop; an arbitrary or mirrored rotation instead runs as a materializing chain op (see Rotation). The validator reference image is orientation-1, so the gate is unaffected.
- **Upscale-without-`^` returns the spec-recommended 400** via the `{:bad_request, _}` transform reason. The *general*, host-customizable error→status mapping is tracked by [#267](https://github.com/hlindset/image_pipe/issues/267).
- **`gray` on a non-alpha output format (e.g. `gray.jpg`) with an alpha source flattens onto the background** (valid output) via the encoder's format-driven flatten ([#269](https://github.com/hlindset/image_pipe/pull/269)); `gray` preserves alpha for alpha-capable formats (`gray.png`/`gray.webp`/`gray.avif`).
- **`sizeUpscaling` advertised without requiring a max bound.** IIIF §5.1: *"A server that supports `sizeUpscaling` must specify `maxWidth` or `maxArea`."* We advertise `sizeUpscaling` unconditionally — explicit `^` forms (`^w,`/`^pct:n`/`^!w,h`) upscale with no ceiling needed. When no bound is configured, `^max` degrades to source size (it has no ceiling to scale to). We deliberately do not force every host to configure a bound (greenfield zero-config default), so this is a documented divergence, not a hard config error.
- **Identity values are ImagePipe's own** (behavioral; no IIIF counterpart — the spec defines no validator format). The `ETag` and the internal cache key both come from `ImagePipe.Representation.build/3`, over material composed by `ImagePipe.Dialect.Declarative.Identity`: the canonical semantic operation chains, `auto_rotate`, the terminal identity, the canonical output plan, the resolved detector identity, and the negotiation outcome. Generated ETags carry the visible `"ipr1-"` schema prefix. Treat the literal value as opaque and unstable across releases — assert it by round-trip (`If-None-Match` → `304`), by *separation* (two different requests never share one), and by *stability* (the same request twice yields the same value). `storage_inputs` values and the plan's cachebuster move the cache key only, never the ETag.

## Deferred extraFeatures

All optional at every compliance level; tracked separately if a consumer needs them: `jp2`/`gif`/`tif`/`pdf` output formats.

## Verification

- **Wire tests:** `test/image_pipe/dialect/iiif/wire_test.exs` — real `ImagePipe.Plug.call/2` end-to-end (status, headers, `Vary`, CORS, decoded dimensions, gray pixel checks incl. the RGBA→JPEG flatten, info.json + ld+json negotiation, 303 redirect, the 400/404 status mapping).
- **Official validator gate:** the Python `image-validator` runs against a live IIIF endpoint serving the canonical `67352ccc-…` reference image via the Static resolver, at `--version=3.0 --level 2` (see `validator/`). The `--level 2` flag is mandatory — the tool defaults to Level 1 and would otherwise silently skip the Level-2 tests. The gate then runs the arbitrary-rotation + mirroring extraFeatures tests by name (`--test rot_full_non90 --test rot_region_non90 --test rot_mirror --test rot_mirror_180`); `--test` ignores `--level`, so these level-3 tests run without opting into full Level-3 conformance (which would pull in tests for unimplemented features such as `size_up`). All pass (Level 2: 33 tests; rotation/mirror: 4 tests; 0 failures). The official `image-validator` has **no** `maxWidth`/`maxHeight`/`maxArea` test, and `size_up.py` (`^max`) asserts `^max` == full source, so the validator server (`validator/server.exs`) intentionally configures **no** bounds (do not add them there). Max-bounds coverage lives in the wire tests.
- **Tiling unit/property:** `test/image_pipe/dialect/iiif/tiling_test.exs` — Cantaloupe reference values, universal invariants with a tautology self-check, OSD `levelSizes` adoption on representative sources.
- **Viewer-simulation gate:** `test/image_pipe/dialect/iiif/openseadragon_sim_test.exs` — replicates OpenSeadragon's `getTileUrl` to drive a full tile traversal through `ImagePipe.Plug.call/2`, asserting status + decoded dims for every tile and an independent gradient-derived pixel oracle for interior/edge/corner tiles at multiple scale factors.
