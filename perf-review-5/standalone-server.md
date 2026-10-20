# Performance review 5: image_pipe_server

Scope: `image_pipe_server/` (release env and VM flags, Dockerfile, Bandit
listeners, router, health, stats, warmup, logging setup), measured as a
running prod release. Repo at `fe70ecc` (main, 2026-10-20).

Pass 4's finding 1 is fixed on main; finding 2 is still open as bead `da5b`
and waits on a Bunny measurement. Two new findings, both about the request
log the server turns on by default: above about 500 lines a second it drops
lines without saying so, and when whatever reads stdout falls behind, request
processes block on the log write and requests stall for up to 3 seconds.
Both come from Erlang's default overload settings for the `:default` handler,
which the server never changes.

## How this was measured

- **Release.** `MIX_ENV=prod mix release` with
  `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` against the session's
  libvips 8.18.7 build. Started with `bin/image_pipe_server start` in the
  foreground, stdout and stderr piped to a file or to a rate-limited reader,
  the way a container runtime reads them. `rel/env.sh` and `rel/vm.args` ran
  as shipped (`+sbwt none +sbwtdcpu none +sbwtdio very_short` on the
  `beam.smp` command line), and jemalloc was preloaded from
  `/usr/local/lib/libjemalloc.so.2`.
- **Machine.** 4 vCPU Firecracker VM, 15 GB, OTP 29.1.1 (erts 17.1),
  Elixir 1.20.4, Bandit 1.13.1. Not gVisor: it can't run in this session.
- **Config.** One file source, a 2 GB output cache, the stats endpoints on a
  separate `health_port`, defaults otherwise (`log_requests = true`,
  `log_format = "text"`). Misses used a copy without the output cache.
- **Load.** Cache hits: `ab -k` against one output-cache hit
  (`w=300/format=webp`, 15 kB). Misses: a Python keep-alive client with
  random `w=200..1600`, `format=jpeg|webp|png|avif` over 10 photos. CPU is the
  BEAM's user+sys from `/proc/<pid>/stat`.
- **Slow log reader.** A Python pipe reader that passes stdout through at a
  fixed byte rate (20 kB/s and 50 kB/s; a request line is about 190 bytes,
  so about 100 and 260 lines a second). It stands in for a log driver or
  collector that can't keep up. Whether Bunny's collector is ever that slow is
  the open question in finding 2.
- Handler variants were tried by appending a
  `config :logger, :default_handler, config: [...]` block to the built
  release's `releases/0.3.0/runtime.exs`, behind an environment switch. The
  repository is unchanged.
- Hit throughput varies by about 10% between runs here, so compare rows, not
  single numbers.

## Findings

### 1. The request log keeps at most about 500 lines a second and drops the rest without a trace

**Severity:** medium for deployments that count or audit requests from the
log, or that serve many cache hits per node. **Measured.**

**Where:** `image_pipe_server/config/config.exs:13-19` configures only the
default formatter; nothing sets the `:default` handler's overload options, so
`logger_std_h` runs with OTP's defaults: `burst_limit_enable: true`,
`burst_limit_max_count: 500`, `burst_limit_window_time: 1000`,
`sync_mode_qlen: 10`, `drop_mode_qlen: 200`, `flush_qlen: 1000`. The request
line comes from `ImagePipe.Telemetry.attach_default_logger/1`
(`lib/image_pipe_server/application.ex:26`, on by default via
`config.ex:123`).

**Evidence:** cache hits, fast sink (stdout to a file), counting request
lines in the output against requests sent:

| load | rps | requests | lines in the log |
|---|---|---|---|
| `ab -k -c 1`, 10,000 hits | 1,000 | 10,000 | 5,468 (55%) |
| `ab -k -c 16`, 10,000 hits | 3,530 | 10,000 | 2,003 (20%) |

- The c=1 run lasted 10 s and kept 547 lines a second: the burst limiter's
  500 a second. The missing lines leave no message: the only notices in the
  log are `Handler :default switched from :sync to :drop mode` and back,
  which say nothing about how many lines went missing.
