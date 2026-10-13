# Bug hunt 4: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources, source coordination and staging, the input and output FileSystem caches (admission, sweep, writers), and cache identity. Read on `main` at `db4fe3c`. Paths are relative to `image_pipe/`.

**How this was checked.** Every finding was read in the code. *Confirmed* means it was reproduced with a throwaway ExUnit test (not committed) and the output is quoted. *By reading* means it wasn't run.

**Dedupe.** Checked against the earlier `bug-hunt*/sources-and-caching.md` reports, `memory-leak-hunt/report.md`, `perf-review*/`, and the pushed beads. The pushed beads (`refs/dolt/data`) were last updated on 2026-10-05, so anything filed from hunt 3 locally since then isn't visible here.

**Earlier findings, as of `db4fe3c`:**
- Fixed: hunt 3 #1 (watermark storage policy, `Execution.storable?/1` now checks every watermark), hunt 3 #2 (function digests, `MaterialDigest.canonicalize/1`), hunt 1 #4 / hunt 3 #5 (Vary on headers Req adds; conditional headers are now a Req step), hunt 1 #5 / hunt 3 #6 (timeouts before headers now map to `:receive_timeout`).
- Partly fixed: hunt 3 #8. The staging directory is now made `0700` and owner-checked (`Input.private_dir/1`), and staged files are `chmod 0600`. It is still under `System.tmp_dir!()`; see the answer below.
- By design: hunt 3 #3 (rotating HTTP auth). Bead `image_plug-e4a.3.11` was closed as intended.
- Not rechecked: hunt 3 #4, #7, #9.

Counts: 1 high, 6 medium, 4 low.

---

## Answer to the memory hunt's open question: are staged originals in /tmp always deleted?

Yes, on every path traced, so staging can't explain growth that keeps rising.

- A staged original is tracked by `Cache.Resources` against the process that staged it (`source_cache.ex:436-483`, `resources.ex`). It is deleted when the request releases its lease (`Execution.with_prepared/6` closes the context in an `after`, `close_output/1` releases the extra lease in an `after`, and the error paths in `attach_lease/2`, `generate_leased/2` and `watermarks/2` release too), or when the owning process dies (`Resources` handles `:DOWN` with `File.rm`).
- A writer that stores the original into the input cache gets its own hard link (`Input.pin/1`), transferred to the writer and removed in the writer's `finish`, which runs on publish, cancel, `EXIT` and the 30 s max age (`publication.ex:200-226`). The bytes it holds are capped by the pending limit (`Writers`, `min(256 MB, max_size_bytes / 20)` per root).
- Watermark assets are read into memory inside their task, and the lease is released in an `after` (`watermarks.ex:236-241`).
- Files left by a VM that died are removed by the staging sweep at boot and every 24 h after, once they are an hour old (`application.ex:32`, `sweep.ex:16,57`).

So staging in `/tmp` costs about (concurrent misses × original size) plus the writers' pending bytes, and drops back when traffic does. If the container's memory kept rising rather than tracking load, the cause is elsewhere; a cache `root` on `/tmp` is still the likeliest. **Open question for Håvard:** which paths were the cache roots on Bunny? If they were on `/tmp`, that explains the growth by itself.

One edge case: the owner of a staged file is the request process. Under HTTP/1.1 keep-alive that is the connection process, so a release path that is skipped without a raise would keep the file until the connection closes. I found no such path; the note is for whoever changes these paths next.

---

## 1. When Finch's pool checkout times out, the fetching process is killed instead of getting an error

- **Severity:** high
- **Confidence:** confirmed (the Plug-level 500 is by reading)
- **Where:** `lib/image_pipe/source/req_stream.ex:177-181` (`send_request`), `:350-362` (`into: :self`); `deps/finch/lib/finch/http1/pool.ex:99-118` (Finch 0.24.0)

