# Performance review 4: image_pipe_server

Scope: `image_pipe_server/` (Dockerfile, `rel/env.sh.eex`, `rel/vm.args.eex`,
Bandit listeners, pool default, router, health and stats plugs), measured as a
running release. Repo at `8edf03b` (main, 2026-10-19).

Both pass-3 findings are fixed on main. Two new findings, one of which
confirms a request-path finding from this round at the server level. The
pending `da5b` measurement (pool × `VIPS_CONCURRENCY`) is answered in
finding 2.

## How this was measured

- **Release.** A real prod release (`MIX_ENV=prod mix release`,
  `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`) against libvips 8.18.7
  built from source (the session's CI build, not the Dockerfile's flags, so
  highway may differ). Started with `bin/image_pipe_server daemon`, so
  `rel/env.sh` and `rel/vm.args` ran as shipped. jemalloc was linked at
  `/usr/local/lib/libjemalloc.so.2` as in the image and preloaded with
  `MALLOC_CONF=background_thread:true` (checked in `/proc/<pid>/maps` and
  `environ`); `+sbwt none +sbwtdcpu none +sbwtdio none` was on the
  `beam.smp` command line. Flag variants were appended with `ERL_ZFLAGS`.
- **Machine.** 4 vCPU Intel Xeon 2.8 GHz Firecracker VM, 15 GB, OTP 29.1.1,
  Elixir 1.20.4. No cgroup quota by default; a cgroup v1 CPU quota was used
  for the quota runs.
- **Not gVisor.** Ubuntu's `runsc` package downloaded, but running it was
  refused in this session, so nothing here ran under gVisor. Where gVisor
  should change the answer, the finding says so.
- **Load.** Misses: a Python keep-alive client sent random `w=200..1600`,
  `format=jpeg|webp|png` requests over 9 photos (0.08–6 MB JPEGs) from a
  file source with no cache, same seed per comparison. CPU is the BEAM's
  user+sys from `/proc/<pid>/stat`, RSS sampled every 50 ms. Cache hits:
  `ab -k` against one output-cache hit (`w=300/format=webp`, 15 kB) from a
  file source. Logging off unless stated. Scripts are in the session
  scratchpad and not committed.
- Run-to-run noise is about 5–8% on misses (seed 2 of the mix is always
  slower than seed 1, so compare within a seed) and about 5% on hits.

## Findings

### 1. `+sbwtdio none` costs 17–30% of cache-hit throughput through the server

**Severity:** medium for hit-heavy (CDN-fronted) deployments. **Measured.**
Confirms and extends `perf-review-4/request-path.md` #2, which measured the
same effect in micro-benchmarks; this is the end-to-end number over HTTP.

**Where:** `image_pipe_server/rel/vm.args.eex:4-8` (added after pass 3's
finding 1, bead `e4a.9.7`).

**Evidence:** cache hits, `ab -k`, 8,000 requests per cell, two runs each
(rps / CPU ms per hit):

| flags | c=1 | c=4 | c=16 |
|---|---|---|---|
| all three `none` (shipped) | 808, 858 / 1.44 | 1728, 1726 / 1.42 | 3121, 3045 / 1.10 |
| `+sbwtdio very_short`, other two `none` | 948, 982 / 1.89 | 2255, 2202 / 1.49 | 3798, 3579 / 0.99 |
| `+sbwt very_short`, other two `none` | 832, 824 / 1.46 | 1853, 1820 / 1.38 | 3217, 3158 / 1.07 |
| all three `very_short` | 943, 1026 / 1.89 | 2260, 2324 / 1.46 | 3682, 3874 / 0.98 |
| all three `medium` (BEAM default) | 1062, 1141 / 1.92 | 2395, 2396 / 1.48 | 3834, 3585 / 0.99 |

- Only `+sbwtdio` matters for hits: the file calls of a hit run on dirty I/O
  schedulers, and each one wakes a sleeping thread. `strace -c` over 200
  hits: 12,701 `futex` calls with the shipped flags, 90 with `medium`.
- At c=16 (pool saturated with hits), busy-waiting uses **less** CPU per hit
  (0.95–1.0 vs 1.1 ms), because the wake-ups cost more than the spinning.
  At c=1 it uses more (1.9 vs 1.4 ms), the idle spin pass 3 measured.
- Misses don't care. Same mix, c=2, 120 requests, two runs (CPU ms per
  image / rps): `none` 312, 322 / 6.96, 6.72; `very_short` 323, 323 /
  6.90, 6.91; `medium` 333, 328 / 6.80, 6.94. That's pass 3's 2–4% at most,
  within noise here.
- The `Performance` workflow wouldn't have caught this: it runs every server
  without a cache (bead `uzzi`, still open).

**Under gVisor:** every `futex` wake is a trap into the Sentry, which costs
more than on Linux, so the hit penalty of `none` is likely larger there. The
spin's CPU also counts against the pod's quota. Neither was measurable here.

