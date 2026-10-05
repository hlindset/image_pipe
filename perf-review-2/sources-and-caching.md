# Performance review 2: sources and caching

Repo `hlindset/image_pipe` at `549fbb5` (main, 2026-10-05). Paths are relative to `image_pipe/lib/image_pipe/`.

All measurements ran in a 4-core cloud container (ext4 on a virtio disk, Elixir 1.20.4, OTP 29), from `image_pipe/` with `mix run`. Microbenchmarks report the best of five rounds. End-to-end timings on this machine vary by ±20% between runs, so compare numbers within one table rather than across tables. Each finding says whether it was **measured** or **inferred**.

## Baseline: a warm cache hit costs 1.6–2.0 ms

A warm hit means the processed image is already in the bounded filesystem cache. For a local file source with default options, `bench/warm_requests.exs get` measured 1.7–2.0 ms per request through `ImagePipe.Plug.call/2`. With 16 concurrent clients, throughput levels off at about 1,000 requests per second on 4 cores, because every core is busy (CPU-bound, not waiting on I/O).

Telemetry span durations per warm request (tracing adds overhead, so the absolute values are inflated):

| Span | Count per request | µs per request |
| --- | ---: | ---: |
| `request` (total) | 1 | 1,923 |
| `cache.lookup` | 3 | 689 |
| `send` (Plug.Test reads the file; production uses sendfile) | 1 | 316 |
| `source.stage` (revalidation inside the source lock) | 1 | 199 |
| `source.fetch` | 1 | 97 |
| `parse` | 1 | 92 |
| `source.resolve` | 1 | 86 |

Each warm request makes three `Store.get` calls (two source-record lookups and one output lookup), 14 calls to the VM-wide `:file_server_2` process, and three Admission hit casts. Findings 1–3 cover most of that.

## Ranked findings

| # | Finding | Impact | Evidence | Risk of fix |
| --- | --- | --- | --- | --- |
| 1 | Bloom-filter hashing makes each Admission hit cost 72–80 µs | High | Measured | Very low |
| 2 | Cache path checks and metadata reads queue on one VM-wide file server | High | Measured | Low–medium |
| 3 | A revalidated source record is looked up twice, and each lookup opens the body | Medium | Measured | Low |
| 4 | Two serial DNS lookups on every fetch, with no cache | Medium | Measured | Low |
| 5 | A cold original is re-read, re-hashed and fsynced before the response is generated | Medium | Measured | Medium |
| 6 | The boot scan takes 5.5 s per 20k entries and walks the tree twice | Low–medium | Measured | Low |
| 7 | The cache key and the ETag each canonicalize the same material | Low | Measured | Very low |

---

### 1. Bloom-filter hashing makes each Admission hit cost 72–80 µs

- **Impact:** High. Every warm request pays this cost, and it all runs inside one GenServer per cache root.
- **Where:** `cache/file_system/admission.ex:443-447` (`handle_cast({:hit, …})`), `admission.ex:817-850` (`sighting/2`), and the doorkeeper built with `Talan.BloomFilter.new/2` at `admission.ex:121` and `:834`.
- **Evidence (measured):**
  - `bench/admission_hits.exs` measured 71.8 µs per hit with 20,000 entries and 78.6 µs with 100,000. Hit cost no longer grows with the number of entries, which confirms the round-one index fix.
  - A `:tprof` call-time profile of the Admission process over 5,000 hits puts 73% of its time in `Murmur.Hash128X64` (`body/3` 58%, `hash_x64_128/2` 15%). Talan's default doorkeeper runs seven pure-Elixir Murmur3 hashes over the 64-character hex key on every `member?/2` and `put/2`.
  - Microbenchmark, one call each:

    | Operation | µs |
    | --- | ---: |
    | `Talan.BloomFilter.member?`, default Murmur, cardinality 1M | 28–34 |
    | `Talan.BloomFilter.put`, default Murmur | 28–34 |
    | `member?` with seven `:erlang.phash2({i, key}, 2^32)` hash functions | 0.67 |
    | `put` with the same functions | 1.12 |
    | `Sketch.increment` (count-min sketch, for comparison) | 1.2 |
  - A warm local-file request sends three hit casts, one per `Store.get`. That adds up to about 220 µs of serialized Admission work per request. Admission used 4,350 of the VM's 27,000 reductions per warm request (16%), all in one process. That caps one cache root at roughly 4,500 warm requests per second however many cores the host has (inferred from the per-hit cost). On this 4-core host the cap isn't reached yet, but the Admission queue already backs up under load.
