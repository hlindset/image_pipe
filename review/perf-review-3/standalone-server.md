# Performance review 3: image_pipe_server

Scope: `image_pipe_server/` (Dockerfile, release env, Bandit listeners, pool
default, router and health plugs). Repo at `259fb05` (main, 2026-10-06).

Two open findings, both low severity. Five of the seven first-round findings
are fixed on main; the sixth (keep-alive GC) doesn't reproduce.

## How this was measured

The review container can't reach the Debian mirrors (403 from the proxy), so
the Docker image itself wasn't built. Instead:

- libvips 8.18.7 (the Dockerfile's pinned, checksum-verified tarball) was
  built on Ubuntu 24.04 with the Dockerfile's meson flags (highway on).
- The server was built as a real prod release (`MIX_ENV=prod mix release`,
  `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`) and started with
  `bin/image_pipe_server start`, so `rel/env.sh` ran as shipped: jemalloc was
  preloaded (checked in `/proc/<pid>/maps`). There's no cgroup CPU quota in
  this container, so `VIPS_CONCURRENCY` stayed unset.
- Machine: 4 vCPU, 15 GB. Config: one file source, no output cache, default
  `[pool]` (`max_concurrency` = 4 schedulers).
- Load: a Python keep-alive client sent random `w=200..1600` and
  `format=jpeg|webp|png` requests over 7 photos (0.85 to 6 MB JPEGs). CPU time
  is the BEAM process's user+sys from `/proc/<pid>/stat`, RSS from
  `/proc/<pid>/status` sampled every 50 ms. Scripts are in the session
  scratchpad and not committed.

## Findings

### 1. Turn off scheduler busy-waiting (repeat, still open)

**Severity:** low (about 4% CPU per image)

**Where:** `image_pipe_server/rel/` has only `env.sh.eex`; there's no
`vm.args.eex`, so the BEAM runs with the default `+sbwt medium` and the
dirty-scheduler equivalents.

**Evidence:** the same 120-request run at 2 concurrent requests, three runs
each:

| flags | CPU ms per image | img/s | p50 / p95 ms |
|---|---|---|---|
| default | 371, 366, 366 | 5.92, 6.00, 6.01 | 337–343 / 548–553 |
| `+sbwt none +sbwtdcpu none +sbwtdio none` | 350, 350, 358 | 6.01, 5.99, 5.89 | 336–344 / 556–595 |

At 1 concurrent request: 371 vs 358 ms. Throughput and latency don't change;
the saved CPU is scheduler spinning between requests. That matters most under
a CFS quota, where spinning counts against the limit and can throttle libvips
threads, and on shared nodes. The flags were confirmed on the `beam.smp`
command line.

**Suggested fix:** add `rel/vm.args.eex` with
`+sbwt none +sbwtdcpu none +sbwtdio none`. Re-measure on the real image under
a CPU limit before adopting it.

### 2. Run jemalloc's background purge thread

**Severity:** low (about 60 MB less resident memory after a burst)

**Where:** `image_pipe_server/rel/env.sh.eex:12-15` preloads jemalloc with no
`MALLOC_CONF`.

**Evidence:** 120 requests at 4 concurrent requests, then idle. RSS at boot
is 235 MB.

| `MALLOC_CONF` | peak | idle 5 s | idle 15 s | idle 30 s | idle 60 s |
|---|---|---|---|---|---|
| unset (run 1) | 977 MB | 675 | 675 | 604 | 604 |
| unset (run 2) | — | 681 | 681 | 598 | 598 |
| `background_thread:true` (run 1) | 972 MB | 571 | 546 | 540 | 540 |
| `background_thread:true` (run 2) | — | 580 | 555 | 543 | 543 |
| `background_thread:true,dirty_decay_ms:0,muzzy_decay_ms:0` | 767 MB | 546 | 546 | 545 | 545 |

Without the background thread, jemalloc purges only while something
allocates, so an idle server keeps freed pages. With it, RSS settles about
60 MB (10%) lower and within 15 seconds. Throughput was the same (10.1 vs
10.2 img/s). Zero decay gets no lower than the background thread at idle, so
the default decay times are fine.

**Suggested fix:** in the jemalloc branch of `env.sh.eex`, export
`MALLOC_CONF="${MALLOC_CONF:-background_thread:true}"`. Debian's
`libjemalloc2` (5.3) supports it on Linux.

**Not from the allocator:** after a burst the server stays about 300 MB above
its boot RSS even with zero decay, while `:erlang.memory()` reports 101 MB
total (binary 0 MB). That matches the first round's pure-C libvips harness
(261–327 MB retained with jemalloc), so it's most likely libvips worker
threads and their buffers. Inferred, not traced to a specific allocation; no
server-level setting addresses it.

## First-round findings rechecked

| # | First-round finding | Status on main |
|---|---|---|
| 1 | Use jemalloc | Fixed: `Dockerfile:119-125` installs and links it, `rel/env.sh.eex:12-22` preloads it, with `MALLOC_ARENA_MAX=2` as the glibc fallback |
| 2 | Build libvips with highway | Fixed: `libhwy-dev` and `-Dhighway=enabled` (`Dockerfile:35,44`) |
| 3 | dav1d for AVIF decoding | Fixed: `libheif-plugin-dav1d` (`Dockerfile:118`) |
| 4 | Cap libvips threads to the CPU quota | Fixed: `rel/env.sh.eex:27-41` derives `VIPS_CONCURRENCY` from cgroup v2 or v1 |
| 5 | Ship a default processing pool | Fixed: `lib/image_pipe_server/config.ex:434-435` defaults `max_concurrency` to online schedulers |
| 6 | GC Bandit connections after every request | Doesn't reproduce, see below |
| 7 | Turn off scheduler busy-waiting | Still open, finding 1 |

## Checked and fine

- **Keep-alive connections don't pin response bodies.** 40 keep-alive
  connections each fetched a ~4.3 MB PNG (172 MB in total) and then sat idle.
  `:erlang.memory(:binary)` was 8 MB, 1 MB after a forced GC of every process.
  Idle connections also close at `read_timeout` (10 s). Changing Bandit's
  `gc_every_n_keepalive_requests` (default 5, checked in Bandit 1.12.5's
  `http1/handler.ex:40`) wouldn't help.
- **libvips threads at saturation.** At 4 concurrent requests (pool full),
  `VIPS_CONCURRENCY` unset, 2, and 1 gave 10.51, 10.61, and 10.64 img/s,
  353/350/346 ms CPU per image, and peak RSS 1034/1075/1040 MB. With the pool
  bounding concurrency to the cores, extra libvips threads cost neither
  throughput nor memory, so the quota-derived default is fine.
- **PNG decoding.** libvips 8.18's `meson.build` uses libpng when present
  and only falls back to libspng, so adding `libspng-dev` wouldn't change the
  PNG loader.
- **Boot.** The release answers `/health/ready` 1.3 s after `start`. Idle RSS
  is 235 MB, of which the BEAM reports 108 MB (49 MB code, 29 MB in 496
  processes, mostly the 100 acceptors and their supervisors). Nothing stands
  out.
- **Per-request server code.** The router does a regex check on a trusted
  request ID, one SHA-256 and a constant-time compare with `auth_token`, an
  atomics read for draining, and `Plug.forward`. None of it shows up next to
  image work.
- **Health check.** The Dockerfile's `curl` every 2 s costs a process spawn
  per check, a fraction of a percent of one core.
- **Listener settings.** `compress: false`, 100 acceptors, and the separate
  health listener are sensible.
