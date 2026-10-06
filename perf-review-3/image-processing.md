# Performance review 3: image processing and encoding

Scope: decode planning, transform operations, materialization, watermarks,
encoding, and the autoquality search. Paths are relative to `image_pipe/`, at
`main` 259fb05. No code was changed on any branch. A few findings were checked by
patching one line locally, timing it, and then reverting the patch. Each of those
says so.

## How this was measured

Most numbers come from real `ImagePipe.Plug.call/2` requests against a file
source with no output cache. They were timed in-process, with per-stage
durations summed from the library's own telemetry stop events. The machine has
4 vCPUs (Intel Xeon at 2.1 GHz) and runs Linux with Vix 0.42's precompiled
libvips. The libvips operation cache was off unless a finding says otherwise.
Each figure is the median of 5 to 7 runs. Micro-benchmarks call the same Vix
operations the code uses, on the same images.

The fixtures are `priv/static/images/` plus files derived from them:
`spin_base.jpg` (spinning.jpg re-saved as a 6000×4000 baseline JPEG at Q90),
`spin_border.jpg` (the same with a 200 px white border), `spin_cmyk.jpg` (a
CMYK baseline copy), `beach_rgba.png` and `beach_rgb.png` (2000×1334, with and
without alpha), and `logo.png` (a 1200×600 RGBA watermark asset).

## Status of earlier findings

Fixed on main since review 2, so they're left out below:

- Crop-mode tiles are scored concurrently (review 2 #2, 4d1f016).
- An arbitrary-angle rotate shrinks on load (review 2 #4, 84cb94f).
  `/rotate=10/w=800` went from 1074 ms to 243 ms.
- `lqip-css` gets a terminal reduction (review 2 #6, 735b362 and c242447).
  `output=info,blurhash,lqip-css` went from 301 ms to 116 ms.
- Blur on float premultiplied input uses approximate precision (review 2 #7,
  0e44fcd).
- Progressive-blur levels are gated by weight (review 2 #8, 9fd7159).

Still open, and repeated below with new measurements: the libvips operation
cache (review 1 #5 and review 2 #1), the autoquality crossover (review 2 #3),
trim (review 1 #2 and review 2 #5), the per-probe lazy chain (review 2 #9), and
serial detector children (review 1 #4).

## Findings, ranked by payoff against risk

### 1. A tiled watermark recomputes the scaled asset for every tile

**Severity: High. New. Measured. Low risk; output bytes unchanged.**

`lib/image_pipe/transform/operation/watermark.ex:133-151`: `tiled/5` embeds the
mark in a cell and `Operation.replicate`s it across the frame. The mark is still
the lazy chain from `size/3` (`watermark.ex:76`): a premultiplied float resize
of the full asset, an unpremultiply, and a fade. libvips doesn't cache between
the replicated tiles, so every tile re-runs that resize over the whole source
asset.

| request (1200×600 logo) | main | mark copied to memory first |
|---|---:|---:|
| `/w=800/format=jpeg/src/beach.jpg` (no watermark) | 120 ms | 120 ms |
| `/w=800/wm=logo/wm-scale=0.2/…` (one mark) | 216 ms | (not on this path) |
| `/w=800/wm=logo/wm-scale=0.2/wm-tile/…` | **1294 ms** | 283 ms |
| `/w=2400/wm=logo/wm-scale=0.1/wm-tile/…` (spin_base) | **5253 ms** | 317 ms |

The right-hand column comes from a local one-line patch, since reverted, that
called `VipsImage.copy_memory(mark)` at the start of `tiled/5`. The response
byte counts were identical (64889 and 550253 bytes). Almost all the time on main
shows up in the delivery materialize span (1235 ms of the 1294).

**Suggested fix:** in `tiled/5`, `copy_memory` the faded mark (or the cell)
before `replicate`. It's small (the drawn size, not the asset size). Leave the
single-mark path alone. It evaluates the mark once anyway, and an earlier
variant that copied on every path made the single-mark request slower (221 ms
to 275 ms).

### 2. Autoquality just below the 6 MP crossover takes 6× longer than just above it (still open)

**Severity: High. Repeat of review 2 #3. Measured. Medium risk; changes the
chosen quality for 2–6 MP outputs.**

`@crossover_megapixels 6` (`lib/image_pipe/output/ssim2_metric/crop_score.ex:19`,
used by `crop?/2` at `lib/image_pipe/output/encoder.ex:103`) is unchanged.
Because crop scoring has become concurrent, the step at the crossover is now
steeper than it was in review 2. Autoquality with JPEG output on
`spin_base.jpg`:

| request | output MP | scorer | request | `encode.search` | encode outside the search |
|---|---:|---|---:|---:|---:|
| `w=1200` | 0.96 | full | 1075 ms | 837 ms | 108 ms |
| `w=2400` | 3.84 | full | 4258 ms | 3717 ms | 379 ms |
| `w=2990` | 5.96 | full | **7009 ms** | 5965 ms | 964 ms |
| `w=3010` | 6.04 | crop | 1095 ms | 720 ms | 154 ms |
| `w=4000` | 10.7 | crop | 1147 ms | 781 ms | 145 ms |

In review 2 it was 6.87 s against 1.91 s. Now it's 7.0 s against 1.1 s. At
`w=2990` the metric leg is 5694 ms of the search, running on one dirty scheduler.
The time outside the search span is the full-frame reference that
`full_frame_opts/3` (`lib/image_pipe/output/encode_search.ex:629`) builds. That's
also a single NIF call, which costs about 160 ms/MP here.

**Suggested fix:** as before, move the crossover down to about 1.5–2 MP, or
choose by estimated cost (pixels × expected probes). Then re-validate the crop
offset against full-frame scoring at the new size (the Part R method in
`bench/autoquality.md`). Below 6 MP the crop sample of 16 × 512² ≈ 4.2 MP no
longer saves pixels by itself. It wins because the 16 tiles score in parallel,
so the crossover should be set by wall time, not by pixel count.

### 3. The default libvips operation cache still costs about 500 MB of RSS and makes requests slower (still open)

**Severity: High. Repeat of review 1 #5 and review 2 #1. Measured. Low risk.**

Nothing in `lib/` or `image_pipe_server/` calls `Vix.Vips.cache_set_max*`.
(Vix's own NIF only turns the cache off in `DEBUG` builds.) I ran 320 requests
(8 fixture JPEGs × 40 widths, JPEG output) in one VM, then ran a full GC and
read the RSS:

| libvips cache | RSS | libvips tracked memory (high-water) | total wall time |
|---|---:|---:|---:|
| off (`cache_set_max(0)`) | 203 MB | 0 MB (32 MB) | 119.7 s |
| default | 704 MB | 98 MB (116 MB) | 126.7 s |

The default was about 6% *slower* overall as well.

**Suggested fix:** unchanged from review 2. Call `Vix.Vips.cache_set_max(0)`
in `ImagePipe.Application.start/2` (`lib/image_pipe/application.ex:18`). If
changing global libvips state from a library is too strong, do it in
`image_pipe_server` and recommend it in `docs/deployment.md`.

### 4. An arbitrary-angle rotate adds an alpha band, which sends the whole frame through float premultiplied processing

**Severity: Medium–High. New. Measured. Medium risk; it touches transparency
semantics.**

`Rotate.rotate/2` (`lib/image_pipe/transform/operation/rotate.ex:47-48`) calls
`Alpha.ensure/1` so that the corners come out transparent. From then on the
frame has 4 bands:

- `Image.rotate/3` runs a premultiplied float affine for images with alpha.
- The following `Resize` uses `Image.resize/3`
  (`lib/image_pipe/transform/operation/resize.ex:48`), which premultiplies to
  float, resizes, unpremultiplies, and casts.
- For JPEG output (the default negotiation without AVIF/WebP in `Accept`, and
  any `format=jpeg`) the encoder flattens the alpha away again.

As a local experiment (reverted), I rotated without adding alpha, onto a white
background:

| request on `spin_base.jpg`, JPEG out | main | no alpha band |
|---|---:|---:|
| `rotate=10/w=800` | 280 ms | 159 ms |
| `rotate=10/w=3000` | **1718 ms** (encode 1083 ms) | 603 ms (encode 115 ms) |
| `rotate=10` on `beach.jpg`, no resize | 478 ms | 423 ms |

The corner pixels differ a little, because they're flattened onto white after
the rotate instead of being drawn as white during it. Byte counts moved by
under 0.1%.

A micro-benchmark shows the cost of the alpha path on its own. Resizing an
in-memory 6000×4000 frame by 0.5 takes 39 ms for RGB uchar, 47 ms for RGBA
uchar without premultiplication, and 350 ms through `Image.resize/3` with
premultiplication.

**Suggested fix:** when the group has an opaque `bg`, or the output format is
fixed to one without alpha (`format=jpeg`, or a policy whose format set has no
alpha-capable format), rotate onto that background colour and skip
`Alpha.ensure/1`. The executor needs one fact from the output policy for that
("can the final format hold alpha?"), which `Policy` can already compute for
explicit formats. Keep today's path when the output can carry transparency.

### 5. Trim is still the slowest single operation (still open)

**Severity: High. Repeat of review 1 #2 and review 2 #5. Measured. Medium risk.**

`/trim=auto/w=800/format=jpeg/src/spin_border.jpg` takes **1642 ms**, against
125 ms without trim, and the trim operation span is 1556 ms. The causes are
unchanged:

- The planner turns off shrink-on-load for any trim
  (`lib/image_pipe/transform/decode_planner.ex:62`).
- `find_trim` runs over the full 28 MP frame (`trim.ex:56`).

Review 2 measured a coarse-plus-refine variant inside `Trim.execute/2` at
143 ms against 1210 ms for `find_trim`. That suggestion still applies as
written: run `find_trim` on a frame shrunk by 8, then refine each edge with
`find_trim` on a 32 px full-resolution strip.

### 6. `min-w` or `min-h` turns off shrink-on-load

**Severity: Medium. New. Measured. Low risk; output pixels change slightly.**

`decode_resize_target/2` (`lib/image_pipe/transform/executor.ex:795-797`)
returns `nil` whenever a minimum is set, so the decode runs at full size even
when the minimum doesn't bind:

| request on `spin_base.jpg` | time | materialize |
|---|---:|---:|
| `w=800` | 134 ms | 110 ms |
| `w=800/min-w=400` (same 800×533 output) | 243 ms | 224 ms |
| `w=800/min-h=300` (same output) | 248 ms | 218 ms |

**Suggested fix:** `decode_request/2` already knows the display dimensions, so
compute the target with the same `Geometry.resize_target/3` the resize uses. That
target already includes the minimums and `enlarge`, so give the planner its
width and height instead of dropping out. A minimum can only make the target
larger, so the planner can never over-shrink.

### 7. Only the first group can shrink the decode

**Severity: Medium–Low. New. Measured. Medium risk; colour operations don't
commute exactly with resampling.**

`decode_request/2` reads only `groups: [group | _]` (`executor.ex:62-63`). When
a preset or URL puts a colour adjustment in a group ahead of the resize, the
whole source is decoded and adjusted at full size:

| request on `spin_base.jpg` | time |
|---|---:|
| `w=800` | 134 ms |
| `w=800/-/gray` | 133 ms |
| `contrast=1.2/-/w=800` | 300 ms |
| `gray/-/w=800` | 373 ms |

**Suggested fix:** when every group before the first resize holds only per-pixel
colour operations (gray, bitonal, monochrome, duotone, brightness, contrast,
saturation, colorize) and no geometry or pixel-sized effect, plan the decode from
that later group's resize. This changes pixels slightly (a tone curve applied
before or after averaging), so it needs a decision and re-baked goldens. How
much it's worth depends on whether presets really put adjustments in a leading
group.

### 8. Every watermarked request decodes and resizes the full watermark asset again

**Severity: Medium. New. Measured. Low risk.**

`Processing.decode_watermarks/2` (`lib/image_pipe/processing.ex:333-336`) calls
`Decode.watermark/2` for each request. That opens the asset bytes with
`access: :random` (`lib/image_pipe/decode.ex:175`). The executor then conditions
it, converts it to the frame's space, premultiplies it, and resizes it from full
size to the drawn size (`watermark.ex:76`).

With the 1200×600 logo drawn at 0.2 scale on an 800 px frame, the watermark adds
about 95 ms to a 120 ms request (216 ms in total). About 37 ms of that is the
asset decode inside the `[:transform, :execute]` span, and about 58 ms is
the asset's pixel work in the delivery materialize. The cost scales with the
asset's pixel count, not the drawn size.

**Suggested fix:** keep a small per-mount cache of the decoded, autorotated
asset in memory (`copy_memory`), keyed by the asset bytes' digest. Then only
the per-request resize and fade remain. A second level keyed by drawn size and
frame colour space would also remove those, if watermark traffic is high.

### 9. Each autoquality probe re-runs the lazy colour and metadata chain (still open)

**Severity: Low. Repeat of review 2 #9. Not re-measured; the code is
unchanged.**

`search_output/5` (`lib/image_pipe/output/encoder.ex:113`) still passes the
lazily finalized image (flatten, ICC conversion, and metadata edits on top of a
`copy_memory`) to `EncodeSearch.run/3`. Every probe encode and the reference
build evaluate that chain again. Review 2 measured 25 ms against 20 ms per JPEG
probe at 2400 px. The suggested fix is unchanged: `copy_memory` the finalized
image once before the search.

### 10. Detector children still run one after another (still open)

**Severity: Low. Repeat of review 1 #4. Inferred; the models aren't available
in this container.**

`Composite.detect/3` (`lib/image_pipe/transform/detector/composite.ex:84`)
still maps over the routed children sequentially. A request that routes to both
the face model and RT-DETR pays both times. Running the children with
`Task.async_stream` would cut that to the slower of the two.

## Checked and not worth changing

- **CMYK sources.** `w=800` from a 6000×4000 CMYK JPEG takes 292 ms against
  126 ms for sRGB. The `[:transform, :input_color_management]` span takes
  245 ms because `remove_profile` (`input_color_management.ex:137`) forces a
  `copy_memory` of the imported frame. But the CMYK JPEG decode alone takes
  230 ms at shrink 4, and the ICC import adds only about 20 ms. Removing that
  forced copy made requests *slower* (458 ms against 288 ms at `w=800`, and
  1053 ms against 344 ms at `w=2400`), because the resize then re-pulls the
  lazy LittleCMS chain. Leave it as it is.
- **Resize of RGBA sources.** `w=800` from a 2000×1334 PNG takes 194 ms with
  alpha against 91 ms without. Part of the gap is PNG decode, and part is
  the float premultiply in `Image.resize/3` (40 ms against 9 ms in memory).
  The premultiply is what keeps colour from bleeding in at transparent edges. An
  exact integer premultiply (uchar × uchar into ushort) was slower in a quick
  test, so I found no cheap fix outside the rotate case in finding 4.
- **Effects at 3000 px** (`spin_base.jpg`, `w=3000`, JPEG out, base 211 ms):
  blur +15 ms, pixelate, brightness, contrast, background, and padding within
  noise, colorize and gradient +0–50 ms, monochrome and duotone +30–50 ms,
  saturation +50 ms (an LCh round trip in `Image.saturation/2`), and sharpen
  +140 ms (libvips `sharpen` works in LabS). Progressive blur is still about 3×
  (628 ms). Review 2 found that only a blend redesign in uchar or ushort would
  change that.
- **Smart crop**: `anchor=smart/h=1000/fit=cover` at 3000 px takes 179 ms.
- **Placeholders**: `output=info,blurhash,lqip-css` takes 116 ms.
- **`fit=stretch` with one axis** keeps the other axis at full size, and JPEG
  shrink-on-load is uniform, so a full decode is correct there.

## Suggested order

1. Copy the mark to memory before tiling (#1). One line, same output, 4–16×
   faster tiled watermarks.
2. Turn off the libvips operation cache at boot (#3). One line, about 500 MB
   less RSS.
3. Let `min-w` and `min-h` feed the decode planner (#6).
4. Cache decoded watermark assets per mount (#8), and copy the finalized frame
   once before a quality search (#9).
5. Rotate onto an opaque background when the output can't hold alpha (#4).
6. Coarse-plus-refine trim inside the operation (#5).
7. Design decisions: a wall-time-based autoquality crossover (#2), planning the
   decode from a later group (#7), and concurrent detector children (#10).
