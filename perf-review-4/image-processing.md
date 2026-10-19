# Performance review 4: image processing and detection

Scope: decode planning, transform operations, materialization, watermarks,
encoding, the autoquality search, and the `image_vision` detector adapters.
Library paths are relative to `image_pipe/`, at `main` 8edf03b8. No code was
changed on any branch. The micro-benchmarks call the same libvips, Nx, and
SSIMULACRA2 functions the code uses, on the same inputs.

## How this was measured

Request numbers come from real `ImagePipe.Plug.call/2` requests against a file
source with no output cache and the libvips operation cache off (as
`image_pipe_server` now sets it). They were timed in-process, with stage times
summed from the library's own telemetry stop events. Each figure is the median
of 5 to 7 runs (3 for autoquality). The machine has 4 vCPUs and runs Linux with
libvips 8.18.7 built by the cloud setup hook.

Fixtures are `priv/static/images/` plus files derived from them:
`spin_base.jpg` (6000×4000 baseline JPEG, Q90), `spin_border.jpg` (the same
with a 200 px white border), `beach_rgba.png` (2000×1334 with alpha),
`logo.png` (a flat 1200×600 RGBA mark), and `logo2.png` (a 1200×600 RGBA crop
of `beach.jpg`, 846 KB, a photographic logo).

The detector models can't run in this container: Ortex needs its ONNX Runtime
download, which the network policy blocks. The detector finding measures
`image_vision`'s preprocessing on its own, with the same Nx calls and the same
`nx` 0.13.1 that `image_pipe_server/mix.lock` pins.

## Status of earlier findings

Fixed on main since review 3:

- A tiled watermark buffers the scaled mark once (review 3 #1, e60bca51).
  `/w=800/wm=logo/wm-scale=0.2/wm-tile` on `beach.jpg` now takes 152 ms
  (it was 1294 ms).
- `image_pipe_server` turns the libvips operation cache off at boot
  (review 3 #3, `image_pipe_server/lib/image_pipe_server/application.ex:24`).
- `min-w` and `min-h` feed the decode planner (review 3 #6, e4a.15.5):
  `w=800/min-w=400` takes 124 ms, the same as `w=800`.
- Detector children run concurrently (review 3 #10, PR #745).
- Trim finds the box on a shrunk preview and refines each edge at full
  resolution (review 3 #5). `/trim=auto/w=800` on `spin_border.jpg` takes
  536 ms (it was 1642 ms). Most of what is left is the full-size decode and
  copy (`transform.materialize` 189 ms), which deferred bead e4a.6.2 (two-pass
  decode) covers.

Closed by decision, so not repeated: the 6 MP autoquality crossover (e4a.15.1),
planning the decode from a later group (e4a.15.4), and the arbitrary-angle
rotate (e4a.15.3). For the record, `rotate=10/w=3000` still takes 1168 ms
against 183 ms without the rotate. The rotate's own materialize is 696 ms and
the encode 422 ms, because the ×2 decode headroom decodes at full size and the
frame stays four-band float through the resize.

Still deferred, with a new data point: e4a.19 (cache sized watermark assets).
With the photographic `logo2.png` at `wm-scale=0.2`, a watermark adds 62 ms to
a 131 ms `w=800` request on `beach.jpg`. Decoding the asset alone takes 19 ms.
The flat `logo.png` adds 22 ms.

## Findings, ranked by payoff against risk

### 1. `image_vision` builds the detector's input tensor in pure Elixir, which costs about 0.9 s per model per request

**Severity: High. New. Measured (preprocessing only). Output unchanged. The
fix is upstream or a rewrite of the adapters' preprocessing.**

Both adapters call `image_vision` 0.4.0
(`lib/image_pipe/transform/detector/image_vision/face.ex:65`,
`objects.ex:81`). Its `preprocess/1` thumbnails the frame to 640 px in libvips,
then converts it to the model's input with `Nx.BinaryBackend`, which runs
element by element in Elixir:

- Faces, `deps/image_vision/lib/face_detection.ex:368-390`:
  `Image.to_nx!(backend: Nx.BinaryBackend) |> Nx.as_type(:f32) |>
  Nx.transpose(axes: [2, 0, 1]) |> Nx.new_axis(0)` on 640×640×3.
- Objects, `deps/image_vision/lib/detection.ex:282-306`: the same with an
  extra `Nx.divide(255.0)`.

Timed on a 640×640 sRGB thumbnail of `beach.jpg`:

| step | time |
|---|---:|
| face preprocessing (`as_type`, `transpose`) | **858 ms** |
| object preprocessing (`as_type`, `divide`, `transpose`) | **954 ms** |
| the same tensor built in libvips (`linear` 1/255, cast to float, one band at a time, then `Nx.from_binary` and `reshape`) | 37 ms |
| face postprocessing, only the `Nx.to_list` calls over the 3 strides | 55 ms |
| object postprocessing (`sigmoid`, `argmax`, `reduce_max`, lists) | 9 ms |

The process that ran the object preprocessing held 81 MB of heap afterwards.
For one routed model that process is the request process, because
`Composite.run_children/4` (`lib/image_pipe/transform/detector/composite.ex:87`)
runs a single child inline.

That is most of a detection request. Bead e4a.6.7 measured
`detect=person,face` at 2.1 s p50 at c=1 and about 0.95 req/s under load in
the vision image. Running the two children concurrently only saved 11%, which
fits two ~0.9 s Elixir loops each sitting on one scheduler. The inference time
itself wasn't measurable here.

**Suggested fix:** build the tensor in libvips and hand Ortex a binary. For
YuNet, cast to float and write one band at a time (CHW). For RT-DETR, also
`linear` by 1/255 first. Then `Nx.from_binary(..., :f32) |> Nx.reshape({1, 3,
640, 640})`. That is 37 ms instead of about 900 ms, and the values are the
same.

- Upstream: file it as a deferred `image_vision` bead, like image_plug-rpsa
  and image_plug-8qdy. The same `preprocess/1` is where rpsa's fix (YuNet
  channel order and the stretched frame) goes, so both could ship together.
- In ImagePipe: the adapters can't reach `preprocess/1`, since it's private.
  A workaround means calling Ortex directly with ImagePipe's own pre- and
  postprocessing for both models (the model load can stay with
  `ImageVision.ModelCache`). That is roughly the size of `image_vision`'s two
  modules.

Question for Håvard: wait for an `image_vision` release, or carry the
preprocessing (and rpsa's fix) in the adapters until then?

### 2. Autoquality on transparent images scores the two backgrounds one after the other

**Severity: Medium. New. Measured. Output unchanged; low risk.**

Since 525ea8b5, an image with alpha is scored against dark and light grey and
the lower score is kept (`lib/image_pipe/output/ssim2_metric.ex:19`).
`background_references/2` (line 56) builds the two references, and
`score/2` (line 37) compares the two, through `map_ok/2` (line 71), which runs
them in turn. Each compare is a dirty NIF call on one scheduler, so a probe on
an alpha image takes twice as long as a probe on an opaque one:

| autoquality, `w=1200`, WebP out | probes | metric per probe | request |
|---|---:|---:|---:|
| `beach.jpg` (opaque) | 3 | 320 ms | 1505 ms |
| `beach_rgba.png` | 2 | 625 ms | 1916 ms |

On a 1200×800 frame in isolation, one compare takes 285 ms, two in a row
583 ms, and two in `Task.async_stream` 306 ms. Building one reference takes
88 ms, so the reference phase doubles too.

**Suggested fix:** compute the two references and the two compares
concurrently (`Task.async_stream` with `timeout: :infinity`, as
`CropScore.each_tile/2` already does). The scores, and so the chosen quality,
don't change.

### 3. The SSIMULACRA2 compare is single-threaded

**Severity: Medium. New angle on the decided crossover. Measured. Output
unchanged; the change is in the `ssimulacra2` package.**

The crossover decision (e4a.15.1) stands, but the cost below it comes from one
place. `ssimulacra2` (hlindset/ssimulacra2, `fast-ssim2` at rev 093aa6f) has no
`rayon` or other threading in its `Cargo.lock` or NIF
(`deps/ssimulacra2/native/ssimulacra2_nif/src/lib.rs:177`, `:240`), so each
compare runs on one dirty scheduler. In this run, a compare costs about
300 ms/MP against 90 ms/MP for building the reference. Full-frame searches
below 6 MP are still the slowest requests in this area:

| autoquality, JPEG out, `spin_base.jpg` | output MP | request | `encode.search` |
|---|---:|---:|---:|
| `w=1200` | 0.96 | 1130 ms | 912 ms |
| `w=2400` | 3.84 | 3957 ms | 3462 ms |
| `w=2990` | 5.96 | **6345 ms** | 5543 ms |
| `w=3010` (crop scoring) | 6.04 | 1344 ms | 876 ms |

**Suggested fix:** in `ssimulacra2`, compute the per-scale work on the three
planes (and the SSIM and edge maps) in parallel, for example with `rayon`
inside the compare. It would need the same `enough` stop token per task. This
speeds up every full-frame search without moving the crossover or changing a
score. Under load it competes with other requests for cores, so measure
throughput as well as single-request time.

Question for Håvard: is threading inside the NIF acceptable for the package,
or should parallelism stay at the Elixir level (finding 2, crop tiles)?

### 4. A single watermark composites the whole frame in float

**Severity: Low. New. Measured. Output unchanged; low risk.**

`composite/4` (`lib/image_pipe/transform/operation/watermark.ex:210`) casts the
whole frame and the mark to float, runs `composite2` at the mark's offset,
then rounds the whole frame back. For a mark that covers a small part of the
frame, every other pixel is still cast, blended with nothing, and rounded.

On an in-memory 3000×2000 frame with a 300×150 mark, copied to memory at the
end:

| approach | time |
|---|---:|
| current: whole-frame float composite | 45 ms |
| extract the covered area, composite it, `insert` it back | 18 ms |
| copy only | 5 ms |

The two outputs are byte-identical. At request level,
`/w=3000/wm=logo/wm-scale=0.1` takes 263 ms against 188 ms without the mark,
and the encode span (where the lazy composite runs) grows from 32 ms to 71 ms.

**Suggested fix:** for an untiled mark, clip the mark's rectangle to the frame,
`extract_area` that part of the base, composite it there in float, round, and
`insert` it back into the untouched base. Keep the whole-frame path for tiled
marks, which cover the frame anyway.

## Checked and not worth changing

- **EXIF-rotated sources.** `w=2000` on a 6000×4000 JPEG tagged orientation 6
  takes 199 ms against 183 ms for `w=3000` on the untagged copy (both 6 MP
  out). At `w=800` the difference is within noise.
- **Profiled sources.** A Display P3 tag on `spin_base.jpg` adds 6–18 ms at
  `w=800` and `w=3000`, and nothing measurable under autoquality.
- **Placeholders and info.** `output=info` answers in 1–3 ms without decoding
  pixels. `output=blurhash` on the 2000 px PNG takes 106 ms, mostly the PNG
  decode.
- **Effects at 3000 px** (base 183 ms): blur 248 ms, pixelate 197 ms, sharpen
  341 ms (sharpen works in LabS, as review 3 found).
- **AVIF chroma.** At Q60 and effort 3, 4:4:4 encodes a 1200 px frame in
  388 ms against 275 ms for `subsample-mode=auto`. The default is a measured
  choice (PR #702), and bead o7dc already re-examines it.
- **`ready?` on the request path.** `ImageVision.ModelCache.cached?/2` is a
  `File.exists?` call, so checking readiness per request costs microseconds.
- **Memory hunt finding 2 (ONNX arena growth)** is about inference memory and
  isn't repeated here. Finding 1 above is separate: an Elixir heap of about
  80 MB per detection, freed when the process collects or exits.

## Suggested order

1. Score the two alpha backgrounds concurrently (#2). A few lines, same
   scores, about half the search time on transparent images.
2. Decide how to get the detector's tensor out of `Nx.BinaryBackend` (#1):
   upstream, or own preprocessing in the adapters. It's the largest single
   cost in a detection request.
3. Composite an untiled watermark only where it lands (#4).
4. Parallelize the compare inside `ssimulacra2` (#3), measured under load as
   well as alone.