- **Suggested fix:** pass `hash_functions:` to `Talan.BloomFilter.new/2`. The key is already a uniform SHA-256, so the bit positions can also be cut straight from the decoded hash bytes. The doorkeeper is rebuilt from traffic and never persisted (`admission.ex:279-281`), so changing the hash functions breaks no state. Expected result: about 20 µs per hit instead of 72–80.

### 2. Cache path checks and metadata reads queue on one VM-wide file server

- **Impact:** High under concurrency. These calls are serialized across the whole VM, not just per cache.
- **Where:**
  - `cache/file_system/store.ex:951-962` (`validate_under_root/2`), called from `paths_from_hash/2` (`store.ex:858-870`) on every get, sink and delete.
  - `store.ex:680` (`File.read/1` for `.meta`).
  - `source/file.ex:206` (`Path.safe_relative/2`) and `source/file.ex:229` (`File.stat/2`).
- **Evidence (measured):**
  - Tracing `gen_server:call/3` during warm requests found 14 calls to `:file_server_2` per request: 8 `read_link` (from `filelib:safe_relative_path/2`, which resolves symlinks one segment at a time), 3 `read_file` (metadata), 2 `read_file_info` (`File.stat` without `:raw`) and 1 `open`.
  - Microbenchmarks:

    | Operation | 1 process, µs/op | 8 processes, µs/op wall |
    | --- | ---: | ---: |
    | `Path.safe_relative("cf/6a", root)` | 18–23 | 18–21 (no scaling) |
    | `File.read(meta)` (through the file server) | 18–20 | 20–21 (no scaling) |
    | `:file.read_file(meta, [:raw])` | 15–20 | 6.7–7.0 |
    | `File.stat(src)` (through the file server) | 8.4–9.7 | 7.5 |
    | `:file.read_file_info(src, [:raw, {:time, :posix}])` | 5.4–7.3 | 3.6–4.1 |
    | `Store.paths_from_hash/2` (whole function) | 25–51 | — |
    | of which `Path.expand` ×2, `relative_to` and joins | about 6 | — |

    The calls that go through the file server don't get faster with more processes. The raw versions run 2–3× faster with 8 processes.
  - In fprof, `validate_under_root/2` was 60% of `Store.get/2`'s inclusive time.
  - Note: `Path.safe_relative/1` isn't a lexical fallback. In Elixir 1.20 it defaults its second argument to `File.cwd!()` and also resolves symlinks (it measured 40 µs).
- **Suggested fix:**
  - The partition directories come from a validated hex hash, so a lexical check is enough for `..` and absolute paths.
  - The symlink guard only has to cover the partition directories themselves. Check them once, when `open_sink` creates them (`mkdir_p`) and at boot, and remember the result. Don't resolve symlinks on every read.
  - Read `.meta` with `:file.read_file(path, [:raw])`, and stat with `[:raw, {:time, :posix}]`. That also avoids local-time conversion: `Cache.File.check_size/1` calls `:file.read_file_info(io)` with local time, which made 9 `universaltime_to_localtime` calls per request.
  - Treat this as a security-relevant change. Keep a test that a symlinked partition directory is refused.

### 3. A revalidated source record is looked up twice, and each lookup opens the body

- **Impact:** Medium. About 200–400 µs per warm request for sources that revalidate on every request, which is the default for local files (`verify: :stat`) and for HTTP origins without `max-age`.
- **Where:**
  - `execution.ex:168-169` (first lookup), and the second one inside the lock in `execution/source_cache.ex:43-58`.
  - `cache.ex:131-140` (`source_record/2` goes through `lookup_entry/2`, which opens the body file).
  - `cache/file_system/store.ex:245-268` (each get sends a hit cast).
- **Status:** item 9 from round one, still unfixed. New evidence follows.
- **Evidence (measured):**
  - Call counts per warm request: with the default policy, 3 `Store.get`, 1 `Work.run` and 2 `File.stat`. With `cache_policy: [freshness: {:force, 3600}]`, 2 `Store.get`, 0 `Work.run` and 1 `File.stat`.
  - `Store.get/2` plus close took 200–228 µs with a bounded cache and 117 µs unbounded (no hit cast). Inside that, `Cache.File.open/2` plus close (raw open, fstat, close) took 56 µs. The open exists only to check the size of a body that a source-record lookup never reads.
  - Four interleaved A/B rounds of 1,000 warm GETs each: the default policy was 200–410 µs slower per request in every round (1,558 vs 1,353, 1,949 vs 1,541, 2,342 vs 2,047, and 2,228 vs 1,993 µs).
