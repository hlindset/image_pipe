# Bug hunt 7: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources, source coordination (source locks, download and image flights, publication), the in-memory records of originals, and the FileSystem caches. Read on `main` at `6a87579` (after #1056). Paths are relative to `image_pipe/`.

**How this was checked.** *Confirmed* means reproduced with a throwaway ExUnit test or script (not committed). Of the 74 commits since hunt 6 (`fe70ecc`), the hunt concentrated on those in this area: the metadata memo (4cfda5f, #1056), the shared recency table (48c81ac), record writes without a writer (ac20d18, #1043), recall from the originals cache and the new record default (051275d), output entries without records (9d7cca1), the download flight cap (b271826), trimmed cache-write file calls (02a9ae2), cache stats while Admission doesn't answer (f56d02c), and the origin pool size (a1d9806).

**Dedupe.** Checked against `bug-hunt-6/sources-and-caching.md`, `perf-review-5/sources-and-caching.md`, and the beads synced from DoltHub in this session (988 issues), including `image_plug-9mti` (record writes inline), `image_plug-7l6a` (download flight cap), `image_plug-e4a.7.6` (the `:global` lock's cost when nothing is written) and `image_plug-lz1o`.

**Hunt 6 findings, as of `6a87579`:**
- Fixed: #2 (a record read from the originals cache now goes back into memory; 051275d), #3 (docs; 0a22b4c), #4 (output entries no longer store or check the record; 9d7cca1).
- Addressed: #1. 051275d recalls records from the originals cache, sizes the default from the output cache (one per 50 KB, 10,000 to 1,000,000), and documents that an origin image is downloaded again after a restart unless an originals cache holds it. A restart without an originals cache still costs one download per active image, now as documented behaviour.
- Lower-confidence items: the biased record eviction is fixed (051275d, then `RecentTable` in 48c81ac; a quick run of 10,000 rows plus 200,000 inserts left none of the unused originals). The overlapped-encode deadline item still stands, tied to `image_plug-lz1o`.
- Still open, not re-reported: hunt 5 #7 / `image_plug-lz1o` (`execution.ex:487-488`, `finish_download/1` still runs after `join_flight/3`), and the residual that the normal `:scan_complete` path (`admission.ex:401`) doesn't call `reconcile_if_over_cap/1` (the crashed-scan path at `:244` now does).

Counts: 1 medium, 1 low (2 confirmed).

---

## 1. A record write now waits for `:global`'s retry sleep in the request, 100 to 300 ms when two requests publish for one original

- **Severity:** medium (tail latency on the first requests for a new original; a regression from ac20d18 / #1043)
- **Confidence:** confirmed, and compared with the commit before ac20d18
- **Where:** `lib/image_pipe/cache/publication.ex:40-46` (`{_root, {:memory, write}} -> run(...)`), `:89-95` (`run/4`), `lib/image_pipe/cache/work.ex:116-131` (`publish/3`, `:global.trans`), `lib/image_pipe/execution/source_cache.ex:403`, `:413`, `:431` (the writes tagged `{:memory, ...}`), `:210-216` (a first download without an originals cache isn't coordinated)

**Evidence.** Since ac20d18 a write that touches no disk (a record put, or an invalidation without an originals cache) runs in the request, under `Work.publish/3`, which is `:global.trans/3`. `:global` doesn't queue lock requests. A requester that finds the lock taken sleeps a random time before it tries again: up to 125 ms the first time, then up to 250 ms, 500 ms, and so on to 8 s. The lock is held for microseconds, but the loser still sleeps.

Before ac20d18 the same write went to a cache writer whenever a cache root existed, so this wait was off the request. With only an output cache (the common server setup), every request for a new original now publishes its record inline, and these requests aren't coordinated (`shared_work?/3` is false without an originals cache and a record), so requests for different variants of one new original all publish at about the same time.

Micro-benchmark: N processes call `Work.publish(same_key, nil, fn -> ets insert end)` at once:

```
n=2  max=113ms  times_ms=[0, 113]
n=4  max=190ms  times_ms=[0, 123, 125, 190]
n=8  max=241ms  times_ms=[0, 0, 1, 86, 158, 169, 225, 241]
n=16 max=423ms
```

Wire test: HTTP source, output cache only, 6 concurrent requests for 6 widths of one new original. The origin holds all 6 responses and releases them together. 6 rounds; times are per request and include a 50 ms wait before the release, so about 66 ms means no extra wait:

```
main 6a87579:  round 2 [65, 66, 67, 73, 185, 260]   all done 207 ms after release
               round 4 [66, 66, 66, 121, 258, 310]  all done 258 ms after release
               (rounds 2-6: 59-258 ms after release)
ac20d18^:      rounds 2-6 all done 24-46 ms after release, slowest request 98 ms
```

**Effect.** The first requests for a new image in several sizes (a gallery, `srcset`, a CDN fetching several variants after a purge) take an extra 100 to 300 ms each when their downloads finish close together, and more when more than two collide. The same applies to invalidations without an originals cache (several requests getting 404 for one source) and to record refreshes, and with a lease each attempt inside the lock also makes a `Work` call (`current?/1`), which widens the window.

**Suggested fix.** Replace the `:global.trans` publication lock with one that queues waiters and hands the lock over at once, for example a per-key lock in the `Work` coordinator (like its source locks) or a small `Registry`/ETS mutex with a FIFO of waiters. That also removes the random sleeps writers take (noted in the PR 860 review). A smaller change: for `{:memory, ...}` writes with no lease, skip the lock and put the record only if it's newer (`received_at`), since an ETS insert is already atomic. Test: the wire test above, asserting the spread of request times stays within a few tens of milliseconds.

**Open question for Håvard:** does a record write without a lease (an uncoordinated first download) need to exclude other publications at all, or is last-writer-wins on the in-memory table enough there?

---

## 2. With an originals cache, past 64 downloads in flight, variants of a new original each download it again

- **Severity:** low (origin traffic and duplicate originals-cache writes in bursts; the residual of `image_plug-7l6a`)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/work.ex:6` (`@max_keys 64`), `:150-151` (`:busy` for a new key once 64 sources are locked), `:41` (`fun.(false, :busy)` runs without coordination), `lib/image_pipe/execution/source_cache.ex:210-216`

**Evidence.** b271826 gave the download flights their own cap of 4,096, but those flights only join identical requests. Requests for different variants of one original coalesce through the source lock in `Work`, which still allows 64 keys across all sources. A source lock is held for the whole download, so 64 slow downloads take every slot without using the CPU, the same reason given for raising the flight cap. Perf review 5 #2 named `work.ex:6` alongside the flight cap; only the flight cap changed.

Wire test: HTTP source, output and originals caches. N requests for distinct originals on a slow origin are held open, then 8 requests for 8 widths of one more original (200 ms origin):

```
slow=0:   origin fetches for hot.png = 1
slow=63:  origin fetches for hot.png = 1
slow=64:  origin fetches for hot.png = 8
slow=100: origin fetches for hot.png = 8
```

All requests answered 200.

**Effect.** In bursts of cold originals (a restart, a purge, a page of new thumbnails on a slow origin), each variant downloads the original itself and tries to store it in the originals cache, and revalidations of a stale original stop sharing one conditional request. This is when coalescing saves the most.

**Suggested fix.** Give the source locks a cap of their own, as b271826 did for download flights (a lock costs a map entry and a monitor), for example 4,096, keeping the 1,024-waiter limit. Test: the wire test above, expecting one fetch at 64 and 100 slow downloads.

---

## Lower confidence, not counted

- **A record recalled from the originals cache can come back after an invalidation (by reading).** `recall/2` (`source_cache.ex:41-47`) reads the record from disk, then puts it with `put_new`. `invalidate/2` (`:462-465`) deletes the disk entry, then the memory row. A request that read the disk record just before the delete and puts it just after puts the invalidated record back. It's the same stale record the invalidating request saw, so the next request validates again; it only matters inside a `stale-while-revalidate` window. Deleting the memory row before the disk entry, or not putting back a record when the key was deleted meanwhile, would close it.
- **The memo skips the metadata read but not its validation (by reading).** A memo hit still runs `FileSystem.decode_entry/2` (`cache/file_system.ex:101-117`): shape checks, `Entry.cacheable_headers/1`, `DateTime.from_iso8601/1` and a rebuilt `Info`, for metadata that already passed them when it was remembered. Remembering the decoded `%Entry{}` fields instead would save that per hit. It's a perf note, not measured.

## Checked and found sound

- **Metadata memo (4cfda5f):** every path that changes an entry's files goes through Admission and forgets it afterwards (commit, admission and reconcile evictions, delete, record refresh, sweep). The epoch check catches a fill that read before a change and inserted after it, including across an Admission restart (all epochs move before the new table exists). A remembered body that won't open falls back to disk. The body filename carries the digest, so a remembered path never names other bytes. A memo hit still counts a sighting.
- **Recency table (48c81ac):** the sampled LRU evicts unused rows. A missing table reads as empty and skips writes. `put_new` doesn't evict when the key exists.
- **Writes without a writer (ac20d18):** a `{:memory, {:invalidate, fun}}` reaches the invalidation clause of `run/4`, and the lease stays with the request, released when its acquisition returns, as before for instances without a cache root.
- **Download flights (b271826):** the monitor index is kept in step on join, transfer, removal and DOWN; promotion skips expired waiters; a deadline after transfer releases the waiters.
- **Cache writes (02a9ae2):** the partition is created only on `:enoent` and the open retried; a failed link with a missing source still fails; only a linked body's temp is deleted after the rename.
- **Origin pool size (a1d9806):** it's part of the pool's name hash for pinned and unpinned pools, so sources with different sizes don't share a pool; `pool_timeout` stays a request option.
- **Record size:** about 1.1 KB per record in ETS with S3-like headers (1.4 KB with seven headers), in line with the documented 1 KB.
