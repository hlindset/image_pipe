# Image materialization investigation

Implementation and measurements for `image_plug-fd8`, 2026-09-22. Orientation
now prepares random access only when needed, reuses existing RAM backing, and
leaves the oriented result lazy. Input color management skips metadata mutation
when the ICC field to remove is absent. Operation order and output pixels are
preserved.

## Reproduce

```sh
mise exec -- mix run bench/pre_clamp_materialization.exs matrix /tmp/fd8
```

The script runs 34 requests in separate VMs. Measurements used Image 0.72.0,
Vix 0.41.0, libvips 8.18.6, Elixir 1.20.4, OTP 29, two libvips threads, and
disabled operation caching. Each request uses
the real Plug lifecycle and a sequential file source. Fixtures are lossless
TIFFs derived from the repository's beach photograph, resized to 600×400.
EXIF 3 and 6 fixtures retain those stored dimensions; physically rotated,
orientation-1 twins provide matching display-frame controls. The twins were
verified to contain exactly the same source pixels after rotation.

`results.json` records request paths, operation/materialization/clamp dimensions,
libvips high-water marks, final dimensions, and decoded pixel hashes.
`comparisons.json` compares EXIF inputs against their physically oriented twins.
Output PNGs are retained for independent inspection. Request high-water is
captured **before** decoding output for comparison. Fixture generation and
cross-image comparisons run outside the measured worker VMs.

These are single-request measurements, not throughput measurements or a
representative workload distribution. Libvips tracked memory excludes some
allocations; RSS measurements below include the whole VM. Timings are recorded
but are not a statistically controlled CPU comparison.

## Baseline allocation path

`Transform.Executor.execute_resize/3` performs resize, the optional cover crop,
then flushes pending orientation. Before this change, `OrientationFlush.flush/1`
copied the unrotated image to RAM for EXIF 3–8/right-angle rotation/vertical flip,
applied orientation, and copied the oriented image to RAM again.

Only after execution does `Processing.produce_stream/7` clamp the final image.
The delivery-side clamp-before-materialization optimization remains intact.
In the baseline oriented path, both large buffers had already been allocated.

With a width-only 6000 request, EXIF 6 changes the display aspect ratio:
the executor resizes the stored frame to 9000×6000 and materializes a
6000×9000 display frame. Comparing it directly with the plain landscape input
would confound orientation with area, so the table includes the portrait twin.

## Baseline measurements

Libvips peak MiB, target width 6000, both axis caps 2048, pixel cap 200 million:

| Request | Plain | EXIF 3 | EXIF 6 | Physically oriented EXIF 6 twin |
|---|---:|---:|---:|---:|
| Fit (`w=6000/enlarge`) | 30.2 | 139.0 | 309.3 | 36.2 |
| Cover (`w=6000/h=2000/fit=cover/enlarge`) | 27.8 | 70.3 | 68.9 | 27.5 |
| Canvas (`w=6000/h=6000/enlarge/extend`) | 130.6 | 193.4 | 183.4 | 125.5 |
| Padding (`w=6000/enlarge/pad=200,300,400,500`) | 142.9 | 205.1 | 331.4 | 179.2 |
| Groups (`w=6000/enlarge/-/w=1500`) | 32.1 | 139.0 | 309.3 | 40.5 |

Cover's 9000×6000 stored-frame overshoot is cropped to 2000×6000 **before**
orientation materializes. Its buffer is therefore the cropped frame, not the
entire overshoot. Clamping the intermediate resize would alter this composition.

The EXIF 3 multiple-group request produces only 1500×1000 and never needs final
clamping, but still materializes 6000×4000 in the first group. The problem is
therefore broader than requests whose final dimensions exceed output caps.

Canvas and padding also allocate substantially in plain requests despite their
only explicit materialization occurring after clamping. Explicit materialization
spans do not account for every allocation inside the lazy libvips graph.

For `w=12000/enlarge`:

| Caps | Plain peak MiB | EXIF 6 peak MiB | Portrait twin peak MiB | EXIF 6 final dimensions |
|---|---:|---:|---:|---|
| Defaults: 8192 axes, 40 million pixels | 238.1 | 1236.2 | 235.0 | 5164×7745 |
| 8192 axes, 200 million pixels | 265.7 | 1236.2 | 262.5 | 5461×8192 |
| 10000 axes, 200 million pixels | 393.4 | 1236.2 | 389.4 | 6667×10000 |

Default-cap runs measured with macOS `/usr/bin/time -l` peaked at 561.0 MiB RSS
for plain, 1778.3 MiB for EXIF 6, and 545.8 MiB for the portrait twin.
These OS peaks include worker startup and output pixel verification; only the
libvips snapshots exclude that post-request verification work.
The baseline EXIF 6 allocation was dominated by two 12000×18000×3-byte buffers, independent
of the final output cap. Result caps are not bounds on intermediate working memory.