**Evidence.** With `into: :self`, Req calls `Finch.async_request`, which runs the pool checkout in a process started with `spawn_link`. When the checkout times out, Finch raises a `RuntimeError` in that linked process. The caller gets an exit signal, which `rescue exception in Finch.Error` in `send_request/1` can't catch. Repro: an origin that accepts connections and never answers, `pool_timeout: 300`, and 60 concurrent `HTTP.fetch/3` calls in monitored processes:

```
exit reasons: %{:normal => 50, %RuntimeError{message: "Finch was unable to provide a connection within the timeout due to excess queuing..."} => 10}
returned: %{{:error, {:source, :receive_timeout}} => 50}
```

**Effect.** Past Finch's default pool size of 50 (which ImagePipe doesn't let hosts change), concurrent fetches to one pinned pool kill the request process instead of returning `{:source, _}`. Source fetches run before a `ProcessingPool` slot is taken, so the processing concurrency limit doesn't bound them. A slow origin under load therefore crashes requests, including coalescing leaders whose waiters then retry. S3 goes through the same `ReqStream` path.

**Suggested fix.** Run the request phase in a monitored process (or trap exits around it) and map the exit to a source error such as `:pool_timeout` (503 or 504). Optionally make the pool size configurable and bound concurrent fetches per pool. Test: the repro above expects every caller to return an error tuple. The linked raise in Finch may be worth an upstream note.

---

## 2. Admission forgets an entry that was committed again after a sweep removed its old metadata

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/file_system/admission.ex:253-264` (`forget_swept({key_hash, :meta}, state)`), `sweep.ex:31-38,84-95`, `admission.ex:152-153`

**Evidence.** The sweep deletes files during its walk but reports the `removed` list to Admission in one cast at the end. For a `{K, body}` item Admission checks the body filename against the tracked entry; for a `{K, :meta}` item it forgets K without a check. If K is committed again between the sweep deleting its old metadata and Admission handling the cast, the new entry stops being counted. Repro: commit K (500 B), corrupt its meta and age it 2 h, run `Sweep.sweep_root/1`, commit K again (700 B), then cast `{:swept, removed}`:

```
removed: [{"86be…", "86be….500.0.body"}, {"86be…", :meta}]
stored before report: 700
after report: %{stored_bytes: 0, tracked_k: false, get: :hit,
  on_disk: ["86be….da5e….700.0.body", "86be….meta"]}
```

This happens in practice after an upgrade that changes the metadata format: every meta older than an hour is unreadable, the sweep removes them across the tree, and traffic re-renders those keys during the walk.

**Effect.** A live entry is served but no longer counted or evictable (eviction samples only tracked entries), so disk use passes `max_size_bytes`. See finding 4 for why it never comes back down.

**Suggested fix.** Treat the `:meta` item like the body item: carry the removed meta's body filename and forget only when the tracked entry still names it, or check that the meta file is really gone before forgetting.

---

## 3. A commit or delete during the startup scan hides the key's on-disk entry from the scan even when it fails

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `admission.ex:296` (`note_scan_change` before `decide`), `:318` (delete), `:338` (the scan skips keys in `scan_changes`), `:400-422`

**Evidence.** The commit handler notes the key as changed whatever the outcome. On `{:reject, _}` or a failed publish, the key's existing entry stays on disk (as intended), but the scan batch now skips the key, so that entry is never counted. `put/2` and `forget/2` already note the change on success, so the early note only matters where it does harm. The delete handler does the same when `delete_entry` fails. Repro: entry K (500 B) on disk, restart Admission with a 1000 B cap, commit K with a 2000 B body during the scan:

```
%{commit_result: {:ok, :rejected}, tracked_k: false, stored_bytes: 0,
  on_disk: ["86be….500.0.body", "86be….meta"]}
