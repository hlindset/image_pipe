# Performance review 2: image processing and encoding

Scope: decode planning, transform operations, materialization, encoding, and the
autoquality search. Paths are relative to `image_pipe/`, at `main` 549fbb5. No
code was changed.

## How this was measured

This time the Elixir toolchain worked, so most numbers are real
`ImagePipe.Plug.call/2` requests against a file source with no output cache,
timed in-process with per-stage durations taken from the library's own
telemetry stop events. The machine is a 4-vCPU Intel Xeon at 2.8 GHz (AVX2 and
AVX-512) running Linux, with Vix 0.42's precompiled libvips. The libvips
operation cache was off unless a finding says otherwise. Each figure is the
median of 3 to 9 runs. Micro-benchmarks call the same Vix operations the code
uses, on the same images.

The fixtures are `priv/static/images/` plus three derived files:
`spin_base.jpg` (spinning.jpg re-saved as a 6000×4000 *baseline* JPEG at Q90,
because every fixture JPEG is progressive), `spin_border.jpg` (the same image
with a 200 px white border, 6400×4400), and `beach_rgba.png` (2000×1334 RGBA).
A finding marked *measured* has numbers from this run. One marked *inferred*
comes from reading the code.

Findings from the first review that have since been fixed are left out: the
AVIF/WebP default effort (#1) and the crop-mode reference cache (#3). Trim (#2)
and the operation cache (#5) are still open, and both appear below with new
measurements. Detector concurrency (#4) is still open but couldn't be measured
here, because the models aren't downloaded in this container.

## Findings, ranked by payoff against risk

### 1. The default libvips operation cache adds about 530 MB of resident memory and gives no speed in return

**Impact: High. Measured. Low risk.**

`lib/` and `image_pipe_server/` never call `Vix.Vips.cache_set_max*`, so
production runs with libvips' default cache (100 operations, 100 MB, 100 files).
The tests and every bench script turn it off.

I ran 320 requests (8 large JPEG fixtures × 40 widths, JPEG output) through one
VM, then ran a GC and read the RSS. Two runs of each:

| libvips cache | RSS after 320 requests | libvips tracked memory (high-water) |
|---|---:|---:|
| off (`cache_set_max(0)`) | 134–140 MB | 0 MB (8 MB) |
| default | 670–674 MB | 15 MB (20 MB) |

Latency for repeated *identical* requests, which is the best case for the
cache, stayed within noise: 149 → 140 ms, 173 → 169 ms, and 206 → 202 ms for
three request shapes, 9 runs each. A typical ImagePipe request decodes from a
new buffer, so cache hits are rare. The cache mostly keeps decoded source
buffers alive after their requests finish.

**Suggested fix:** call `Vix.Vips.cache_set_max(0)` at boot, in
`ImagePipe.Application.start/2` (`lib/image_pipe/application.ex:18`) or at least
in the server release. A host that wants the cache can raise it again. If
changing global libvips state from a library seems too strong, set it in
`image_pipe_server` and recommend it in `docs/deployment.md`.

### 2. Crop-mode autoquality scores its 16 tiles one after another

**Impact: High. Measured. Low risk; scores and output are identical.**

Above the 6 MP crossover, every probe scores 16 SSIMULACRA2 tiles in a serial
`Enum.reduce_while` (`lib/image_pipe/output/ssim2_metric/crop_score.ex:109`),
and `references/1` (`crop_score.ex:83`) builds the 16 tile references serially
too. Each tile is an independent NIF call on a dirty CPU scheduler, and the NIF
itself runs on one thread.

For a 4000×2667 frame encoded as JPEG Q80:

| step | serial (current) | `Task.async_stream`, 4 schedulers |
|---|---:|---:|
| `references/1`, built once per search | 461 ms | 150 ms |
| `p10/2`, run once per probe | 1057 ms | 356 ms |

The p10 score was identical (80.691…). A real 4000 px autoquality request
spends 1228 ms of its 2032 ms in the metric leg, all on one core.

**Suggested fix:** score the tiles with
`Task.async_stream(refs, …, max_concurrency: System.schedulers_online(), ordered: false)`,
then sort. Do the same for `references/1`. Under full load this trades
per-request latency for throughput that the other requests would have used, so
cap concurrency at the dirty-CPU scheduler count.

### 3. Full-frame scoring just below the 6 MP crossover costs 3.5× more than crop scoring just above it

**Impact: High. Measured. Medium risk; it changes which quality gets chosen.**

Below `@crossover_megapixels 6` (`crop_score.ex:19`, used by `crop?/2` at
`lib/image_pipe/output/encoder.ex:103`), every probe scores the whole frame. On
this x86 machine SSIMULACRA2 costs about 300 ms/MP per compare and 100 ms/MP to
build the reference. `bench/autoquality.md` calibrated the crossover on Apple
Silicon, where it measured about 44 ms/MP. That is a 6–7× difference.
Rebuilding the NIF locally with `target-cpu=native` changed less than 10%, so a
precompiled build missing SIMD isn't the cause.

Autoquality requests with JPEG output (a cheap encoder, so the metric dominates)
on `spin_base.jpg`:

| request | output MP | scorer | probes | metric time | request |
|---|---:|---|---:|---:|---:|
| `w=1200` | 0.96 | full | 3 | 885 ms | 1.16 s |
| `w=2400` | 3.84 | full | 3 | 3597 ms | 4.27 s |
| `w=2990` | 5.96 | full | 3 | 5984 ms | **6.87 s** |
| `w=3010` | 6.04 | crop | 1 | 1121 ms | 1.91 s |
| `w=4000` | 10.7 | crop | 1 | 1228 ms | 2.03 s |

The step at the crossover is backwards: a slightly smaller image takes 3.6×
longer. On x86 the crop sample (16 × 512² ≈ 4.2 MP) is cheaper than the full
frame for anything over about 2 MP. Even a 1200 px AVIF autoquality request
spends 332 ms of its 931 ms in the metric. Of that, about 50 ms is the AVIF
decode, because the candidate decodes lazily inside the metric leg.

**Suggested fix:** two parts.
1. Lower the crossover to about 2 MP, or switch on estimated cost (pixels ×
   probes), and re-validate `@crop_offset` and the Part E/L agreement numbers at
   the new size. This changes the chosen quality for 2–6 MP outputs, so it
   needs the same benchmark evidence as the original calibration.
2. Re-run `mix autoquality.bench` on x86 Linux and record it next to the Apple
   Silicon numbers, so the latency budgets in the docs match common server
   hardware.

Finding 2 makes the crop side cheaper still, which widens the gap.

### 4. Arbitrary-angle rotate turns off shrink-on-load

**Impact: Medium–High. Measured. Medium risk; output pixels change slightly.**

`Executor.decode_request/2` returns an empty `%DecodePlanner.Request{}` when the
first group rotates by an angle that isn't a right angle
(`lib/image_pipe/transform/executor.ex:62-65`). So `rotate=10/w=800` decodes all
24 MP, rotates at full size, buffers the result (`buffer_before_resize?`), and
only then resizes.

`/rotate=10/w=800/format=jpeg/src/spin_base.jpg` takes 1074 ms against 167 ms
for `rotate=90`. Telemetry splits it into rotate 200 ms, materialize 459 ms, and
resize 261 ms. The same Vix chain with a decode shrink:

| decode shrink | 1 (current) | 2 | 4 |
|---|---:|---:|---:|
| decode + rotate + buffer + resize to 800 px | 1092 ms | 480 ms | 242 ms |

Shrink 1 and shrink 4 differ by a mean of 0.82 levels per channel, and the
output height by 1 px from rounding.

**Suggested fix:** let the planner shrink before an arbitrary rotation. The
rotated bounding box of a `w×h` source is `w·|cos θ| + h·|sin θ|` wide, so
compare the resize target against that box scaled by the shrink. Rotation and
uniform scaling commute, so this costs only resampling-order differences. Trim
or crop in the same group still need their own handling. This changes output, so
it needs re-baked goldens for rotate.

### 5. Trim is still the slowest single operation (first review's #2, still open)

**Impact: High. Measured. Medium risk.**

`/trim=auto/w=800/format=jpeg/src/spin_border.jpg` takes **1647 ms**, against
126 ms without trim. The trim operation span is 1541 ms. New measurements show
where it goes:

- `find_trim` on the 28 MP frame: 1210 ms on its own. The sRGB conversion in
  `prepare/1` (`lib/image_pipe/transform/operation/trim.ex:76`) adds only about
  100 ms. Copying the ICC transform to memory alone costs 92 ms.
- The first review's two-pass plan, which is a cheap preview decode then
  `find_trim`, measured 115 ms (shrink 8), 213 ms (shrink 4), and 542 ms
  (shrink 2) for preview decode + ICC + `find_trim`.

A variant that leaves the decode plan alone and stays inside `Trim.execute/2`:
shrink the already-decoded frame by 8 (`Operation.shrink`), `find_trim` that
(42 ms in total), then refine each of the 4 edges with `find_trim` on a 32 px
full-resolution strip around the coarse edge. That measured **143 ms** in total
against 1210 ms, and gives full-resolution edges in the normal case. Its risk is
a coarse pass that misses a border feature narrower than the shrink factor,
which the strip refinement only partly covers.

**Suggested fix:** do the in-op coarse + refine first. It's local to
`trim.ex`, keeps full-resolution edges, and should leave goldens unchanged for
ordinary borders. The full-resolution decode (about 220 ms here) then stays the
main cost, and the two-pass shrink-on-load design from the first review can
follow if that matters.

### 6. `output=lqip-css` decodes at full resolution to make a 3×3 image

**Impact: Medium. Measured. Low risk.**

`decode_terminal_reduction/1` (`lib/image_pipe/transform/executor.ex:783-789`)
gives shrink-on-load only to a single-group `:blurhash` request. A `:lqip_css`
request resizes to 3×3 (`executor.ex:133`) from a full-size decode.

| request on `spin_base.jpg` | time | materialize |
|---|---:|---:|
| `output=blurhash` (gets the reduction) | 105 ms | — |
| `output=lqip-css` | 205 ms | 163 ms |
| `output=info,blurhash,lqip-css` | 301 ms | 170 ms |

Decoding this file takes 206 ms at shrink 1 and 78 ms at shrink 8.

**Suggested fix:** give a single-group `:lqip_css` request a terminal reduction
too, the same way as blurhash. Any target of about 32 px or more is plenty for a
3×3 mean. `info` with `lqip-css` is harder. `executed_facts/3`
(`lib/image_pipe/processing/terminal.ex:101`) takes the result width and height
from the frame it decoded, so that decode can't simply be shrunk. Compute the
`info` lqip value from its own reduced decode instead, the way `put_blurhash/4`
(`terminal.ex:125`) already re-decodes for blurhash. Two cheap decodes cost
less than one full-size decode. The 3×3 value can move by a level or so, so
re-bake the lqip golden.

### 7. Blur and sharpen on images with alpha run about 10× slower per pixel since the switch to float precision

**Impact: Medium. Measured. Low–medium risk; pixels move by at most 2–4 levels.**

Commit 07185f1 made `AlphaPremultiply.with_alpha_premultiplied/2`
(`lib/image_pipe/transform/operation/alpha_premultiply.ex`) hand the float
premultiplied image to the filter. That fixed low-alpha colour truncation. But
libvips' Gaussian convolution on float input takes the slow path, while
uchar input uses the vectorized integer path.

| `beach_rgba.png`, 2000×1334 RGBA (no resize, JPEG out) | request | materialize |
|---|---:|---:|
| none | 86 ms | 37 ms |
| `blur=10` | 309 ms | 239 ms |
| `sharpen=2` | 273 ms | 201 ms |
| `progressive-blur=10` | **1224 ms** | (in encode: 1139 ms) |

For comparison, `blur=10` on a 6 MP *RGB* frame adds only 21 ms.

Micro-benchmark, `gaussblur` on the same 2000×1334 image:

| sigma | RGB uchar | RGBA float premultiplied (current) | float, `precision: :approximate` | premultiplied → ushort ×257 |
|---|---:|---:|---:|---:|
| 2 | 12 ms | 60 ms | 53 ms | 60 ms |
| 10 | 17 ms | 225 ms | 81 ms | 175 ms |

With `precision: :VIPS_PRECISION_APPROXIMATE` the result differs from the
current output by at most 2 levels at sigma 10 and 4 levels at sigma 2, while
keeping the float premultiplied input that fixed the truncation.

**Suggested fix:** pass `precision: :VIPS_PRECISION_APPROXIMATE` to `gaussblur`
when the input is float (in `Blur` and in `ProgressiveBlur.add_level/5`). Check
the low-alpha case from 07185f1's test still holds, and re-bake the alpha blur
goldens. Sharpen goes through a ushort round-trip plus libvips' LabS conversion
(`sharpen.ex`), so this flag doesn't apply to it. Sharpen costs a lot on RGB
too (+114 ms at 6 MP), so I didn't find a quick fix for it.

### 8. Progressive blur costs about 18× a plain blur, mostly in float blending

**Impact: Low–Medium. Measured. Low risk for the part that's safe.**

`ProgressiveBlur` (`lib/image_pipe/transform/operation/progressive_blur.ex:66,78`)
blurs the whole frame at 8 sigmas and blends all 9 levels with 9 full-frame
float weight maps, even though each pixel uses only 2 adjacent levels. On a
3000×2000 RGB frame at sigma 10: the operation takes 428–436 ms against 24–30 ms
for one `blur`. The 8 blurs alone take 200 ms. Building the ramp and the 9
weights takes most of the rest, and so does blending the 8 blurs once they're
already in memory (341 ms).

Gating each level with `ifthenelse(weight > 0, acc + term, acc)` lets libvips
skip regions where a level contributes nothing. It gave identical pixels (max
diff 0) and took 357–406 ms, a 7–17% gain. Building the weights on a 1-pixel
column and replicating it was *slower*, and so was processing each row band
separately. Most of the cost is the float multiply and add over 3 bands.

**Suggested fix:** take the `ifthenelse` gating, since it's free and leaves
output unchanged. A real speedup needs fewer float passes, for example blending
in uchar or ushort with `maplut` weights. That's a design change and only
worth it if progressive blur gets real traffic.

### 9. Each autoquality probe re-runs the lazy colour and metadata chain over the buffered frame

**Impact: Low. Measured. Low risk.**

`Encoder.finalize/3` (`lib/image_pipe/output/encoder.ex:215`) copies the frame
to memory and then adds flatten, ICC conversion (`to_standard`, sRGB→sRGB for
the usual tagged JPEG), and metadata edits lazily on top. With a quality search,
every probe encode and the reference build evaluate that chain again. At
2400 px a JPEG probe took 24.8 ms on the lazy chain against 19.9 ms when the
chain is copied to memory first (15 ms once). At 800 px the difference was
about 1 ms for JPEG and 4–6 ms for WebP and AVIF.

**Suggested fix:** in `search_output/5`, `copy_memory` the finalized image once
before `EncodeSearch.run/3`. It pays off from the second probe onward. It
doesn't apply to the single-encode path.

## Checked and not worth changing

- **Plain resize pipeline.** `/w=800` from a 24 MP baseline JPEG takes 150–158
  ms, and 117 ms of that is the delivery materialize. The same chain built by
  hand (shrink 4 decode + resize + copy) takes 113 ms, and
  `thumbnail_buffer` is slower (147 ms). Decode dominates (shrink 4: 101 ms;
  shrink 8: 78 ms), and the planner already picks the largest legal JPEG
  shrink.
- **Smart crop.** `anchor=smart` adds 56–75 ms over a gravity crop at 3000×2000,
  which is acceptable for attention scoring.
- **Encoders at current defaults.** At 800 px: JPEG 10 ms, WebP about 70 ms,
  AVIF about 200 ms (effort 3). The first review covered this, and it has been
  decided.
- **PNG sources.** `cooking.png` (9.7 MP) spends about 400 ms decoding for a
  `w=800` request. libvips has no shrink-on-load for PNG.

## Outside this area

Every request spends 13–24 ms in `source.stage` for a local file source. That
belongs to sources and caching, not image processing.

## Suggested order

1. Turn off the libvips operation cache at boot (#1). One line, about 530 MB
   less RSS here.
2. Score the crop-mode tiles and build their references in parallel (#2).
   Small diff, same output.
3. Give `lqip-css` (and `info` with placeholders) a terminal reduction (#6).
4. Copy the finalized frame once before a quality search (#9), and gate
   progressive-blur levels (#8). Both are free.
5. Approximate-precision Gaussian for float premultiplied input (#7). Re-bake
   goldens.
6. Coarse + refine trim inside the operation (#5).
7. Design notes: shrink-on-load before an arbitrary rotate (#4), and a lower,
   x86-calibrated autoquality crossover (#3).
