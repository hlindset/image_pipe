# Bug hunt 6: standalone server (image_pipe_server)

Date: 2026-10-20. Scope: `image_pipe_server/` on `main` at `fe70ecc`
(0.3.0 plus Unreleased): the router, health, auth, the `/stats` and
`/metrics` endpoints, config loading, the boot-time log settings in
`config/runtime.exs`, `rel/`, the Dockerfile, and the server docs. Most of
the new surface since bug hunt 5 is the `df`-based disk reading
(`ec0bc59`), the `503` from the stats endpoints (`6457ef5`), refused caches
in `/stats` (`4231456`), log settings applied in `runtime.exs` (`771a1e6`),
and `[cache] max_remembered_originals` (`0784b6b`).

Deduped against `bug-hunt/` through `bug-hunt-5/`, the memory hunt report,
and the pushed beads (pulled from DoltHub today).

## Bug hunt 5 findings: all seven fixed on main

| Hunt 5 finding | Fixed by |
| --- | --- |
| 1. No disk space for a cache on a network or FUSE volume, and a hung `df` blocks every scrape | `ec0bc59`: `df -kP -- <root>` without `-l` or a shell, a 2-second wait, one `df` per root at a time |
| 2. A cache root with a space gets no disk metrics, shell syntax runs | `ec0bc59` (checked: `stats_test.exs` has a root with a space) |
| 3. `/stats` answers 500 while the instance isn't running | `6457ef5`: `503` (the busy-admission half is finding 2 below) |
| 4. Guide names `IPS_STATS_TOKEN` | `95adf7f`: now `IPS_STATS__TOKEN` and `IPS_STATS__TOKEN_FILE` |
| 5. Static S3 credentials with a line break pass boot | `998e456`, in the library and in `config/sources.ex` |
| 6. Boot lines ignore `log_format`, `log_colors`, `log_level` | `771a1e6`: `runtime.exs` applies them, `colors: [enabled: false]` in `config.exs` |
| 7. `/stats` drops a refused cache, and `entries` counts source records | `4231456` lists refused caches. `0784b6b` stopped storing source records, but the guide still says it (finding 3 below) |

How this was checked: the server ran locally with `mix run --no-halt` and a
TOML file per case (Bandit 1.13.1, OTP 29.1.1, Elixir 1.20.4), with `curl`
against it. One case ran a script under `mix run` that suspends the cache's
admission process with `:sys.suspend/1` and calls `/stats` with `:httpc`.
The server's own tests pass (180 tests, 1 skipped). No Docker image was
built.

---

## 1. Medium-low: overlapping scrapes get no disk sizes, and a `df` slower than 2 seconds never reports any

- **File:** `image_pipe_server/lib/image_pipe_server/stats.ex:96-126`
  (`disk/1`)
- **Status:** reproduced for overlapping scrapes. The slow-`df` case is
  reasoned from the code.
- **Evidence:** `disk/1` runs `df` only when `:ets.insert_new/2` adds the
  root to the in-flight table. Any other request for that root while a `df`
  runs gets `@unknown` (`null` sizes) at once, without waiting for the
  running one. Nothing keeps the last good result. On a healthy local disk,
  where `df` takes a few milliseconds:

  ```text
  # 8 parallel GET /stats, 5 rounds
  responses with "disk_free_bytes":null: 6, 7, 6, 7, 7 of 8

  # GET /metrics on the health port and the image port at the same moment, 50 rounds
  missing disk gauges in 39 of 100
  ```

  Overlapping scrapes are normal: an HA pair of Prometheus servers, a
  Prometheus scrape plus an operator's `curl /stats`, or a scraper on each
  listener. Each lost race drops `image_pipe_cache_disk_free_bytes` and
  `image_pipe_cache_disk_total_bytes` from that scrape, so the series gets
  gaps, and an `absent()` or "disk almost full" alert flaps.

  The slow case: when `df` takes longer than `@df_timeout` (2 s), the scrape
  answers `null` and unaliases the reply. The `df` keeps running and frees
  the root when it ends, but its result is thrown away. The next scrape
  starts a new `df`, which is just as slow. On a volume where `df` always
  takes more than 2 seconds (a busy network volume), the sizes are never
  reported, though `df` works. The guide says they are `null` "when the
  server can't read them" (`docs/server-deployment.md:291`).