```

The oversize body only forces the rejection; late in a real scan, `:score_too_low` rejections do the same. Related: a commit that *succeeds* during the scan for a key not yet scanned replaces it with `replaced = nil` (`:400-407,422`), so the old body isn't deleted. Repro: old 500 B body and new 300 B body both on disk, 300 counted. The sweep removes it only after the next periodic sweep (up to 24 h).

**Effect.** Valid entries are uncounted and never evicted until the next restart, and replaced bodies linger uncounted. Disk use goes over the cap.

**Suggested fix.** Drop the early `note_scan_change` in the commit and delete handlers and rely on `put`/`forget`, or undo it on the reject and error paths. In `finish_commit`, when `replaced` is nil and the scan is still running, delete the body the old meta named (the prepared paths are at hand).

---

## 4. Once over the cap, a bounded cache never drains back under it

- **Severity:** medium (amplifies findings 2 and 3)
- **Confidence:** confirmed
- **Where:** `admission.ex:243-249` (a hit on a stored but untracked key calls `put/2` without evicting), `:361-365` (`needed = min(stored + added - max, added)`)

**Evidence.** After the startup reconcile, each write frees at most the bytes it adds, so nothing brings the count back under the cap. Repro with a 1000 B cap: untrack K (400 B) with a stale `{:swept, [{K, :meta}]}`, fill to 900, then hit K:

```
stored after fill: 900
stored after hit: 1300
stored after 10 more writes (cap 1000): 1050   (35 admitted writes)
body bytes on disk: 1050
```

The same happens when the scan process crashes: `complete_scan` runs on `:DOWN` with only part of the tree counted, and later hits count the rest without evicting.

**Effect.** After any drift, the cache stays above `max_size_bytes` until restart, against the moduledoc's "stored bytes never pass the cap".

**Suggested fix.** When a hit's `put` takes the count over the cap, start a reconcile (`start_reconciliation/1`), or let `decide` cover the whole excess once the scan is complete.

---

## 5. Info output depends on `format`, but its cache key and ETag don't include it

- **Severity:** medium (needs `max_result_width`/`max_result_height` above 16383; the default is 8192)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/processing/terminal.ex:158-159` (`result_limits/2` clamps to the encoder limit of `request.output.format`), `lib/image_pipe/execution/identity.ex` (`representation_material(_, nil, _)` puts only `{:info, placeholders}` in identity)

**Evidence.** A mount with `max_result_width/height: 30_000` and a 100×10 source:
- `w=20000/enlarge/format=webp/output=info` returns `"width":16383`.
- `w=20000/enlarge/format=jpeg/output=info` returns `"width":20000`.
- Both carry the same ETag (`"ipr1-99tDiPPZ…"`). With an output cache, the jpeg request after the webp one is served the cached `"width":16383`.

**Effect.** Wrong info JSON from cache, and one strong validator for two different bodies. It also contradicts the existing test "image-only URL options do not change info", which treats `format` as inert for info.

**Suggested fix.** Either put the explicit format (or the limits it selects) into the info terminal identity, or drop `format` from info's `result_limits` so it really is inert. **Open question for Håvard:** should info report what an image request with the same `format` would produce (keep the clamp, key it), or the format-independent geometry (drop the clamp)? Add a wire test with raised result limits either way.

---

## 6. A corrupt stored watermark original is never checked, so every image using it fails with 415

- **Severity:** medium (needs on-disk corruption)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/execution.ex:531-537` (`finish/2`)

**Evidence.** On `{:decode, _}` or `:source_format_required`, `finish/2` runs `SourceCache.check/2` for the main source's input key only. A watermark decode failure also surfaces as `{:decode, _}`, but its own `input_key` is never verified. The existing test "a stored original whose bytes are corrupt is discarded after a decode failure", adapted to a named watermark with `max-age=600` and its stored `.body` zeroed (same size):

```
{30, 415, []}
{31, 415, []}
{32, 415, []}
```

Each variant failed and none refetched the watermark. The same corruption on the main original heals on the next request.

**Effect.** With an origin that sends validators, revalidation returns 304 and keeps the corrupt bytes, so the outage lasts until the entry is evicted, not just until the record expires.

**Suggested fix.** On a decode failure, also run `SourceCache.check/2` for each watermark with an `input_key`, or tag watermark decode errors with the asset so `finish/2` checks only that key.

---

## 7. Each resolved address gets its own full timeout, so a fetch can run several times past `fetch_timeout`

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/http/pinned_target.ex:27-44` (`connect/6`), `req_stream.ex:350-362,391-399`

