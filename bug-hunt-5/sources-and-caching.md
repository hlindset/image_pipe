# Bug hunt 5: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources (DNS cache, pinned connects, URL parsing, S3 credential refresh, freshness rules), source coordination (source lock, shared download flight, overlapped processing), and the FileSystem caches (admission, sweep, source records, `cache_stats/1`). Read on `main` at `8edf03b`. Paths are relative to `image_pipe/`.

**How this was checked.** Every finding was read in the code on `main`. *Confirmed* means it was reproduced with a throwaway ExUnit test (not committed). *By reading* means it wasn't run.

**Dedupe.** Checked against `bug-hunt*/sources-and-caching.md`, `memory-leak-hunt/report.md`, `perf-review*/` and the beads synced from DoltHub in this session (open epics `image_plug-6lz0.4`, `image_plug-e4a.8`, `image_plug-xdsq`).

**Hunt 4 findings, as of `8edf03b`:**
- Fixed: #1 (Finch pool checkout kills the caller; `ReqStream` now runs the request in a monitored relay and maps the exit to `:pool_timeout`), #2 and #3 (admission around the startup scan, c62d24d), #5 (info identity includes lowered result limits, 50fd5db), #6 (watermark input keys checked after a decode failure), #8 (source lock released before the overlap is awaited, 12e58a1), #9 (query encoded, 64174c4), #10 and #11 (conditional headers and Req byte options dropped from `req_options`, 8205c13).
- Fixed apart from what's documented: #7. Per-address receive and pool timeouts are capped to the time left (`source/http/pinned_target.ex:38-62`); only `connect_timeout` can still overrun, as the docs say.
- Mostly fixed: #4 (over the cap never drains). `reconcile_if_over_cap/1` now runs after a hit and after a scan crash. A narrow gap remains; see the note under finding 5.

Counts: 1 high, 3 medium, 5 low.

---

## 1. A waiter that times out can leave the source lock held for good

