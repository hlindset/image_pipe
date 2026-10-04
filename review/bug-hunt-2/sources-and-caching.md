# Bug hunt 2: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources, source records, the input and output filesystem caches, admission, and request coordination. Read on `main` at `b50bca8`.

**Branch `claude/project-thread-8jzkwh`.** Seven of its eight commits are already on `main` under new hashes: size-only hit checks with sendfile, admission indexing, unchanged source records, raw readability check, pinned Finch pools, option revalidation and the docs commit. Their bugs are listed below against `main` and tagged **[speedup]**. The one commit not on `main`, "Resolve IPv4 and IPv6 addresses concurrently", adds no new bug that I could find.

**How this was checked.** I read the code for every finding. Findings marked *confirmed* were reproduced with a throwaway ExUnit test (not committed); the output is quoted. *By reading* means the code path is unambiguous but I did not run it. *Suspected* means a test is needed before acting.

**Earlier findings.** Of the earlier report's issues, S3 credential rotation, the empty S3 revision, S3 dot segments and the watermark freshness merge are fixed on `main`. Nothing new to add on the others.

Counts: 0 high, 5 medium, 4 low.

---

## 1. Rotating HTTP `auth` changes cache partitions and ETags

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source.ex:224-228`, `lib/image_pipe/source/http.ex:431-434`, `lib/image_pipe/source/auth.ex:4-8`

**Evidence.** `HTTP.prepare_cache/3` resolves `req_options[:auth]` (a 0-arity fun, an MFA or `:netrc`) to its current value and stores it in `fetch[:prepared_req_options]`. `identity_fetch/3` keeps the *prepared* fetch for every adapter except S3, so the resolved credential goes into the fetch context. That context feeds `Representation.input_key` (the source partition, which is also in the output key's `storage_only`) and, for immutable HTTP sources, the strong byte identity `{seed, MaterialDigest.of(context)}`. The fix for S3 rotation (earlier finding #1) was S3-only.

A repro with `auth: fn -> {:bearer, "token-#{n}"} end` and `stable: :immutable`, calling `Source.prepare_cache_context/2` twice:

```
byte identity equal?, fetch context equal?: {false, false}
```

**Effect.** Each token rotation misses every cached original and processed image for that source. For immutable sources the ETag also changes, so clients and CDNs re-download identical bytes. That breaks the AGENTS.md rule that the ETag tracks byte identity only.

**Suggested fix.** Use `source.fetch` (the configured, unresolved options) for HTTP's identity as well, as S3 does. The fun or MFA itself is already in `opts`, so two differently configured sources still stay apart. Add the same rotating-auth test as a regression test.

---

## 2. Unbounded caches never delete a replaced body, and source records leak one file per refresh

- **Severity:** medium
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/file_system/store.ex:313-322` and `704-710`, `lib/image_pipe/cache.ex:125-135`

**Evidence.** Bodies are content-addressed (`<key>.<sha256>.body`). In unbounded mode, `legacy_commit/1` renames the new body into place and then replaces the `.meta`. Nothing deletes the previous body when its SHA differs. Bounded mode handles this case: `same_key_replace/3` emits a body-only victim.

The same key gets new bytes all the time. `Cache.remember_source/3` stores the source record as a cache entry whose body is `term_to_binary(record)`, and the record holds `received_at` and origin times. Every revalidation that stores a record therefore writes a new body for the same key. Records with remaining freshness are always stored, per `unchanged_record?/4`.

A repro committing two bodies under one key with `root:` only:

```
body files for one key: 2
```

**Effect.** With no `max_size_bytes`, each refresh of a revalidated source leaves an orphaned body file behind, one per source per refresh, forever. Nothing reclaims them: no scan, no `.meta` points at them, and the cache has no size accounting.

**Suggested fix.** In `legacy_commit`, read the old metadata before the meta rename. After the new meta is in place, delete the old body if its filename differs. Test: commit two different bodies under one key and assert one `.body` file remains.

---

## 3. [speedup] Cache hits trust size alone, and writes are never fsynced

- **Severity:** medium
- **Confidence:** by reading (crash behaviour not reproduced)
- **Where:** `lib/image_pipe/cache/file.ex:197-216`, `lib/image_pipe/cache/file_system/store.ex:695-716`, `lib/image_pipe/cache/input.ex:108-115`