- **Suggested fix:**
  - Read the source record from the `.meta` term only: `Store.metadata/2` already exists (`store.ex:609`). Don't open the body, and don't count the read as an Admission hit, or count only one per request.
  - Inside `SourceCache.acquire/5`, reuse the record from before the lock when `Work.run` reports no coordination (`coordination == false`), or when nobody else held the lock.

### 4. Two serial DNS lookups on every fetch, with no cache

- **Impact:** Medium for HTTP sources. It applies to every miss and every revalidation, including a `304`.
- **Where:** `source/http/target_guard.ex:49-67` (`default_resolver/1`).
- **Status:** item 5 from round one, still unfixed. New measurements follow.
- **Evidence (measured; container resolver 8.8.8.8, no local cache):**

  | Host | `default_resolver/1` | `:inet` only | `:inet6` only |
  | --- | ---: | ---: | ---: |
  | `github.com` | 5.9 ms | 2.8 ms | 2.7 ms |
  | `hex.pm` | 5.9 ms | 2.9 ms | 2.9 ms |
  | `localhost` | 3.4 ms | 0.07 ms | 3.2 ms |

  The IPv6 query runs even when the host has no AAAA record, and it costs a full round trip. For comparison, the loopback cold-miss benchmark (finding 5) measured `source.fetch` at 7–8 ms for a 10 MB body, so DNS alone would almost double that span against a real host. A host with nscd or systemd-resolved would be faster; that part is inferred.
- **Suggested fix:** run the A and AAAA lookups concurrently (two tasks, or `:inet_res` in parallel). Add a short TTL cache keyed by host, for example 30–60 s, bounded and in ETS. The address policy must still run on cached answers, so DNS-rebinding protection keeps working.

### 5. A cold original is re-read, re-hashed and fsynced before the response is generated

- **Impact:** Medium. About 29 ms per 10 MB original on a cold miss with the originals cache on, and it runs while the per-source single-flight lock is held.
- **Where:**
  - `execution/source_cache.ex:172-197` (`publish/6` calls `Input.put/5` inside `fetch/6`, inside `Work.run`).
  - `cache/input.ex:165-190` (`File.stream!` re-reads the spool file into a new sink).
  - `cache/file_system/store.ex:402-413` (`:file.datasync`).
- **Status:** the round-one tier-3 item "cold copied originals are written and hashed twice", still unfixed. New evidence follows.
- **Evidence (measured):**
  - Cold misses against a loopback Bandit origin serving the 10,671,398-byte `waterfall.jpg`, 10 sequential requests to distinct URLs, using a corrected copy of `bench/coordinated_cache.exs`:

    | Span | Two pools | Output only |
    | --- | ---: | ---: |
    | `cache.write` (input pool) | 29.3 ms | — |
    | `source.stage` | 138 ms | 39 ms |
    | `source.fetch` | 8.3 ms | 7.0 ms |
    | Whole request (dominated by decode and resize) | 824 ms | 896 ms |

  - fprof of one cold request shows the order: spool, then the overlapped decode finishes, then `publish` → `Input.put`, then `Execution.open` → `generate`. So the input write sits on the critical path between staging and generation.
  - `datasync` cost on this disk:

    | Body size | Write without sync | Write with `datasync` |
    | ---: | ---: | ---: |
    | 32 KB | 0.06 ms | 0.57 ms |
    | 1 MB | 0.21 ms | 2.3 ms |
    | 10 MB | 2.2 ms | 12.7 ms |

    Every commit syncs, so a cold output write also pays about 0.5 ms (whether this delays the response depends on where the output sink commits; that part is inferred).
  - I couldn't explain the remaining roughly 70 ms difference in `source.stage` between the modes from spans alone. Request totals overlapped within noise.
- **Suggested fix:**
  - Spool directly into the input pool's directory, so the spool is on the same filesystem as the pool. Then adopt the file with `rename` and reuse the SHA-256 computed while spooling, instead of streaming it through a second sink.
  - Run the `datasync` and publish after the lock is released or after the response is sent. The lock only needs to cover the bytes being available. Waiters can read the spooled path through the lease.
  - Medium risk: this touches crash safety and the "a published body is fully synced" guarantee in `store.ex:402-404`, so keep that ordering for the rename.

### 6. The boot scan takes 5.5 s per 20k entries and walks the tree twice

