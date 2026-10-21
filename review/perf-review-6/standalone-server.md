# Performance review 6: image_pipe_server

Scope: `image_pipe_server/` as a running prod release (release env and VM
flags, Dockerfile, Bandit listeners, router, logging, stats, health), plus
the server-wide cost of what the library keeps in memory. Repo at `6a87579`
(main, 2026-10-21), which includes #1056 (cache entry metadata kept in
memory) and the in-memory source records.

Both of pass 5's findings are fixed on main, including for the JSON log
formats. One new finding: the memory the caches keep for bookkeeping is
sized from the cache's disk size, not from the container's memory, and with
default settings it can reach several hundred MB to about 1.7 GB on a
container that may have far less. Nothing in `/metrics` shows it.
Everything else checked came out fine.

## How this was measured

- **Release.** `MIX_ENV=prod mix release` with
  `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` against the session's
  libvips 8.18.7 build, started with `bin/image_pipe_server start`, stdout
  to a file. `rel/env.sh` and `rel/vm.args` as shipped, jemalloc preloaded.
  Distribution was turned on (`RELEASE_DISTRIBUTION=sname`) only to read
  memory with `rpc`.
- **Machine.** 4 vCPU Firecracker VM, 15 GB, OTP 29.1.1, Elixir 1.20.4,
  Bandit 1.13.1. Not gVisor: it can't run in this session.
- **Config.** A file source, an HTTP source pointed at a local Python
  HTTP/1.1 origin on port 9000, a 10 GB `output` and a 10 GB `input` cache
  (so the memo and record limits are 200,000 each), stats on a separate
  `health_port`, defaults otherwise.
- **Memory.** `:erlang.memory/0` after a forced GC of every process, ETS
  table sizes from `:ets.info/2`, and `VmRSS`. Per-row costs are deltas
  between two such readings, so they include everything the rows pin.
- **Load.** `ab -k` for single-URL cache hits; a Python keep-alive client
  (8 threads) over 30,000 distinct 64×64 JPEG originals (`w=32`) for
  bookkeeping growth.

## Findings

### 1. In-memory cache bookkeeping is sized from disk, not memory, and can outgrow the container

**Severity:** medium on Bunny (memory-billed, gVisor, `/tmp` already in
memory), low on hosts with memory to spare. **Measured.**

**Where:**

- Source records: `image_pipe/lib/image_pipe/cache.ex:118-125`
  (`put_source_records/2`): one record per 50 KB of
  `output.max_size_bytes`, at least 10,000 and at most 1,000,000.