**Evidence.** `connect/6` moves to the next address on any `%Req.TransportError{}` with `status: nil`, including `:timeout` while waiting for headers on a connection that was made, and `:closed`. `receive_timeout` and `pool_timeout` are computed once as `min(timeout, remaining)`, and each address gets the full value again without a deadline check. `ReqStream.request/5` can then repeat the whole set once on `:closed`/`:econnreset`. Repro: resolver returns 127.0.0.1, .2 and .3, `receive_timeout: 900`, `fetch_timeout: 1000`, origin accepts and stays silent:

```
{{:error, {:source, :receive_timeout}}, 2761}
```

The origin saw a connection on all three addresses.

**Effect.** The documented bound (the whole download, overrun only by `connect_timeout`) is exceeded about N times; dual-stack hosts are already N=2. Requests waiting on the leader give up at `fetch_timeout + 1 s` while it keeps going, and a slow origin receives the same GET up to 2N times.

**Suggested fix.** Fall through to the next address only on connection-establishment failures, and recompute the receive and pool timeouts from the remaining deadline per attempt, stopping once it has passed.

---

## 8. Other variants wait behind the leader's overlapped processing, not just its download, and get 504

- **Severity:** low to medium (large sources under load)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/execution/source_cache.ex` (`acquire_locked`/`open_or_fetch` run `fetch/7` inside `Work.run({:source, hash})`; `spool/5` runs `Overlap.with_session`, and `spool_file/4` calls `Overlap.finish/1`, which waits up to 60 s for the overlap task)

**Evidence.** On a first fetch of a source over 1 MB with a Content-Length, the overlap task waits for a processing-pool slot and runs `Processing.prepare_download`. The source lock is held through that queueing and preparation, while waiters get a budget sized for a download only (`fetch_timeout + 1_000`). Repro with `max_concurrency: 1`, the slot held by a blocker, and `fetch_timeout: 1_000`: request A (w=100) starts an overlapped fetch, request B (w=50, same source) waits on the lock, and the origin then finishes at once.

```
B: {504, "source timeout", 2006 ms}
A: 200 at 2838 ms, after the slot was freed
```

**Effect.** With defaults (30 s fetch, 10 s queue timeout), sibling variants fail with 504 once download + queue + preparation passes 31 s, and are serialized behind the leader's preparation short of that. This may be related to the overlap work in `overlap-415/` and bead `image_plug-6j4` (flaky `SourceOverlapWireTest`), but it's a different symptom.

**Suggested fix.** Publish the staging result and release the source lock once the download finishes, and await the overlap task outside `Work.run` (return the overlap state and finish it in `Execution`).

---

## 9. A raw URL-source query is never encoded, so a space or non-ASCII byte gives a 502 after DNS

- **Severity:** low
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/parser.ex:83,90` (the query is only checked for well-formed `%`), `lib/image_pipe/source/http.ex:530-536` (`build_url` appends it as is), `req_stream.ex:139` (`Req.HTTPError` becomes `:invalid_body`)

**Evidence.** The plain source `http://o.test:PORT/p?a b` (also `?é`, `?a"b`, `?a\r\nX:1`) returns `{:error, {:source, :invalid_body}}`, a 502 "incomplete source response". Mint rejects the request target, so there is no header injection. Path segments are encoded with `encode_path_segment`; the query isn't.

**Effect.** A client-input problem is reported as an origin failure, and only after DNS resolution and pool checkout, against the rule that parse failures return before side effects. URLs with non-ASCII in the query can't be fetched.

**Suggested fix.** Encode the query with the same byte-preserving escaper (keeping `%`, `&` and `=`), or reject it at parse time with `{:invalid_source, _}`.

---

## 10. A 304 on a first fetch crashes when `req_options` set a conditional header

