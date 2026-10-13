# Bug hunt 4: image processing and output

Scope: transform geometry and decode (including SVG sources and trim), pixel effects and colour, watermarks, output policy and encoding (autoquality, `max-bytes`, PNG options, `info`, placeholders), and object/face detection with smart cropping, in `image_pipe/` at `db4fe3c`. Findings already in `bug-hunt/`, `bug-hunt-2/`, `bug-hunt-3/` and `memory-leak-hunt/`, and open beads, are left out.

**How this was checked:** every finding below was reproduced with real `ImagePipe.Plug.call/2` requests in a cloud session (`MIX_ENV=test mix run`, File source, response decoded and pixels read back), with fake detectors implementing `ImagePipe.Transform.Detector` for the detection findings (real models can't be downloaded here). Numbers are actual output. The repro harness is the same as bug hunt 3 (`/mnt/project-files/bug-hunt-3/image-processing-and-output.md`, end of file).

**Beads that can be closed** (fixed on main, rechecked): `image_plug-e4a.1.5` (info clamp), `e4a.1.6` (JPEG 65,500), `e4a.1.8` (bitonal 16-bit), `e4a.1.9` (pixelate premultiply). For `e4a.1.13` (CMYK metric NIFs): no failure, accuracy unverified.

**Bug hunt 3 fixes rechecked and complete:** 8-bit blur (also progressive-blur, gray, 16-bit), `format-q` with autoquality, arbitrary rotate with shrink-on-load, colorize flatten. The rounding fix is partial (finding 9).

---

## 1. A crop or region on a shrunk decode changes the output size

**Severity:** Medium (the same URL gives a different size for a JPEG/WebP than for a PNG of the same pixels; up to 7 px, about 4%, on narrow crops)

**Where:** `lib/image_pipe/transform/executor.ex:312-345` with `executor/geometry.ex:269-271`. On a shrunk decode the crop box is resolved at full resolution, then divided by the shrink and rounded per axis (`shrink_dimension`). `run_crop` then calls `Geometry.clear_source_frame`, so the following resize works from the rounded live crop, and its aspect error is multiplied by the resize.

**Evidence:** `base` is a 2003×1501 image saved as JPEG, PNG and lossless WebP; `p4000` is 4000×2998. All with `format=png`:

| request | JPEG | PNG (correct) |
|---|---|---|
| `/crop=101,1500/w=50` on base | **50×750** | 50×743 (exact 742.6) |
| `/region=0,0,25,1500/w=3` on base | **3×187** | 3×180 |
| `/crop=1236,985/w=258` on p4000 | **258×205** | 258×206 (exact 205.6) |
| `/region=101,203,1003,707/w=150` on EXIF 5/6 JPEG vs display-frame PNG | **150×105** | 150×106 |

`output=info` reports the same differing sizes. Telemetry for the first row: decode `{:shrink, 2}`, loaded 1001×750, crop became `round(101/2.001)`=50 by 750. Across 80 random requests on 5 source pairs, every size mismatch involved `crop` or `region`; pixels otherwise line up. `test/image_pipe/shrink_through_crop_test.exs` allows ±1 px here, but the first two rows go well past that.

**Suggested fix:** after a crop on a shrunk decode, do what `rotated_source_frame` now does for arbitrary rotate instead of clearing the frame: set `source_dimensions` to the resolved full-resolution crop size and `decode_shrink` to full ÷ live per axis. Add a wire test that `crop=101,1500/w=50` gives the same size for the JPEG and PNG of one image.

**Question for Håvard:** is ±1 px between source formats acceptable by design? Even if so, narrow crops exceed it.

---

## 2. `q` in `request_defaults` or a preset makes every `format=png` request fail with 400

**Severity:** Medium (a host following the documented example breaks all explicit PNG requests)

**Where:** `lib/image_pipe/output/policy.ex:241-251` (`validate_png_quality/2`) checks the merged `request.quality`, not only a `q` written in the URL. `docs/defining-presets.md:70-76` and `docs/shared-url-settings.md:164-180` use `request_defaults: "q=80"` as the example.

**Evidence:**
- `/format=png/src/small.png` with `request_defaults: "q=80"`: **400 `invalid output`** (200 without the default).
- Same with `output=info` added: 400.
- `/preset=hq/format=png/...` with preset `hq => "q=90"`: 400.
- Adding `q=unset`, or leaving out `format=png` (negotiated PNG): 200.

**Suggested fix:** reject `q` with `format=png` only when both come from the URL layer, or drop the rule and ignore `q` for non-palette PNG. Add a wire test with `request_defaults: "q=80"`.

---

## 3. `autoquality` + `max-bytes` ships a lower quality than `max-bytes` alone

**Severity:** Medium (noticeably worse images than the budget allows, labelled `hit`)

**Where:** `lib/image_pipe/output/encode_search.ex:38` (`@default_max_iterations 6`), `cap_descend/4` (~276), `ship_floor/3` (~296). The quality search and the byte-budget phase share one 6-encode budget. The quality search often uses 4–6, leaving the budget phase 0–2 probes, so it falls back to the best fitting quality already encoded or to the floor (25, or 20 for AVIF). This is a different problem from `e4a.1.12`, which is only the label.

**Evidence:** `placement.png`, `w=800/format=webp`:

| request | bytes | quality | outcome | encodes |
|---|---:|---:|---|---:|
| `autoquality=70` | 30,862 | 92 | hit | 6 |
| `max-bytes=18517` | 18,424 | 35 | | |
| `autoquality=70/max-bytes=18517` | 17,034 | **25** | hit | 7 |

At fixed quality q35 is 18,424 bytes, so it fits. A 72-request sweep found 17 that shipped a quality at least 3 below the highest fitting one, all labelled `hit`: `high_freq.jpg` w=800 WebP target 85 shipped q25 (q34 fits); w=300 AVIF target 70 shipped q29 (q38 fits); `exif_large_6.jpg` w=800 JPEG target 70 shipped q57 (q64 fits).

**Suggested fix:** give the byte-budget phase its own probe allowance (about 5), and label a forced floor `best_effort` unless the search bracketed it. Add a test that the combined request never picks a lower quality than `max-bytes` alone.

---

## 4. SVG: `min-w`/`min-h` alone and single-axis `fit=stretch` don't render at the requested size

**Severity:** Medium (documented vector behaviour broken; a 24×24 icon comes back 24×1)

**Where:** `lib/image_pipe/transform/executor.ex:873-904`. `decode_resize_target/3` returns `nil` for single-axis stretch and `decode_box/3` returns `nil` for `min-w`/`min-h` only, so `Decode.SVG` renders at the SVG's own size, `vector?` is false, `vector_group/1` isn't applied and the enlargement clamp stays on. `docs/serving-svg-images.md` and the API contract say a vector source's first-group resize isn't clamped to its own size.

**Evidence:** `icon.svg` is 24×24:

| request | result | expected |
|---|---|---|
| `/w=480/fit=stretch` | **24×1** | 480×24 |
| `/h=480/fit=stretch` | **1×24** | 24×480 |
| `/min-w=480` | **24×24** | 480×480 |
| `/w=480` (control) | 480×480 | 480×480 |
| `/w=480/h=48/fit=stretch` (control) | 480×48 | 480×48 |

`output=info` reports the same wrong sizes.

**Suggested fix:** when an SVG's first group has a resize, always render it as a vector; where the planner has no target, derive the render scale from the stretch axis or from the minimum scale (or at least render at scale 1.0 with `vector?: true`). Wire tests for both cases.

---

## 5. `png-options=bitdepth:2|4` writes wrong gray levels; `bitdepth:1|2|4` with alpha fails with 500

**Severity:** Medium (a valid URL option, or a host `png_options` default, scrambles tones or 500s; `bitonal` + 1-bit PNG fails for every transparent source)

**Where:** `lib/image_pipe/output/encoder.ex:176-183` passes `bitdepth` straight to libvips' PNG saver; `image_pipe_url/lib/image_pipe/plan/output/png_options.ex:19` accepts 1, 2, 4, 8, 16 whatever the image's bands. `docs/processing/output.md` documents it as "Bits per channel".

**Evidence:**
- Gray output at 2 or 4 bits keeps the low bits: uniform gray 150 with `/format=png/png-options=bitdepth:4` decodes to **102** (expected 153). Gray 50/100/137/200 give 34/68/153/136 at 4 bits and 170/0/85/0 at 2 bits; `v mod 16 × 17` and `v mod 4 × 85` reproduce every value. Bare libvips does the same (`pngsave_buffer(Image.new!(64,48,color: [150]), bitdepth: 4)` → 102). `bitdepth:1` thresholds correctly.
- Any gray+alpha result with bitdepth 1, 2 or 4 gives **500 `error encoding image`** (`vips2png: unable to write to target`): `/bitonal/format=png/png-options=bitdepth:1/src/alpha.png`, `/format=png/png-options=bitdepth:2/src/gray_alpha.png`, and `/rotate=30/bitonal/.../bitdepth:1` on an opaque source (rotate adds alpha).
- Silently ignored: bitdepth 1/2/4 on RGB/RGBA results (8-bit output); `palette` on a 16-bit result (`hdr=preserve`), and `palette,bitdepth:16`.

**Suggested fix:** decide the PNG depth in the encoder from the final image. For 1-band images at 2 or 4 bits without palette, shift right by `8 - bitdepth` before saving, or force `palette`; for more than one band, drop `bitdepth` below 8 or force `palette` (tRNS carries alpha). Wire tests: gray 150 at `bitdepth:4` decodes to 153; `/bitonal/png-options=bitdepth:1` on `alpha.png` returns 200.

**Question for Håvard:** the 2/4-bit gray result looks like a libvips bug (its 1-bit path is right); worth reporting upstream, but ImagePipe needs the guard either way.

---

## 6. Detector warmup gives up after ~340 ms, so `detector_required: true` can answer 503 until a restart

**Severity:** Medium (a transient model-download failure at boot leaves detection down for the life of the node)

**Where:** `lib/image_pipe/transform/detector/warmup.ex:31-38,73-91`: `retries: 2`, 100 ms base backoff, then the worker exits `:normal` and, as a transient child, isn't restarted. `lib/image_pipe/processing.ex:106-111` returns `:not_ready` before `detect/2` runs, so no request triggers the download either. `docs/enabling-detection.md:101-104` says an instance downloads models at startup.

**Evidence:** a detector whose `warmup/1` fails 3 times and would then succeed, in an `ImagePipe` instance with `detector_required: true`: log shows "warmup failed … 2/1/0 retries left", then the worker exits after 339 ms. Three later detect requests all return 503 and the warmup counter stays at 3. The bundled adapters take this path on a failed download. The `-vision` server image isn't affected (models baked in). A new variant of the closed `image_plug-297q`.

**Suggested fix:** keep retrying while the detector isn't `ready?`, with backoff capped at 30–60 s, or let a `:not_ready` request start a single-flight background warmup.

**Question for Håvard:** should the retry budget be configurable?

---

## 7. Detection runs even when the crop can't move

**Severity:** Medium (a full inference per request for nothing; a detector error turns a plain resize into `no-store`, or 500 with `detector_required`)

**Where:** `executor.ex:380-392` (`resize_tail` always builds a gravity `Crop`), guided crop at `executor.ex:321-345`, `operation/crop.ex:177-189,275-310` (never checks whether the box equals the image), and `executor/step.ex:63-65` (also forces materialization for these no-op crops).

**Evidence:** 600×400 source, fake detector:

| request | detector | status | Cache-Control | detector called with |
|---|---|---|---|---|
| `/w=300/h=200/fit=cover/detect=face` | finds marker | 200 | `public, max-age=0` | 300×200 |
| `/crop=600,400/detect=face` | finds marker | 200 | | 600×400 |
| `/crop=2000,2000/detect=face` | finds marker | 200 | | 600×400 |
| `/w=300/h=200/fit=cover/detect=face` | always errors | 200 | **`no-store`** | 300×200 |
| same with `detector_required: true` | always errors | **500** | | 300×200 |
| `/w=300/h=200/fit=cover/anchor=smart-face` | always errors | 200 | `no-store` | 300×200 |

The output is the whole image whatever the detector returns. With real models each request pays a full inference (RT-DETR is 175 MB; `detect=all` runs both).

**Suggested fix:** treat a gravity crop whose resolved box equals the live image size as a no-op: no detection, smartcrop, attention or materialization. Applies to `:smart`, `{:smart, :face_assist}` and `{:detect, _}`. Keep the cache key unchanged.

**Question for Håvard:** should `Executor.detections/1` still count these groups (work limits)?

---

## 8. `output=info` reports a size for URLs whose image request fails with 422

**Severity:** Low

**Where:** `lib/image_pipe/processing/terminal.ex` (`executed_facts/4`) never calls `Executor.check_evaluation/1`, which the image path (`processing.ex:227`) and the placeholder path call.

**Evidence:** 150×150 PNG: `/w=20000/enlarge` → 422 `intermediate image exceeds the pixel limit`; `/w=20000/enlarge/output=info` → 200 with result 6324×6324. `/pad=6000` behaves the same. `output=blurhash` correctly gives 422. The docs say `result` is the size of the image the same URL would return.

**Suggested fix:** call `check_evaluation` in the info path before the clamp, or document that info skips work limits.

---

## 9. Rounding fix misses `composite2`/`flatten` and `image`'s `resize`/`rotate`

**Severity:** Low (one 8-bit level, always downward; what remains of bug hunt 3 #5)

**Where:** these steps already return truncated uchar, so the `Rounding.cast` after them does nothing (or there is none):
- `operation/watermark.ex:214-223` (`composite2` then uchar→uchar cast)
- `operation/background.ex:58` (`composite2`, `bg` with alpha) and `:42` (`flatten`, opaque `bg`)
- `operation/colorize.ex:46` (`flatten`)
- `output/encoder.ex:234` (`Image.flatten` for JPEG)
- `operation/resize.ex:48` → `Image.resize/3` (`deps/image/lib/image.ex:4664-4680`: unpremultiply then plain cast)
- `operation/rotate.ex:38` → `Image.rotate/3` → `premultiplied_affine` (`deps/image/lib/image.ex:12040-12043`)

**Evidence:**
- Watermark sweep: 60 of 120 8-bit composites one level below `round(exact)` (mark 255 at alpha 32 on frame 120: exact 136.94, got 136).
- `bg=…,alpha`: 60 of 72 off by one (`[37,37,37,60]` with `bg=646464,0.75`: 81, exact 81.67).
- Opaque `bg`: 13 of 24 off by one (50.59 → 50); JPEG flatten 169.51 → 169.
- Uniform `[200,120,37,100]` with `w=31`, `w=200/enlarge` or `rotate=30` → `[200,119,37,100]`; the 16-bit twin is exact.

**Suggested fix:** run `composite2` and `flatten` on float input, then `Rounding.cast`. For `Image.resize`/`Image.rotate`, add a ``Workaround for `image` `` in `Operation.Resize`/`Operation.Rotate` using `AlphaPremultiply.with_alpha_premultiplied` with `Operation.resize`/`affine`, and file an `image-upstream` bead (none exists for this). Extend the uniform semi-transparent unit tests to watermark, `bg`, `w=31` and `rotate=30`.

---

## 10. A region smaller than half a pixel crashes the request

**Severity:** Low (500, or an exception raised out of `Plug.call` for info and placeholders)

**Where:** a region width or height under 0.5 px rounds to a 0-pixel frame. `DecodePlanner.open_options/3` (`decode_planner.ex:34`, guard `width > 0`) raises `FunctionClauseError`; with a resize, `Executor.Geometry.resize_box/3` (`executor/geometry.ex:173-175`) raises `ArithmeticError`.

**Evidence:** `/region=0,0,0.3,1/format=png/src/placement.png` → 500 (`FunctionClauseError` in `open_options(:png, {0, 1}, nil)`); `/region=0,0,0.3,1/w=10` → 500 (`ArithmeticError`); `/region=0,0,0.3,1/output=info` (also `blurhash`, `lqip-css`) → `Plug.call` raises.

**Suggested fix:** keep the realized region at least 1×1 px, or reject a size that rounds to 0 with 400 at parse time.

---

## 11. A region starting a fraction of a pixel inside the right or bottom edge is rejected

**Severity:** Low

**Where:** `executor.ex:727-740` (`region_crop/2`) rounds the origin before the `left >= display_width` check.

**Evidence:** source 2003 px wide: `/region=2002.4,0,10,10` → 10×10; `/region=2002.6,0,10,10` → **400 `requested region is outside the image`**; `/region=99.99pct,0,10,10` (2002.8) → 400. The contract only rejects a region that starts at or beyond the edge.

**Suggested fix:** check the unrounded origin, then clamp the rounded one; or document that the origin rounds first.

---

## 12. SVG sources ignore `page`

**Severity:** Low (no 422; each `page=N` stores an identical cache copy)

**Where:** `lib/image_pipe/decode.ex:209-212`: `decode_detected(:svg, …)` never checks `request.page`, unlike the raster path's `select_page`.

**Evidence:** `/page=1/src/icon.svg` → 200 at 24×24; `/page=5/output=info/src/icon.svg` → 200 with `"pages":1`; `/page=1/src/base.png` → 422 `requested page does not exist in the source image`.

**Suggested fix:** return `{:page_out_of_range, page, 1}` for page ≥ 1 on SVG.

---

## 13. Placeholders flatten transparency onto black, JPEG output onto white

**Severity:** Low

**Where:** `lib/image_pipe/output/terminal/pixel_space.ex:13` uses `background: :black`; `encoder.ex` `flatten_for_format/2` uses white. The docs say placeholders match the image the same URL returns.

**Evidence:** transparent 60×60 PNG with an opaque white 20×20 square: `/format=jpeg` returns a white image; `/format=jpeg/output=blurhash` returns a dark hash (`LMAJ~A…`) while the BlurHash of the delivered JPEG is light (`L5TSUA…`); `output=lqip-css` returns `#001bb800`.

**Suggested fix:** flatten placeholders onto the output's flatten background (white by default) and bump the `{:blurhash, 1}` / `{:lqip_css, 1}` identity tuples.

**Question for Håvard:** for a PNG/WebP URL (alpha kept), should the placeholder flatten at all, or should LQIP keep alpha as it already does in its colour?

---

## 14. `detector:` accepts any atom; every detect or smart-face request then raises

**Severity:** Low (a config typo shows up only as 500s on some URLs)

**Where:** `lib/image_pipe/config.ex:324-334` uses `{:or, [{:in, [:default, nil]}, :atom]}`. The only module check (`config.ex:782-795`) runs only with `detector_required: true`, and raises `UndefinedFunctionError` rather than `ArgumentError`.

**Evidence:** `detector: MyApp.Typo` (also `:face`, `String`) configures fine; then `/crop=20,20/detect=face` raises `UndefinedFunctionError` "MyApp.Typo.supported_classes/1 is undefined", and `/w=20/h=20/fit=cover/anchor=smart-face` raises "…identity/1 is undefined". Requests without detection keep working.

**Suggested fix:** after `resolve_detector`, require the module to be loaded and to export the behaviour's callbacks; raise `ArgumentError` naming the option.

---

## 15. `anchor=smart-face` calls a not-ready detector under `detector_required: true`

**Severity:** Low

**Where:** `processing.ex:70-80` checks readiness only for explicit `detect` classes; `operation/crop.ex:181-189,223-228` (face-assist) calls the detector regardless. With the bundled adapter, image_vision's `load_model` then calls `ModelCache.fetch!`, downloading YuNet inside the request.

**Evidence:** detector with `ready?/1` → `false`, `detector_required: true`: `/w=50/h=100/fit=cover/detect=face` → 503 without calling the detector; `/w=50/h=100/fit=cover/anchor=smart-face` → 200 and the detector is called with `classes: ["face"]`. Contradicts `docs/enabling-detection.md:101` ("requests don't download models").

**Suggested fix:** in face-assist, when required and not ready, fall back to attention cropping without calling the detector; or reword the docs to exempt smart-face.

---

## 16. The per-model detection span reports an unavailable child as `:error`

**Severity:** Low (observability)

**Where:** `lib/image_pipe/transform/detector/composite.ex:144-145`: `result_metadata({:error, _})` becomes `%{result: :error}`.

**Evidence:** default detector without image_vision: logs two `[warning] image_pipe transform detect model: error (0 regions, …ImageVision.Face/Objects)` lines, then `detect: unavailable`. Child stop events carry `result: :error`, so the tracer marks each child span failed; the parent correctly says `:unavailable` and the response is a correct cacheable 200.

**Suggested fix:** map `{:error, {:detector, :unavailable}}` to `result: :unavailable`; update `docs/telemetry-events.md` and the logger and handler tests.

---

## 17. `hdr=preserve` is dropped when PNG is chosen automatically

**Severity:** Low

**Where:** `lib/image_pipe/output/policy.ex:360-367` (`supports_hdr?/2`) returns `false` when the format is only known after the transform. The code comment says this is deliberate, but `docs/processing/output.md` promises high bit depth for any PNG response.

**Evidence:** 16-bit RGBA TIFF, no `Accept`: `/hdr=preserve/src/t16.tif` → PNG, **8-bit**; adding `format=png` → PNG, 16-bit.

**Suggested fix:** document the exception, or decide alpha early from the source header and the requested operations.

---

## Not confirmed

- **image_vision concurrent first loads:** `load_model` is check-then-put on `:persistent_term` and `ModelCache.fetch!` has no single-flight, so requests during boot warmup (with `detector_required: false`) can download and load the 175 MB model in parallel. Static reading only (upstream).
- **YuNet channel order:** YuNet expects BGR; image_vision feeds RGB and only divides by 255 although a comment mentions ImageNet normalization. Accuracy impact unmeasured (upstream).
- **Detection on small frames:** detection runs on the shrunk or resized frame (`w=64/h=64/fit=cover` on 6000×4000 hands the detector 96×64), so small faces are likely missed. Design trade-off, unmeasured.
- **Info `dpr` after the result-size clamp:** `/w=4000/dpr=3` on 9000×3000 reports dpr 2.25 at width 8192 (3641 CSS px, not 4000). Needs a contract decision.
- **`ExtendCanvas` rounds offsets half away from zero** while crops and watermarks round ties to even; a half-pixel `extend-offset` may land 1 px off. Untested.
- **`bitdepth:16` on an 8-bit result** widens by ×256 rather than ×257 (under one 8-bit level; same family as bug hunt 2 #4).
- **`blur=1000` / `progressive-blur=1000`** take 4.5 s / 6.1 s on 1600×1200; a work-budget question.

## Checked and clean

- Shrink-on-load without a crop: ~260 random JPEG/WebP vs PNG requests (w/h, cover, contain, stretch, dpr, min-w, zoom, quarter and arbitrary rotations, flips, EXIF 5/6/8) gave identical sizes.
- Trim preview plus full-resolution strips matched a full-resolution `find_trim` on 120 random images; 8/16-bit, gray and JPEG correct.
- Multi-group requests, anchor offsets with dpr and quarter turns, `orient=none`, pad/extend contract examples, `page` on raster and animated sources, truncated sources (415), work limits (422 at delivery and for blurhash).
- No 500s across 4,180 effect requests (19 source types including CMYK, Lab float, scRGB, P3 16-bit, palette, 1-bit × 22 effects × 10 output policies). Requested colours land exactly; watermark placement, assets (EXIF 2–8, odd colour types) and SVG watermarks correct.
- Detector coordinate frames under EXIF 1–8, `orient=none`, rotate/flip, trim, region, shrink-on-load, dpr, zoom; invalid detector returns handled; composite routing/merging correct; unknown classes give 400 before fetch.
- `format-q` with autoquality, `max-bytes` alone, bracket midpoint, `Accept` parsing, `Vary`/ETag, Content-Disposition, `meta`, orientation tag, dpi, gray ICC, animated originals, placeholder vs image orientation.