- **Severity:** high
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/work.ex:44-66` (`lock/3`, `cancel_wait/2`), `:220-228` (`handle_call({:cancel_wait, key}, ...)`), `:363-374` (`release_lock/3`)

**Evidence.** `lock/3` waits with `:gen_server.receive_response(request, wait)`. When that times out, OTP abandons the request: it removes the monitor and deactivates the reply alias (OTP 29 `gen.erl`), so any later reply to it is dropped. `cancel_wait/2` assumes the opposite. Its comment says a grant sent after the wait ran out "is then already here", and it checks with `receive_response(request, 0)`.

The race: the holder unlocks after the waiter's timeout fires but before `Work` handles `{:cancel_wait, key}`. `release_lock/3` makes the waiter the owner and replies `{:ok, next, :coalesced}`, which is dropped. `cancel_wait` only removes refs still in `lock.waiters`, so it doesn't release a lock the caller now owns, and the follow-up receive finds nothing. `Work.run` returns `:timeout` while `Work` still records the caller as owner. Repro (holder takes the lock, waiter calls `Work.run(..., wait: 200)`, `Work` suspended while the holder unlocks and the waiter times out, then resumed):

```
waiter result: :timeout
lock after waiter gave up: %{owner: #Reference<...>, context: nil, waiters: []}
third request: :timeout
```

**Effect.** The lock is freed only when the orphaned owner's process dies. Under HTTP/1.1 keep-alive that is the connection process, so it can last as long as the connection. Until then, every request for that source waits out its full wait (`fetch_timeout + 1_000`, 31 s by default) and gets a 504. A later request on the same connection queues behind its own stale lock. The timing needs the release to land at the waiter's deadline (for example a ~30 s download plus the writer's 2 s lease hand-off against a 31 s wait), so it is rare, but nothing recovers from it.

**Suggested fix.** Wait with `:gen_server.wait_response(request, wait)`, which keeps the alias active. On `:timeout`, call `cancel_wait`, then `receive_response(request, 0)`: a grant made before the cancel is then guaranteed to be in the mailbox, and the existing `unlock` handles it. Alternatively, store the owner's pid with its ref and let `cancel_wait` release a lock the caller owns. Test: the repro above, expecting the lock to be free after the waiter returns.

---

## 2. A cached source record with a missing field crashes the request instead of reading as a miss

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/origin.ex:36-41` (`valid?/1`); callers `lib/image_pipe/cache/file_system.ex:101-110` (`source_record/2`), `:112-114` (`decode_entry/2`), `lib/image_pipe/cache.ex:167-173` (`read_source_record/2`)

**Evidence.** `valid?(%__MODULE__{} = origin)` matches any map whose `__struct__` is `Origin`, then reads `origin.status`, `origin.vary` and the rest with dot access. Metadata is external data decoded from disk. A metadata file whose `source_record.origin` is an `Origin` without `:vary`:

```
** (KeyError) key :vary not found
```

from `ImagePipe.Cache.FileSystem.source_record/2`. Nothing on the output-cache or source-index path rescues it. `Cache.Input` does rescue (`input.ex:55,115`), so only the output cache and the source-record index are exposed.

**Effect.** A 500 instead of a miss. Reachable from a corrupt file, or from metadata written by another ImagePipe version with a different `Origin` shape under the same `@metadata_version`, for example during a rolling upgrade over a shared cache root. The guidelines treat cache reads as a serialization boundary that fails open.

**Suggested fix.** Match the required keys in the function head (`%__MODULE__{status: status, vary: vary, ...}`) so a missing key falls to `valid?(_) -> false`. Test at the cache boundary with such a metadata file, expecting a miss.

---

## 3. A slow but reachable origin is treated as a moved one, and evicts the shared DNS answer

- **Severity:** medium
- **Confidence:** by reading (the per-address resend is covered by the existing silent-origin test in `pinning_test.exs`)
- **Where:** `lib/image_pipe/source/http/pinned_target.ex:38-44`, `lib/image_pipe/source/req_stream.ex:164-176` (`@unreachable` includes `:timeout`), `:184-198` (`reroute`)

**Evidence.** Mint reports a connect timeout and a header receive timeout the same way, and Req normalizes both to `%Req.TransportError{reason: :timeout}` with no status. `PinnedTarget.connect/7` moves to the next address on any `TransportError`, marks the pool as not connected, and sends the GET again. Then `request_failed/3` treats `:timeout` as unreachable and calls `reroute`, which runs `invalidate_target` (deletes the host from the `DnsCache` table every request shares) and looks the host up again.

**Effect.** An origin that accepts connections but answers slowly (a cold thumbnailer, an overloaded S3-compatible gateway behind a dual-stack name) gets the same GET once per address, its pools drop down the live ordering, and every slow fetch evicts the shared DNS entry so concurrent requests re-resolve. Commit 8df30b6 made timeouts reroutable on purpose (a moved origin that blackholes SYNs), so the question is only about the receive phase.

**Suggested fix.** Treat only connect-phase timeouts as unreachable: for example, compare the attempt's elapsed time with `connect_timeout`, or check whether a connection was established. At least don't invalidate the DNS entry after a receive timeout. **Open question for Håvard:** should a receive timeout still try the next address (slow origin) or not (moved origin)? Today both are the same error.

---

## 4. `cache_stats` counts a request on an expired record twice

- **Severity:** medium (the counters are new and documented as once per request)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/execution.ex:291-304` (`open(%Context{stale?: true})`), `:306-309` (`open_current/1`), `:348` (`lookup/2` defaults to `&Cache.lookup_entry/2`), `:424-425` (`open_with_lease/2`)

**Evidence.** `open/1` for a stale context calls `lookup(context)`, which counts through `Cache.lookup_entry/2`. On a miss it acquires and calls `open_with_lease/2`, which calls `open_current/1`, which calls `lookup(context)` again with the counting function. The coalesced paths (`:488`, `:509`) already pass `&Cache.recheck_entry/2` for this reason.

**Effect.** Each request whose source record had expired and whose output wasn't stored records two misses (or a miss and a hit), skewing the hit rate that `cache_stats/1` reports toward misses exactly when records turn over.

**Suggested fix.** Use `&Cache.recheck_entry/2` for the lookup inside `open_with_lease/2`'s path. Test: a stale-record request moves the miss counter by one.

---

## 5. `cache_stats/1` can exit the caller

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/cache/file_system/store.ex:289-290` (`usage/1`), `lib/image_pipe/cache/file_system/admission.ex:152` (`usage/1` is a bare `GenServer.call` with the default 5 s timeout)

**Evidence.** `Store.usage/1` looks Admission up and calls `Admission.usage/1` with no catch. If Admission dies between the lookup and the call (`:noproc`), or is busy for more than 5 s, the exit goes to whoever called `ImagePipe.cache_stats/1`. One busy case: a hit on an untracked key reads metadata inside Admission (`admission.ex:259-265`, `stored?/2` at `:288`), and during the startup scan nearly every key is untracked.

**Effect.** A metrics poller or health endpoint calling `cache_stats/1` crashes during an Admission restart or a slow startup scan instead of getting partial stats.

**Suggested fix.** Catch the exit in `Store.usage/1` and report that cache as unavailable. Related perf note: skip the metadata read for a hit while the scan is still running (`scan_changes != nil`), since the scan will count the entry.

Residual from hunt 4 #4, by reading: `reconcile_to_cap` runs before the startup sweep, and a hit that adds an untracked entry while the sweep runs is skipped by the `scan_complete?` guard in `reconcile_if_over_cap/1` (`:636-638`). `complete_scan/1` doesn't reconcile afterwards, and later commits free only what they add. It needs an entry the scan couldn't count, so it is rare. Fix: call `reconcile_if_over_cap/1` at the end of `complete_scan/1`.

---

## 6. A DNS failure answers 404 as a denied address

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/source/http/target_guard.ex:107-113` (`resolve_via/2`), `lib/image_pipe/response/error_status.ex:53`

**Evidence.** Any resolver result other than `{:ok, list}`, and any raise, becomes `{:error, :denied_address}`, which maps to 404 (documented at `source/http.ex:194` for policy denials). That covers NXDOMAIN, the native resolver's own timeout, and a crashed `DnsCache` lookup. A lookup cut off by the fetch deadline gives `:receive_timeout` (504) instead.

**Effect.** A transient DNS outage looks like a missing image to clients and CDNs (404s are often cached), and like a policy denial in telemetry.

**Suggested fix.** Return a separate reason such as `:resolve_failed` and answer 502 (or 504 for a resolver timeout). Keep `:denied_address` for addresses the policy rejects. **Open question for Håvard:** is 404 for an unresolvable host intended, to avoid revealing which hosts resolve? If so, the telemetry reason should still differ.

---

## 7. Identical requests can give up waiting on the download and render the image twice

- **Severity:** low (wasted work, not a wrong result)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/execution.ex:243-247` (`finish_download`), `:456-466` (`join_output` releases download waiters only after joining the image's flight), `lib/image_pipe/execution/overlap.ex` (`finish/1` waits up to 60 s)

**Evidence.** The leader of a download flight releases identical waiters with `{:ready, record}` only in `join_output/3` (or `close`, or on a cache hit). Before that it has awaited the source lock, the download, its overlapped processing (`finish_overlap`), watermarks and the conditional gate. Waiters time out at `fetch_timeout + 1_000` from when they joined.

**Effect.** With a slow download plus overlapped processing, a waiter expires with `:bypass`, finds the newly published record, and leads the image's own flight before the original leader reaches it. It renders from scratch, and the original leader then waits behind it and throws its overlapped result away. Double CPU and memory on exactly the large, slow sources overlap is for. Also, if the leader itself waits on another request's image flight, its download waiters wait for that too.

**Suggested fix.** Release download waiters with `{:ready, record}` as soon as the source work is done, before `finish_overlap`, or join the image's flight before awaiting the overlap.

---

## 8. After a commit timeout, `remember_source` deletes the record it just wrote

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/cache.ex:181-196` (`remember_source/3`), `lib/image_pipe/cache/file_system/admission.ex:301`

**Evidence.** Any `Sink.store` result other than `:ok` calls `forget_source/2`, including `{:error, :admission_timeout}`. A timed-out commit stays queued in Admission and is still published, and the delete queues behind it, so it removes the new record rather than an older one.

**Effect.** Lookups fall back to the originals cache's record, so nothing stale is served; it costs one extra revalidation or rehash per affected source, and only when Admission is already slow.

**Suggested fix.** Skip the delete on `:admission_timeout`, or keep it and say in the comment that it may remove the new record.

---

## 9. Starting a fresh DNS lookup instead of joining a stuck one doesn't help with the native resolver

- **Severity:** low
- **Confidence:** by reading (OTP `inet_gethost_native.erl`)
- **Where:** `lib/image_pipe/source/http/dns_cache.ex:13-16` (comment), `:22` (`@join_within 1_000`), `:116-133` (`join_or_start/4`)

**Evidence.** A lookup older than `@join_within` isn't joined, so "requests recover as soon as DNS does". The default resolver calls `:inet.getaddrs/2`, which with the default `native` lookup goes through `inet_gethost_native`. That server merges a request for the same name with the pending one instead of sending it to the port again, so each new lookup waits on the same stuck `getaddrinfo`.

**Effect.** No faster recovery; just one extra lookup process per host per second during a resolver stall.

**Suggested fix.** Always join the pending lookup and drop `join_within`, or, if real recovery is the goal, resolve with `:inet_res` and an explicit timeout.

---

## Lower confidence, not counted

- **Attempts started with almost no time left fail as `:pool_timeout` (by reading).** The next-address loop checks only `remaining(deadline) == 0` (`pinned_target.ex:43`), and the `:closed` retry and the post-reroute request also start with whatever is left. A pool timeout of a few ms makes Finch raise "unable to provide a connection", which the relay reports as `:pool_timeout`, hiding the real connect or receive error. Both likely answer 504, so the harm is diagnostic.
- **S3 credential refresh every 5 s near expiry (by reading).** `RefreshCache.Entry.schedule_refresh/1` uses `max(5_000, diff - margin)`. A provider that keeps returning the same credentials until close to expiry (IMDS rotates about 5 min before) is polled every 5 s once less than 5 min 5 s remains, until it rotates.
- **A watermark task exit skips the release (by reading).** If `Watermarks.await` exits because a task crashed, the exit leaves `prepare` before `with_prepared`'s `try`, so the source lease and download flight are released only when the process dies. Under keep-alive that is the connection.
- **The sweep reads each old metadata file two or three times (perf, by reading).** `remove_unreadable/4` decodes every `.meta` older than an hour (`sweep.ex:84-98`), then `sweep_body/5` decodes it again, twice, for each old body (`:179-180`). This runs at every boot and every 24 h; noticeable on large caches on network storage.

## Checked and found sound

- **DNS cache:** used only with the default resolver, keyed by host; `TargetGuard.validate` runs the address policy on cached and fresh answers alike, so a cached answer is never unchecked. Failures and empty answers aren't stored; expiry uses monotonic time; the table is capped and swept; a crashed lookup replies to every waiter; a dead cache server falls back to a direct lookup; the reroute happens at most once per fetch.
- **Shared download flight:** the flight key includes the source partition, waiters get only the record and read the original under their own input key, and no staged file or overlap state crosses processes. Leader errors, raises and deaths complete or promote; waiters demonitor with `:flush`.
- **Local file hash memo:** keyed by input key and valid only while size, mtime, ctime, inode and device match; same-second edits keep no evidence; the memory table is capped with random eviction.
- **Pending byte accounting:** `Writer.reserve`/`terminate` ordering and `Publication`'s `hold(0)` leave no drift.
- **S3 credentials:** single-flight refresh, fail-closed on expiry, redacted state and labels, retired idle entries re-fetched on `:retired`.
- **Freshness rules (`Source.CacheState`):** duplicate or invalid `Age`, `Date`, `Expires` and lifetimes fall back conservatively; qualified `private`/`no-cache` restrict only retained fields.
- **URL parsing:** userinfo and fragments rejected, ports bounded, path and query re-encoded byte-preservingly, `base_url` paths reject dot and empty segments, `path_pattern` anchored once.
