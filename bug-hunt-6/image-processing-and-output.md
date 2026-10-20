# Bug hunt 6: image processing and output

Scope: transform geometry and decode, pixel operations and colour, watermarks, output policy and encoding, and detection with content-aware cropping, in `image_pipe/` at `fe70ecc`. The hunt concentrated on code changed since bug hunt 5 (`8edf03b..fe70ecc`), which is mostly the bug hunt 5 fixes. Findings already in `bug-hunt/` through `bug-hunt-5/`, and open or deferred beads, are left out.

**How this was checked:** every finding was reproduced with real `ImagePipe.Plug.call/2` requests in a cloud session (`MIX_ENV=test mix run`, File source, response decoded and pixels read back), using the bug hunt 3 harness (`/mnt/project-files/bug-hunt-3/image-processing-and-output.md`, end of file). Detection findings use a fake detector implementing `ImagePipe.Transform.Detector`. libvips 8.18.7, PNG saved with libpng. Numbers are actual output.

**Bug hunt 5 status:** all 17 findings have a fix commit on main and their beads are closed. Re-run here and fixed: date tag as a number (#1, code read), blur budget bypass (#2: `blur=1000/-/w=6000/enlarge` now 4.6 s against 4.5 s for the blur alone), 1-bit PNG (#3), thin JPEG/WebP 415 (#4), `crop-ratio` division (#5), lossless WebP with defaults (#9), watermark opacity rounding (#12, exact `[184,150,59]`), 16-bit palette and sub-8-bit colour (#13), 16-bit white (#14), info dpr (#15), enlarges on oriented sources (#11, exact). Fixed by code reading: #6, #7, #8, #16, #17. **Incomplete:** #11 for `kernel=nearest` (finding 1 below) and #10 for a not-ready detector (finding 6).

---

## 1. `kernel=nearest` downscales of EXIF-oriented, flipped or rotated sources pick different pixels

**Severity:** Medium (pixel art, the main use of `kernel=nearest`, comes out with entirely different pixels; breaks "deferred orientation must preserve the logical result")

**Where:** `lib/image_pipe/transform/executor.ex:554-570` (`run_stored_resize/4`, `enlarges?/2`). f0250a4 flushes the pending orientation only before a resize that enlarges, because the bead notes say "nearest downscale commutes". It doesn't. Nearest-neighbour picks one sample per output pixel at a fixed offset from the left/top edge, so in a mirrored storage frame it picks from the other side of each block. User `flip`, `rotate=90|180|270` and EXIF 2–8 all go through the same pending-orientation path. Transpose (EXIF 5) happens to commute, the others don't.

**Evidence:** a 64×64 PNG of random pixels, its EXIF-tagged twins (orientation stored in the PNG), and pre-flipped/pre-rotated plain twins. Mean absolute difference per channel from the upright result (0 means identical):

| request | EXIF 2 | EXIF 3 | EXIF 6 | `flip=h` vs pre-flipped | `rotate=180` vs pre-rotated | `rotate=90` vs pre-rotated |
|---|---:|---:|---:|---:|---:|---:|
| `kernel=nearest/w=16` | **78.3** | **81.9** | **78.3** | **78.3** | **81.9** | **82.0** |
| `kernel=nearest/w=32` | 84.0 | 82.4 | 84.0 | | | |
| `kernel=nearest/w=21` | 4.0 | 7.6 | 3.9 | 4.0 | 7.6 | 4.0 |
| `kernel=nearest/w=128/enlarge` | 0 | 0 | 0 | | | |
| `w=16` (lanczos3) | 0 | 0 | 0.28 | 0 | 0 | 0.28 |

`/flip=h/kernel=nearest/w=16` is byte-for-byte the mirror of the unflipped result, which is the storage-frame resize followed by the flip; the contract wants the resize of the flipped image. The same shows on a 1999×2999 photo-like JPEG: `kernel=nearest/h=30` differs by 54–57 levels for EXIF 2, 3, 4, 6, 7, 8 and 0.2 for EXIF 5.

**Suggested fix:** flush before a resize whose kernel is `:nearest` too (the decode already runs at full size for nearest, since `decode_target/4` at `executor.ex:175` turns shrink-on-load off). Extend the property test in `deferred_orientation_property_test.exs` to `kernel=nearest` downscales at integer and non-integer scales, comparing pixels against the pre-oriented twin.

---

## 2. The blur budget applies per operation, so repeating the blur in more groups multiplies it

**Severity:** Medium (one short URL runs about N × the CPU `max_blur_work` allows; mitigated where URLs must be signed)

**Where:** `lib/image_pipe/transform/work_limits.ex:25-32` (`blur/2`) checks one blur's work against `max_blur_work`; `Step.work_limit/2` (`lib/image_pipe/transform/executor/step.ex`) calls it once per `Blur`/`ProgressiveBlur`. Nothing sums the work across groups, and I found no cap on the number of groups in the URL grammar. The 6lz0.5.4 decision notes that a deadline doesn't stop a running libvips operation, so the value budget is what bounds CPU.

**Evidence:** 2003×1501 JPEG, default config, JPEG output (each `blur=1000` uses about 75% of the default budget):

| request | status | time |
|---|---|---:|
| `/blur=1000` | 200 | 4.6 s |
| `/blur=1000/-/blur=1000` | 200 | 8.8 s |
| 4 groups of `blur=1000` | 200 | 17.8 s |
| 30 groups of `blur=1000` (a 357-character path) | 503 | 61 s |

The 30-group request gave up at the processing deadline; per the 6lz0.5.4 notes, the blur work already queued keeps running. The same applies to any other step bounded per operation (enlarge, arbitrary rotate, pixelate), but blur is by far the most expensive per call.

**Suggested fix:** keep a running blur-work total on `State` and check `total + work` against `max_blur_work`, so the budget holds per request. The `max_blur_work` doc (`lib/image_pipe/config.ex:176-183`) describes it per blur, so update it with the fix. Wire test: two groups that each fit but together exceed the budget return 422 before work.

**Question for Håvard:** should the budget be per request (the fix above), or would you rather cap the number of groups in the URL grammar as well?

---

## 3. WebP sources decode straight to the target size, so their thumbnails differ from the same image as PNG or JPEG

**Severity:** Low–Medium (visible quality difference on small outputs, every WebP source)

**Where:** `lib/image_pipe/transform/decode_planner.ex:101-103` passes `scale: 1.0 / load_shrink` with the full target ratio, so libwebp's own rescaler produces the output size and the lanczos resize after it does almost nothing. JPEG stops at the power of two at or below the ratio (`jpeg_shrink_n/1`), so libvips' kernel does the final reduction.

**Evidence:** a 1200×1600 photo (`exif_large_6.jpg`, auto-rotated) saved as PNG, lossless WebP and JPEG q100. Mean absolute difference from the PNG result:

| request | WebP | JPEG |
|---|---:|---:|
| `w=16` | **7.58** | 1.46 |
| `w=50` | **4.40** | 1.19 |
| `w=200` | 1.77 | 1.12 |
| `w=600` | 0.70 | 0.72 |

Decoding the same WebP by hand with `webpload(scale: 2 × target / width)` and then `resize` to the target gives 1.51, 0.84 and 0.39 for `w=16`, `50` and `200`, in line with JPEG. The 1,350-request geometry fuzz shows the same: the largest pixel differences from the PNG twin are all WebP outputs under about 30 px.

**Suggested fix:** decode WebP at about twice the target (`load_shrink / 2`, not below 1), as the arbitrary-rotate path already does with its headroom of 2. The extra decode is 4× the output's pixels, which is small for exactly the outputs this affects. Label the PR `perf`, since it changes decode work.

---

## 4. 16-bit sources narrowed to 8 bits are off by one level for about a quarter of values

**Severity:** Low (one level, but on 25% of RGB and 16% of gray values; the narrowing twin of `image_plug-y7mu`)

**Where:** libvips narrows 16 to 8 bits by shifting right 8 (dividing by 256 and truncating) instead of `round(v / 257)`. ImagePipe hits that in:
- `lib/image_pipe/transform/input_color_management.ex:189,191,128` (`working_space/2` maps RGB16 to sRGB and GREY16 to B_W without `hdr=preserve`, then `Operation.colourspace/2`), for an untagged 16-bit source.
- the PNG saver for `hdr=preserve/png-options=bitdepth:8`. `narrow_to_8_bits/1` (`lib/image_pipe/output/encoder.ex:257-279`, 418794b) rounds correctly but only runs for a multi-band result at a depth below 8.

**Evidence:** a 256×256 ramp holding every 16-bit value once, as RGB16 and GREY16 PNG, compared with `round(v / 257)`:

| request | RGB16 wrong | GREY16 wrong |
|---|---:|---:|
| `/format=png` | 24.8% | 16.2% |
| `/format=webp/webp-options=lossless` | 24.8% | 16.2% |
| `/format=png/hdr=preserve/png-options=bitdepth:8` | 24.8% | 16.2% |

Every error is ±1. Examples: 65400 (254.47) gives 255; 128 (0.498) gives 1 for gray and 0 for RGB. 64×257 and other exact multiples come out right.

**Suggested fix:** narrow 16-bit untagged input to 8 bits in ImagePipe with `linear(1/257)`, `round`, `cast`, before the colourspace step, and use the same helper for an explicit `bitdepth:8` on a 16-bit result. Track it with `image_plug-y7mu` or in a new `libvips-upstream` bead. A wire test with values 65400 and 129 expects 254 and 1.

---

## 5. The result-size clamp resizes alpha images with `Image.resize/3`, which loses a level

**Severity:** Low (one 8-bit level on semi-transparent pixels of every clamped image)

**Where:** `lib/image_pipe/output/clamp.ex:187` calls `image_module.resize/3`, which is `Image.resize/3`. That is the `image` 0.72.0 truncation recorded in `image_plug-qeqt`, whose workaround (`Resize.resample/4`, through `AlphaPremultiply.with_alpha_premultiplied/2`) covers `Operation.Resize` and `Operation.Rotate` but not the clamp. a65e379 added float widening for opaque 16-bit images only.

**Evidence:** uniform `[200,120,37,100]` RGBA PNG, 900×100, `max_result_width: 613`:

| request | result |
|---|---|
| `/format=png` (clamped to 613×68) | **`[200,119,37,100]`** |
| `/format=png/hdr=preserve` (clamped) | **`[200,119,37,100]`** |
| `/w=613/format=png` (same size by an explicit resize) | `[200,120,37,100]` |
| the RGB twin, clamped | `[200,120,37]` |

The clamp also always uses lanczos3, so `kernel=nearest` pixel art comes out blurred when the result is clamped.

**Suggested fix:** call `Resize.resample/4` from `Clamp.resize/3` (it already rounds alpha images and resizes 16-bit images in float, so `widen/1` and `narrow/2` can go), passing the request's kernel if one is available. Add the clamp to the workaround list in the qeqt bead. Wire test: the example above returns `[200,120,37,100]`.

---

## 6. A not-ready detector still makes smart-face requests decode at the detection floor and buffer a detection frame

**Severity:** Low (performance, only while the model is warming up under `detector_required: true`)

**Where:** `lib/image_pipe/transform/executor.ex:124-130` (`detection_runs?/2`) checks `available?/1` only. Under `detector_required: true`, `anchor=smart-face` with a detector that isn't ready goes to `attention_until_ready/2` (`lib/image_pipe/transform/operation/crop.ex:207,347`) and never detects, but the decode planner and `prepare_detection_frame/4` (`executor.ex:492`) still keep 640 px. Bug hunt 5 #10 asked for this case; 8de13c2 covered the unavailable and moot cases only.

**Evidence:** 2003×1501 JPEG, `/w=96/h=64/fit=cover/anchor=smart-face/format=png`, buffered frames from `[:transform, :materialize]`:

| detector | buffered |
|---|---|
| available, `ready?` false, `detector_required: true` | **1001×750** |
| none | 96×72 |
| same not-ready detector, `anchor=smart` | 96×72 |

**Suggested fix:** in `detection_runs?/2`, also return false for `{:smart, :face_assist}` when `detector_required` is set and `Detector.ready?/2` is false, which needs `detector_required` in the decode options. Optional: the same for a `detect` guide, which fails with 503 before the fetch anyway.

---

## Not confirmed

- **First-load lock race** (static reading, `lib/image_pipe/transform/detector/image_vision/model.ex:84-96`): a waiter that finds the lock with `Process.whereis/1` just before the holder releases it monitors a dead pid, gets `:noproc`, and retries the failing probe instead of sharing its error. Only the requests arriving in that window retry.
- **Thin crops now decode at full size:** `crop_shrink_limit/1` (af3e40d) makes a crop under 16 px thick decode without shrink. On an 8000×5000 JPEG, `region=0,4500,8000,15/w=400` took 320 ms against 224 ms for a 64-row region and 254 ms for plain `w=400`. Not worth changing at this cost.
- **Composite detector, unavailable child:** `counted_detection/2` skips only `{:error, {:detector, :unavailable}}`. A Composite call where every requested class is unavailable returns `{:ok, []}` and is counted as a detection. Not measured.

## Checked and clean

- **Geometry fuzz:** 450 random single- and two-group requests (crop, region, anchors and offsets, focus, `crop-ratio`, quarter and arbitrary rotate, flips, `dpr`, `zoom`, `min-w`, `extend` with `extend-at`/`extend-offset`, `pad`, `enlarge`, `kernel=linear`) on three sizes (2003×1501, 1999×2999, 4001×1203), each against JPEG, WebP and a random EXIF 2–8 JPEG twin of the PNG: no status or size mismatch. Pixel differences are within JPEG noise apart from finding 3.
- **Gravity placement before shrink (4c49ef1), thin-crop cap (af3e40d), crop-ratio floor (e714f8e):** covered by the fuzz.
- **Rebuffer after blur, progressive blur and sharpen (618d1a6):** later enlarge, pixelate, sharpen, rotate and smart crops buffer first; the multi-group cost in finding 2 is the budget, not recomputation.
- **PNG depth:** every combination of `palette`, `bitdepth:1|2|4|8|16` and `interlace` on RGB16, RGBA16, gray, gray+alpha, alpha, palette, bitonal, P3 and JPEG sources, with and without `hdr=preserve`: all 200. 16-bit gray/alpha/colour with `bitdepth:4` round correctly through `narrow_to_8_bits/1`.
- **Watermark fade in float (187cffd):** 8-bit and RGBA frames, PNG with alpha, RGB PNG and JPEG marks, `wm-tile`, `wm-scale`: exact to 0.5.
- **16-bit float resize (d82db2d, a65e379):** white stays 65535 for RGB16 and RGBA16, resized or clamped.
- **Animated GIF and WebP:** `page` 0–2 with resize, region, crop, rotate, `dpr`, 1×1 cover and info all pick the right frame; `page=3` gives 422.
- **Detection with the default detector and without image_vision:** detect, `detect=all`, `detect=person,face` and smart-face give 200 and no 500 with `:default` and with `nil`.