- Entry metadata memo (#1056):
  `image_pipe/lib/image_pipe/cache/file_system/memo.ex:23-25`
  (`limit_for/1`): one row per 50 KB of each cache's `max_size_bytes`,
  1,000 to 200,000, for the `output` and the `input` cache each.
- Admission's `:entries` index (not new): one row per entry on disk.
- The server passes these through unchanged (`config.ex:241`
  `max_remembered_originals`; the memo has no setting) and exports none of
  them in `/stats` or `/metrics` (`stats.ex`).

**Evidence:** 30,000 distinct originals, one miss and then one hit each,
on a fresh release:

| step | `:erlang.memory(:total)` | ETS | binary | RSS |
|---|---|---|---|---|
| after boot | 57.8 MB | 2.0 MB | 0.5 MB | 128 MB |
| after 30,000 misses (records, `:entries`) | 111.6 MB | 36.1 MB | 18.9 MB | 201 MB |
| after 30,000 hits (memo rows) | 171.0 MB | 75.5 MB | 39.2 MB | 257 MB |

Per row:

| table | ETS bytes per row | what else it pins | measured total |
|---|---|---|---|
| memo row (`output`) | 1,305 | the body path and body filename as off-heap binaries (394 B here) | **~2.0 KB** (59.4 MB / 30,000, whole-VM delta; RSS delta 1.85 KB) |
| source record, local file | 697 | nothing off-heap | ~0.7 KB |
| source record, origin image | 995 | nothing off-heap | ~1.0 KB |
| `:entries`, per entry on disk | 208 | — | ~0.2 KB |

The library docs say 1.5 KB per memo row; through the server it's closer to
2 KB. The body path here is about 60 bytes longer than
`/var/cache/image_pipe/...` would be, so a deployment row is about 1.9 KB.

What the defaults allow, from those per-row numbers (memo full of hit
entries, records full of originals in use):

| `output.max_size_bytes` | memo rows | records | memo | records | together |
|---|---|---|---|---|---|
| 1 GB | 20,000 | 20,000 | ~40 MB | 14–20 MB | ~60 MB |
| 10 GB | 200,000 | 200,000 | ~380 MB | 140–200 MB | ~520–580 MB |
| 50 GB | 200,000 | 1,000,000 | ~380 MB | 0.7–1.0 GB | ~1.1–1.4 GB |

On top of that: the `input` cache's memo (same formula on
`input.max_size_bytes`, but it only holds originals that were hit, so it
stays small unless originals are small), and `:entries` at 0.2 KB per
stored entry (10 GB of 20 KB thumbnails is 500,000 entries, about 100 MB).
None of this is freed while the server runs: both tables evict only to make
room, so once full they stay full.

- **Half of a memo row is debug info.** Of a row's 1,264 heap bytes,
  `metadata.debug` (the `ImagePipe.Debug.Info` struct with timings) is 624.
  A hit uses it only for debug headers, which need
  `allow_debug_headers: true` (off by default, and the server doesn't set
  it). The row also stores the full body path next to `body_filename`,
  from which the path can be derived.
- **The memo's gain didn't show through the server here.** Switching the
  memo off at runtime (limit 1, table emptied) and back on, alternating
  runs, single-URL hits:

  | | c=16 rps | c=16 CPU per hit | c=1 rps | c=1 CPU per hit |
  |---|---|---|---|---|
  | memo on | 4,065 / 3,654 / 3,801 | 0.92 / 1.03 / 0.99 ms | 859 / 871 | 1.99 / 1.97 ms |
  | memo off | 3,970 / 3,857 / 3,715 | 0.94 / 0.96 / 1.00 ms | 905 / 827 | 1.90 / 2.03 ms |

  That's within run-to-run noise. On local disk with a warm page cache, the
  `.meta` open, read, and close it saves are cheap. Under gVisor each of
  those is a trip through the Sentry (and the Gofer for a bind-mounted
  volume), so the saving should be bigger there, but it can't be measured
  here.

**Suggested fix:**

1. Size the defaults from memory, not disk. `rel/env.sh` already reads the
   cgroup CPU quota; the memory limit is next to it
   (`/sys/fs/cgroup/memory.max`). For example, give the memo and the
   records together a budget of about 10% of the container's memory limit
   when there is one, capped by the disk-based count, and keep the disk-based
   count when there's no limit.
2. Add a server setting for the memo, or one memory budget for both, next
   to `[cache] max_remembered_originals`.
3. Export the row counts (and ETS bytes) in `/stats` and `/metrics`, e.g.
   `image_pipe_cache_memo_entries{cache=...}` and
   `image_pipe_remembered_originals`, so the memory is visible next to the
   cache size.
4. Make memo rows smaller: keep `debug` only when the mount allows debug
   headers (or read the `.meta` from disk for a debug request), and store
   the body filename instead of the full path. That roughly halves a row.
5. Document the per-GB memory cost in `docs/server-deployment.md` sizing,
   including the memo, which the server docs don't mention (bead `34c0`
   covers the changelog entry only).

**Open questions for Håvard:**

- What memory limit do the Bunny containers have, and what are their
  `output` and `input` `max_size_bytes`? At 10 GB output the defaults
  allow about half a GB of bookkeeping.
