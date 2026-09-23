# Source/decode overlap investigation

Beads issue: `image_plug-yx6`. Cold remote-cache acquisitions can overlap staging
and decoding for JPEG (including progressive JPEG) and PNG. Automatic selection
uses observed transfer timing; other requests retain complete-file spooling.

## Experiment

`bench/source_overlap.exs` compares three strategies over an existing JPEG:

- `spool`: consume the source into a staged file, then decode sequentially.
- `overlap`: tee each source chunk to that file and libvips concurrently.
- `auto`: stage a bounded prefix, choose a strategy from its arrival timing,
  and replay the prefix to libvips if overlap is selected.

All strategies hash the complete source while staging it, apply the same JPEG
shrink-on-load option, resize by 0.5, and evaluate the complete output pixel
buffer. The runner checks identical pixel and source digests across strategies
and repetitions. Each sample also checks that the staged file matches the
source digest and byte count. Publication to either cache is outside this
experiment.

The source is a local file paced against an absolute byte/time schedule in
64 KiB chunks. Rate zero means unthrottled. This models source availability,
not HTTP connection setup, socket buffering, redirects, or Req backpressure.
The shrink factor is supplied in advance. The production path independently
inspects a bounded prefix and uses the request's normal shrink planner.

Each measurement runs in a fresh VM with modules preloaded and the libvips
operation cache disabled. Strategy order reverses between repetitions. Timing
ends only after both pixel evaluation and source completion. RSS is sampled
every 10 ms through that point; post-run staging verification is excluded.
RSS includes VM overhead and is approximate, especially for small images.
The libvips allocation high-water mark is reported separately.

The `probe` command withholds the source after its first 256 KiB until the
consumer reports that the JPEG header has opened. Pixel evaluation then
finishes after an explicit release message. This proves header decode starts
before the source completes without relying on a sleep. It does not establish
when the first pixels are computed.

## Measurements, 2026-09-23

Environment: macOS 27 arm64, Elixir 1.20.4 / OTP 29, Image 0.72.0,
Vix 0.41.0, and libvips 8.18.6.

The large-input matrix uses progressive `waterfall.jpg` (10,671,398 bytes), three repetitions
per strategy/case, and JPEG shrink factors 1 and 8. The table shows median
elapsed milliseconds; the complete samples and memory figures are in
[`bench/source_overlap_samples.json`](../bench/source_overlap_samples.json).

| Source schedule | JPEG shrink | Spool | Always overlap | Automatic |
| --- | ---: | ---: | ---: | ---: |
| Unthrottled | 1 | 473.5 | 485.6 | 470.1 |
| Unthrottled | 8 | 362.1 | 378.6 | 363.7 |
| 20 MiB/s | 1 | 999.4 | 631.1 | 630.1 |
| 20 MiB/s | 8 | 893.6 | 522.2 | 522.2 |
| 80 MiB/s | 1 | 592.6 | 478.9 | 490.7 |
| 80 MiB/s | 8 | 493.0 | 378.7 | 379.8 |
| 320 MiB/s | 1 | 486.7 | 484.8 | 485.6 |
| 320 MiB/s | 8 | 380.1 | 377.0 | 379.6 |

Automatic selection reduced elapsed time by about 37–42% at 20 MiB/s
and 17–23% at 80 MiB/s. It chose spooling for every unthrottled and 320 MiB/s
sample, where the benefit was absent or small. At 80 MiB/s and shrink 1,
one observation lasted 1.907 ms and fell just below the 2 ms threshold. That
sample chose spooling and took 601.5 ms; the other two chose overlap and took
483.0 and 490.7 ms. This is a concrete threshold-sensitivity problem, even
though it loses a potential benefit rather than selecting the slower strategy.

The dominant libvips high-water allocations were similar between strategies:
about 58.3 MiB at shrink 1 and 6.3 MiB at shrink 8. VM-inclusive RSS varied
substantially, so these samples do not establish a memory improvement. Three
repetitions also do not support claims about sub-percent latency differences.

The small-input matrix uses `woman.jpg` (83,904 bytes), rates zero and 20 MiB/s,
and the same shrink factors and repetition count. All automatic samples chose
spooling after reaching EOF within the prefix budget. Unthrottled medians were
6.64 ms spool versus 6.75 ms automatic at shrink 1, and 3.78 versus 3.83 ms at
shrink 8. Complete samples are in
[`bench/source_overlap_small_samples.json`](../bench/source_overlap_small_samples.json).
The successful final matrices contain 108 samples with matching source and
pixel digests across strategies for each case.

An earlier exploratory high-throughput invocation exited nonzero; its stderr
was not retained by the initial runner, and a direct rerun passed. The complete
large-input matrix above subsequently passed. The runner now surfaces stderr
and stdout on failure. No upstream defect is inferred from that invocation.

## Automatic selection candidate

The experimental selector stages up to 256 KiB and retains those bytes for
replay. It observes the interval between the first and last sampled chunks,
excluding first-byte latency. It selects overlap only when:

- the source has not completed;
- the observation spans at least 2 ms; and
- the estimated remaining transfer time is at least 30 ms.

The estimate uses the known total file length. A production equivalent could
use a validated Content-Length as a performance hint, without trusting it for
body-size enforcement. Unknown lengths need a separate policy; a conservative
initial fallback is complete-file spooling. These thresholds are experimental,
not established defaults.

Suspending the source enumerable preserves its position and hash state. On
overlap, the decoder receives the retained prefix followed by the continuation;
the prefix is not downloaded, hashed, or staged a second time. On spooling,
only the continuation is drained before opening the completed file. The
prototype uses process-backed file handles so the continuation can move to
Vix's reader process.