- **Open question for Håvard:** How long does `df -kP` take on the cache
  volume on Bunny Magic Containers under gVisor? If it's ever close to
  2 seconds, the slow case applies there.
- **Suggested fix:** Keep the last result per root in the same ETS table,
  with the time it was read. The process that runs `df` writes its result
  there whether or not the scrape that started it still waits. A scrape that
  finds a `df` already running, or times out, answers with the stored result
  when it's recent (say, under a minute old) and `null` only when there is
  none. A test can hold a `df` in flight (a stub on `PATH` that sleeps) and
  check that a second request still gets the sizes.

## 2. Low: a cache whose admission process is busy or restarting drops out of `/stats` and `/metrics` without a sign, after a 5-second wait

- **Files:** `image_pipe/lib/image_pipe/cache.ex:223-242` (`stats/1` keeps
  only `{:ok, stats}`), `image_pipe/lib/image_pipe/cache/file_system/store.ex:329-345`
  (`usage/1`), `image_pipe/lib/image_pipe/cache/file_system/admission.ex:154`
  (`GenServer.call/2` with the default 5-second timeout);
  `image_pipe_server/lib/image_pipe_server/stats.ex:72-81`
- **Status:** reproduced with a suspended admission process.
- **Evidence:** `Store.usage/1` returns `{:error, :admission_unavailable}`
  when the call exits (busy past 5 seconds, or the process dies during the
  call), and `:unavailable` when the admission process isn't registered (it's
  restarting). `Cache.stats/1` then leaves that cache out of the map, and the
  server renders what's left with a `200`. With the output cache's admission
  process suspended:

  ```text
  /stats -> 200 in 5065 ms: {"input":{...,"entries":0,...}}
  # resumed
  /stats -> 200 in 4 ms: {"input":{...},"output":{...,"entries":1,...}}
  ```

  The `output` cache vanished from the response, and from `/metrics` its
  series, including `image_pipe_cache_max_bytes` and the counters, just stop.
  The guide says only that "A cache that isn't configured isn't listed"
  (`docs/server-deployment.md:297`), so the operator reads a configured cache
  as gone. A Prometheus `scrape_timeout` under 5 seconds would also time out
  the whole scrape. Admission answers `usage` between other calls, so a long
  eviction (bead `image_plug-egb3`, "Evict victims outside the Admission
  process for huge evictions") or a slow storage call makes it wait. A
  restart after a crash leaves it unregistered for a moment.
- **Suggested fix:** In `Cache.stats/1`, keep the cache with
  `%{available: false, max_bytes: ...}` (as refused caches keep
  `refused: true`), and have the server render it as such: an
  `image_pipe_cache_available` gauge (0 or 1), and `"available": false` in
  JSON. Give the `usage` call a shorter timeout than the scrape, such as
  1 second. Say in the guide what a missing count means. Add a test to the
  library's `cache_stats_wire_test.exs` with the admission process suspended.

## 3. Low (docs): the guides still say `output`'s `entries` counts one entry for each original

- **Files:** `image_pipe_server/docs/server-deployment.md:284-285`;
  `image_pipe/docs/cache.md:414` (the same sentence in the library guide)
- **Status:** reproduced.
- **Evidence:** Since `0784b6b` ("Keep the records of originals in memory"),
  records of originals are held in the instance's memory and no longer
  written to the processed-image cache. The guide still says
  "`output`'s `entries` also counts one small entry for each original that
  processed images were made from, and `bytes` includes them." One request
  on an empty cache now gives:

  ```text
  "output":{"bytes":285,"entries":1,...}
  ```

  Bug hunt 5 measured `"entries": 2`, `"bytes": 670` for the same request.
  An operator who follows the guide halves the image count in their head.
  Records left from before the upgrade still count until they're evicted,
  as the library changelog says.
- **Suggested fix:** Remove the sentence from both guides. If old records
  are worth a note, say that entries written by earlier versions for
  originals count until the cache evicts them.

## 4. Low: requests the router answers itself leave no log line, and the logged path drops `mount_path`

- **Files:** `image_pipe_server/lib/image_pipe_server/router.ex:71-90`
  (`authorize/2` and `route/2` answer `401` and `404` before
  `ImagePipe.Plug`); `image_pipe/lib/image_pipe/plug/runner.ex:46-48`
  (`ParsedRequest.mount_relative_path/1`); `image_pipe_server/CHANGELOG.md:94`
  (0.3.0: "The path is as sent")
- **Status:** reproduced.
- **Evidence:** With `IPS_SERVER__AUTH_TOKEN=secret` and
  `IPS_SERVER__MOUNT_PATH=/img`, three requests:

  ```text
  GET /img/w=4/src/pic.png  (no token)    -> 401
  GET /other/x              (with token)  -> 404
  GET /img/w=4/src/pic.png  (with token)  -> 200
  ```

  logged one line:

  ```text
  [info] GET /w=4/src/pic.png 200 41ms 285B cache=miss ...
  ```

  - The `401` and the `404` logged nothing, at any level. Only
    `ImagePipe.Plug` emits the request span the default Logger prints, and
    the router answers these without it. A client with a wrong or missing
    token, or a CDN pointed at the wrong prefix, leaves no trace in the logs
    or traces, so the operator can't tell that requests arrive and fail.
  - The `200`'s line shows `/w=4/src/pic.png`, not the `/img/...` the client
    sent. The 0.3.0 changelog says "The path is as sent", and grepping the
    logs for a URL from a CDN log finds nothing when a mount path is set.
- **Open question for Håvard:** Should the server log its own `401` and
  `404` answers? If so, at `warning` like the library's `4xx` lines, or
  `info` for the `404` outside the mount path?
- **Suggested fix:** For the first part, emit a request line from the router
  for the answers it gives itself (method, path, status, duration) through
  the same Logger, with `request_id`, skipping the health checks so probes
  don't flood the log. For the second, either log `conn.request_path` (the
  full path) in the request span's `:path`, or say in the docs that the path
  is relative to `mount_path`.

