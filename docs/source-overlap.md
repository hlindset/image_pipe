# Source/decode overlap investigation

Beads issue: `image_plug-yx6`. This is a feasibility experiment; the request path
still spools sources before decoding them.

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
The shrink factor is supplied in advance; header inspection and reopening for
request-dependent shrink planning remain production integration work.

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

The large-input matrix uses `waterfall.jpg` (10,671,398 bytes), three repetitions
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

The next policy experiment should collect more observations when the first
window is too short, with a fixed upper bound on retained prefix bytes, rather
than immediately making the 2 ms cutoff decision. It should include bursty
origins, unknown lengths, and CPU contention over real HTTP. The evidence
supports continuing with automatic selection, but does not justify enabling
these particular thresholds in the library.

## Production design constraints

`Execution.prepare/5` currently acquires untrusted remote bytes before choosing
the final representation. `Source.Record.new/4` uses a full-body SHA-256 when
the source has no trusted byte identity. An overlapping decoder must preserve
that identity, the conditional gate, and cache publication ordering. A new
request option or placeholder digest cannot stand in for completed identity.

The natural integration is request-owned speculative processing while the
complete encoded source is staged. It needs processing admission before any
speculative pixel work; today source-cache acquisition precedes processing
admission. Successful processing and final source validation must rendezvous
before response delivery or publication. An output-cache hit discovered after
identity resolution must release any speculative image resources.

Source transport and staging remain under the source/cache owners. Decode
owns format selection, header inspection, shrink planning, and replay. The
executor continues to own image operations and their materialization rules.
Formats requiring seeking retain a completed-file fallback. Header preflight
and the planned sequential reopen must use the same acquisition, including
bytes already consumed by the first reader.

The Vix `new_from_enum/2` implementation in the checked-in dependency starts a
linked reader and returns the image without an explicit reader cancellation
handle. It is sufficient for these successful finite experiments, but using
it directly does not establish the request cancellation/error contract. The
production bridge needs explicit ownership and cleanup for source failure,
decode early exit, client cancellation, and native reads waiting for bytes.

The current Req transport uses `into: :self`. Blocking a tee writer alone does
not prove bounded network buffering: incoming messages can still accumulate.
Bounded producer/consumer behavior must be demonstrated at the actual HTTP/S3
transport boundary, including slow decoding and failed cache writes.

The issue remains open until real request tests establish lifecycle cleanup,
limits, format fallback, unchanged warm-cache behavior, and latency benefits
under realistic HTTP delivery. This microbenchmark does not satisfy those
acceptance criteria.

## Reproduction

```sh
mise exec -- mix run --no-compile --preload-modules bench/source_overlap.exs probe priv/static/images/waterfall.jpg
mise exec -- python3 bench/source_overlap.py bench/source_overlap_samples.json --trials 3 --auto --rate 0 --rate 20 --rate 80 --rate 320
mise exec -- python3 bench/source_overlap.py bench/source_overlap_small_samples.json --trials 3 --auto --source priv/static/images/woman.jpg
```

`--source` selects another JPEG, `--shrink` narrows the shrink factors, and
repeated `--rate` options choose the source-availability sweep. The benchmark
expects already-built dependencies and library modules.
