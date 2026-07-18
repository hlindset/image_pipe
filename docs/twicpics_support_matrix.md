# TwicPics support matrix

This matrix compares ImagePipe's `ImagePipe.Dialect.TwicPics` support with the
[TwicPics media transformation API](https://www.twicpics.com/docs/essentials/api.md).

`ImagePipe.Dialect.TwicPics` is a self-contained Plug. It parses a URL into an
ordered `ImagePipe.Dialect.TwicPics.Request`. It resolves source and output
policy, builds representation identity before cache access, and executes the
request through its own Pipeline and pipeline-local PointFlow. Request steps
reuse product-neutral Plan operation structs when their semantics match. The
dialect doesn't construct a root `ImagePipe.Plan` or use the framework's
resolver strategy. Unsupported transformations fail before source fetch or
cache lookup. ImagePipe doesn't ignore them.

The imgproxy dialect parses order-insensitive URLs into a fixed-order pipeline.
The TwicPics dialect is **order-dependent**: transformations apply in chain order and relative units
(`p`, `s`) resolve with the running dimensions (`resize=340/resize=50p` →
170px). `Request.steps` preserves the literal chain. `Pipeline.run/4` executes
those steps sequentially, and PointFlow carries focus through each realized
geometry stage.

> **Phase-1 comparison arm.** The framework mount (`ImagePipe.Plug` with
> `ImagePipe.Parser.TwicPics`) remains temporarily so the wire, hosted-SaaS, and
> exact local suites can execute both implementations. This is comparison
> coverage, not the serving architecture after parser retirement. Phase 2 does
> not start until the recorded dual-run gates pass.

## Reference documentation

Source index: <https://www.twicpics.com/llms.txt>

### Essentials

<!-- vale off -->
- [TwicPics API](https://www.twicpics.com/docs/essentials/api.md) — writing requests to the transformation API (URL shape, `twic=v1/` chaining, order).
- [Domain Configuration](https://www.twicpics.com/docs/essentials/domain-configuration.md) — setting up domains in the TwicPics dashboard.
- [Path Configuration](https://www.twicpics.com/docs/essentials/path-configuration.md) — configuring domain paths to tweak, control, and protect delivery (origin mapping).

### Reference

- [Color chaining](https://www.twicpics.com/docs/reference/color-chaining.md) — how color transformations, overlays, and masks interact.
- [TwicPics Native Attributes](https://www.twicpics.com/docs/reference/native-attributes.md) — attributes recognized by TwicPics Native.
- [API Parameters](https://www.twicpics.com/docs/reference/parameters.md) — complete reference of transformation parameter types.
- [Placeholders API](https://www.twicpics.com/docs/reference/placeholders.md) — the placeholders API.
- [API Transformations](https://www.twicpics.com/docs/reference/transformations.md) — complete reference of supported media transformations.
<!-- vale on -->

## Status legend

<!-- vale off -->
| Status | Meaning |
| --- | --- |
| ✅ Supported | The dialect parses and executes this through its ordered request pipeline. |
| ➕ Extension | An ImagePipe feature with no TwicPics counterpart, exposed through the dialect grammar. |
| 📋 Planned (v1) | Scoped for the first iteration, not yet implemented. Flip to ✅ when it lands. |
| ⚠️ Partial | Some TwicPics syntax or semantics supported, but not the whole option. |
| 🔗 URL-only | Supported as a request option, but not a TwicPics dashboard / config default. |
| 🧩 Host-owned | Plug, router, or web-server configuration owns this outside ImagePipe. |
| 🚫 Rejected | Recognized and intentionally unsupported; returns an error before side effects. |
| ⭕ Missing | Not implemented and not yet scoped. |
| 🛑 Out of scope | Excluded from ImagePipe's library surface (e.g. video). |
<!-- vale on -->

## URL shape, source, and configuration

<!-- vale off -->
| TwicPics feature | Status | Notes |
| --- | --- | --- |
| `?twic=v1/<chain>` query parameter | ✅ Supported | Required `v1/` prefix; chain is an ordered `/`-separated list of `name=args`. `twic` may appear anywhere in the query string. |
| Ordered chaining | ✅ Supported | Transformations apply in order; later transforms see earlier results. Stored as literal `Request.steps` and executed sequentially by `Dialect.TwicPics.Pipeline`. |
| Running-dimension relative units (`p`, `s`) | ✅ Supported | Each unit uses the running image at execution time, not a static parse-time size. The dialect reuses neutral dimension terms and measures each realized resize stage before continuing. |
| Static chain collapse / shadowing | ⭕ Missing | **Behavioral divergence:** TwicPics discards an earlier relative resize when a later absolute resize fully shadows it (`resize=50p/resize=340` → `resize=340`). On the 400×400 differential source, TwicPics returns 340×340. Both temporary local comparison arms execute both resizes and return 200×200 because plain resize doesn't enlarge. The suite quarantines the live fixture under [#464](https://github.com/hlindset/image_pipe/issues/464) until the upstream-proven rewrite lands. This isn't a general last-wins rule; chain order remains observable outside a proven shadow. |
| Path → source resolution | ✅ Supported | `conn.path_info` resolves to a product-neutral `Plan.Source.Path` stored on the dialect Request. |
| Multi-origin [path configuration](https://www.twicpics.com/docs/essentials/path-configuration.md) | ⭕ Missing | Prefix → origin mapping. Out of scope for v1; single configured origin only. |
| [Domain configuration](https://www.twicpics.com/docs/essentials/domain-configuration.md) | 🧩 Host-owned | Dashboard domain setup has no ImagePipe equivalent; the host router/Plug owns mounting. |
| URL signature / path protection | ⭕ Missing | Not modeled for TwicPics yet. |
<!-- vale on -->

## Transformations

Mapped to [API Transformations](https://www.twicpics.com/docs/reference/transformations.md).

<!-- vale off -->
| TwicPics transform | Status | Notes / dialect lowering |
| --- | --- | --- |
| `resize=W` | ✅ Supported | Single dim → `Resize(:fit, W, :auto)`, preserves aspect and doesn't enlarge. The live `resize=600` fixture stays 400×400 on a 400×400 source. This characterizes plain resize only; the conditional `resize-min` surface remains rejected below. |
| `resize=WxH` | ✅ Supported | Exact dims, may distort → `Resize(:stretch, …)` (= imgproxy `force`). |
| `resize=W:H` (ratio) | 🚫 Rejected | Surface-preserving resize-to-ratio has no clean mapping to an existing op; deferred with its own operation design. |
| `resize-max` / `resize-min` | 🚫 Rejected | Conditional variants deferred; recognized and rejected. |
| `cover=WxH` | ✅ Supported | `Resize(:cover, …, guide: focus)` — fill + crop to focus. |
| `cover=W:H` (ratio) | ✅ Supported | `CropGuided(:full_axis, :full_axis, aspect_ratio: …, guide: focus)` — largest matching-ratio area. Integer and decimal ratios (e.g. `16:9`, `1.5:2`) both supported. **Diverges (behavioral) when the largest-area dimension is fractional.** When the matching-ratio area has an integer dimension (e.g. `cover=16:9` on a 400×400 → 400×225), ImagePipe's integer crop is byte-identical to TwicPics. When it is fractional (e.g. `cover=2:3` on 400×400 → 266.667×400), TwicPics resamples the float area to the rounded integer output with sub-pixel center-crop phase, antialiasing the cropped-axis edges; ImagePipe extracts a sharp integer crop. Placement matches to sub-pixel; the difference is confined to edge antialiasing on the cropped axis. |
| `cover-max` / `cover-min` | 🚫 Rejected | Conditional variants deferred. |
| `contain=WxH` | ✅ Supported | `Resize(:fit, …)` — fits inside, may be smaller, no letterbox. |
| `contain-max` / `contain-min` (aliases `max` / `min`) | 🚫 Rejected | Conditional variants deferred. |
| `inside=WxH` | ⚠️ Partial (v1) | `Resize(:fit, …)` + `Canvas(W, H, placement: center, fill: transparent)` — letterboxed to exact dims. **Transparent fill only**; user-specified `background` deferred. Non-alpha output (e.g. `output=jpeg`) flattens the letterbox (documented, tested). **Pixel dimensions only** in v1 (relative units deferred). |
| `inside=W:H` (ratio) | ✅ Supported | `Canvas({:ratio, w, 1}, {:ratio, h, 1}, placement: center, fill: transparent)` — pads/letterboxes the whole image into a box of this aspect ratio with transparent borders (expands the image's canvas on the needed axis; never crops). Single op, no resize. Integer and decimal ratios (e.g. `4:3`, `1.5:2`) both supported. (`cover=W:H` crops to the ratio; `inside=W:H` pads to it.) **Transparent fill only**; user-specified `background` deferred. Non-alpha output flattens the letterbox. **Diverges (behavioral/pixel) under shrink:** when a later cover triggers 2× WebP shrink-on-load, ImagePipe and TwicPics resample the invisible RGB beneath the transparent letterbox differently; opaque pixels match. The three `inside_ratio_*_cover_shrink` cases monitor this accepted difference under [#434](https://github.com/hlindset/image_pipe/issues/434). |
| `crop=WxH` | ✅ Supported | This creates an ordered focused `CropGuided(W, H, guide: :center)` step. PointFlow binds its carried point before executable emission. An omitted crop dimension or `-` means `1s`, the full running axis (`:full_axis`), not aspect-preserving auto. Pixel and relative (`p` / `s` → `{:ratio}`) dimensions use the running image at execution time. |
| `crop=WxH@XxY` | ✅ Supported | `CropRegion(x: X, y: Y, width: W, height: H)`; **carries** the point through the crop (translated into the new frame; clamped only when the next `cover`/`crop` consumes it), like every other geometry op — it does **not** reset it to the crop-result centre. The official docs claim a reset; live TwicPics disagrees ([#331](https://github.com/hlindset/image_pipe/issues/331), confirmed by differential probe). Both axes must be explicit (an omitted axis is rejected). Pixel **and** relative dimensions/coordinates; zero-based coordinates (`@0x0`) supported. |
| `focus=<anchor>` | ✅ Supported | One of the eight anchors becomes an ordered `{:set_focus, operand}` step. PointFlow resolves it at its chain position and carries the concrete point for following `cover` / `crop` steps. This step emits no pixel operation. |
| `focus=<coords>` (relative `p` / `s`) | ✅ Supported | A relative coordinate becomes an ordered `{:set_focus, operand}` step and uses the running frame at that position. PointFlow clamps a ratio greater than 1, such as `150p`, to the far edge. This matches live TwicPics. A ratio of exactly 1 (`100p`) denotes the edge or corner. |
| `focus=<coords>` (bare pixel) | ✅ Supported | Pixel-coordinate focus ([#321](https://github.com/hlindset/image_pipe/issues/321)) uses the running frame at its chain position and accounts for shrink-on-load. PointFlow carries the resulting point. Mixed-unit pairs such as `100x50p` work. Positive out-of-bounds values clamp to the far edge. Negative coordinates fail before any source fetch. Live TwicPics returns 404 for the same invalid value, while ImagePipe returns 400. |
| `focus=auto` | ✅ Supported | Content-aware subject focus → the `{:smart, :face_assist}` guide for the next `cover` / `crop`; emits no operation. **Diverges (behavioral):** TwicPics leaves `auto` unspecified ("chosen automagically" — no documented algorithm; its explicit object detection lives in the separate `refit*` family). ImagePipe approximates it with libvips attention saliency blended toward detected faces (~0.7), the same engine as imgproxy `g:sm` with face detection. Falls back to plain attention (`VIPS_INTERESTING_ATTENTION`) when no detector is configured, so detector-less hosts get pure saliency. |
| `focus=center` | ✅ Supported | Resolves to the centre point. The documented `anchor` parameter list omits `center` (it lists eight literals), but **live TwicPics accepts `focus=center`** (verified: returns `200`, whereas a bogus `focus=middle` returns `404`), so supporting it matches observed behavior. |
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
<!-- vale on -->

### Focus state and stage order

TwicPics carries focus as image state through pixel transformations. It
doesn't bake the value onto the consuming operation. Black-box probing of live
TwicPics confirms this behavior. See `docs/twicpics_porting_reference.md` and
`tools/twicpics_focus_probe.exs`.
ImagePipe models this in the dialect pipeline:

- `RequestBuilder` preserves each `focus` as a positional `{:set_focus,
  operand}` step. `Pipeline` gives the step the current `SourceShape`, and
  `PointFlow.set_focus/3` resolves anchor, pixel, or relative coordinates once
  into an exact-rational point. A later literal focus overwrites that point.
- Each geometry transformer (`resize`/`contain`, `cover`'s scale, `inside`'s
  fit and letterbox, and the EXIF/orientation flush) advances the local point by
  its realized scale, translation, or reflection. Consumers (`cover`,
  `crop`) bind a concrete focal gravity immediately before executable emission.
  The point persists across consumers.
- **Diverges (behavioral, detector-gated):** a **smart/detect**-gravity crop
  (`focus=auto` → `{:smart, :face_assist}`) chooses its window from image data, so the
  resolve-time point walk passes the carry through **unchanged** rather than
  translating it by a crop origin it can't know before detection runs. The
  translate-vs-pass-through split only appears when a configured detector's
  detection succeeds. The differential and wire conformance lanes run without
  detectors. In those lanes, `focus=auto` resolves its window from attention and
  never advances the carried point, so old and new behavior agrees.
- This is order-sensitive because focus uses the frame at its position. The
  point carries through EXIF-oriented sources. `focus=auto` stays a
  consumer-resolved smart-gravity mode (not a carried point). `zoom`/`turn`/`flip`
  also consume or transform focus, but this version defers their TwicPics
  segments. They can compose with this model when implemented.
- **Stage/order (#434, #438):** the dialect owns the loop. `Pipeline.run/4`
  seeds one `SourceShape` and one PointFlow for the literal step list, delegates
  product-neutral lowering to `ImagePipe.Transform.NeutralResolver`, follows
  measured continuations without reordering, and flushes pending orientation
  once at the request boundary.

## Output and encoding

Mapped to [API Parameters](https://www.twicpics.com/docs/reference/parameters.md).

<!-- vale off -->
| TwicPics feature | Status | Notes |
| --- | --- | --- |
| `output=auto` | ⚠️ Partial (v1) | The Request's `Plan.Output` is `:automatic`, and local negotiation emits `Vary: Accept`. For the reviewed Chrome `Accept` header, hosted TwicPics selected WebP while ImagePipe's configurable, Accept-only default selected AVIF. Phase 2 must preserve negotiation and decide this compatibility gap from live evidence. |
| `output=avif\|webp\|jpeg\|png` | ✅ Supported | Explicit `{:explicit, format}`, bypasses negotiation. |
| `output=heif` | 🚫 Rejected | Not in the v1 explicit-format set (`avif`/`webp`/`jpeg`/`png`); the parser rejects it with `{:unsupported_output, "heif"}` before side effects. |
| `output=blurhash\|preview\|maincolor\|meancolor\|blank` | 🚫 Rejected | Non-image preview outputs; deferred. |
| `output=h264\|h265\|vp9` | 🛑 Out of scope | Video output codecs. |
| `quality=1..100` | ✅ Supported | URL quality on the Request's `Plan.Output` has **top precedence**. When the URL omits `quality`, the configured host default (neutral default `80`; per-format `webp 79 / avif 63 / jpeg_xl 77`) applies as the base. |
| `quality-max` / `quality-min` | 🚫 Rejected | Conditional variants deferred. |
<!-- vale on -->

**Host neutral config (surface + behavioral).** The neutral `ImagePipe.Config`
options include `quality`, `format_quality`, `strip_metadata`/`keep_copyright`,
`strip_color_profile`, `preserve_hdr`, the per-format encoder options
(`jpeg_options`/`png_options`/`webp_options`/`avif_options`/`jxl_options`), and the
`autoquality_*` knobs. The dialect accepts them as flat options, validates them
through `ImagePipe.Config`, and stamps them onto the Request's `Plan.Output`.
A URL `quality=N` still wins over the configured
default. **Behavioral default:** absent host config, output uses the neutral
default quality rather than the libvips encoder built-in. Mount-time validation
rejects an invalid `autoquality` combination, such as
`autoquality_method: :size` without a `:size` target.

## Debug headers (ImagePipe extension)

<!-- vale off -->
| Chain segment | Status | Notes |
| --- | --- | --- |
| `debug=1` (also `true`/`0`/`false`) | ➕ Extension | **No TwicPics counterpart.** This opts one request into `X-ImagePipe-*` debug response headers when the mount enables `allow_debug_headers: true`. It sets `Request.response.debug?` and emits no operation. The value is order-independent and never affects bytes, the cache key, or the ETag. An invalid value (`{:invalid_debug, value}`) fails before side effects. **Unprotected:** TwicPics has no request signing, so any caller that reaches the mount can add it. See [debug_headers.md](debug_headers.md). |
<!-- vale on -->

## Metadata and orientation

The [Path Configuration](https://www.twicpics.com/docs/essentials/path-configuration.md)
documentation says TwicPics may change or remove EXIF orientation and color
profiles because it uses them to generate the transformed image. TwicPics
writes EXIF orientation into output pixel data by default.

<!-- vale off -->
| TwicPics behavior | Status | Notes |
| --- | --- | --- |
| EXIF automatic orientation (default) | ✅ Supported | This is input conditioning, not a URL transform. Dialect config sets `Request.auto_rotate: true`. ImagePipe renders an EXIF-tagged source upright, drops the orientation tag, and runs chained transforms in the display frame. No v1 URL option toggles this behavior. |
<!-- vale on -->

## Parameter types

The transformations consume the value grammars from
[API Parameters](https://www.twicpics.com/docs/reference/parameters.md).

<!-- vale off -->
| TwicPics type | Status | Notes |
| --- | --- | --- |
| Length (px / `p` percent / `s` scale) | ✅ Supported | `{:px, n}` (bare number = pixels); `p`/`s` convert to an exact `{:ratio, n, d}`. Dimensions are strictly positive; coordinates are zero-based. A bare-pixel value is absolute, so a fractional result rounds at parse time half away from zero — matching live TwicPics (`(7/2)` → 4px, `7.2` → 7px, `2.5` → 3px). The sign/zero rule is checked against the *exact* value (an exact `0` or negative is rejected), then a rounded dimension is clamped to ≥ 1 — so a strictly-positive value that rounds down to zero (`(1/4)` = 0.25 → 1px) is kept, not rejected. Positions round the same way but allow `0` and apply no clamp. `p`/`s` stay exact (resolved against the running axis at execution, where the shared transform layer rounds). |
| Size (`WxH`, `-` auto) | ✅ Supported | One dimension may be `-` for auto. Mixed units allowed. |
| Ratio (`W:H`) | ✅ Supported | Two strictly-positive numbers — integer, decimal, or expression (e.g. `16:9`, `1.5:2`, `(5*2):3`) — folded to an exact integer `{:ratio, n, d}` (no pixel rounding; a ratio is already exact). |
| Coordinates (`XxY`) | ✅ Supported | Two zero-based Length values provide the `crop=…@XxY` origin. Pixel or relative `p` / `s` values become a `CropRegion` that uses the running image. Focus operands can use relative, pixel, or mixed units. |
| Anchor (8 named positions) | ✅ Supported | `top`, `bottom`, `left`, `right`, and four corners become focus operands. The leaf grammar has no `center` anchor. Transformation parsing accepts `focus=center` as a special case. |
| Crop size | ✅ Supported | Distinct from Size: omitted dim / `-` means `1s` = full running axis (`:full_axis`), **not** aspect-preserving auto. `crop=320` ≡ `320x-` ≡ `320x1s`. |
| Number with expressions `(1/3)`, `+ - * /` | ✅ Supported | A `number` is a decimal literal **or** a fully *parenthesized* expression over `+ - * /` with nesting and normal precedence (`(1/3)`, `(5*(7+2)/3)`, `(100/(4/2))`). Constant-folds to an exact rational at parse time. A bare top-level operator (`5*3`) is rejected — live TwicPics 404s it; only `(5*3)` is accepted. The outer-paren requirement lets the chain splitter treat a top-level `/` as a segment separator and an in-paren `/` as division. Decimal literals follow the JSON number grammar: the integer part is `0` or a no-leading-zero run and a dot needs a non-empty fraction, so `.5`, `5.`, `00.5`, and `01` are rejected (matching live TwicPics), while `0.5`, `5.0`, `0.05` are accepted. A JSON exponent suffix `[eE][+-]?[0-9]+` folds in as `mantissa × 10^exp` (`1e2` → 100, `1.5e2` → 150, `5e-1` → rounds to 1; leading zeros allowed only in the exponent, `1e02` = `1e2`); a malformed/empty exponent (`1e`, `1e+`, `1e2.5`) is rejected. **Diverges** at extreme magnitudes: TwicPics parses numbers into IEEE-754 doubles and 404s overflow/underflow (`1e309`, `1e-1000`), whereas ImagePipe folds to an exact rational and accepts any magnitude (an overflow becomes a huge `{:px, n}` later bound by downstream dimension limits; an underflow clamps to 1px) — a deliberate consequence of the exact-rational model, not the IEEE-754 range. Applies to every numeric leaf (length, size, coordinates, crop size, ratio). |
| Color (names / hex / rgb / hsl / alpha) | 🚫 Rejected | Used by color chaining; deferred. |
| Angle (number / named) | 🚫 Rejected | Used by `turn`; deferred. |
| Axis (`x` / `y` / `both`) | 🚫 Rejected | Used by `flip`; deferred. |
| Boolean (`true`/`yes`/`on` …) | ⭕ Missing | No v1 transform consumes a boolean yet. |
| Padding (CSS-style shorthand) | ⭕ Missing | No v1 transform consumes padding yet. |
<!-- vale on -->

## Placeholders and Native

<!-- vale off -->
| TwicPics feature | Status | Notes |
| --- | --- | --- |
| [Placeholders API](https://www.twicpics.com/docs/reference/placeholders.md) | ⭕ Missing | LQIP / placeholder generation; out of scope for v1. |
| [TwicPics Native attributes](https://www.twicpics.com/docs/reference/native-attributes.md) | 🛑 Out of scope | Client-side frontend attribute system, not a server URL API. |
<!-- vale on -->

## Differential conformance

`test/image_pipe/twicpics_differential_conformance_test.exs` verifies the
temporary framework comparison arm and the dialect. It compares their geometry
and placement with committed output from the hosted TwicPics Image API
(`mise run twic:bake`). This enforces the behavioral and placement claims in
this matrix. The suite contains 39 fixtures. Five accepted divergences remain
on the default lane inside two-sided bands. The suite quarantines one unresolved
shadowing case.

The suite decodes the committed TwicPics output and each local arm's live output.
It performs pixel comparison with `PixelCompare.outliers ≤ tol.budget`. TwicPics and
ImagePipe both use libvips, so per-pixel comparison provides the stricter gate.
This runs on the default `mix test` lane without network access.

<!-- vale off -->
- **`:equal`** cases assert that ImagePipe matches TwicPics within the per-case
  tolerance budget (minor cross-version resampling skew absorbed).
- **`:diverges`** cases stay on the default lane but assert an *accepted, monitored*
  divergence sits inside an expected two-sided band — failing if it grows (regression)
  or shrinks toward a match (promote signal). There are five: `cover_ratio_tall` and
  `focus_bottomright_cover_ratio` monitor fractional `cover=2:3` resampling under
  [#331](https://github.com/hlindset/image_pipe/issues/331);
  `inside_ratio_cover_shrink`, `inside_ratio_focus_anchor_cover_shrink`, and
  `inside_ratio_focus_px_cover_shrink` monitor invisible RGB-under-alpha differences
  in transparent letterboxes under [#434](https://github.com/hlindset/image_pipe/issues/434).
- Quarantined cases (`@tag :twicpics_triage`) are excluded by default; they record a
  divergence under active investigation with a reason (+ tracking issue) while keeping
  the case exercised and its fixture baked. There is one:
  `resize_shadow_relative_then_absolute`, tracked by
  [#464](https://github.com/hlindset/image_pipe/issues/464). Its committed TwicPics
  result is 340×340; both temporary local arms return 200×200.
<!-- vale on -->

If the suite exposes a permanent placement difference, add a "Diverges" note
to the relevant transformation row.

The `test/support/image_pipe/test/twicpics_differential/README.md` file
describes regeneration, the source-hosting handshake, and the bake and triage
workflow.
