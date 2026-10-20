# Bug hunt 6: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources, source coordination (source lock, download flight, overlapped processing, spooling), the in-memory records of originals, and the FileSystem caches (admission, sketch, sweep, `cache_stats/1`). Read on `main` at `fe70ecc` (after #1019). Paths are relative to `image_pipe/`.

**How this was checked.** *Confirmed* means reproduced with a throwaway ExUnit test (not committed). *By reading* means it wasn't run. Most of the 158 commits since hunt 5 touch this area, so the hunt concentrated on what changed: records kept in memory (0784b6b), admission deciding before the sync (4141c02, 6865070), the packed 4-bit sketch and raw admission rows (7ab9d67, d127233, effeacf), DNS refresh (ef18752), batched spool writes (31c07b6), the overlapped encode continuation (bfaf924), the file-source open skip (770b5ba), and the S3 refresh backoff (81a0a82).

**Dedupe.** Checked against `bug-hunt-4/` and `bug-hunt-5/sources-and-caching.md`, the earlier hunts' section titles, and the beads synced from DoltHub in this session (last update 2026-10-20 19:23 UTC), including the closed `image_plug-zi90` that led to #1019 and the open `image_plug-lz1o`.

**Hunt 5 findings, as of `fe70ecc`:**
- Fixed: #1 (lock left held after a waiter timed out; 0eecc91, then 1936b96 for a cancel that itself times out), #2 (origin missing a field crashed instead of missing; 77527dd), #3 (receive timeout evicted the shared DNS answer; ef18752 re-resolves without evicting), #4 (stale-record request counted twice; 07bfb6f), #5 (`cache_stats/1` could exit the caller; 0559862).
- Fixed as reported, status kept: #6. An unresolvable host now has its own reason, `:unresolved_host` (4ad8067), and still answers 404, as documented in `source/http.ex:195`.
- Documented instead of changed: #9 (comment corrected in fa4c699; `@join_within` stays).
- Moot: #8. 0784b6b removed source-record commits to the output cache altogether.
- Still open: #7 (download waiters released only after the leader joins the image flight; bead `image_plug-lz1o`, code unchanged at `execution.ex:490-492`), and the residual under #5: `complete_scan/1` (`admission.ex:432-436`) still doesn't call `reconcile_if_over_cap/1`.
- Lower-confidence items from hunt 5, all fixed: attempts started with almost no time left (44a4044), S3 refresh every 5 s inside the margin (81a0a82), watermark task exit skipping the release (14b7764), sweep reading metadata two or three times (6d6c933).

Counts: 1 high, 3 low.

---

## 1. After a restart, or past 10 000 originals, a cached image needs its original downloaded again