**Evidence.** Hits now check only that the body file's size matches `body_byte_size`. The comment says this "catches truncation". But no write path calls `:file.sync/1` or `:file.datasync/1` before renaming: not the body, not the `.meta`, not the directory. After a power loss or kernel crash, ext4 (`data=writeback`), XFS and others can leave a renamed file at its full length with zero-filled or stale blocks. The size check passes such a file.

The input cache is affected too. `Input.open` pins the body when the stored record's `byte_identity` matches, so the decoder reads the original without any content check. A corrupted original then produces a wrong processed image, which is cached under a key derived from the *correct* identity.

**Effect.** After an unclean shutdown, corrupted entries can be served indefinitely with a strong ETag, and only manual purging removes them. Before the speedup, the SHA-256 check rejected them as invalid metadata.

**Suggested fix.** Pick one:
- `:file.datasync` the temp body (and meta) before the rename. This costs one fsync per write.
- Verify the SHA lazily, on the first hit after boot. For example, the startup scan can mark entries unverified, and the first hit hashes them.

At minimum, change the comment and docs so they don't promise integrity the check can't give.

---

## 4. No overall deadline on a source download, and coordinated waiters wait forever

- **Severity:** medium
- **Confidence:** by reading
- **Where:** `lib/image_pipe/source/req_stream.ex:254-260`, `lib/image_pipe/cache/work.ex:14-24`, `lib/image_pipe/execution/source_cache.ex:43-62` and `64-78`

**Evidence.** `receive_timeout` applies only between body messages (`next_message/2`). An origin that sends a small chunk just inside each timeout can stretch one download to `max_body_bytes / chunk × receive_timeout`. Staging runs in the request process during `prepare`, before `ProcessingPool`, so `processing_timeout` doesn't cover it. Meanwhile `Work.run/3` holds the per-source lock, and every other request for that source waits on `GenServer.call({:lock, key}, :infinity)`.

**Effect.** One slow or misbehaving origin (or a slow network path) pins the leader and up to 1,024 waiting request processes for as long as it keeps trickling. Each waiter holds a connection. Allowed origins are semi-trusted, but a CDN or object store in a degraded state can behave like this.

**Suggested fix.** Add a total fetch deadline, as a source option or derived from `receive_timeout`. Check it in `stream_response/1` and raise `StreamError` with `:receive_timeout` once it passes. Give `Work.run` waiters a bounded wait that falls back to the uncoordinated path. Test: a Bandit plug that sends 1 byte every 50 ms with `receive_timeout: 100` should fail within the deadline.

---

## 5. A request-specific `{:decode, _}` error throws away the shared cached original

- **Severity:** medium
- **Confidence:** suspected (needs a test with a failing ICC transform or allocation)
- **Where:** `lib/image_pipe/execution.ex:497-505`, `lib/image_pipe/output/encoder.ex:224-232`, `293-296`, `345-363`, `lib/image_pipe/transform/executor.ex:793`

**Evidence.** `Execution.finish/2` calls `SourceCache.invalidate/2` for any `{:error, {:decode, _}}`. That deletes the input-cache original and overwrites the source record with `nil`. Several failures carry the `:decode` tag but depend on the request rather than the source:
- `icc_transform`/`icc_export` failures for the requested output profile (encoder 293-296 and 345-363);
- `copy_memory` in `finalize/3` on the *output* pipeline (encoder 224-232);
- input colour-management errors (executor 793).

**Effect.** If one variant fails this way, for example an output profile that libvips can't apply to a given source, or an allocation failure on a very large output, the original that every other variant shares is discarded. The next request for any variant then makes a full origin fetch with no validators. A client repeating the failing variant turns each request into an origin download, which amplifies load on the origin.

**Suggested fix.** Invalidate only for failures that point at the stored bytes: open/header failures and `:source_format_required`. Tag encoder and colour-conversion failures separately (they would still answer 415), or pass a flag. Test: make the output ICC transform fail, then check that a second, different variant is served from the input cache with no new origin request.

---