- **Severity:** low (host misconfiguration)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/req_stream.ex:116-118,194-207`

**Evidence.** `revalidated/3` decides a 304 is expected by looking for `if-none-match`/`if-modified-since` on the outgoing request, and host `req_options` headers aren't stripped of these. With `previous = nil`, `not_modified/3` reads `previous.headers`. With `req_options: [headers: [{"if-none-match", "\"v1\""}]]` and an origin that answers 304:

```
** (BadMapError) expected a map, got: nil   (req_stream.ex:207)
```

**Effect.** A 500 instead of `{:source, :unexpected_not_modified}`. S3 `req_options` too.

**Suggested fix.** Handle `previous == nil` by returning `:unexpected_not_modified`, or drop `if-*` headers in `ReqSanitizer`.

---

## 11. Req's `range:` option gets past the byte-header stripping

- **Severity:** low (host misconfiguration that the docs say is handled)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/req_sanitizer.ex:20-24`; docs at `source/http.ex:79` and `source/s3.ex:65`

**Evidence.** `ReqSanitizer` filters only the `:headers` list, but Req's `put_range` step adds a `range` header from the `range:` option. With byte headers stripped and `req_options: [range: 0..9, headers: [{"range", "bytes=5-6"}]]`, the origin received `range: ["bytes=0-9"]`.

**Effect.** The 206 partial body is accepted as the whole original, so decodes are truncated or fail with 415, although the docs promise range is dropped.

**Suggested fix.** Drop `:range` (and arguably `:compressed`) from `req_options` when byte headers are stripped.

---

## Lower confidence, not counted

- **Pending writer bytes can leak after a forced kill (by reading).** If a `Writer` is killed after its 25 s shutdown timeout, `terminate/2` never marks it finished, and a request still streaming into that sink reserves bytes on the restarted `Writers` counters that nothing releases. It needs a Writers restart and a disk write hung for over 25 s, so realistically only a hung network mount.
- **A rejected source-record index write can shadow a newer record (by reading).** In `SourceCache.lookup/3`, the output cache's source-record index wins over input-cache metadata, and Admission can reject an overwrite of the index (cost-0 entries score by size only), leaving the older record. That costs repeated refetches or stale serving inside the stale-while-revalidate window. Bounded; mostly a performance concern.
- `:inet.getaddrs/2` has no caller timeout although a comment says it does, so DNS time counts toward the deadline but isn't cut off by it.

## Checked and found sound

- **Staging and pins:** see the answer above.
- **Representation key and ETag:** storage-only material (cachebuster, storage inputs, source and watermark partitions) stays out of the ETag; watermark identity, opacity and byte identity are in both.
- **Usage accounting with every key counted:** `decide` plus eviction before publish keeps the count at or under `max - pending`; replacement and repeated overwrites don't drift.
- **Readers versus eviction:** body before meta on eviction, replaced bodies removed only after the new meta is in place, names carry sha, size and cost, and sizes are checked, so a reader sees a miss, never wrong bytes.
- **Writer temp files:** cleaned on open, write, abort, rejection, prepare failure and Admission unavailability; the rest is left for the one-hour sweep.
- **`Cache.Work` and `OutputWork`:** locks, waiters, promotion, deadline bypass (not stored), and lease transfer to the coordinator and writer.
- **Owner and root claims:** takeover races, refused roots, writers stopping on a refused root, shutdown order.
- **Address policy and pinning:** IPv4-mapped, 6to4, NAT64 and short IPv4 forms; one pinned IP per hop; SNI on the logical name; Host header rebuilt; `allowed_hosts` port matching.
- **Redirects:** credentials stripped across origins, hop limits, URI normalization the same for the guard and Req.
- **Cache headers:** quoted commas, unterminated quotes, qualified `private`/`no-cache`, duplicate or invalid Age and Expires, all three HTTP date forms.
- **S3:** SigV4 encoding of unusual keys, `versionId` checks, dot segments, bucket allowlist, single-flight credential refresh and idle retirement.
- **File source:** traversal and symlink checks, size limit before read, same-second stat guard.