**Suggested fix:** set `+sbwtdio very_short` (or drop that line and take the
BEAM default) and keep `+sbwt none +sbwtdcpu none`, which hold the miss-path
saving pass 3 wanted. That row recovers the whole hit loss in the table.
Label it `perf`; the comparison won't show hits until `uzzi` lands, so put
this table in the PR description.

**Open question for Håvard:** your Bunny deployment is the best place to
check the gVisor side. With `+sbwtdio none` vs `very_short`, does a warm-hit
load (or the share of hits in real traffic) change p50 latency or CPU? If
hits are rare behind your CDN, the change is still free on misses.

### 2. A request uses one to one and a half cores, so the pool decides CPU use, not `VIPS_CONCURRENCY`

**Severity:** medium for your 8-CPU Bunny deployment's settings, low for the
defaults. **Measured** on Linux; answers bead `da5b` there.

**Where:** `rel/env.sh.eex:47-64` (`VIPS_CONCURRENCY` = CPU quota),
`lib/image_pipe_server/config.ex:480` (`max_concurrency` defaults to
`System.schedulers_online()`), and the pinned values in bead `6lz0.3.3`'s
notes (`max_concurrency = 2`, `VIPS_CONCURRENCY = 4` on 8 CPUs).

**Evidence:** cores busy during a single request (one client, 8 requests per
URL, `dog_2.jpg` 6 MB source; median ms / cores):

| request | `VIPS_CONCURRENCY=1` | `=2` | `=4` |
|---|---|---|---|
| `w=800` jpeg | 405 / 1.02 | 401 / 1.05 | 411 / 1.07 |
| `w=800` webp | 461 / 1.00 | — | 467 / 1.06 |
| `w=800` avif | 784 / 0.99 | 686 / 1.25 | 617 / 1.33 |
| `w=1600` `blur=10` | 634 / 1.02 | 528 / 1.29 | 492 / 1.43 |
| `w=1600` `sharpen=2` | 761 / 1.02 | 608 / 1.39 | 533 / 1.58 |
| `w=3000` jpeg | 714 / 1.05 | 612 / 1.31 | 558 / 1.44 |

A plain resize stays on about one core whatever `VIPS_CONCURRENCY` is
(decode and encode are serial). Blur, sharpen, large outputs and AVIF use up
to about 1.6 cores with 4 threads. Throughput therefore scales with the
number of requests in flight:

4 cores, no quota, 8 concurrent clients, 160 requests, two seeds (rps / CPU
ms per image / p95 ms / peak RSS):

| pool × `VIPS_CONCURRENCY` | seed 1 | seed 2 |
|---|---|---|
| 4 × 4 (default) | 11.70 / 312 / 1074 / 676 MB | 10.55 / 349 / 1162 / 708 MB |
| 4 × 2 | 11.97 / 308 / 1054 / 728 MB | 10.72 / 346 / 1117 / 733 MB |
| 4 × 1 | 11.78 / 312 / 1083 / 678 MB | 10.89 / 339 / 1138 / 713 MB |
| 2 × 2 | 6.75 / 321 / 1704 / 466 MB | 6.14 / 354 / 1748 / 476 MB |
| 8 × 4 | 12.00 / 322 / 1467 / 969 MB | 10.92 / 354 / 1407 / 921 MB |
| 8 × 1 | 12.30 / 312 / 1307 / 1030 MB | 11.24 / 344 / 1396 / 867 MB |

2-CPU quota (cgroup v1, 200 ms per 100 ms; OTP picked 2 schedulers, so the
default pool is 2), 4 clients, 100 requests, seed 1 twice:

| pool × `VIPS_CONCURRENCY` | rps | CPU ms per image | p95 ms | peak RSS |
|---|---|---|---|---|
| 2 × 2 (what the image would pick) | 6.19, 6.39 | 320, 310 | 1064, 1046 | 463 MB |
| 2 × 1 | 6.52, 6.52 | 303, 303 | 1023, 1081 | 445 MB |
| 2 × 4 | 6.22, 6.20 | 318, 319 | 1072, 1089 | 468 MB |
| 4 × 1 | 6.33, 6.65 | 312, 298 | 1299, 1230 | 579 MB |
| 4 × 2 | 6.37, 6.19 | 310, 320 | 1285, 1390 | 575 MB |

What this says, on Linux:

- **Halving the pool halves throughput** (2 × 2 on 4 cores: 6.8 vs 11.7
  rps). The libvips threads can't fill the idle cores, because most of a
  request is serial.
- **`VIPS_CONCURRENCY` barely moves saturated throughput** (within noise on
  4 cores; 1 is about 4% faster under the quota) and doesn't change memory.
  Its effect is on single-request latency at low load, for the heavy
  operations only: 2 threads get most of 4's gain.
- **The default pool is right.** A pool twice the cores (8 × 4, the
  "16 busy" case) gives the same throughput with a worse p95 (1.4 vs 1.1 s)
  and about 300 MB more peak RSS.

