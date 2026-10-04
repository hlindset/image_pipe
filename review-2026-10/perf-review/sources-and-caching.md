# Performance review: sources and caching

Repo `hlindset/image_pipe` at `84eeac2`. All paths are relative to `image_pipe/lib/image_pipe/`.

Elixir isn't installed in this environment, so nothing here was benchmarked. Each item comes from reading the code. The top items were re-checked by hand. Line numbers are approximate.

## Tier 1: likely large wins

### 1. Admission lookups scan whole ETS tables on every cache hit
- **Where:** `cache/file_system/admission.ex:677`, `:755`, `:846`
- **Now:** the queues are `:ordered_set` tables keyed `{pos, hash}`. Lookups by hash use `:ets.match_object(table, {{:_, hash}, :_})`, which walks the entire table. A single hit cast runs `locate` twice across three tables, so up to six full scans happen inside the one Admission GenServer. Source-record lookups count as hits too.
- **Fix:** add a `:set` index `hash -> {queue, pos}` and pass the located result through to `promote_on_hit`.
- **Impact:** each hit goes from O(N) to O(1). With around 100k entries, every scan takes milliseconds. Under a few hundred hits per second the mailbox grows, commits pass the 5 s call timeout, and writes are dropped as `:admission_unavailable`. The boot directory scan has the same problem and runs O(N²) (`admission.ex:305-347`, `:450`, `:540-556`, where each `.meta` file is also read twice).

### 2. Local-file mounts rewrite a cache entry on every request
- **Where:** `execution/source_cache.ex:146-150`, `:194-199`, and `cache.ex:125-135`
- **Now:** the defaults (`verify: :stat`, origin freshness 0) make every request revalidate. The revalidation returns `:not_modified`, but `remember/4` still runs `Input.refresh` plus `Cache.remember_source`. That is a full output-pool entry write: mkdir, exclusive temp body, temp metadata, two renames, and in bounded mode an `Admission.commit` call. It happens even when the processed result is already cached.
- **Fix:** skip the write when only `received_at` changed and the record still can't become fresh or stale.
- **Impact:** roughly 6–8 filesystem metadata operations and one Admission call saved per request. The per-key `Work` lock makes concurrent requests for one popular file do this one after another (`cache/work.ex:14-24`). An output miss on a file source also fetches and remembers twice (`execution.ex:297-315`, `source_cache.ex:242`).

### 3. Every cache hit reads and SHA-256-hashes the whole body, then reads it again to send it
- **Where:** `cache/file.ex:10-36` and `response/sender.ex:135-158`
- **Now:** the body is fully hashed before the headers go out, then streamed through the BEAM in 64 KB chunks. HEAD and 304-after-stale responses pay for verification too. Bodies are content-addressed and never rewritten, so the per-hit hash only guards against disk corruption.
- **Fix:** verify at write time. On a hit, check size against the metadata and deliver with `Plug.Conn.send_file` (sendfile, zero copy). Don't open the body for HEAD or 304. If integrity checking should stay, keep it sampled or opt-in.
- **Impact:** removes one full read and hash per hit, about 1–2 ms of CPU per MB. Input-cache hits do the same before decode, about 5–15 ms on a 10 MB original (`cache/input.ex:91-104`).

### 4. S3 temporary-credential rotation invalidates cached results and ETags (needs a design decision)
- **Where:** `source/s3.ex:281-286` and `source.ex:191-217`
- **Now:** `prepare_cache` freezes the current credentials into the fetch options. Those are digested into both `input_key` and the strong ETag. STS, instance-role and web-identity credentials rotate roughly hourly, and each rotation turns every cached original and result for that bucket into a miss and changes every ETag, so clients download everything again. HTTP `auth:` given as a fun or MFA behaves the same way.
- **Fix:** partition by provider identity and options rather than secret values. The comment at `source.ex:191` suggests the current behavior is intended, so this is a choice for you.
- **Impact:** possibly the biggest hit-rate effect for S3 deployments that use rotating credentials.