- **Impact:** Low–medium. It runs only once per boot, but the time grows with the cache, and until the scan reaches a key, every hit on that key reads its `.meta` from disk inside the Admission process (`admission.ex:449-473`, `current_descriptor?/2`).
- **Where:**
  - `cache/file_system/admission.ex:314-385` (`scan_directory/2`, `walk_meta_files/1`, which calls `File.dir?/1` on every directory entry).
  - Phase D re-walks the tree with `Sweep.run/3` (`admission.ex:341`, `sweep.ex:25-80`).
- **Evidence (measured; `bench/admission_hits.exs`, cache files on ext4):**

  | Entries | Scan time |
  | ---: | ---: |
  | 5,000 | 1.5 s |
  | 20,000 | 5.2–5.7 s |
  | 100,000 | 31.4 s |

  Breakdown at 20k entries (57,491 files in the tree):

  | Step | Time |
  | --- | ---: |
  | `File.dir?/1` on every path | 0.5–2.2 s |
  | `read_descriptor/1` on every `.meta`, sequential | 1.0–1.3 s |
  | Same with `:raw` reads | 0.84 s |
  | Same with `:raw` reads, 8 parallel workers | 0.61 s |
  | Second walk by `Sweep.run/3` | 1.5–1.6 s |

  The rest is the 200 `apply_scan_batch` calls. Round one flagged this as O(N²). It now grows close to linearly (6× the time for 5× the entries), but it's slow per entry, about 300 µs.
- **Suggested fix:**
  - Walk the two-level partition tree once. Use `File.ls` names (`.meta`, `.body`, `.tmp` suffixes) instead of `File.dir?` per file. Do the leftover-file sweep in the same pass.
  - Read the descriptors with raw reads over a small `Task.async_stream` per partition.
  - Optionally read the persisted protected list first, so hot keys are tracked before cold ones.

### 7. The cache key and the ETag each canonicalize the same material

- **Impact:** Low. About 40 µs per request.
- **Where:** `representation.ex:57-73` (`build/3` calls `digest_hex(key_data)`, then `etag/1` on the same data minus `storage_only`) and `material_digest.ex:30-62`.
- **Evidence (measured):** a warm request makes 5 `MaterialDigest.of/1` calls. The two large ones (1,541 and 1,406 bytes once encoded) took 29.7 and 28.6 µs. A plain `:crypto.hash(:sha256, :erlang.term_to_binary(t, [:deterministic]))` on the same terms took 10.0 and 8.2 µs. `canonicalize/1` (with a `Keyword.keyword?` check, `sort_by` and per-element closures) costs about 3× the hashing itself.
- **Suggested fix:** canonicalize `key_data` once and hash both projections from it (drop `storage_only` from the canonical list). Or build the material in canonical order at the source, so `canonicalize/1` becomes a no-op check. Round one listed this as µs-level; this measures it.

## Fixed since round one

These were confirmed in the code, and finding 1 confirms the index by measurement:

- Admission lookups by hash use an index (`5b2a545`). Hit cost is flat from 20k to 100k entries.
- Unchanged source records are no longer rewritten (`ec24c0d`).
- Cache hits use sendfile and check only the size (`94bf572`).
- S3 is partitioned by configured credentials, not rotated ones (`8b786d9`).
- Pinned Finch pools start once under ImagePipe's supervisor (`03f0d7c`).
- Store options are no longer revalidated on every path lookup (`1639a1f`).

Round-one items 7 (pools keyed by pinned IP, no idle timeout) and 8 (S3 credentials read through a GenServer on every request) look unchanged in the code. I have no new measurements for them, so they aren't repeated here.

## Notes on the benchmarks

- `bench/coordinated_cache.exs` no longer runs. It passes `sources: [url: {ImagePipe.Source.HTTP, …}]`, which `ImagePipe.Source.validate_config!/1` now rejects ("expected a keyword list with :adapter, :match, and :options"). The `cache.md` numbers can't be reproduced until it's updated.
- `bench/warm_requests.exs` gets slower the longer it runs. Plug.Test sends every response to the calling process's mailbox, and nothing drains it, so about 32 MB of body binaries pile up per 1,000 requests (98 MB of binaries survived a full GC after 3,000 requests). That makes later batches slower. Draining the mailbox (or using the `bandit` mode) gives steadier numbers.
- The scripts used for this review (component microbenchmarks, span aggregation, the cold-miss breakdown, and the scan breakdown) were throwaway. I can turn any of them into `bench/` files if that helps.