## 6. Past 64 concurrent source misses, fetches stop writing to the caches

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/cache/work.ex:6-7` and `74-86`, `lib/image_pipe/execution/source_cache.ex:47-50`, `89-90`, `129-139`

**Evidence.** `Work` replies `:busy` once 64 distinct sources are locked or 1,024 waiters are queued. The `false` branch then drops `:cache` and `:input_cache` from the config, and `publish_coordinated` also publishes without caches. So the fetched original isn't stored in the input cache, and its source record isn't stored either. Reads aren't affected: the previous record was already read in `prepare_remote`.

**Effect.** Under a burst, such as a page with more than 64 uncached images or a cache warm-up, the overflow fetches never populate the caches, so they miss again on the next request. The uncoordinated fallback was presumably meant to skip only the lock, not the caching.

**Suggested fix.** On `:busy`, keep the caches. Writes are atomic renames and admission is serialized, so the worst case is a duplicate write. Or raise the key limit to match the processing pool size. Test: lock 64 keys, fetch a 65th source, and assert its original and record are stored.

---

## 7. [speedup] Sendfile reopens the body by path, so an eviction race aborts the response

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/response/sender.ex:136-150`, `deps/bandit/lib/bandit/adapter.ex:158`

**Evidence.** The hit path opens the body, checks its size and keeps the descriptor open. `send_body/2` then calls `Plug.Conn.send_file(conn, 200, file.path, 0, file.size)`, which reopens the file *by path*. If bounded eviction, reconciliation or `Admission.delete` unlinks the body in between, Bandit's `{:ok, fileinfo} = :file.read_file_info(path, ...)` raises a `MatchError` before any headers go out. That is not `client_gone?`, so it becomes `:processing_error` and the connection is aborted. The open descriptor would still have read the unlinked file; the old streaming path did that.

**Effect.** Under eviction pressure, a client occasionally gets a dropped connection or 500 on a cache hit instead of the image. The comment at line 136 acknowledges it, but it is a regression from the fd-based read.

**Suggested fix.** When `send_file` raises before the response starts (`conn.state == :unset`), fall back to streaming `CacheFile.stream/1` from the open descriptor with `send_chunked`, or with `send_resp` for small bodies. Test: open a hit, delete the body file, then deliver; expect 200 with the full body.

---

## 8. URL sources re-encode reserved characters in the path

- **Severity:** low
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/source/http.ex:456-460`, `lib/image_pipe/source/parser.ex` (`url_path_segments/1`)

**Evidence.** The parser percent-decodes each path segment, and `build_url/1` re-encodes everything except RFC 3986 unreserved characters. Sub-delimiters that were literal in the source URL (`, + = ; : @ ! $ & ' ( ) *`) reach the origin percent-encoded:

```
https://h.example/w_100,h_100/a+b=c.jpg  ->  https://h.example/w_100%2Ch_100/a%2Bb%3Dc.jpg
```

RFC 3986 doesn't treat these forms as equivalent. Origins whose paths carry signatures or tokens (CDN path tokens, `s--sig--` segments) compare the raw path and will reject the request. S3 website endpoints read `+` and `%2B` differently.

**Suggested fix.** Re-encode with a predicate that keeps sub-delimiters, `:` and `@` (the RFC `pchar` set), so only bytes that can't appear raw in a path are escaped. Test: the URL above round-trips unchanged.

---

## 9. Temp files and pinned hard links survive a crash, with no sweep

- **Severity:** low
- **Confidence:** by reading
- **Where:** `lib/image_pipe/cache/resources.ex`, `lib/image_pipe/cache/input.ex:117-141`, `lib/image_pipe/execution/source_cache.ex:270`, `lib/image_pipe/cache/file_system/store.ex:919-922`, `lib/image_pipe/cache/file_system/admission.ex:921`

**Evidence.** Four kinds of temp files are cleaned up only by their owner, or by `Resources` when the owning process goes down:
- staged originals (`.image-pipe-*.tmp` in `System.tmp_dir!()`);
- input-cache pins (`.image-pipe-*.tmp` hard links inside the cache partition directories);
- sink temps (`.<hash>.<rand>.tmp`);
- admission state temps (`*.state.tmp.N`).

On a VM crash, OOM kill or `kill -9`, the files remain. Nothing removes them at boot: the startup scan reads only `*.meta`. A leftover pin is a hard link, so it also keeps an evicted body's inode, and its disk space, alive.

**Effect.** Disk usage that bounded accounting can't see grows with each unclean restart. For input caches holding large originals, a few crashes during busy periods can add up to gigabytes.

**Suggested fix.** At startup, have the admission scan (or `Cache.Input` init) delete `.image-pipe-*.tmp`, `.*.tmp` and stale `*.state.tmp.*` files older than a grace period in each pool root. Delete staged temps in `tmp_dir` the same way, or stage them under a per-instance directory that is cleared at boot.
