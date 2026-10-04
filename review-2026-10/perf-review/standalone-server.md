# Performance review: image_pipe_server

Scope: `image_pipe_server/` (Docker image, release, Bandit listener, pool and
libvips/BEAM runtime settings). Repo at `84eeac2`.

## How this was measured

No Docker daemon or Elixir toolchain in the review container, so the image
itself was not built. Instead libvips 8.18.7 (the Dockerfile's pinned,
checksum-verified tarball) was built twice on Ubuntu 24.04 / 4 vCPU / 15 GB with
the Dockerfile's exact meson flags:

- **A**: as shipped (orc SIMD, no highway, because `libhwy-dev` isn't installed)
- **B**: same flags plus `libhwy-dev` (highway SIMD)

A small C load generator (`vips_image_new_from_buffer` → `thumbnail_image` →
optional `sharpen` → `copy_memory` → `write_to_buffer` as JPEG/WebP/PNG, random
widths 200–1600, 4 source files from 1.5 to 24 MP) ran N threads in one process,
which mirrors how the BEAM hosts libvips. Numbers are best-of-3 (single ops) or
one run (load tests). Scripts are in the session scratchpad and not committed.

## Candidates, ranked by expected impact

### 1. Use jemalloc for the release (large memory win)

`Dockerfile:112` (runtime `ENV`) / no allocator setting anywhere.

libvips mallocs a lot from many threads, and glibc's per-thread arenas hold the
freed memory. Same workload, one process:

| workload | allocator | img/s | peak RSS | RSS after load |
|---|---|---|---|---|
| 16 threads × 60 imgs | glibc | 17.1 | 2628 MB | 1942 MB |
| 16 threads × 60 imgs | jemalloc | 16.9 | 1287 MB | 327 MB |
| 4 threads × 60 imgs | glibc | 16.0 | 1509 MB | 1319 MB |
| 4 threads × 60 imgs | jemalloc | 15.0 | 442 MB | 261 MB |
| 4 threads × 60 imgs | glibc `MALLOC_ARENA_MAX=2` | 15.1 | 509 MB | 299 MB |

Peak RSS drops by half to two thirds, retained RSS by ~80%, at ±5% throughput
(within noise). The BEAM makes this worse than the C harness, because every
scheduler and dirty-scheduler thread can get its own glibc arena.

Change: install `libjemalloc2` in the runtime stage and set
`LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2` (arch-dependent path;
resolve it at build time). `MALLOC_ARENA_MAX=2` is the zero-dependency
alternative with most of the benefit. BEAM's own allocators are unaffected;
this only changes NIF/libvips `malloc`. imgproxy ships jemalloc for the same
reason (inferred from its public Dockerfile, not checked here).

### 2. Build libvips with highway SIMD (≈40–50% less CPU on resize/blur)

`Dockerfile:25-29` (build deps). Add `libhwy-dev`; the runtime package list is
derived from `ldd` (`Dockerfile:48-50`), so `libhwy1t64` follows automatically.

CPU time (user+sys), `VIPS_CONCURRENCY=1`, 6000×4000 RGB:

| op | A (orc) | B (highway) |
|---|---|---|
| `reduce` 2.7× | 0.222 s | 0.116 s |
| `resize` 0.37 | 0.212 s | 0.119 s |
| `gaussblur` σ5 | 0.360 s | 0.208 s |
| `resize` from PNG (decode-bound) | 0.466 s | 0.392 s |
| `sharpen` | 2.38 s | 2.52 s (no SIMD path, noise) |
| JPEG thumbnail via shrink-on-load | 0.146 s | 0.151 s |

Biggest win is for sources without shrink-on-load (PNG, WebP, AVIF, JXL) and
blur/pixelate. libvips treats highway as the preferred backend and orc as the
fallback. Debian trixie packages highway 1.2 (Ubuntu's 1.0.7 was used here).
Verify with `vips --vips-config | grep SIMD` in the build stage, like the existing
`jxlload` check.

### 3. Add dav1d for AVIF decoding (≈30% faster AVIF input)

`Dockerfile:96` installs only `libheif-plugin-aomdec`/`aomenc`. With
`libheif-plugin-dav1d` present, libheif prefers it for decoding automatically.

6000×4000 AVIF decode: aomdec 0.73 s wall / 0.74 s CPU, dav1d 0.51 s / 0.58 s.
The test image is synthetic noise; dav1d's lead is usually larger on photos.

Not recommended: `libheif-plugin-svtenc` for encoding. At libvips' default
effort it was 3× slower than aom here (2.3 s vs 0.78 s for 1620×1080).

### 4. Cap libvips threads to the container's CPU quota (high impact on k8s, reasoned)

Nothing sets `VIPS_CONCURRENCY`. libvips sizes each pipeline's thread pool from
`g_get_num_processors()`, which reads CPU affinity, not the cgroup `cpu.max`
quota. OTP does honor the quota for schedulers. So a pod limited to 2 CPUs on a
64-core node runs 64 libvips threads per in-flight image, which means heavy
throttling and per-thread buffer memory. Not measurable here (no quota in this
container); this is from how glib and libvips size thread pools.

Change: a `rel/env.sh.eex` that derives `VIPS_CONCURRENCY` from
`/sys/fs/cgroup/cpu.max` when it isn't set, and documentation of the variable in
`docs/server-deployment.md`.

Related measurement: with 16 concurrent images on 4 cores, `VIPS_CONCURRENCY=1`
gave 17.4 img/s vs 16.9 default and 15% lower peak RSS. When requests already
saturate the cores, extra libvips threads add memory but not throughput. They
still help single-request latency at low load, so 1 is not a universal default.

### 5. Ship a default processing pool (medium, a product decision)

`lib/image_pipe_server/application.ex:100` and `docs/server-deployment.md:184`:
without `[pool]` every request processes at once.

On 4 cores, 4 concurrent images gave the same throughput as 16 (15–16 vs
17 img/s) at about a third of the peak memory (jemalloc: 442 MB vs 1287 MB;
glibc: 1.5 GB vs 2.6 GB). An unbounded server turns a traffic burst into an
OOM kill instead of 503s. A default of `max_concurrency` = online schedulers and
a small queue would make the safe setting the default. This changes visible
behavior (503 under overload), so it needs your call.

### 6. GC Bandit connection processes after every request (small, reasoned)

`lib/image_pipe_server/application.ex:90`. Bandit's HTTP/1 handler keeps the
connection process across keep-alive requests and by default only forces GC
every 5 requests (`http_1_options: [gc_every_n_keepalive_requests: 5]`, from
Bandit's docs, not checked against 1.12.5 source). Image bodies are MB-sized refc
binaries, so an idle keep-alive connection can pin several responses' worth of
memory. Setting it to `1` frees them right after each response, at the cost of
one small GC per request. Worth measuring in the real server before adopting.

### 7. Turn off scheduler busy-waiting (small, reasoned)

No `rel/vm.args.eex`, so the BEAM uses `+sbwt medium` (and the dirty-scheduler
equivalents). Spinning schedulers take CPU from libvips threads, which do the
real work here. `+sbwt none +sbwtdcpu none +sbwtdio none` is the usual setting
for NIF-heavy or co-located workloads. This needs a load test on the real image
to confirm. A gain is plausible but not measured.

## Checked and fine

- Bandit: `compress: false` avoids gzip on already-compressed images and a
  `Vary: Accept-Encoding`. Acceptor and connection settings are sensible.
- libvips is built with `--buildtype=release` (`-O3`) and without modules, so
  there's no plugin scan at startup.
- Startup: config load is plain parsing/validation. No heavy work shows up in
  `Application.start/2`. Vision models are baked at build time, so there's no
  runtime download. Release boot time wasn't measured (no Docker/Elixir here).
- Health check (`curl` every 10 s) has negligible cost.
