# Bug hunt 5: image processing and output

Scope: transform geometry and decode (including SVG), pixel operations and colour, watermarks, output policy and encoding, and object/face detection with content-aware cropping, in `image_pipe/` at `8edf03b`. The hunt concentrated on code changed since bug hunt 4 (`db4fe3c..8edf03b`, mostly the bug hunt 4 fixes). Findings already in `bug-hunt/` through `bug-hunt-4/`, and open beads, are left out.

**How this was checked:** every finding was reproduced with real `ImagePipe.Plug.call/2` requests in a cloud session (`MIX_ENV=test mix run`, File source, response decoded and pixels read back), or with a direct process-level call where noted. Detection findings use fake detectors implementing `ImagePipe.Transform.Detector` (real models can't be downloaded here). libvips 8.18.7, PNG saved with libpng. Numbers are actual output. The harness is the same as bug hunt 3 (`/mnt/project-files/bug-hunt-3/image-processing-and-output.md`, end of file).

**Bug hunt 4 status:** every bug hunt 4 image bead (`image_plug-6lz0.1.*`) is closed on main. Rechecked and complete: shrunk-decode crop size (#1), PNG `q` from defaults (#2), `autoquality` + `max-bytes` quality (#3), SVG render target (#4), detector warmup retry (#6), moot content-aware crop (#7), info work limits (#8), SVG `page` (#12), placeholders on white (#13), detector config validation (#14), unavailable child spans (#16), region rounding (#10, #11), extend offsets, ×257 widening. **Incomplete:** #5 (PNG bit depth, findings 3 and 13 below), #9 (rounding, finding 12), the info dpr investigation (finding 15), the blur budget from request handling #4 (finding 2), and the WebP twin of #2 (finding 9).

---

## 1. A date tag stored as a number makes every default request for that image fail with 500

**Severity:** Medium (one camera or editor writing a non-ASCII date tag makes the image unservable unless the URL says `meta=keep`)

**Where:** `lib/image_pipe/output/encoder.ex:518-522`. `minimize_metadata/2` rescues only `ArgumentError`. In `image` 0.72.0, `Image.Exif.Decode.date_time/1` (`deps/image/lib/image/exif/decode.ex:134-138`) calls `String.trim_trailing(value, "\x00")`. When DateTime (0x0132), DateTimeOriginal (0x9003) or DateTimeDigitized (0x9004) is stored as SHORT, LONG or UNDEFINED, the value is an integer or a list, and that raises `FunctionClauseError`. The rescue in `stream_output` turns it into `500 error encoding image`. This is the same workaround 0f93775 added, but for a different exception.

**Evidence:**

| source | default `meta`, `meta=strip`, any format | `meta=keep` |
|---|---|---|
| JPEG with IFD0 DateTime as SHORT 2024 | **500** | 200 |
| same plus an ASCII Copyright | **500** | 200 |
| JPEG with DateTimeOriginal as LONG | **500** | 200 |
| ASCII `2024:01:01 02+02:00:00` (the case 0f93775 fixed) | 200 | 200 |

The log shows `FunctionClauseError … String.trim_trailing(2024, <<0>>) … Image.Exif.Decode.date_time/1 … Image.minimize_metadata/2 … encoder.ex:519`. Storing every tag the decoder knows as SHORT×1, SHORT×2, LONG×1, ASCII×4 and UNDEFINED×4 showed that only these three date tags raise anything other than `ArgumentError`.

**Suggested fix:** rescue any exception from `Image.minimize_metadata/2` (the fallback is already "strip everything"). Better, read `exif-ifd0-Copyright` and `exif-ifd0-Artist` from the libvips header, `Image.remove_metadata/1`, and set the two back, so no EXIF is parsed in Elixir. Update the ``Workaround for `image` `` comment and the image-upstream bead to name this case. Wire test with a JPEG whose DateTime is a SHORT.

---

## 2. A large blur followed by an enlarge, pixelate or sharpen in a later group gets around the blur budget

**Severity:** Medium (one default-config request runs about 13× the CPU the budget allows; it grows with the output size)

**Where:**
- `lib/image_pipe/transform/executor/step.ex:139` (`materialize(%State{materialized?: true})`) skips the copy.
- `lib/image_pipe/transform/state.ex` (`set_image/2`) never clears `materialized?`.
- `lib/image_pipe/transform/work_limits.ex` (`blur/2`) counts only the pixels being blurred.

`Step.prepare` materializes before the blur and sets the flag, but the blur's result stays lazy. Every later step that reads overlapping or out-of-order regions then recomputes the large-sigma convolution per region: a later group's enlarge, `pixelate` (its own `random_access?` materialization is skipped because the flag is still true), and `sharpen`. This makes 605fe6c (bug hunt 4, request handling #4) incomplete.

**Evidence:** 1500×1125 JPEG, default config, JPEG output:

| request | time |
|---|---:|
| `/blur=1000` | 2.7–3.4 s |
| `/w=6000/enlarge` | 0.34 s |
| `/blur=1000/-/w=6000/enlarge` | **37.5 s** |
| `/blur=1000/-/pixelate=4` | **18.9 s** |
| `/blur=1000/-/w=3000/enlarge` | 17.0 s |
| `/progressive-blur=1000/-/w=4000/enlarge` | 13.2 s (the blur alone: 3.1 s) |
| `/blur=1000/-/sharpen=1` | 5.0 s |

With `Operation.Blur` recompiled in-process to `copy_memory` its result (no repo edit), the enlarge requests took 2.5–2.9 s.

**Suggested fix:** make `materialized?` mean "the current image is a memory image": reset it in `set_image/2`, or check the image in `Step.materialize`. Otherwise the `random_access?` table silently stops applying after the first materialization (pixelate here). Also materialize the result of `Blur`, `ProgressiveBlur` and `Sharpen` above a small sigma. Add a work-budget test for `blur=…/-/w=…/enlarge`.

**Question for Håvard:** the shared root cause may also skip the re-buffer before a later blur or sharpen (for example `/sharpen=0.3/-/w=6000/enlarge/sharpen=10`). Timing that was inconclusive on the loaded test box.

---

## 3. `png-options=bitdepth:1` turns almost every gray pixel white

**Severity:** Medium (a valid URL option, or a host `png_options` default, wipes out a grayscale image)

**Where:** `lib/image_pipe/output/encoder.ex:282` (`keep_gray_levels(image, 1)` returns the image unchanged). libvips' libpng saver writes any non-zero value as 1 at 1 bit. Bug hunt 4 #5 said 1 bit "thresholds correctly"; it doesn't, so e7770e4 left this case out.

**Evidence:**
- Uniform gray PNG at `/format=png/png-options=bitdepth:1`: 15 → **255**, 100 → **255**, 150 → 255 (expected 0, 0, 255).
- A photo through `/gray/format=png`: mean 127, 1.4% white pixels. Adding `png-options=bitdepth:1`: mean 247, **96.9% white**.
- `/gray/bitonal/format=png/png-options=bitdepth:1`: correct (input already 0/255). 16-bit gray with `hdr=preserve`: same as 8-bit.
- Bare libvips `pngsave_buffer(bitdepth: 1)` reads back 255 for 1, 15, 64, 100, 127, 128 and 200.

Related: the 2- and 4-bit path shifts right, which truncates instead of picking the nearest level. Gray 200 at 2 bits becomes 255 (nearest is 170), and 15 at 4 bits becomes 0 (nearest is 17).

**Suggested fix:** in `keep_gray_levels/2`, shift depth 1 by 7 (15 for ushort), or quantize every depth to the nearest level, `round(v·(2^d−1)/max)`. Wire tests: gray 100 at `bitdepth:1` gives 0; gray 150 gives 255.

---

## 4. Thin JPEG/WebP images, and WebP with a sub-pixel target, fail with 415

**Severity:** Medium (valid images answer "not a supported image"; the PNG of the same pixels works)

**Where:** `lib/image_pipe/transform/decode_planner.ex:57-66` derives the load shrink from the target ratio only, and `:90-97` passes the JPEG `shrink` or WebP `scale` to libvips uncapped. When a side drops below 1 px, libvips fails with "image: bad dimensions" (checked directly: `jpegload(shrink: 2)` on a 7×1 JPEG), which surfaces as a decode error.

**Evidence:**
- 2000×3 image, `/w=100/format=png`: JPEG **415**, WebP **415**, PNG 200 at 100×1. Also with `w=200`, `w=8`, and with `output=info` or `output=blurhash` plus a resize.
- 640×7 JPEG/WebP with `w=8`, 400×2 with `w=100`, 64×1…64×4 JPEGs with `w=8`, 1×64 and 3×64 with `h=8`, 7×1 with `w=2`: all 415.
- Ordinary 2003×1501 WebP: `/w=1/dpr=0.5`, `/w=4/dpr=0.1`, `/w=2/zoom=0.2` and `/w=1/dpr=0.5/output=info` all 415; JPEG and PNG give 200 at 1×1.
- Same cause, no error: a thin region pulls in pixels from outside it. 2000×1600 source with white rows 803–810 and red rows 811–818: `/region=0,805,2000,3/w=100` gives `[255,255,255]` from the PNG but **`[254,96,95]`** from the JPEG; `/region=0,813,2000,3/w=100` gives `[255,0,0]` vs **`[96,0,1]`**. A shrink of 8 on a 3-row region averages rows outside it.

**Suggested fix:** cap the load shrink so the decoded image keeps at least 1 px per axis (JPEG n ≤ min(w, h); WebP scale ≥ 1/min(w, h)), and also by the short side of the crop extent so a thin region keeps its own rows (the planner needs the source size for the first). Wire tests: 2000×3 JPEG and WebP with `w=100` return 200 at 100×1; WebP with `w=1/dpr=0.5` returns 200.

---

## 5. An extreme `crop-ratio`, or a small crop box with a ratio, raises `ArithmeticError`

**Severity:** Medium (500 for images; the exception escapes `Plug.call` for `output=info` and placeholders)

**Where:** `lib/image_pipe/transform/executor/geometry.ex:68-87`. `ratio_box` rounds the reduced axis to 0 and `scale_into` divides by it. Reached from `executor.ex:887` (`guided_box`) and `executor.ex:85` (`decode_crop_extent`, before decode). The parser accepts ratio terms up to 2,147,483,647.

**Evidence:** 2003×1501 PNG:
- `/crop=2003,1501/crop-ratio=1:4000/format=png` → **500** (`ArithmeticError` in `scale_into/2`); `1:3003` → 500; `1:3002` → 200 at 1×1501; `crop-ratio=0.0002` → 500.
- With `output=info` or `output=blurhash` the error is raised out of `Plug.call`.
- Ordinary ratios on small boxes: whenever the reduced axis × ratio is under 0.5, for example `crop=300,40/crop-ratio=1:100`, or `/flip=hv/w=4000/h=5/-/rotate=1/crop=1pct,1pct/w=3/crop-ratio=1:3/format=jpeg` on a 2×5 PNG.

**Suggested fix:** `max(1, …)` on both rounded axes in `ratio_box` before `scale_into`. Wire test: `crop=2003,1501/crop-ratio=1:4000` returns 200 at 1×1501, and the same for info.

---

## 6. A `detect` or smart-face crop decodes, buffers and detects on the full-resolution original

**Severity:** Medium (a 64×64 output costs a 48 MP buffer and runs 5–8× slower; can turn a 200 into a 422)

**Where:** `lib/image_pipe/transform/executor.ex:86-97`. `detection_floor/2` (db54c08) is applied against `extent`, the guided crop's size. A guided crop detects on the whole decoded frame, not the crop, so the 640 px floor blocks shrink-on-load even when the whole frame would stay far above 640 px at the normal shrink. The crop path also has no "at most twice the floor" cap; `prepare_detection_frame` only runs for resizes.

**Evidence:** 8000×6000 JPEG, `/crop=10pct,10pct/…/w=64/h=64/fit=cover/format=png`, events from telemetry:

| request | time | decoded | materialized | detector frame |
|---|---:|---|---|---|
| `detect=face`, fake detector | 461 ms | **8000×6000** | 8000×6000, then 800×600 | 8000×6000, then 800×600 |
| `detect=face`, no detector | 72 ms | 1000×750 | 1000×750 | |
| `anchor=smart-face`, fake detector | 379 ms | **8000×6000** | 8000×6000 | 8000×6000 |
| `anchor=smart` | 68 ms | 1000×750 | 1000×750 | |

- The default detector without image_vision (`:default` still resolves to Composite) on a 7000×5000 JPEG: 371 ms, 7000×5000 decoded and buffered, detect result `:unavailable`; no detector: 44 ms at 1750×1250.
- 12000×9000 JPEG with `max_input_pixels: 200_000_000`: the fake detector gets **422 "intermediate image exceeds the pixel limit"**; no detector gets 200.
- The same group also runs the detector twice (whole frame for the crop, then the 800×600 crop for the cover resize).

**Suggested fix:** compute the floor on the frame the detector sees: `min(target_ratio(extent), max(long_edge(crop_frame)/640, 1))`, or give the crop path the same capped detection frame as the resize path.

---

## 7. The image_vision first-load lock makes failed model loads run one at a time

**Severity:** Medium while model loading fails (model host unreachable, `detector_required: false`, the default, and no model on disk yet)

**Where:** `lib/image_pipe/transform/detector/image_vision/model.ex:26-43` (bf9e263). When the lock holder's load returns `{:error, _}`, each waiter retakes the lock in turn and repeats the failing download. `await_release/1` waits with no timeout. So the N-th concurrent request waits N × the download timeout. Before bf9e263 those requests failed in parallel and fell back to attention cropping.

**Evidence:** direct process-level call: six concurrent `Model.first_load` calls whose load sleeps 200 ms and fails finished at 201, 402, 603, 807, 1008 and 1217 ms, and the load ran 6 times. No lock process was left behind.

**Suggested fix:** single-flight: callers that waited on a failed attempt get that attempt's error rather than retrying; or allow one retry per backoff window.

---

## 8. `autoquality` + `max-bytes` spends 0.75–1.3 s scoring probes whose score is never used

**Severity:** Medium (performance; 30–50% of the request)

**Where:** `lib/image_pipe/output/encode_search.ex`:
- `do_encode` → `maybe_score` (around lines 583-587) runs `score_fun` (decode the candidate plus SSIMULACRA2) for every encode, including the `:cap` phase, which decides on bytes alone. The score only reaches telemetry.
- `cap_descend/4` bisects `[floor, objective_q]` from scratch, ignoring the sizes the quality search already measured.

8978a93 raised the cap phase from 0–2 probes to 5, which made this larger.

**Evidence:**

| request | total | max-bytes probes | probe time | of which decode + metric |
|---|---:|---:|---:|---:|
| `placement.png` `w=800/format=webp/autoquality=70/max-bytes=27776` | 2,577 ms | 5 | 995 ms | 752 ms |
| `exif_large_6.jpg` `w=800/format=jpeg/autoquality=70/max-bytes=97676` | 2,522 ms | 5 | 1,341 ms | 1,300 ms |

In the WebP case the search had already measured q84 = 26,168 B (fits) and q89 = 29,280 B (too big), so the answer was in 85..88; the cap phase still probed 58, 75, 88, 86, 87. In the JPEG case it knew 73 fits and 83 doesn't, and still probed 57 and 81 first. The chosen qualities are correct.

**Suggested fix:** skip `score_fun` in the cap phase (score the shipped quality once if telemetry needs it), and start the bisection from the memo-derived bracket (about 2–3 encodes instead of 5). Label the PR `perf`.

---

## 9. Lossless WebP rejects `autoquality` or `max-bytes` that come from request defaults or a preset

**Severity:** Low–Medium (the WebP twin of bug hunt 4 #2; a host default breaks every explicit WebP URL)

**Where:** `lib/image_pipe/output/policy.ex:223-237` (`validate_lossless_webp_request/2`) checks the merged spec output, so `request_defaults` and presets count. The host's own `autoquality: true` doesn't go through this check, so the two ways of turning the search on behave differently.

**Evidence:** `/format=webp/w=50/src/small.png`:

| host config | URL | status |
|---|---|---|
| `webp_options: [lossless: true]` | `/format=webp/…` | 200 |
| same + `request_defaults: "autoquality"` | `/format=webp/…` | **400 `invalid output`** |
| same + `request_defaults: "max-bytes=50000"` | `/format=webp/…` | **400** |
| same + `request_defaults: "max-bytes=50000"` | `/w=50/…` with `Accept: image/webp` | 200 (search skipped) |
| same + preset `hq => "autoquality=80"` | `/preset=hq/format=webp/…` | **400** |
| `request_defaults: "autoquality"` | `/format=webp/webp-options=lossless/…` | **400** |
| `autoquality: true` | `/format=webp/webp-options=lossless/…` | 200 |

`docs/choosing-an-autoquality-target.md:35-36` says lossless WebP is "encoded once" when the search is on; `docs/processing/output.md:169` scopes the 400 to a request that sets `format=webp` while WebP is lossless.

**Suggested fix:** as for PNG in 7e99063: drop the rule and ignore the search for lossless WebP (`Encoder.search?/1` already does), or apply it only to options written in the URL. Wire tests with `request_defaults: "autoquality"` plus `webp_options: [lossless: true]`.

---

## 10. The 640 px detection floor and detection-frame buffering run when no detection will happen

**Severity:** Low–Medium (performance: up to 16× more decoded pixels and a buffered pre-resize frame)

**Where:** `lib/image_pipe/decode.ex:611` applies the floor whenever a detector is configured, even an unavailable one; `executor.ex:94-97` applies it to a cover crop that covers the image; `executor.ex:444-461` (`prepare_detection_frame`) shrinks, buffers and flushes before `Step.moot?` skips the crop. An interaction between db54c08 and 3afa4bd.

**Evidence:** 2400×1600 JPEG, `/w=96/h=64/fit=cover/detect=face` (the crop can't move; the detector is never called):

| detector | status | time | decoded | buffered |
|---|---|---:|---|---|
| fake, finds a box | 200 public | 52 ms | 1200×800 | 1200×800 |
| fake, always errors | 200 public | 19 ms | 1200×800 | 1200×800 |
| `:default` without image_vision, `anchor=smart-face` | 200 | 16 ms | 1200×800 | 1200×800 |
| none | 200 | 8 ms | 300×200 | 96×64 |

The output bytes also differ from the no-detector response, although the crop can't move. Every default install without image_vision pays this on every detect or smart-face request.

**Suggested fix:** apply the floor only when the detector is available for the group's classes, skip it and `prepare_detection_frame` when the cover crop covers the resized image, and skip `prepare_detection_frame` when smart-face will fall back to attention because the detector isn't ready.

---

## 11. Enlarges and `kernel=nearest` differ for EXIF-oriented, flipped or rotated sources

**Severity:** Low–Medium (breaks "deferred orientation must preserve the logical result"; visible on enlarged phone photos)

**Where:** the executor resizes in the storage frame with compensated dimensions, then flushes the pending orientation (`OrientationFlush`). Two libvips behaviours don't commute with a flip: the upscale (`vips_resize` → affine) maps output x to `x/scale − 0.5` instead of the centre-aligned `(x+0.5)/scale − 0.5`, and nearest-neighbour reduce rounds asymmetrically. Downscales with the blending kernels are symmetric. `kernel=nearest` is new in 1555d6b. Related to the closed investigation `e4a.1.14` (focus crop ties), but this is the resample itself.

**Evidence:** a 40×30 ramp (R = column × 6), stored upright, with EXIF 3 and 6, and pre-flipped/pre-rotated for comparison with `flip=h` and `rotate=90`. Channel values that differ from the upright request (about 23k values at 101×76):

| request | EXIF 3 | `flip=h` | `rotate=90` |
|---|---:|---:|---:|
| `w=13/kernel=nearest` | 10 | 10 | 17 |
| `w=101/enlarge/kernel=nearest` | 5,792 | 2,964 | 4,117 |
| `w=101/enlarge` (default lanczos3; other kernels similar) | 15,099 | 7,524 | 13,230 |
| `w=13`, any blending kernel | 0 | 0 | 0 |

At `w=100/enlarge` the upright source samples x = 3.50, 7.50, 11.50…; EXIF 3 and 6 sample 3.83, 7.83…; centre-aligned would be 3.70, 7.70…. On a 400×300 high-frequency photo at `w=1000/enlarge`, upright vs EXIF 3 differs by a mean of 17 levels (max 42), EXIF 6 by 9.7 (max 26).

**Suggested fix:** flush the pending orientation before a resize that enlarges or uses `kernel=nearest`, or run the enlarge as an explicit centre-aligned affine (`idx/idy/odx/ody`) with symmetric rounding for nearest. Add a property test comparing pixels, not only sizes, of an oriented source against its upright twin.

**Question for Håvard:** the upright result is itself off-centre by libvips' convention; is matching it enough, or should enlarges be centre-aligned for every source?

---

## 12. Watermark opacity still lands a level off, because `fade` rounds the mark's alpha first

**Severity:** Low (one level on opaque frames; large relative error for low-alpha marks)

**Where:** `lib/image_pipe/transform/operation/watermark.ex:138-147` (`fade/2` calls `Rounding.cast(faded, format)`), so alpha × opacity is quantized (21.5 → 22) before the float composite. Named-watermark `opacity:` and `wm-tile` share the path. What remains of bug hunt 4 #9 after 0da06bc.

**Evidence:** frame `[197,147,61]`, mark `[40,186,32,43]`, `/wm=m/wm-opacity=0.5/format=png` → `[183,150,58]`; exact `[183.76,150.29,58.55]` rounds to `[184,150,59]`. A mark stored with integer alpha 22 gives the same wrong result, proving the quantization. 150 random frames and marks: none off at opacity 1.0, 31 off by more than 0.5 below 1.0. Worst: frame `[34,217,8,37]`, mark `[76,194,206,5]` at 0.5 → `[36,216,18,39]` vs exact `[36.68,215.53,20.65,39.14]` (alpha 2.5 became 2, a 20% weight error). A mark alpha of 1 at opacity below 0.5 vanishes.

**Suggested fix:** drop the `Rounding.cast` in `fade/2` and keep the mark as float; `composite/4` already rounds once at the end. Wire test for the example above.

---

## 13. PNG bit-depth leftovers: `bitdepth:16,palette` widens by ×256, and a depth below 8 on 16-bit colour stays 16

**Severity:** Low

**Where:** `lib/image_pipe/output/encoder.ex:231-261` (`fit_png_depth/2`).
- The `palette != true` guard skips the ×257 widening (4a2dd93), but libvips ignores `palette` at 16 bits. The comment "A palette PNG takes any depth" is wrong for 16.
- For a multi-band 16-bit result with a depth below 8, the branch sets `bitdepth` to `nil`, so the PNG stays 16-bit.

**Evidence:**
- `/format=png/png-options=bitdepth:16,palette` on an 8-bit `[128,64,200]` source → 16-bit truecolour `[32768,16384,51200]`; without `palette` → `[32896,16448,51400]` (correct).
- `/format=png/hdr=preserve/png-options=bitdepth:4/src/rgba16.png` → 16-bit PNG. The `png-options` table in `docs/processing/output.md` says "Other images use 8".

**Suggested fix:** treat `palette` with `bitdepth:16` as non-palette (or reject it), and set `bitdepth: 8` instead of `nil` (or reword the doc).

---

## 14. Opaque 16-bit downscales lose up to 0.2%, so white isn't white

**Severity:** Low (16-bit output only, under half an 8-bit level)

**Where:** `lib/image_pipe/transform/operation/resize.ex` (`resize/4`): without alpha, `Operation.resize` runs on the ushort image, and libvips' fixed-point ushort reduce has a DC gain error. Alpha images go through float premultiply and are exact; 8-bit is exact. `GaussianBlur` already works around the same class of problem with float.

**Evidence:**
- `/w=13/hdr=preserve/format=png` on uniform RGB16 65535 → **`[65471,65471,65471]`**; the RGBA16 twin stays 65535; 8-bit white stays 255.
- RGB16 `[51400,30840,9509]` at `w=13`, R by kernel: linear 51349, lanczos3/cubic/mks2021 51362, mitchell 51374, mks2013 51463.
- Bare libvips over 60 scales × 7 kernels: 0 mismatches for 8-bit, 808 of 1,260 for ushort, max deviation 128.

**Suggested fix:** cast ushort to float before `Operation.resize`, then `Rounding.cast` back; the same in `Watermark.resize/3`.

---

## 15. Info `dpr` after the result-size clamp uses the rounded width ratio

**Severity:** Low (what ae81d4b fixed for wide images is still wrong for narrow ones)

**Where:** `lib/image_pipe/processing/terminal.ex:158-159` multiplies by `info.scale`, the realized width ratio `rw / w` (`lib/image_pipe/output/clamp.ex:56`), which the clamp's 1 px floor and narrow-width rounding distort.

**Evidence:**
- 7×4000 PNG with `max_result_height: 1000`, `/output=info`: dpr **0.2857**. The image is 2×1000 and the true scale is 0.25 (1000 / 0.2857 = 3500 CSS px, not 4000).
- Same source, `/dpr=2/pad=1`: 0.545, expected about 0.4998.
- `max_result_pixels: 500`, `/w=1/h=1000/fit=stretch/enlarge`: a 1×500 image reported with dpr 1.0. `max_result_height: 7` gives 1×7 with dpr 1.0.

**Suggested fix:** report the clamp's intended scale (`primary_scale`), or the ratio on the binding axis, `max(rw/w, rh/h)`.

---

## 16. Smart-face with a not-ready detector is reported as `:detection_failed`, with no detect event

**Severity:** Low (observability)

**Where:** `lib/image_pipe/transform/operation/crop.ex:199,337-340` (`attention_until_ready`, from 24d4794) marks the response degraded but emits neither `[:transform, :detect]` nor `[:transform, :detect, :skipped]`; `lib/image_pipe/response/cache_policy.ex:70` gives every degraded response reason `:detection_failed`. The docs describe that reason as "detection failed", but the detector was never called.

**Evidence:** a detector whose `ready?/1` is false, `detector_required: true`, `/w=64/h=64/fit=cover/anchor=smart-face` → 200 `no-store`; the only event is `[:http_cache, :fallback, :no_store]` with `reason: :detection_failed`. A detector that always errors gives detect start, stop with `result: :error`, and the same reason. "Model not downloaded yet" and "detector broke" look the same.

**Suggested fix:** emit `[:transform, :detect, :skipped]` with `result: :not_ready`, or add a distinct no-store reason; update `docs/telemetry-events.md` and the Logger/handler tests.

---

## 17. Gravity crops on a heavily scaled WebP decode land up to 1 output px off

**Severity:** Low (not a regression)

**Where:** `lib/image_pipe/transform/executor/geometry.ex:229` (`rescale_crop`) with the gravity handling in `operation/crop.ex`. The crop box is rescaled to live pixels and centred with `center_origin` at live resolution; rounding the live size, the +1 centring bias and ties-to-even add up to about 1 live px. A WebP `scale` makes live ≈ output, so that is about 1 output px.

**Evidence:** `/crop=1403,789/w=13/format=png` on a 2003×1501 image: top-left pixel `[45,81,45]` for PNG and JPEG, `[56,91,57]` for WebP (about 110 source px). Over 60 random crops the largest shift was 0.96 output px for lossless WebP and 0.43 for JPEG.

**Suggested fix:** resolve the gravity rectangle at full resolution and map left/top with `round(left / shrink)`, or keep the WebP scale at 2× the target or more when a crop runs.

---

## Not confirmed

- **Cache cost counts unavailable detections** (static reading): `counted_detection` runs before `run_detect` (`crop.ex:240,307`) and each detection weighs 150,000 µs (`cost.ex:46`), so unavailable or instantly failing detections inflate the cost estimate, though 3afa4bd says only detections that ran count.
- **Warmup with a bad `:detector` crash-loops its supervisor** (static reading): a host-supervised `{Detector.Warmup, detector: Typo}` isn't checked against the behaviour; a raising warmup callback inside an instance does the same.
- **PNG depth on spng builds:** `keep_gray_levels` assumes libvips saves PNG with libpng. A libvips built with spng (possibly vix's precompiled one) could shift 2/4-bit gray twice. This build, the server Dockerfile and CI all use libpng.
- **Encode count:** `autoquality` + `max-bytes` can now run up to 12 encodes per request with no work budget. Finding 8 removes most of the scoring cost, not the encodes.
- **`kernel=nearest` at non-integer enlarge scales** gives different run patterns per axis (4 → 10 px: 3,3,2,2 along a row, 3,2,3,2 down a column). Looks like libvips.
- **Detection-frame output:** on the db54c08 path the output is resized from the 640 px detection frame, so pixels differ slightly from a run without a detector. Not measured for visibility.

## Checked and clean

- **Geometry:** about 500 random single-group requests on JPEG, WebP and EXIF 2–8 JPEGs against the PNG (crop, region, anchors and offsets, `crop-ratio`, `focus`, quarter and arbitrary rotate, flips, `dpr`, `zoom`, `min-w`, `extend`, `pad`): no size mismatches; pixels match except finding 17. About 300 multi-group and 200 trim requests, and 300 info sizes, matched. About 1,500 fuzz requests on tiny sources, SVGs and photos found nothing beyond findings 4 and 5.
- **SVG (3bd03aa, cdb1f31):** one-axis stretch, `min-w`/`min-h` alone, crop or region with stretch or minimum, rotate, `dpr`, `zoom`, `kernel=nearest`, later-group clamp; `page=1` gives 422 for image, info, blurhash and lqip-css.
- **Pixel ops:** 8 kernels × 7 source types × downscale/enlarge/stretch keep uniform colours exact apart from finding 14. `kernel=nearest` adds no colours and disables JPEG shrink-on-load. sRGB watermark compositing (26ae8cb) on P3, Adobe RGB, P3 16-bit and P3 RGBA frames with every `profile` and `hdr` setting: an invisible mark is byte-identical to no watermark; a red mark lands exactly. Rounding (0da06bc): 120 random `bg` and `colorize` requests within 0.5 of exact. Blur, sharpen, progressive blur and pixelate exact on uniform sources (apart from the open low-alpha sharpen bead). Pixelate (58867c2) block sizes 7–5000 on sequential JPEG, EXIF 6, after `rotate=33` and on 16-bit RGBA: 200, grid anchored at the display top-left. Blur budget: 422 before work for a single-group blur, including info and blurhash.
- **Output:** `max-bytes` budget (8978a93) over 32 budgets × WebP/AVIF/JPEG × targets 70–85 never does worse than `max-bytes` alone above the floor. PNG depth (e7770e4): 2/4-bit gray, 16-bit gray at 1/2/4/8, bitonal + 1-bit with alpha, colour falls back to 8. ×257 widening for RGB, RGBA, gray, gray+alpha, P3 and negotiated PNG (apart from finding 13). PNG `q`/`format-q` from defaults gives the same bytes and ETag as plain `format=png`. Per-format keys (1454314): another format's settings leave the ETag and bytes unchanged; every policy field the encoder reads is keyed. Transparent autoquality scoring (525ea8b), placeholders on white for 8- and 16-bit, info work limits and wide-image dpr all correct. 1,000 random output-option and `Accept` requests: no 500s apart from finding 1.
- **Detection:** crop placement with a pixel-finding fake detector under EXIF 1–8, rotate 90/180/270/10, flips, `dpr`, `zoom`, `kernel=nearest`, `orient=none`, `fit=auto`, second groups and guided crop + cover. Moot-crop skip gives a cacheable 200 with an erroring detector and no 500 under `detector_required`. Smart-face not ready doesn't call the detector. Warmup backoff caps at 60 s and logs recovery. The first-load lock is released when the holder errors, raises or dies. Config validation raises `ArgumentError` for `:face`, `String`, and an unavailable default under `detector_required`. Detection counts survive every fallback path.