- Is the memo worth its memory on Bunny? A cache-hit run there with the
  memo on and off (the runtime switch above works over a remote console)
  would show whether gVisor's file calls make it pay off. If it doesn't,
  a much lower default limit would keep most of the hot-entry benefit.

## Earlier findings rechecked

| Source | Finding | Status on main |
|---|---|---|
| perf-review-5 #1 | Request log kept at most ~500 lines/s, dropping the rest silently | Fixed (PR #1025): `config/config.exs:21-32` turns the burst limit off. The running release reports `burst_limit_enable: false` with `log_format = "json"` too, so `runtime.exs` keeps the handler config |
| perf-review-5 #2 | Slow log reader stalled requests up to 3 s | Fixed (PR #1025): `sync_mode_qlen` equals `drop_mode_qlen` (1000), and drop mode logs a `notice`. Documented under Logging |
| perf-review-4 #2 | Pool, not `VIPS_CONCURRENCY`, decides CPU use | Still open as bead `da5b`; `rel/env.sh.eex:47-64` unchanged. Waits on a Bunny run |
| memory-leak-hunt #1 | `/tmp` is memory on gVisor | Still open as bead `e4a.8.22` |
| perf-review-4, checked | `/metrics` ran `df` per scrape | Replaced by `Stats.Disk` (PR #1030), which runs `df` per root every 15 s in the background. Scrapes no longer spawn anything; see below |

## Checked and fine

- **Cache-hit cost.** Single-URL hit (`w=300/format=webp`, 946 B): 0.92–1.03
  ms CPU and 3,650–4,080 rps at c=16, 1.8–2.0 ms and 830–970 rps at c=1.
  The same as pass 5, but now every request line is written (pass 5 dropped
  80% of them at c=16), so the full log line is included.
- **Idle keep-alive connections.** 2,000 idle connections: 5.5 KB of
  process memory each with no request, plus 9.1 KB of binary each after one
  request (any request, `/health/live` too, so it's the socket's read
  buffer, not the image path), measured after a forced GC. At the default
  `max_connections = 2048` that's about 30 MB, and `read_timeout` (10 s)
  closes them.
- **Origin connections.** 2,000 misses at 8 concurrent against the HTTP/1.1
  origin used 9 connections, so the Finch pool reuses connections. Hits
  revalidate with the origin on every request when the origin sends no
  `Cache-Control` (this test origin), which is the configured freshness
  policy working, not a server cost.
- **Restart with an `input` cache.** After a restart, 2,000 hits of
  origin-backed entries all came back `cache=hit source_fetch=not_modified`
  with no original downloaded, at 622 rps against 890 before the restart.
  Without an `input` cache they'd download every original again; that's the
  #1019 regression the sources-and-caching passes already reported, not
  re-reported here.
- **Boot.** Ready 1.1 s after `start`, RSS 160 MB (JSON log format).
- **`Stats.Disk`.** One `df` per cache root every 15 s, outside requests.
  Negligible, and under gVisor the fork costs more but still only every
  15 s.
- **Bounded binary memory on origin hits.** A fresh release serving
  origin-backed hits grew `:erlang.memory(:binary)` by about 34 MB in its
  first 4,000 requests, held by no process and no ETS table I could find,
  then stayed flat over 8,000 more (35.15–35.17 MB). Bounded, so not a
  finding; its owner wasn't identified.

## Pointer for the request-path pass

A call-count profile (`tprof`, 3,000 single-URL hits) shows per hit: 2 file
opens, 2 `read_file_info`, 2 `read_link` (the file source resolving its
path), 2 closes, 6 SHA-256 hashes, 6 `term_to_binary`, about 205
`String.downcase` calls and about 104 `MaterialDigest.canonicalize` calls.
On local disk none of it stands out, but under gVisor the six file calls per
hit are the part most likely to cost more. Library code, so left to that
area.