Prefix throughput is a prediction, not a guarantee. An origin may send its
prefix slowly and then burst the remainder, or send the prefix quickly and
stall. Connection latency must not be included in the estimate. CPU pressure,
format, progressive encoding, shrink factor, and input size also affect the
crossover. A single bandwidth threshold cannot establish a universal win.

## Production path

For image requests acquiring a remote source without an existing record,
`Execution.SourceCache` stages and hashes the source in its fetching process.
The selector requires a known Content-Length above 1 MiB, within the body
limit. It observes at least 256 KiB and 5 ms of transfer, extending observation
up to 1 MiB. An estimated remaining transfer of at least 30 ms makes JPEG/PNG
eligible if libvips can open the bounded header prefix. Unknown lengths,
other formats, small/fast sources, and revalidation retain spooling.

`Source.Download` tracks committed file offsets. The native feeder replays the
growing file in reads of at most 64 KiB; the coordinator stores positions,
not a queue of encoded chunks. Slow decoding therefore does not block source
staging or add an unbounded in-memory tee. The existing Req transport still
uses asynchronous incoming messages; this change does not establish a new
bound for the transport mailbox itself.

The decoder inspects the prefix and reopens the same acquisition sequentially
with normal shrink planning. Existing transforms and materialization run under
processing admission. The resulting processing result is used only after the
full body is staged and hashed and the normal representation, conditional,
and output-cache gates run. Speculative errors are deferred to generation;
admission rejection falls back to ordinary processing. Source failures prevent
publication. An early-finished decoder does not stop source hashing/staging.

Acquisition returns one concrete result carrying the source record, response,
lease, byte count, and optional processing result. Decode receives either a
resolved source, an acquired response, or the growing-file input explicitly.

The download coordinator monitors the request, processing worker, and feeder.
Worker completion stops any remaining feeder; request cancellation stops both.
It owns worker/feeder shutdown; overlap orchestration closes the coordinator
and discards its task monitor. The source lease owns temporary-file cleanup.
Source enumeration classifies adapter failures while preserving exceptions
from the staging consumer. Cache publication failures keep
the response usable, and staging write failures cancel speculation and retain
the existing in-memory fallback.

Wire tests hold an actual HTTP origin's tail until header opening is observed.
They cover JPEG/PNG pixel equivalence, resize followed by arbitrary rotation,
early crop completion, complete original-byte publication, truncation,
cancellation, cache failures, pixel limits, warm output hits, and conditional
304 responses. Full-resolution arbitrary rotation before resizing exposed an
independent slow buffered case, tracked in `image_plug-dcw`.

## HTTP request measurements

`bench/source_overlap_request.exs` measures a cold real HTTP request including
source hashing/staging, transform, PNG encoding, and both filesystem caches.
It resizes the large progressive JPEG to width 366. The spool baseline omits
Content-Length to force the ordinary path. Each sample uses a fresh preloaded
VM with native operation caching disabled. Three trials alternate mode order;
all 24 output pixel digests match. The local origin's in-memory body is included
in process RSS. Raw results: [request samples](../bench/source_overlap_request_samples.json).

| Source schedule | Spool ms | Automatic ms | Selection |
| --- | ---: | ---: | --- |
| Unthrottled | 404.3 | 403.4 | Spool |
| 20 MiB/s | 918.7 | 565.9 | Overlap |
| 80 MiB/s | 525.8 | 417.7 | Overlap |
| 320 MiB/s | 420.0 | 423.1 | Spool |

The paced cases improve 38.4% and 20.6%. Native peak allocation is 7,542,695
bytes in every sample. Median RSS varies between 426 and 444 MB across cases,
with differences in both directions; this does not establish a memory win.
The 320 MiB/s median regression is 0.7%, with only three trials.

## Other formats

The format probe uses `waterfall.jpg` resized by 0.25, then encoded with default
PNG or WebP settings. Each mode runs three times at zero and 20 MiB/s, with
matching source and pixel digests. PNG's 20 MiB/s median improves from 398.9
to 361.2 ms (9.4%), with identical native peak allocation. WebP changes from
74.25 to 74.07 ms, while native peak allocation increases from 50.9 to 63.8 MB.
These cases support including PNG and retaining WebP's buffered path. They do
not prove that every image of either format has the same performance.
AVIF/HEIF and TIFF remain on the buffered path pending broader measurements.

Raw results: [PNG](../bench/source_overlap_png_samples.json),
[WebP](../bench/source_overlap_webp_samples.json).

## Reproduction

```sh
mise exec -- mix run --no-compile --preload-modules bench/source_overlap.exs probe priv/static/images/waterfall.jpg
mise exec -- python3 bench/source_overlap.py bench/source_overlap_samples.json --trials 3 --auto --rate 0 --rate 20 --rate 80 --rate 320
mise exec -- python3 bench/source_overlap.py bench/source_overlap_small_samples.json --trials 3 --auto --source priv/static/images/woman.jpg
```

`--source` selects another image (`--shrink 1` for non-JPEG), `--shrink` narrows the shrink factors, and
repeated `--rate` options choose the source-availability sweep. The benchmark
expects already-built dependencies and library modules.

Run a production-path sample with:

```sh
mise exec -- mix run --no-compile --preload-modules bench/source_overlap_request.exs auto priv/static/images/waterfall.jpg 20
mise exec -- mix run --no-compile --preload-modules bench/source_overlap_request.exs spool priv/static/images/waterfall.jpg 20
```