For your Bunny pod, `max_concurrency = 2` with `VIPS_CONCURRENCY = 4` on
8 CPUs means at most two requests run, each using one to 1.6 cores: about
2–3 of the 8 CPUs at saturation. The "8 busy threads" budget behind that
choice doesn't hold, because the 4 libvips threads per request are mostly
waiting on the serial decoder or encoder. Your observation that 16 busy
processes lost 22% against 8 fits the 8 × 4 row here (no gain, worse tail)
and may cost more under gVisor; it doesn't argue for a pool of 2.

**Suggested fix:**

- Deployment: on Bunny, try `max_concurrency = 8` (the default on that pod)
  with `VIPS_CONCURRENCY = 1` or `2`. That's 8–16 libvips threads, but at
  most about 8–12 cores' worth of runnable work, and it should roughly
  triple saturated throughput over 2 × 4 if gVisor behaves like Linux here.
- Default: consider `VIPS_CONCURRENCY = min(quota, 2)` in `env.sh.eex`
  instead of the full quota. On Linux it costs nothing at saturation and
  keeps most of the single-request gain for blur, sharpen and large outputs;
  on gVisor fewer threads means fewer futex and scheduling traps. A default
  change is a `perf` PR.
- Docs (`docs/server-deployment.md:370-377`): say that the pool sets how
  many cores the server uses, that a request uses about one core, and that
  `VIPS_CONCURRENCY` only speeds up single heavy requests.

**Open question for Håvard:** can you run the 8 × 1 (or 8 × 2) setting on
Bunny against your current 2 × 4 with the same load? That's the one number
this container can't produce, and it decides both the deployment change and
whether the `min(quota, 2)` default holds up under gVisor.

## Earlier findings rechecked

| Source | Finding | Status on main |
|---|---|---|
| perf-review-3 #1 | Turn off scheduler busy-waiting | Done: `rel/vm.args.eex` sets all three to `none` (now partly revisited by finding 1) |
| perf-review-3 #2 | jemalloc background purge thread | Fixed: `rel/env.sh.eex:38` exports `MALLOC_CONF=background_thread:true` |
| perf-review 1, #1–#5 | jemalloc, highway, dav1d, quota-derived `VIPS_CONCURRENCY`, default pool | Still in place (Dockerfile, `env.sh.eex`, `config.ex:480`) |
| memory-leak-hunt #1 | `/tmp` is memory on gVisor | Still open. `image_pipe/lib/image_pipe/cache/input.ex:171` stages originals under `System.tmp_dir!()`, and `docs/server-deployment.md:53-54` still says to mount `/tmp` as tmpfs with no gVisor note. The code side is bead `e4a.8.22` |
| memory-leak-hunt #2 | ONNX Runtime arena grows with concurrent detections | Bead `e4a.6.7` (limit concurrent detection) is closed |
| bead `da5b` | Does pool × `VIPS_CONCURRENCY` oversubscribe? | Answered on Linux by finding 2; gVisor still unmeasured |

## Checked and fine

- **One acceptor.** `num_acceptors: 1` (`application.ex:199`) accepted
  10,573 new connections per second (`ab -c 64`, no keep-alive, health
  endpoint), with `ab` itself a likely limit. Keep-alive: 45,900 rps. An
  image server never needs that accept rate.
- **CPU quota detection.** Under a 2-CPU cgroup quota, OTP 29 started 2
  schedulers and 2 dirty CPU schedulers (`:erlang.system_info(:cpu_quota)`
  = 2), so the pool default follows the quota.
- **Request log line.** With `log_requests = true` (the default) a cache hit
  costs 1.22 ms CPU and 2,648 rps at c=16, against 1.02 ms and 3,346 rps
  without it: about 0.2 ms per request for one line. That's the price of the
  line, not waste in the handler (`ImagePipe.Telemetry.Logger` attaches only
  the summary, background and failure events unless `log_stages` is on). For
  misses it's under 0.1%. A hit-heavy deployment that gets its numbers from
  the CDN can turn it off.
- **Interactive boot mode.** Ready 1.23 s after `daemon` with 155 MB RSS,
  against 1.74 s and 260 MB in embedded mode. The first cache hit after boot
  takes 37–46 ms (code loading) and every later one 2–3 ms; the warmup
  already covers the processing path. A one-time cost, not worth 100 MB.
- **OpenTelemetry SDK with tracing off.** The SDK and grpcbox still start
  (`traces_exporter: :none`), 12 small processes; no exports, no measurable
  cost.
- **Stats endpoints.** `/metrics` takes about 11 ms, because
  `:disksup.get_disk_info/1` runs `df` through disksup's shell port for each
  cache root, and calls are serialized in the disksup process (113 rps cap
  with 4 clients). At any scrape interval that's noise; on gVisor the `df`
  fork costs more, still once per scrape.
- **Health check.** `/health/ready` on the image listener is about 65 µs of
  server time per check; the Docker `HEALTHCHECK` curl every 2 s is a
  process spawn, as pass 3 noted.
- **Idle BEAM.** 54 MB `:erlang.memory(:total)`, 209 processes, 155 MB RSS
  after boot in interactive mode.
