# Image materialization investigation

Implementation and measurements for `image_plug-fd8`, 2026-09-22–23. Orientation
flushes prepare random access when needed and buffer their display frame for
downstream consumers. Input color management skips metadata mutation when the
ICC field to remove is absent. Operation order and output pixels are preserved.

**Speed decision:** repeated request timings rejected the lazy orientation
changes despite their memory savings. Orientation buffering is restored and the
absent-ICC guard is retained. The memory tables below describe the earlier
implementation in `ed4e70d7`; the [latency audit](#latency-audit-of-retained-fd8-changes)
and restoration results explain the final decision.

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

These original memory runs are single-request measurements, not throughput
measurements or a representative workload distribution. Libvips tracked memory excludes some
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

## Initial implementation decision

The initial implementation contained the orientation and absent-profile optimizations.
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

Two further candidates reduced memory, but both failed the speed acceptance gate
below and were rejected. They were evaluated with isolated overrides loaded by
`mix run --no-compile -r` and temporary implementations. Measurements use the
same worker, fixtures, two libvips threads, disabled operation caching, and
request-only tracked high-water as above.

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

All seven outputs retain exact decoded pixel hashes and dimensions. A subsequent
implementation compared the input against the buffer actually required after
cover cropping and left already-backed and sequential-safe paths alone. Narrow
crops can make buffering the input more expensive than buffering the cropped
result. A second restriction required at least halving the backing buffer, to
avoid slowing modest enlargements for negligible memory savings. Streamed JPEG,
EXIF/rotation/flip property, request, and telemetry tests passed; timing still
showed material regressions, so neither selection rule is retained.

### Clean retained orientation metadata after the clamp (`image_plug-0s9`)

`orient=none/meta=keep/w=6000/enlarge/format=png` on the EXIF 6 fixture currently
materializes 6000×4000 to remove the orientation tag before final clamping to
2048×1365. Moving that cleanup from the executor to the encoder, after its existing
checked `copy_memory`, reduced peak memory from **92.9 to 30.2 MiB**, matching the
`meta=strip` control. The complete encoded PNG, including metadata, was
byte-identical between baseline and prototype.

The temporary implementation passed focused request/trace checks, including
format-specific metadata and retained ICC in JPEG, PNG, and WebP, explicit and host-default metadata
retention, and corrupt-tail 415 behavior. It retained checked decode evaluation
before Vix mutation. Its timing regression also ruled it out.

### Speed acceptance gate

The user explicitly prioritizes speed over lower memory. The following medians
measure complete Plug request latency, excluding VM startup, fixture generation,
and verification. Each measurement ran in a fresh VM, alternating baseline and
candidate order. Early-buffer comparisons used three trials per version; metadata
comparisons used five. These are serial local timings, not concurrent throughput
or isolated CPU-time measurements.

| Candidate and case | Baseline ms | Candidate ms | Baseline → candidate peak MiB |
|---|---:|---:|---:|
| Early backing, EXIF 6 fit width 6000 | 1093.4 | 1610.9 | 190.0 → 37.9 |
| Early backing, EXIF 6 canvas width 6000 | 1384.0 | 1906.2 | 186.7 → 122.1 |
| Early backing, full JPEG rotation width 4500 | 884.4 | 1484.5 | 111.5 → 60.3 |
| Late metadata cleanup, EXIF 6 width 6000 | 531.5 | 1114.5 | 92.9 → 30.2 |
| Late metadata cleanup, EXIF 6 width 128 | 42.3 | 48.0 | 2.1 → 2.1 |

The metadata-strip control stayed at 1117.4→1117.2 ms. The bounded early-buffer
rule kept modest JPEG enlargement at 486.0→487.7 ms and 50.1 MiB, but did not
avoid the slowdown in larger requests where it activated. Small timing changes
can be noise; the large-case regressions are sufficient to reject both changes.
The likely mechanism is repeated work when downstream consumers read a lazy
resize graph, instead of reading its already-evaluated result.

A resize-only check isolates pixel evaluation from decode, metadata mutation,
and encoding. Starting from the same RAM-backed 600×400 input, it enlarges to
6000×4000 and shrinks to 2048×1365. Across three fresh-VM trials, buffering the
enlarged result took a median 263.1 ms, then evaluating the final shrink took
23.8 ms (286.9 ms total). Evaluating the two resizes as a lazy chain took 383.4 ms,
with identical final pixels. This confirms an evaluation cost even without
metadata or encoding; the exact internal recomputation/cache costs have not been
profiled. Records: `/tmp/fd8-lwl-implemented/resize-only-timing.json`.

The production implementation preceding these two experiments is retained.
Issues `image_plug-lwl` and `image_plug-0s9` are closed as rejected approaches,
rather than completed optimizations. Reconsider only an approach that preserves
speed and demonstrates that with request latency as well as memory measurements.

Reproduce the workload coverage (13 requests) with:

```sh
mise exec -- mix run bench/pre_clamp_materialization.exs followup /tmp/fd8-followup
```

The same worker command accepts individual cases for alternating-version timing
runs. Local comparison records are in
`/tmp/fd8-lwl-implemented/timing-comparison.json`, `jpeg-bounded.json`, and
`metadata-timing.json`.

Other inspected copies have a purpose: encoder finalization catches deferred
decode errors; the classifier buffers a reduced grayscale frame for repeated
reads; LQIP buffers only 3×3 pixels; info output reads headers without executing
transforms. Profiled linear input still incurs metadata-triggered evaluation,
but safely deferring that removal needs explicit color-policy handling. No
additional measured optimization is claimed for those paths.

## Latency audit of retained fd8 changes

The original fd8 acceptance measured memory and correctness, but did not run a
repeated before/after speed comparison. This audit adds that missing gate for
the retained changes, independently of the two rejected follow-up experiments.

```sh
mise exec -- python3 bench/materialization_latency.py /tmp/fd8-speed --preload
```

The audit runner at commit `4c74f7b0` compared the then-current implementation with the runtime behavior before
commits `ed4e70d7` (orientation) and `8b50724c` (absent ICC), and with one isolated
reversal per workload. Source overrides are generated in the output directory
and loaded into each worker VM; source files and compiled application beams are
unchanged. The historical orientation baseline restores the original flush
wrapper and telemetry boundary as well as both copies. Isolated variants keep
the current wrapper/telemetry behavior:

- `eager_final` restores only the post-orientation copy, including horizontal
  flips, and marks that result materialized.
- `no_reuse` removes only the guard that skips preparation for already-backed
  images. It still skips preparation for row-preserving orientation.
- `icc_mutation` restores only unconditional ICC-field mutation.

Each case runs five trials of all three versions, reversing their order on
alternate trials, in fresh VMs. All loaded applications' modules are preloaded
before timing to avoid bias from compiling the historical overrides. The plain
request and profiled linear input provide unchanged-path controls. Timings cover
the complete Plug request, including encoding; VM startup, module preloading,
fixture generation, output writing, and output verification are excluded.
Libvips uses two threads and disabled operation caching. Peak tracked memory is
captured before output verification, and is not process RSS.

An initial pass without module preloading also ran 150 requests. Its large-case
regressions agree with the preloaded pass, but several small-case differences
disappear after preloading. Use the preloaded measurements for comparisons;
cold module-loading differences are not evidence of pixel-processing regressions.
These are serial local request timings with warm filesystem caches, not a
concurrent throughput benchmark or an estimate of production workload frequency.

The [committed samples](materialization_latency_samples.json) retain individual
timing and memory samples, dimensions, pixel hashes, platform, libvips version,
and hashes of the measured source files. The runner produces this evidence as
`latency-samples.json`, alongside full records and a summary. Full local
request/telemetry records are in
`/tmp/fd8-speed/latency-results.json` and
`/tmp/fd8-speed-preloaded/latency-results.json`.

### Results

Medians from the preloaded pass; positive latency change means slower. All 300
comparison requests across both passes have identical decoded pixel hashes and
dimensions within each workload.

| Workload | Before fd8 ms | Current ms | Latency change | Before → current peak MiB |
|---|---:|---:|---:|---:|
| Plain TIFF, width 3000, cap 1024 | 299.7 | 298.3 | −0.5% | 13.7 → 13.7 |
| EXIF 6, width 6000, cap 2048 | 940.0 | 1057.3 | +12.5% | 309.3 → 190.0 |
| EXIF 6, width 128 | 8.5 | 8.5 | +0.7% | 2.8 → 2.8 |
| Full JPEG, rotate 90, width 2800, cap 2048 | 448.9 | 462.0 | +2.9% | 67.6 → 50.1 |
| Horizontal flip, TIFF width 3000, cap 1024 | 158.7 | 315.8 | +99.0% | 27.3 → 16.2 |
| Horizontal flip, JPEG width 128 | 51.3 | 50.8 | −0.9% | 2.7 → 2.7 |
| Two rotation groups, widths 3000/1500, cap 1024 | 269.2 | 297.2 | +10.4% | 77.5 → 61.7 |
| EXIF 6, resize groups 6000/1500, cap 2048 | 954.7 | 1070.8 | +12.2% | 309.3 → 194.3 |
| Unprofiled linear TIFF, width/cap 128 | 13.0 | 9.9 | −23.5% | 15.0 → 8.7 |
| Profiled linear TIFF control, width/cap 128 | 12.4 | 12.1 | −3.0% | 15.0 → 15.0 |

The five-trial timing ranges do not overlap between historical and current
versions for the large EXIF, JPEG rotation, large horizontal flip, and grouped
workloads. Small-request and unchanged-path control ranges overlap; do not infer
speed changes from their small median differences.

The individual reversals identify the costs:

- Restoring only the final orientation copy brings large EXIF to **937.1 ms**,
  JPEG rotation to **447.3 ms**, and the large horizontal flip to **157.6 ms**.
  All are near their historical baselines. Small EXIF and small horizontal
  requests are effectively unchanged.
- Restoring preparation of already-backed images brings two rotation groups
  from **297.2 to 285.6 ms**, with peak memory **61.7 to 54.0 MiB**. That isolates
  a roughly 4% latency penalty from skipping this copy on the current graph.
  Restoring this preparation does not affect the resize-only second-group
  control: **1070.8 versus 1068.7 ms**. The complete historical orientation
  behavior is faster still for the two-rotation case, at **269.2 ms**.
- Restoring unconditional ICC mutation raises the unprofiled linear request
  from **9.9 to 11.9 ms** and **8.7 to 15.0 MiB**. Four of five paired trials
  favor the guard; the remaining trial is effectively tied. This is a modest
  absolute speed benefit on one fixture, with overlapping ranges, rather than
  a general 23.5% claim. The profiled-input control remains effectively unchanged.

### Speed-first decision

The orientation changes in `ed4e70d7` fail the user's speed-first criterion.
Recommend restoring the prior orientation buffering behavior and retaining the
absent-ICC guard from `8b50724c`. Removing copies reduces peak memory, but the
remaining lazy graph can cost more to evaluate downstream; the isolated final
copy reversal demonstrates that tradeoff without changing operation order or
pixels. Internal libvips recomputation/cache costs have not been profiled.

This audit reopened `image_plug-fd8` to restore request speed. The benchmark task
`image_plug-pt9` recorded the evidence before production changes were made.

## Orientation buffering restored

The final implementation prepares random access for every orientation that
reorders rows, even when an earlier group has RAM backing, then buffers each
oriented result. Horizontal flips also buffer their result. Each orientation
materialization span measures the complete flush and reports display-frame
dimensions. Pixel, streamed-source, corrupt-tail, Logger, and trace coverage is
retained.

The runner now compares `baseline` (restored orientation plus unconditional ICC
mutation), `current` (restored orientation plus the ICC guard), and `lazy`
(rejected lazy orientation plus the ICC guard). Overrides run only inside the
benchmark VMs. The original audit samples remain in
`materialization_latency_samples.json`; restoration samples are separate.

```sh
mise exec -- python3 -B bench/materialization_latency.py /tmp/fd8-restored --preload \
  --case plain --case exif_large --case rotate_jpeg --case horizontal_large \
  --case rotation_groups --case icc_absent
```

Five alternating trials per version, six workloads, **90 requests**. All outputs
match each other and the original audit's decoded pixel hashes and dimensions.
Application modules were preloaded; timing ran after the test suite completed,
with the same two libvips threads and disabled operation caching.

| Workload | Baseline ms | Rejected lazy ms | Restored ms | Lazy → restored peak MiB |
|---|---:|---:|---:|---:|
| Plain TIFF control | 297.8 | 295.0 | 293.4 | 13.7 → 13.7 |
| Large EXIF 6 | 917.7 | 1054.9 | 926.1 | 190.0 → 342.8 |
| JPEG rotation | 445.7 | 453.6 | 441.4 | 50.1 → 67.6 |
| Large horizontal flip | 156.2 | 314.0 | 156.3 | 16.2 → 27.3 |
| Two rotation groups | 273.7 | 304.7 | 275.5 | 61.7 → 77.5 |
| Unprofiled linear TIFF | 11.8 | 10.6 | 10.5 | 8.7 → 8.7 |

The restored orientation workloads are within roughly 1% of the contemporaneous
baseline or faster, with overlapping timing ranges, and recover the clear
regressions versus lazy orientation. The larger buffers are intentional under
the speed-first requirement. Baseline and restored orientation peaks match in
this run; high-water values can vary between runs with allocation lifetimes.
The retained ICC guard reduces its fixture from **11.8 to 10.5 ms** and
**15.0 to 8.7 MiB** compared with unconditional mutation.

Individual samples and source hashes are committed in
[materialization_restoration_samples.json](materialization_restoration_samples.json).
Full request/telemetry output is in `/tmp/fd8-restored/latency-results.json`.

Validation: the updated buffering and telemetry assertions failed before the
restoration; 139 focused tests/properties passed afterward. `mise run precommit`
passed formatting, warnings-as-errors compilation, strict Credo, Dialyzer,
duplication checks, and **2533 tests/properties**, with four integration tests
excluded. `image_plug-fd8` is complete with orientation buffering restored and
the measured absent-ICC optimization retained.