## Tier 2: per-request overhead on fetches

### 5. Two serial DNS lookups on every fetch and redirect hop, with no cache
- **Where:** `source/http/target_guard.ex:48-68`
- **Now:** `getaddrs(:inet)` runs, then `getaddrs(:inet6)`. Pinning means a warm keep-alive connection still pays for both.
- **Fix:** run the two in parallel, and add a short TTL cache by default.
- **Impact:** saves 1–2 DNS round trips per miss or revalidation.

### 6. Every fetch passes pool options to Req, which calls `DynamicSupervisor.start_child` on its single `Req.FinchSupervisor`
- **Where:** `source/req_stream.ex:290-316`
- **Now:** each call also runs `term_to_binary` and md5 on the options, plus Finch's NimbleOptions validation, all serialized VM-wide.
- **Fix:** compute the pool name once, start the pool once, then pass `finch: [name: ...]`.
- **Impact:** tens of µs per fetch, and one serialization point removed.

### 7. Pools are keyed by pinned IP
- **Where:** `source/http/pinned_target.ex`
- **Now:** when round-robin DNS rotates its answers, connections spread across many pools, so keep-alive reuse drops. No `pool_max_idle_time` is set, so pools for retired IPs never go away.
- **Fix:** sort the vetted addresses into a stable order and set an idle timeout.
- **Related:** the pool size is fixed at the Finch default of 50, and only HTTP/1 is used.

### 8. S3 credentials are read through one GenServer per bucket on every request, including cache hits
- **Where:** `source/s3/credentials.ex:32` and `refresh_cache/entry.ex:254`
- **Fix:** publish the credentials to ETS or `persistent_term` and read them from there.
- **Related:** `auth: :netrc` re-parses the netrc file on every request.

### 9. The source-record lookup goes through a full entry open
- **Where:** `cache.ex:113-122`
- **Now:** the lookup opens the body, hashes it, sends a hit cast and closes it, only to read `source_record`, which is already in the metadata. It also repeats the lookup `prepare_remote` just did (`source_cache.ex:53`).
- **Fix:** read the metadata only, and skip the second lookup when the lock was uncontended.

## Tier 3: smaller items
- **Cold copied originals are written and hashed twice.** Spooling goes to `System.tmp_dir!` and is then streamed into the pool sink (`source_cache.ex:250`, `:297-327`, and `input.ex:558-577`). Spooling into the pool directory and adopting the file by rename would avoid the second pass.
- **Spool writes are small.** Each network message becomes one `:file.write` plus one `Download.advance` call (`source_cache.ex:313-341`). Buffering about 64 KB per write would cut that.
- **Cache files open without `:raw`.** Each open spawns an I/O process, and each chunk is a message round trip (`cache/file.ex:11`, `store.ex:263`, `source/file.ex:221-226`).
- **Eviction-gated commits copy whole queues to lists.** The commit then deletes victims inside the GenServer (`admission.ex:699-701`, `:733`, `:513-525`). A lazy walk capped at 64 entries would avoid the copy.
- **Store path validation does too much per call.** It re-runs NimbleOptions and the symlink-resolving `safe_relative` on every call (`store.ex:796-808`, `:889-900`).
- **The cache key and the ETag hash the same material separately.** `represent` also runs two or three times per request (`representation.ex:59-70`). The cost is µs.

## Already fine
Bodies stream with `into: :self` and enforce limits per chunk. SHA-256 is computed incrementally while spooling. libvips opens staged paths directly, and format sniffing reads a 32 KB prefix. Input pinning uses hard links. Commits use rename with no fsync. The conditional-GET 304 is answered before any cache or source work. The sketch and doorkeeper are cheap. The single-flight GenServers run only on misses.

## Suggested next step
Write two benchmarks to size items 1 and 2: a bounded pool with about 100k entries under concurrent hits, and concurrent warm requests for one local file.