---

## Checked and found sound

- **Stats auth and routing.** `/stats` and `/metrics` answer `401` without
  the stats token on both listeners, `check?/1` accepts `HEAD`, and with stats off the
  paths fall through to the image auth and the mount. A stats request while
  no instance runs gets `503` (`stats_test.exs`).
- **`df` parsing.** `-P` keeps one line per filesystem. The sizes are found
  from the capacity field, so a filesystem name or mount point with spaces
  parses. Total `0` gives `null`. A missing `df` binary gives `null`, not a
  crash. Disk sizes for a refused cache are still read.
- **Prometheus text.** Every gauge and counter has `HELP` and `TYPE`. A
  refused cache has no counter samples and no `NaN`.
- **Boot log settings.** `log_settings/2` returns `nil` for any config that
  raises `ConfigError`, so a bad file still stops the server with its own
  message at application start. `runtime.exs` sets `colors` per
  `log_colors` and leaves JSON formatters uncolored.
- **`max_remembered_originals`.** `[cache] max_remembered_originals` passes
  through to `ImagePipe.config/1`, with or without an `output` or `input`
  cache, and from `IPS_CACHE__MAX_REMEMBERED_ORIGINALS`.
- **Warmup.** The startup warmup doesn't write to the output cache or count
  lookups (an empty cache shows `entries: 0`, `misses: 0` after boot).
- **Request IDs.** On a keep-alive connection, each request sets its own
  `request_id` metadata. The library adds no other Logger metadata that
  could carry over between requests on one connection.
- **Release scripts and Dockerfile.** No changes since bug hunt 5 beyond
  `+sbwtdio very_short` and the smoke test additions. The runtime image has
  coreutils `df`, which `ec0bc59` needs.