- The cut applies to every log line in the window, so a warning or error
  (a failed source fetch, a cache write error) during a hit burst can be
  dropped the same way.
- With the burst limit off and sync mode off (the variant in finding 2's
  table), c=1 kept 6,000 of 6,000 lines. At c=16 it kept 2,003 and 2,361 of
  6,000: one handler process writing through the standard I/O server tops
  out at about 1,400 lines a second on this machine, so at that rate lines
  still drop, but in drop mode, which is the overload protection working as
  meant.
- `/stats` and `/metrics` counters (`hits`, `misses`) are unaffected; only the
  log loses lines.

**Suggested fix:** set the handler's overload options in `config.exs`
(together with finding 2's fix):

```elixir
config :logger, :default_handler,
  config: [burst_limit_enable: false, sync_mode_qlen: 1000, drop_mode_qlen: 1000, flush_qlen: 5000]
```

That keeps drop mode as the guard against an unbounded queue and removes
the fixed 500 a second ceiling. The JSON formats go through `runtime.exs:25`,
which sets `:default_handler` again; the `config:` key has to survive there
too. Then say in `docs/server-configuration.md` (`log_requests`) that one
node logs up to roughly 1,000–1,500 lines a second and drops lines beyond
that, and that hit-heavy nodes should take request counts from `/metrics` or
the CDN.

**Open question for Håvard:** do you count or bill anything from the request
log on Bunny? If so, how many requests a second does one node serve at peak?
Above 500 a second the log there is already a sample.

### 2. A log reader slower than the log rate stalls requests for up to 3 seconds

**Severity:** medium when the container's log collector can be slow, none
otherwise. **Measured** with a rate-limited stdout reader.

**Where:** the same handler defaults as finding 1. Once more than 10 lines are
queued (`sync_mode_qlen: 10`), the logging process (the request's connection
process) waits until the handler has written its line. If stdout
is a pipe that isn't drained fast enough, the write blocks, and so does
every request that logs.

**Evidence:** cache hits, `ab -k -c 16`, 8,000 requests per run, three runs
each (rps; p99 ms; longest request ms):

| stdout reader | shipped handler settings | burst limit off, sync mode off |
|---|---|---|
| fast (file) | 3,961 / 12 / 32; 4,121 / 10 / 36; 3,718 / 13 / 37 | — |
| 50 kB/s (~260 lines/s) | 2,376 / 16 / 776; **792 / 1,176 / 1,212**; 3,422 / 9 / 1,181 | 4,216 / 10 / 14; 4,315 / 9 / 15; 4,229 / 10 / 17 |
| 20 kB/s (~100 lines/s) | 1,788 / 11 / **3,122**; **967** / 14 / 3,101; 1,037 / 11 / 3,124 | 4,064 / 10 / 16; 4,059 / 10 / 18; 4,018 / 10 / 20 |

- With the shipped settings, throughput fell to a quarter to a half and some
  requests waited 0.8–3.1 seconds, entirely on the log write. With sync mode
  off, the same slow reader cost nothing: lines past the queue limit are
  dropped instead (finding 1).
- c=1 at 1,000 rps showed nothing, because the burst limiter (finding 1)
  caps the queue's input at 500 a second; the stall needs a reader slower than
  what the limiter lets through, or a burst.
- The request line is logged when the `[:request]` span stops
  (`image_pipe/lib/image_pipe/plug/runner.ex:27`), after the response is sent
  and the pool turn has ended. So the blocked write doesn't delay the response
  it describes or hold a pool turn; it holds the connection process, and the
  next request on that keep-alive connection waits. A CDN or proxy that
  reuses connections sees that as latency, which is what `ab -k` measured.
- Misses log about 10 lines a second per node here, so they only stall when
  the reader stops almost entirely (a stuck log pipe).
- The variant's CPU cost per hit is the same as the shipped settings
  (1.77–1.81 ms at c=1, 0.88–0.93 ms at c=16, against 1.79–1.82 and
  0.93–1.02).

**Under gVisor:** every stdout write is a syscall the Sentry handles, and
Bunny's log collector reads the container's stdout. If that path is slow or
pauses (collector restart, backpressure from the log store), the shipped
settings turn it into request latency. Not measurable here.

**Suggested fix:** the handler options in finding 1 (`sync_mode_qlen` equal
to `drop_mode_qlen` turns sync mode off). Not a request-path code change, but
it changes what the server does under load, so a `perf` label and these tables
in the PR description fit. A test can check that the server's
`:logger.get_handler_config(:default)` has sync mode off.

**Open question for Håvard:** have you seen request latency spikes on Bunny
that didn't line up with misses or CPU? Long cache-hit times in the request
log next to `switched from :drop to :sync mode` notices would be this.

## Earlier findings rechecked

| Source | Finding | Status on main |
|---|---|---|
| perf-review-4 #1 | `+sbwtdio none` costs 17–30% of cache-hit throughput | Fixed: `rel/vm.args.eex:8` sets `+sbwtdio very_short` (PR #954, bead `lksl` closed). The gVisor side was never measured |
| perf-review-4 #2 | Pool, not `VIPS_CONCURRENCY`, decides CPU use | Open as bead `da5b` with pass 4's notes. `rel/env.sh.eex:47-64` still sets `VIPS_CONCURRENCY` to the full quota and `docs/server-deployment.md:387-389` is unchanged. Waits on the 8 × 1 or 8 × 2 run on Bunny |
| perf-review-3 #1, #2 | Scheduler busy-waiting, jemalloc background thread | Still in place (`vm.args.eex`, `env.sh.eex:38`) |
| perf-review-4, checked | `/metrics` ran `df` through disksup | Replaced by `System.cmd("df", ...)` per root (`stats.ex:107-135`, bead `ogot`); see below |
| memory-leak-hunt #1 | `/tmp` is memory on gVisor | Still open as bead `e4a.8.22`. `image_pipe/lib/image_pipe/cache/input.ex:176` stages under `System.tmp_dir!()`, and `docs/server-deployment.md:53-54` still says to mount `/tmp` as tmpfs with no gVisor note |

## Checked and fine

- **Memory after a burst.** No cache, 160 misses at 4 concurrent: RSS
  124 MB at boot, 838 MB peak, 508 MB right after, 135 MB after 30 s idle
  (jemalloc's background thread at work). The BEAM's own allocators hold
  about 58 MB of carriers before and after (`binary_alloc` 2 MB, `eheap_alloc`
  7–8 MB, `ll_alloc` 41 MB), and a full GC changes nothing, so response
  binaries don't pin memory between bursts.
- **First requests after boot.** One fresh boot per case, two runs each, first
  request against a second one of a larger size: file-source misses as webp,
  jpeg, with `blur`, and from a PNG original were no slower first (0.33–0.59 s
  first, 0.34–0.75 s second), so the warmup covers them. The first cache hit
  takes 44–52 ms and every later one about 2 ms, as pass 4 found. The first
  HTTP-source fetch takes 46–48 ms longer (`fetch_ms=48` against 2 for the
  next), loading Req and Finch and starting the pool: a one-time cost, not
  worth adding to the warmup, which would need a reachable origin. TLS setup
  for an `https` origin wasn't measured (no reachable origin here).
- **`/metrics` with `df`.** 7–11 ms per scrape, the `df` process spawn. A
  second scrape that arrives while one is running gets no disk gauges, by
  design (`stats.ex:101-106`): with `ab -c 4` 392 of 400 scrapes came back
  without them. Two Prometheus replicas scraping on the same schedule would
  see gaps in `disk_free_bytes`; harmless, but it reads as missing data.
  Under gVisor the spawn costs more, still once per scrape.
- **Request log CPU.** Per hit, `log_format = "json"` costs the same as text
  (0.93–0.95 vs 0.93–1.02 ms at c=16), and turning the line off saves about
  0.15–0.2 ms (0.77–0.80 ms, 4,760–4,830 rps vs 3,670–4,020), in line with
  pass 4. The c=16 numbers understate the line's cost, since 80% of the lines
  were dropped (finding 1).
- **Router and health.** Unchanged since pass 3's check: request-ID
  generation, an atomics read for draining, and `Plug.forward` don't show up
  next to the hit path.