## Implemented orientation changes

Physically orienting before resizing preserved dimensions but changed output
pixels in all 13 EXIF/twin comparisons. At target 6000, maximum absolute channel
differences were 12–25 on the 8-bit outputs. This is not a byte-preserving fix.

`OrientationFlush` materializes only when rows must be reordered and the state
does not already have RAM backing. It then builds the orientation lazily, without
a second copy. Identity and horizontal-only orientation preserve sequential
access; delivery materializes after the final clamp when needed. Existing RAM
backing is reused across groups. Resize/crop/clamp order is unchanged.

| Case | Baseline peak MiB | Implemented peak MiB | Reduction |
|---|---:|---:|---:|
| Fit, EXIF 3, 6000→2048 cap | 139.0 | 97.9 | 29.6% |
| Fit, EXIF 6, 6000→2048 cap | 309.3 | 190.0 | 38.6% |
| Cover, EXIF 6, 6000→2048 cap | 68.9 | 58.6 | 15.0% |
| Groups, EXIF 6, 6000→1500→2048 cap | 309.3 | 194.3 | 37.2% |
| Fit, EXIF 6, 12000, default caps | 1236.2 | 846.9 | 31.5% |
| Fit, EXIF 6, 12000→8192 cap, raised pixel cap | 1236.2 | 874.1 | 29.3% |
| Fit, EXIF 6, 12000→10000 cap, raised pixel cap | 1236.2 | 999.6 | 19.1% |

All 34 matrix cases had identical decoded pixel hashes and dimensions to
their baseline counterparts. However, oriented canvas/padding peak memory increased
by 0.5–2.7%; retaining the unrotated RAM backing changes downstream allocation
and access behavior. The implemented path still allocates one oversized image.
Canvas peaks changed from 193.4→198.3 MiB (EXIF 3) and 183.4→186.7 MiB (EXIF 6);
padding changed from 205.1→210.6 and 331.4→333.0 MiB, respectively. These bounded
regressions accompany the larger fit/cover/group savings; this is not a universal
peak-memory reduction.

`State.materialized?` describes RAM-backed random access, not a contiguous buffer
for the current lazy result. Materialization telemetry reports the dimensions
actually copied before orientation. Flush-operation telemetry reports the display
frame. Logger and trace coverage assert both, including skipped copies.

## Broader audit

The scope also covers repeated orientation groups, sequential-safe flips,
metadata mutation, and output finalization. Reproduce the additional 14 requests:

```sh
mise exec -- mix run bench/pre_clamp_materialization.exs audit /tmp/fd8-audit
```

The orientation/metadata audit uses width 3000, axis caps 1024, and a
200-million-pixel cap. It adds
a Display-P3 fixture, retaining its 480-byte ICC profile in a lossless TIFF.
Telemetry snapshots include input conditioning, encoding start/stop, and live
tracked memory as well as high-water. Encoding stop measures through the first
chunk; the request high-water includes complete response consumption.

| Plain-source request | Baseline peak MiB | Implemented peak MiB | Final dimensions |
|---|---:|---:|---|
| `w=3000/enlarge` | 13.7 | 13.7 | 1024×683 |
| `flip=h/w=3000/enlarge` | 27.3 | 16.2 | 1024×683 |
| `rotate=90/w=3000/enlarge/-/rotate=90/w=1500` | 77.5 | 64.2 | 1024×683 |

The horizontal case now materializes at 1024×683 after clamping, instead of
3000×2000 during flush. Rotation groups prepare the first storage frame and
reuse its RAM backing for the second orientation. All 12 original audit cases
retain their baseline dimensions and decoded pixel hashes.

Plain and Display-P3 requests were also measured with `meta=keep`, `meta=strip`,
`profile=preserve`, and `profile=srgb`. Peaks remained 13.7 MiB for plain and
15.0 MiB for P3 in all those samples. This does not establish that finalization
allocates nothing: allocations below an earlier high-water do not raise it.
It does mean this audit has not demonstrated an overall memory saving there.
These intentionally different metadata/color policies are separate baselines;
their output hashes are not expected to match each other.

Code inspection found unconditional `copy_memory` in encoder finalization and
implicit calls inside Vix metadata mutation. A separate direct-library probe
retained every image reference: a 2000×1500 RGB RAM image used 9,000,016 tracked
bytes; repeating `copy_memory` and editing a metadata field left that unchanged.
Editing metadata after a lazy 0.5 resize raised live memory to 11,250,032 bytes.
Thus call count cannot substitute for allocation measurements.

The ordinary transform gate already respects `materialized?`; this audit does
not justify broadly removing random-access preparation. The relevant distinction
is between display-frame orientation, RAM-backed random access, and an evaluated
contiguous result. Metadata-triggered evaluation also needs accounting alongside
explicit materialization spans.

