# TwicPics support matrix

This matrix compares ImagePipe's `ImagePipe.Parser.TwicPics` support with the
[TwicPics media transformation API](https://www.twicpics.com/docs/essentials/api.md).

ImagePipe treats TwicPics URLs as a compatibility parser for a product-neutral
`ImagePipe.Plan`. Supported transformations translate cleanly into canonical
plan / output / cache / response fields. Unsupported transformations fail before
source fetch or cache lookup — ImagePipe doesn't ignore them.

Unlike the imgproxy dialect — whose URLs are order-insensitive, with its parser
emitting a fixed-order pipeline regardless of option order — the TwicPics dialect
is **order-dependent**: transformations apply in chain order and relative units
(`p`, `s`) resolve against the running dimensions (`resize=340/resize=50p` →
170px). ImagePipe's `Plan` is an ordered pipeline by design, so this maps
directly; the TwicPics-specific quirks stay isolated in the parser and the Plan
carries only product-neutral relative dimension units.

> **Seeded at design time (2026-05-31).** Statuses reflect the intended v1
> outcome. 📋 marks work scoped for v1 but **not yet implemented** — flip 📋 → ✅
> as each row lands. The design spec is
> [`docs/superpowers/specs/2026-05-31-twicpics-parser-design.md`](superpowers/specs/2026-05-31-twicpics-parser-design.md).

## Reference documentation

Source index: <https://www.twicpics.com/llms.txt>

### Essentials

- [TwicPics API](https://www.twicpics.com/docs/essentials/api.md) — writing requests to the transformation API (URL shape, `twic=v1/` chaining, order).
- [Domain Configuration](https://www.twicpics.com/docs/essentials/domain-configuration.md) — setting up domains in the TwicPics dashboard.
- [Path Configuration](https://www.twicpics.com/docs/essentials/path-configuration.md) — configuring domain paths to tweak, control, and protect delivery (origin mapping).

### Reference

- [Color chaining](https://www.twicpics.com/docs/reference/color-chaining.md) — how color transformations, overlays, and masks interact.
- [TwicPics Native Attributes](https://www.twicpics.com/docs/reference/native-attributes.md) — attributes recognized by TwicPics Native.
- [API Parameters](https://www.twicpics.com/docs/reference/parameters.md) — complete reference of transformation parameter types.
- [Placeholders API](https://www.twicpics.com/docs/reference/placeholders.md) — the placeholders API.
- [API Transformations](https://www.twicpics.com/docs/reference/transformations.md) — complete reference of supported media transformations.

## Status legend

| Status | Meaning |
| --- | --- |
| ✅ Supported | The parser translates this into `ImagePipe.Plan` or another request facet. |
| ➕ Extension | An ImagePipe feature with no TwicPics counterpart, exposed through the dialect grammar. |
| 📋 Planned (v1) | Scoped for the first iteration, not yet implemented. Flip to ✅ when it lands. |
| ⚠️ Partial | Some TwicPics syntax or semantics supported, but not the whole option. |
| 🔗 URL-only | Supported as a request option, but not a TwicPics dashboard / config default. |
| 🧩 Host-owned | Plug, router, or web-server configuration owns this outside ImagePipe. |
| 🚫 Rejected | Recognized and intentionally unsupported; returns an error before side effects. |
| ⭕ Missing | Not implemented and not yet scoped. |
| 🛑 Out of scope | Excluded from ImagePipe's library surface (e.g. video). |

## URL shape, source, and configuration

| TwicPics feature | Status | Notes |
| --- | --- | --- |
| `?twic=v1/<chain>` query parameter | ✅ Supported | Required `v1/` prefix; chain is an ordered `/`-separated list of `name=args`. `twic` may appear anywhere in the query string. |
| Ordered chaining | ✅ Supported | Transformations apply in order; later transforms see earlier results. Modeled as an ordered `Plan` pipeline executed sequentially. |
| Running-dimension relative units (`p`, `s`) | ✅ Supported | Resolved against the running image at execution time, not statically at parse. Requires an additive `Plan.Operation.Resize` dimension widening. |
| Static chain collapse / shadowing | ⭕ Missing | TwicPics collapses redundant transforms (`resize=340/resize=50p` → `resize=170`). Deferred optimization, **not** correctness: v1 runs each op and resolves relative units at runtime. Collapse is sound only when operands are literal *and* the intermediate dimension is provably fixed. Buys perf + sharpness (avoids double resampling). |
| Path → source resolution | ✅ Supported | `conn.path_info` resolves to a `Plan.Source` reusing the imgproxy path-source origin mechanism. |
| Multi-origin [path configuration](https://www.twicpics.com/docs/essentials/path-configuration.md) | ⭕ Missing | Prefix → origin mapping. Out of scope for v1; single configured origin only. |
| [Domain configuration](https://www.twicpics.com/docs/essentials/domain-configuration.md) | 🧩 Host-owned | Dashboard domain setup has no ImagePipe equivalent; the host router/Plug owns mounting. |
| URL signature / path protection | ⭕ Missing | Not modeled for TwicPics yet. |

## Transformations

Mapped against [API Transformations](https://www.twicpics.com/docs/reference/transformations.md).

| TwicPics transform | Status | Notes / Plan mapping |
| --- | --- | --- |
| `resize=W` | ✅ Supported | Single dim → `Resize(:fit, W, :auto)`, preserves aspect. |
| `resize=WxH` | ✅ Supported | Exact dims, may distort → `Resize(:stretch, …)` (= imgproxy `force`). |
| `resize=W:H` (ratio) | 🚫 Rejected | Surface-preserving resize-to-ratio has no clean mapping to an existing op; deferred with its own operation design. |
| `resize-max` / `resize-min` | 🚫 Rejected | Conditional variants deferred; recognized and rejected. |
| `cover=WxH` | ✅ Supported | `Resize(:cover, …, guide: focus)` — fill + crop to focus. |
| `cover=W:H` (ratio) | ✅ Supported | `CropGuided(:full_axis, :full_axis, aspect_ratio: …, guide: focus)` — largest matching-ratio area. Integer and decimal ratios (e.g. `16:9`, `1.5:2`) both supported. **Diverges (behavioral) when the largest-area dimension is fractional.** When the matching-ratio area has an integer dimension (e.g. `cover=16:9` on a 400×400 → 400×225), ImagePipe's integer crop is byte-identical to TwicPics. When it is fractional (e.g. `cover=2:3` on 400×400 → 266.667×400), TwicPics resamples the float area to the rounded integer output with sub-pixel center-crop phase, antialiasing the cropped-axis edges; ImagePipe extracts a sharp integer crop. Placement matches to sub-pixel; the difference is confined to edge antialiasing on the cropped axis. |
| `cover-max` / `cover-min` | 🚫 Rejected | Conditional variants deferred. |
| `contain=WxH` | ✅ Supported | `Resize(:fit, …)` — fits inside, may be smaller, no letterbox. |
| `contain-max` / `contain-min` (aliases `max` / `min`) | 🚫 Rejected | Conditional variants deferred. |
| `inside=WxH` | ⚠️ Partial (v1) | `Resize(:fit, …)` + `Canvas(W, H, placement: center, fill: transparent)` — letterboxed to exact dims. **Transparent fill only**; user-specified `background` deferred. Non-alpha output (e.g. `output=jpeg`) flattens the letterbox (documented, tested). **Pixel dimensions only** in v1 (relative units deferred). |
| `inside=W:H` (ratio) | ✅ Supported | `Canvas({:ratio, w, 1}, {:ratio, h, 1}, placement: center, fill: transparent)` — pads/letterboxes the whole image into a box of this aspect ratio with transparent borders (expands the image's canvas on the needed axis; never crops). Single op, no resize. Integer and decimal ratios (e.g. `4:3`, `1.5:2`) both supported. (`cover=W:H` crops to the ratio; `inside=W:H` pads to it.) **Transparent fill only**; user-specified `background` deferred. Non-alpha output flattens the letterbox. |
| `crop=WxH` | ✅ Supported | `CropGuided(W, H, guide: :carried)` — reads the carried point. Crop-size: an omitted dim / `-` means `1s` = full running axis (`:full_axis`), not aspect-preserving auto. Pixel **and** relative (`p` / `s` → `{:ratio}`) dimensions, resolved against the running image at execution time. |
| `crop=WxH@XxY` | ✅ Supported | `CropRegion(x: X, y: Y, width: W, height: H)`; **carries** the point through the crop (translated + clamped into the new frame), like every other geometry op — it does **not** reset it to the crop-result centre. The official docs claim a reset; live TwicPics disagrees ([#331](https://github.com/hlindset/image_pipe/issues/331), confirmed by differential probe). Both axes must be explicit (an omitted axis is rejected). Pixel **and** relative dimensions/coordinates; zero-based coordinates (`@0x0`) supported. |
| `focus=<anchor>` | ✅ Supported | One of the eight anchors, resolved at its chain position to a concrete point and carried for the following `cover` / `crop`; emits a positional `set_focus` `Directive` (no pixel operation). |
| `focus=<coords>` (relative `p` / `s`) | ✅ Supported | A relative coordinate resolves against the running frame at its chain position into a carried point; emits a positional `set_focus` `Directive` (no pixel operation). An **out-of-range** relative focus (a ratio > 1, e.g. `150p`) is **clamped to the far edge** at resolution — matching live TwicPics — not rejected. A ratio of exactly 1 (`100p`) is the edge/corner. |
| `focus=<coords>` (bare pixel) | ✅ Supported | Pixel-coordinate focus ([#321](https://github.com/hlindset/image_pipe/issues/321)) resolves against the running frame at its chain position (rescaled by any shrink-on-load) into a carried point; emits a positional `set_focus` `Directive` (no pixel operation). Mixed-unit pairs (`100x50p`) are supported. Positive out-of-bounds clamps to the far edge; negative coordinates are rejected before any source fetch. |
| `focus=auto` | ✅ Supported | Content-aware subject focus → the `{:smart, :face_assist}` guide for the next `cover` / `crop`; emits no operation. **Diverges (behavioral):** TwicPics leaves `auto` unspecified ("chosen automagically" — no documented algorithm; its explicit object detection lives in the separate `refit*` family). ImagePipe approximates it with libvips attention saliency blended toward detected faces (~0.7), the same engine as imgproxy `g:sm` with face detection. Falls back to plain attention (`VIPS_INTERESTING_ATTENTION`) when no detector is configured, so detector-less hosts get pure saliency. |
| `focus=center` | ✅ Supported | Resolves to the centre point (= the default carried point). The documented `anchor` parameter list omits `center` (it lists eight literals), but **live TwicPics accepts `focus=center`** (verified: returns `200`, whereas a bogus `focus=middle` returns `404`), so supporting it matches observed behavior. |
| `zoom=N` | 🚫 Rejected | Deferred; `Resize` already has `zoom_x` / `zoom_y` so a fast follow is cheap. |
| `flip=x\|y\|both` | 🚫 Rejected | Deferred; maps to `Flip`. |
| `turn=<angle>` | 🚫 Rejected | Deferred; maps to `Rotate` (right-angle multiples). |
| `background=<color>` / `background=remove` | 🚫 Rejected | Color chaining deferred; `remove` needs AI background removal. |
| `border=<color>` | 🚫 Rejected | Color chaining deferred. |
| `colorize=…` | 🚫 Rejected | Color chaining deferred. |
| `achromatopsia` / `deuteranopia` / `protanopia` / `tritanopia` | 🚫 Rejected | Experimental color-blindness corrections; deferred. |
| `refit-cover` / `refit-inside` | 🚫 Rejected | Content-aware resizing; deferred. |
| `truecolor` | 🚫 Rejected | PNG quantization control; deferred. |
| `download` | ⭕ Missing | Forces browser download; `Response` disposition could model it later. |
| `noop` | ⭕ Missing | Pass-through; deferred. |
| `duration` / `from` / `to` | 🛑 Out of scope | Video slicing. ImagePipe treats video as out of scope. |

### Focus state (carried)

TwicPics carries the focus as **image state transformed with the pixels**, not as a
value baked onto the consuming op (confirmed by black-box probing of live TwicPics
— see `docs/twicpics_porting_reference.md` → "Focus state", `tools/twicpics_focus_probe.exs`).
ImagePipe models this faithfully:

- A `focus` segment emits a positional `%ImagePipe.Plan.Operation.Directive{name:
  :set_focus, payload: operand}` that resolves its operand (anchor / literal px /
  relative `p`/`s`, including mixed pairs) **once**, against the running frame at
  its chain position, into an exact-rational point stored as the neutral
  `carried_point` field on `ImagePipe.Transform.State`. The directive is addressed
  to the plan's carried resolver strategy (`ImagePipe.Parser.TwicPics.Resolver`,
  spec §4.4), which owns `:set_focus` resolution and delegates every other op to
  the neutral resolver.
- Each geometry **transformer** (`resize`/`contain`, `cover`'s scale, `inside`'s fit
  + letterbox, the EXIF/orientation flush) applies its own realized affine to the
  carried point; **consumers** (`cover`, `crop`) read it via the `:carried` gravity
  and normalize it to a focal point at the libvips boundary (the only rounding
  point). The point persists across multiple consumers until a `crop=…@XxY` reset.
- This is order-sensitive (focus resolves against the frame at its position) and
  carries faithfully through EXIF-oriented sources. `focus=auto` stays a
  consumer-resolved smart-gravity mode (not a carried point). `zoom`/`turn`/`flip`
  are focus consumers/transformers too but their TwicPics segments are deferred
  (above), so they compose with this model once they land.
- **Stage/order (#434, #438):** TwicPics plans carry the
  `ImagePipe.Parser.TwicPics.Resolver` strategy (mirroring the imgproxy
  strategy's shape). It owns positional focus resolution — the `:set_focus`
  `Directive` resolves against the frame at its position and commits the
  carried point — and hands every other operation to the product-neutral
  `ImagePipe.Transform.NeutralResolver`.

## Output and encoding

Mapped against [API Parameters](https://www.twicpics.com/docs/reference/parameters.md).

| TwicPics feature | Status | Notes |
| --- | --- | --- |
| `output=auto` | ✅ Supported | `Plan.Output` `:automatic` — Accept-negotiated, emits `Vary: Accept`. |
| `output=avif\|webp\|jpeg\|png` | ✅ Supported | Explicit `{:explicit, format}`, bypasses negotiation. |
| `output=heif` | 🚫 Rejected | Not in the v1 explicit-format set (`avif`/`webp`/`jpeg`/`png`); the parser rejects it with `{:unsupported_output, "heif"}` before side effects. |
| `output=blurhash\|preview\|maincolor\|meancolor\|blank` | 🚫 Rejected | Non-image preview outputs; deferred. |
| `output=h264\|h265\|vp9` | 🛑 Out of scope | Video output codecs. |
| `quality=1..100` | ✅ Supported | URL `Plan.Output` quality — **top precedence**. When the URL omits `quality`, the configured host default (`twicpics: [quality: …]`, neutral default `80`; per-format `webp 79 / avif 63 / jpeg_xl 77`) applies as the base. |
| `quality-max` / `quality-min` | 🚫 Rejected | Conditional variants deferred. |

**Host neutral config (surface + behavioral).** The neutral `ImagePipe.Config`
tunables — `quality`, `format_quality`, `strip_metadata`/`keep_copyright`,
`strip_color_profile`, `preserve_hdr`, the per-format encoder options
(`jpeg_options`/`png_options`/`webp_options`/`avif_options`/`jxl_options`), and the
`autoquality_*` knobs — are accepted under the `twicpics:` key, validated through `ImagePipe.Config`, and
stamped onto `Plan.Output`. A URL `quality=N` still wins over the configured
default. **Behavioral default:** absent host config, output uses the neutral
default quality (above) rather than the libvips encoder built-in. An invalid
autoquality combination (e.g. `autoquality_method: :size` with no `:size` target)
is rejected at mount time.

## Debug headers (ImagePipe extension)

| Chain segment | Status | Notes |
| --- | --- | --- |
| `debug=1` (also `true`/`0`/`false`) | ➕ Extension | **No TwicPics counterpart.** Opts a single request into `X-ImagePipe-*` debug response headers, honored only under the `allow_debug_headers: true` mount flag. Sets `Plan.Response.debug?` and emits no operation, so it is **order-independent** and never affects produced bytes, the cache key, or the ETag (all three exclude `Plan.Response`). An invalid value is rejected (`{:invalid_debug, value}`) before side effects, like any bad chain segment. **Unprotected:** TwicPics has no request signing, so anyone reaching the mount can add it — see [debug_headers.md](debug_headers.md). |

## Metadata and orientation

Mapped against [Path Configuration](https://www.twicpics.com/docs/essentials/path-configuration.md), which notes that "EXIF orientation and color profiles may be changed or removed [...] since they are used for generating the transformed image" — TwicPics bakes EXIF orientation into the pixels by default.

| TwicPics behavior | Status | Notes |
| --- | --- | --- |
| EXIF auto-orientation (default) | ✅ Supported | Input conditioning, not a URL transform: the parser sets `Plan.auto_rotate: true`, so an EXIF-tagged source is rendered upright and the orientation tag is dropped. Applied before chained transforms, which therefore see the upright frame. No URL option toggles it in v1. |

## Parameter types

Mapped against [API Parameters](https://www.twicpics.com/docs/reference/parameters.md). These are the value grammars the transformations above consume.

| TwicPics type | Status | Notes |
| --- | --- | --- |
| Length (px / `p` percent / `s` scale) | ✅ Supported | `{:px, n}` (bare number = pixels); `p`/`s` convert to an exact `{:ratio, n, d}`. Dimensions are strictly positive; coordinates are zero-based. A bare-pixel value is absolute, so a fractional result rounds at parse time half away from zero — matching live TwicPics (`(7/2)` → 4px, `7.2` → 7px, `2.5` → 3px). The sign/zero rule is checked against the *exact* value (an exact `0` or negative is rejected), then a rounded dimension is clamped to ≥ 1 — so a strictly-positive value that rounds down to zero (`(1/4)` = 0.25 → 1px) is kept, not rejected. Positions round the same way but allow `0` and apply no clamp. `p`/`s` stay exact (resolved against the running axis at execution, where the shared transform layer rounds). |
| Size (`WxH`, `-` auto) | ✅ Supported | One dimension may be `-` for auto. Mixed units allowed. |
| Ratio (`W:H`) | ✅ Supported | Two strictly-positive numbers — integer, decimal, or expression (e.g. `16:9`, `1.5:2`, `(5*2):3`) — folded to an exact integer `{:ratio, n, d}` (no pixel rounding; a ratio is already exact). |
| Coordinates (`XxY`) | ✅ Supported | Two zero-based Lengths; used for the `crop=…@XxY` origin (pixel **or** relative `p` / `s` coords → `CropRegion`, resolved against the running image) and for relative-unit `focus` (→ `{:focal}` guide; bare-pixel coordinate focus deferred). |
| Anchor (8 named positions) | ✅ Supported | `top`, `bottom`, `left`, `right`, four corners → Plan guides. No `center` anchor — `center` is the default focus only. |
| Crop size | ✅ Supported | Distinct from Size: omitted dim / `-` means `1s` = full running axis (`:full_axis`), **not** aspect-preserving auto. `crop=320` ≡ `320x-` ≡ `320x1s`. |
| Number with expressions `(1/3)`, `+ - * /` | ✅ Supported | A `number` is a decimal literal **or** a fully *parenthesized* expression over `+ - * /` with nesting and normal precedence (`(1/3)`, `(5*(7+2)/3)`, `(100/(4/2))`). Constant-folds to an exact rational at parse time. A bare top-level operator (`5*3`) is rejected — live TwicPics 404s it; only `(5*3)` is accepted. The outer-paren requirement lets the chain splitter treat a top-level `/` as a segment separator and an in-paren `/` as division. Decimal literals follow the JSON number grammar: the integer part is `0` or a no-leading-zero run and a dot needs a non-empty fraction, so `.5`, `5.`, `00.5`, and `01` are rejected (matching live TwicPics), while `0.5`, `5.0`, `0.05` are accepted. A JSON exponent suffix `[eE][+-]?[0-9]+` folds in as `mantissa × 10^exp` (`1e2` → 100, `1.5e2` → 150, `5e-1` → rounds to 1; leading zeros allowed only in the exponent, `1e02` = `1e2`); a malformed/empty exponent (`1e`, `1e+`, `1e2.5`) is rejected. **Diverges** at extreme magnitudes: TwicPics parses numbers into IEEE-754 doubles and 404s overflow/underflow (`1e309`, `1e-1000`), whereas ImagePipe folds to an exact rational and accepts any magnitude (an overflow becomes a huge `{:px, n}` later bound by downstream dimension limits; an underflow clamps to 1px) — a deliberate consequence of the exact-rational model, not the IEEE-754 range. Applies to every numeric leaf (length, size, coordinates, crop size, ratio). |
| Color (names / hex / rgb / hsl / alpha) | 🚫 Rejected | Used by color chaining; deferred. |
| Angle (number / named) | 🚫 Rejected | Used by `turn`; deferred. |
| Axis (`x` / `y` / `both`) | 🚫 Rejected | Used by `flip`; deferred. |
| Boolean (`true`/`yes`/`on` …) | ⭕ Missing | No v1 transform consumes a boolean yet. |
| Padding (CSS-style shorthand) | ⭕ Missing | No v1 transform consumes padding yet. |

## Placeholders and Native

| TwicPics feature | Status | Notes |
| --- | --- | --- |
| [Placeholders API](https://www.twicpics.com/docs/reference/placeholders.md) | ⭕ Missing | LQIP / placeholder generation; out of scope for v1. |
| [TwicPics Native attributes](https://www.twicpics.com/docs/reference/native-attributes.md) | 🛑 Out of scope | Client-side frontend attribute system, not a server URL API. |

## Differential conformance

`test/image_pipe/twicpics_differential_conformance_test.exs` verifies ImagePipe's
geometry/placement against committed reference output baked from the live hosted
TwicPics Image API (`mise run twic:bake`). It is the **behavioral/placement**
enforcement of this matrix.

The suite decodes both TwicPics' committed output and ImagePipe's live output and
**compares pixels** (`PixelCompare.outliers ≤ tol.budget`), because **TwicPics is
libvips-based** — the same engine ImagePipe renders with — so per-pixel comparison is
the right, stricter gate. This runs on the default `mix test` lane without network
access.

- **`:equal`** cases assert that ImagePipe matches TwicPics within the per-case
  tolerance budget (minor cross-version resampling skew absorbed).
- **`:diverges`** cases stay on the default lane but assert an *accepted, monitored*
  divergence sits inside an expected two-sided band — failing if it grows (regression)
  or shrinks toward a match (promote signal). The two `cover=2:3` fractional-area cases
  (`cover_ratio_tall`, `focus_bottomright_cover_ratio`) are `:diverges`, tracked under
  [#331](https://github.com/hlindset/image_pipe/issues/331): the divergence above is
  real, understood, and permanent, so it is monitored within a band rather than excluded.
- Quarantined cases (`@tag :twicpics_triage`) are excluded by default; they record a
  divergence under active investigation with a reason (+ tracking issue) while keeping
  the case exercised and its fixture baked. There are currently **0** — the `cover=2:3`
  cases moved to `:diverges` (monitored), and the third prior quarantine
  (`crop=WxH@XxY` focus-carry) was a real bug, fixed to match live TwicPics — see the
  `crop=WxH@XxY` row.

Any placement divergence surfaced by the suite and deliberately modelled as a
permanent difference should be documented here with a "Diverges" note in the relevant
transformation row above.

Regeneration, the source-hosting handshake, and the bake/triage workflow are
documented in
`test/support/image_pipe/test/twicpics_differential/README.md`.