- **Severity:** high (regression in #1019: origin traffic and latency, not wrong output)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache.ex:133-175` (`source_record/2`, `record_store/1`, `remember_source/3`), `lib/image_pipe/execution/source_cache.ex:31-36` (`lookup/3`), `lib/image_pipe/execution.ex:143-150` (`byte_identity/1`), `:176-206` (`prepare_remote/1`, `resolve_record/2`), `:214-225` (`join_download/1`), `lib/image_pipe/source/record.ex:15-23`, `lib/image_pipe/config.ex:413-425` (`max_remembered_originals`)

**Evidence.** An HTTP or S3 source that isn't `stable` (the default) is identified by its content: `Record.new/4` sets the byte identity to `{:source_sha256, digest}`, and `byte_identity/1` builds the cache key and the ETag from the record. Without a record, the request can't name the cached image, so `resolve_record/2` finds nothing and `join_download/1` fetches the original in full (no validator, since there's no record to take one from), hashes it, and only then looks the image up in the output cache.

Before #1019 the record lived in the output cache, on disk, so it survived a restart and was bounded by the cache's bytes. Now it lives only in the instance's ETS table, capped at `max_remembered_originals` (10 000, random eviction), and the only fallback is the originals cache (`Input.metadata/2`), which is off by default.

Repro 1 (output cache only, origin answers `Cache-Control: public, max-age=3600`): one request, a second one that the origin doesn't see, then a restart of the instance and the same request again:

```
after restart, origin hit with if-none-match: []
```

That is a full GET for an image whose original is still fresh and whose output is still cached. Before #1019 the fresh record would have been read from the output cache and the origin not contacted (by reading the parent commit).

Repro 2 (same origin, `max_remembered_originals: 2`, three originals, all outputs cached and fresh): 9 requests, 6 full origin downloads.

```
origin fetches over 9 requests for 3 fresh, cached outputs: 6
```

**Effect.** For a deployment with HTTP or S3 sources and an output cache but no originals cache:
- Every restart or deploy turns the first request for each image into a full origin download, even though the processed image is on disk. A container platform that restarts often pays this every time.
- With more than 10 000 originals in use, most requests whose record was evicted download the original again, in steady state, even with a large output cache. The output cache then saves the processing but not the origin traffic or the download latency.
- The conditional-GET fast path is gone in the same cases: the ETag comes from the record, so a CDN's revalidation (`If-None-Match`) can't get a `304` before the original is downloaded.
- Watermark assets go through the same lookup (`execution/watermarks.ex:175`), so each one is downloaded again too.

The docs and changelog (`docs/caching-and-freshness.md:128-134`, `CHANGELOG.md`) mention only that a local file is hashed again after a restart. They don't say that an origin image is downloaded again.

**Suggested fix.** Options, roughly in order of how much they keep from #1019:
1. Keep memory as the first tier, and on a miss fall back to a persisted copy that doesn't compete with images: for example, write records into the output cache's root as small metadata-only files outside Admission (or exempt from eviction), read only on a memory miss.
2. Keep the old source-index entries in the output cache, but score them for what a miss costs (a re-download for an origin, a re-hash for a file) rather than by frequency alone, so they don't lose to popular images in bursts (the problem `image_plug-zi90` found).
3. At least size the default from the output cache (its entry count, not a fixed 10 000) and document the re-download for origin images.

Test: the two repros above, as wire tests counting origin requests across an instance restart and across a working set larger than the limit.

**Open question for Håvard:** does the Bunny deployment run an originals cache (`[cache] input`)? If not, every redeploy currently costs one full download per active image.

---

## 2. A record read from the originals cache is never put back in memory

- **Severity:** low (a disk read per request instead of an ETS lookup)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/execution/source_cache.ex:31-36` (`lookup/3`), `:333-340` (`publication({:not_modified, _}, ...)`), `:380-398` (`store/7`), `:421-427` (`unchanged_record?/4`)

**Evidence.** On a memory miss, `lookup/3` takes the record from the originals cache's metadata. For an origin that must be validated on every use (`no-cache`, or no lifetime), a `304` gives a record that `unchanged_record?/4` treats as unchanged, so no write is planned and `remember_source/3` never runs. The memory table stays empty for that source, and every later request reads and decodes the metadata file again.

Repro (output and originals caches, origin answers `no-cache` with an ETag and `304` to a matching `If-None-Match`): one request, a restart, then three requests:

```
records before restart: 1
records after 3 requests post-restart: 0
origin requests: [[], ["\"v1\""], ["\"v1\""], ["\"v1\""]]
```

The revalidations are expected; the empty table is not.

**Effect.** After each restart, each such source costs a metadata read and `binary_to_term` from the originals cache on every request, for as long as the node runs. It's slower only on slow storage, but that is where the originals cache is most likely (network volumes).

**Suggested fix.** In `lookup/3`, put a record found in the originals cache into memory (`SourceRecords.put/4`), or make `unchanged_record?/4` compare against where the record came from and still remember it in memory when it came from disk. Test: the repro above, expecting one record after the first post-restart request.

---

## 3. The docs still say the output cache holds a small entry for each original

- **Severity:** low (docs)
- **Confidence:** by reading
- **Where:** `lib/image_pipe.ex:359-361` (`cache_stats/1` doc), `docs/cache.md:414-415`, `../image_pipe_server/docs/server-deployment.md:284-285`, `docs/telemetry-events.md:502`

**Evidence.** 4231456 documented that `:entries` and `:bytes` of the output cache count "one small entry for each original that processed images were made from". 0784b6b, a few hours later, moved those records to memory, so new ones are never written. `telemetry-events.md:502` still says `:estimated_cost_us` is "not on source records", which no longer exist as cache writes.

**Effect.** Operators reading `/stats` or `cache_stats/1` are told about entries that new nodes never write. Entries an older version left are evicted in time, as the changelog says.

**Suggested fix.** Remove the three "also counts one small entry" bullets and the "and not on source records" clause.

---

## 4. Every processed image still stores and checks a record that nothing reads

- **Severity:** low (wasted bytes and decode work per hit; a spurious miss in one case)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/execution.ex:570`, `:668` (session and facts carry `source_record`), `lib/image_pipe/cache/sink.ex:61,79,142`, `lib/image_pipe/cache/file_system.ex:103-117` (`decode_entry/2`), `lib/image_pipe/cache/entry.ex:18,39-46`

**Evidence.** Each output entry's metadata carries the full `Source.Record` (the origin's response headers, about 1 KB), and each hit decodes it and runs `Entry.validate_source_record/1`. The resulting `%Entry{source_record: ...}` field is never read: no caller in `lib/` uses it. Records are looked up by input key, never through an output entry, and the entry can't be found without the record in the first place.

**Effect.** About 1 KB more metadata per stored image to write, read and decode on every hit. And an entry whose stored record no longer passes `Record.valid?/1` (an `Origin` shape change under the same `@metadata_version`, as in hunt 5 #2) is treated as a corrupt entry and missed, although the image itself is fine.

**Suggested fix.** Stop putting `source_record` into output entries' metadata and drop the check and the field from `Entry`; the originals cache (`Cache.Input`) keeps its own. Old entries that still carry it decode fine if the key is ignored.

---

## Lower confidence, not counted

- **An overlapped encode can inherit a deadline that ran out while it waited for another request's image (by reading).** Since bfaf924 the encode after an overlapped decode continues the decode turn's deadline (`execution.ex:579-584`, `processing_pool.ex:309-311`). Between the two, `join_output/3` can wait up to 60 s behind another request's flight for the same image (`execution.ex:490-503`). If that flight ends with `:bypass` (not stored), this request encodes with a deadline that may already have passed and fails with `{:processing, :timeout}`, with an idle pool. It needs the race in hunt 5 #7 (`image_plug-lz1o`), so it is rare; fixing that bead would also close this. Otherwise, take a fresh turn when the continuation's deadline has passed before it queues.
- **Random eviction of remembered originals is biased (by reading).** `SourceRecords.evict/1` picks `:ets.slot(table, rand(size) - 1)`. A set table usually has more hash slots than records, so records in slots at or past `size` are evicted only through the `:ets.first/1` fallback. Harmless at the default limit, but "a random one is forgotten" isn't quite what happens.

## Checked and found sound

- **Admission decide/commit split:** a timed-out `decide` is skipped by deadline and emits nothing; a write admitted at `decide` whose victims another commit already evicted is resampled and gated again in `room/4`; the own-key exclusion and pending-byte accounting (`held`) match the old single call; a rejected linked sink only removes its own hard link; `[:cache, :admission]` documents that an admitted write can still go unstored.
- **Sketch:** 4-bit counters can't carry (increments stop at 15), the halving mask clears each nibble's top bit after the shift, conservative update touches only the minimum counters, and only Admission writes.
- **Raw admission rows:** every key and body hash reaching `raw/1` is a validated lowercase hex digest (request keys, parsed body filenames, `@meta`/`@body`-matched sweep names), so `Base.decode16!/2` can't raise from disk data.
- **DNS refresh:** a refresh replaces the cached answer only when it changed or expired, a failed refresh leaves it, and a dead cache server falls back to the direct answer.
- **Batched spool writes:** batching applies only while no decode reads the file (`Overlap.reading?/1`), the last batch is flushed before the size check, and a failed write falls back to the buffer with the bytes already on disk.
- **File source open skip:** a matching stat implies unchanged mode, owner and ACLs (ctime), and losing search permission on a parent fails the stat itself.
- **S3 refresh backoff:** inside the margin the timer is half the remaining life with the 5 s floor; an expired value is still fetched on the next `get/2`.
- **Source lock:** `wait_response/2` plus `cancel_wait` releases a grant made before or during the cancel, including one made after the cancel call itself timed out (`granted_to`), and a lease handed to a writer isn't released by it.
- **`max_remembered_originals` config:** rejected per call and without an instance, kept across `override/2`, and passed through by the server's `[cache]` section with or without caches.