Two additional requests cover profiled and unprofiled linear scRGB TIFFs, each
1000×667 with target width and axis caps 128. Removing an absent ICC field used
to force evaluation through Vix metadata mutation. Skipping that no-op reduced
the unprofiled request from 15.0 to 8.7 MiB (42.0%), with exactly the same decoded
pixel hash and 128×85 dimensions. The profiled case still needs mutation and
peaks at 15.0 MiB. Wire tests cover both resizing and no-geometry output;
property coverage compares sequential and random input across sizes and HDR
conditioning policies.

## Decision

The measured orientation and absent-profile optimizations are implemented.
Universal clamp reordering or resample folding is not justified: moving
orientation before resize changed pixels. Output finalization remains the
evaluation/error backstop; the metadata audit did not demonstrate savings from
changing it. Result caps still do not bound all intermediate working memory.

Validation includes 34 matrix requests and 14 audit requests, with exact baseline
pixel-hash and dimension matches for the 46 original cases plus the separately
measured unprofiled-linear case. Thirteen physically oriented twin comparisons
document why operation reordering was rejected. Streamed JPEG tests retain a
known-random-operation self-check; property tests cover EXIF/user rotation/flip
combinations and linear color conditioning. Request-boundary tests cover lazy
horizontal flips, repeated groups, ICC behavior, and corrupt JPEG tails returning
415 before successful delivery. Logger and trace tests cover materialization
dimensions and skipped copies.

`mise run precommit` passed: formatting, compilation with warnings as errors,
strict Credo, Dialyzer, duplication checks, and 2533 passing tests/properties
(68 properties, 2465 tests; 4 integration tests excluded).

## Follow-up experiments after fd8

The completed implementation still has two measurable opportunities. These are
isolated prototypes loaded with `mix run --no-compile -r`; they are not production
changes. Measurements use the same worker, fixtures, two libvips threads, disabled
operation caching, and request-only tracked high-water as above.

### Buffer the smaller input before enlargement (`image_plug-lwl`)

The prototype adds a materialization immediately before the compensated resize
when pending orientation will need random access, no RAM backing exists, and
the resize increases pixel area. Resize, cover crop, rotation, and final clamp
still execute in their original order. Unlike physically orienting before resize,
this changes the evaluation boundary without moving pixel operations.

| Case | Current peak MiB | Prototype peak MiB |
|---|---:|---:|
| Fit, EXIF 3, width 6000, cap 2048 | 97.9 | 34.9 |
| Fit, EXIF 6, width 6000, cap 2048 | 190.0 | 37.9 |
| Cover, EXIF 6, width 6000, cap 2048 | 58.6 | 31.6 |
| Canvas, EXIF 6, width 6000, cap 2048 | 186.7 | 122.1 |
| Padding, EXIF 6, width 6000, cap 2048 | 333.0 | 180.9 |
| Groups, EXIF 6, width 6000, cap 2048 | 194.3 | 42.2 |
| Fit, EXIF 6, width 12000, default caps | 846.9 | 229.6 |

All seven outputs retain exact decoded pixel hashes and dimensions. The prototype
is intentionally insufficient as a production selection rule: cover can crop to
a frame smaller than the input even when its intermediate resize enlarges. Compare
against the buffer actually required after cropping, preserve already-backed and
sequential-safe paths, and test downsizing, streamed JPEGs, shrink-on-load, user
orientation, multiple groups, and decode errors. CPU/throughput effects remain
unmeasured; fewer allocated bytes can mean more repeated lazy pixel work.

### Clean retained orientation metadata after the clamp (`image_plug-0s9`)

`orient=none/meta=keep/w=6000/enlarge/format=png` on the EXIF 6 fixture currently
materializes 6000×4000 to remove the orientation tag before final clamping to
2048×1365. Moving that cleanup from the executor to the encoder, after its existing
checked `copy_memory`, reduced peak memory from **92.9 to 30.2 MiB**, matching the
`meta=strip` control. The complete encoded PNG, including metadata, was
byte-identical between baseline and prototype.

Production work needs metadata/ICC/copyright coverage across output formats and
host defaults, corrupt-tail 415 coverage before delivery, and telemetry checks.
Keep the checked decode evaluation before Vix mutation: its linked mutable-image
process still evaluates lazy input when started.

Other inspected copies have a purpose: encoder finalization catches deferred
decode errors; the classifier buffers a reduced grayscale frame for repeated
reads; LQIP buffers only 3×3 pixels; info output reads headers without executing
transforms. Profiled linear input still incurs metadata-triggered evaluation,
but safely deferring that removal needs explicit color-policy handling. No
additional measured optimization is claimed for those paths.
