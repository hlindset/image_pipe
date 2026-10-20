# Performance review 5: sources and caching

Repo `hlindset/image_pipe` at `fe70ecc` (main, 2026-10-20, after #1019 "Keep the records of originals in memory"). Paths are relative to `image_pipe/lib/image_pipe/`.

Measurements ran in a 4-core cloud container (Intel Xeon 2.1 GHz, Elixir 1.20.4, OTP 29, libvips 8.18.7 built as CI does), from `image_pipe/` with `MIX_ENV=dev mix run`. File syscalls are slow on this VM, so absolute I/O numbers overstate a bare-metal host; compare within a table. Each finding says whether it was **measured** or **inferred**. The throwaway scripts are described in each finding so the numbers can be reproduced; none are in the repo.

## Where things stand

Pass 4's sources-and-caching findings are nearly all done (details at the end). A warm output-cache hit for a local file now costs 716 µs (`bench/warm_requests.exs get`), 444 µs for `head`, and 322 µs wall per request with 8 clients (pass 4: 768 / 563 / 345 µs). `bench/full_cache.exs` in its default setup now renders 71–76 times per 2,000 requests once warm, and a rejected write costs about 0.6 ms of writer time against 3 ms for an admitted one, because it's deleted unsynced.

The biggest problem this round is new: #1019 (merged today) moved originals' records into a 10,000-entry in-memory table that forgets a random record when full. The output-cache key needs the record, so once more than 10,000 originals are in use, a large share of *warm* output-cache hits download the original again (HTTP) or re-hash it (local files). Finding 1 measures it. Findings 2 and 3 are concurrency caps that stop coalescing or queue fetches under bursts, which finding 1 (and every restart) makes more likely.

## Ranked findings

| # | Finding | Impact | Evidence | Status |
| --- | --- | --- | --- | --- |
| 1 | Forgotten source records make warm output-cache hits download or re-hash the original | High | Measured | New (regression from #1019) |
| 2 | Past 64 downloads in flight, identical requests stop coalescing and each downloads the original | Medium | Measured | New |
| 3 | One origin address gets at most 50 connections; other requests to it queue, then 504 | Medium | Measured | Perf side of bug hunt 4's pool finding |
| 4 | Each cache write makes about 17 file-server calls; two of Admission's are no-ops | Low | Measured | New |
| 5 | A record-only publication starts a writer process from the request | Low | Measured | New |

---

### 1. Forgotten source records make warm output-cache hits download or re-hash the original

- **Severity:** High for any deployment with more than `max_remembered_originals` (default 10,000) originals in use, with HTTP or S3 sources and no originals cache, or with local files. It also hits every deployment once after each restart.
- **Where:**
  - `cache/source_records.ex:52-69`: `put/4` evicts a random record once the table holds `limit` records. Nothing tracks use.
  - `execution.ex:197-211` (`resolve_record/2`) and `execution/source_cache.ex:31-36` (`lookup/3`): the record comes from the in-memory table, then the originals cache's metadata, or nil.
  - `execution.ex:143-156` (`byte_identity/1`): a non-immutable source's output-cache key is built from the record's content hash, so without a record the request can't even look up the processed image. It goes to `join_download/1` and `acquire(context, nil)`, a full fetch or hash.
  - `config.ex:413-425`: `max_remembered_originals` defaults to 10,000.
- **Evidence (measured):**
  - **Cost of one forgotten record**, warm output-cache hit for `/w=300/format=webp`, with the record present versus deleted from the instance's `SourceRecords` table before each request (200 and 100 requests, p50 / p90):

    | Source | Original | Record present | Record forgotten | Origin requests when forgotten |
    | --- | ---: | ---: | ---: | ---: |
    | Local file | 0.85 MB | 630 / 761 µs | 2,192 / 2,778 µs | — (re-hash) |
    | Local file | 6.1 MB | 616 / 745 µs | 8,166 / 9,980 µs | — (re-hash) |
    | Local file | 10.7 MB | 645 / 949 µs | 12,347 / 14,287 µs | — (re-hash) |
    | Local file + originals cache | 6.1 MB | 597 / 752 µs | 7,019 / 10,547 µs | — (file sources don't copy by default) |
    | HTTP, loopback origin | 0.85 MB | 689 / 913 µs | 4,083 / 5,502 µs | 100 of 100 |
    | HTTP, loopback origin | 6.1 MB | 674 / 875 µs | 11,431 / 13,660 µs | 100 of 100 |
    | HTTP + originals cache | 6.1 MB | 688 / 830 µs | 708 / 877 µs | 0 |

    The HTTP rows use a zero-latency loopback origin, so they are the floor: against a real origin each forgotten record is a full download with its latency and egress, served from the output cache only afterwards.
  - **How often records are forgotten**, simulated with the real `SourceRecords` module (limit 10,000, 600,000 Zipf-distributed requests over N originals, first 200,000 as warm-up), against an exact LRU of the same size:

    | Zipf exponent | Originals in use | Record hit ratio (random eviction) | LRU of the same size |
    | --- | ---: | ---: | ---: |
    | 0.8 | 20,000 | 0.695 | 0.796 |
    | 0.8 | 50,000 | 0.420 | 0.586 |
    | 0.8 | 200,000 | 0.216 | 0.375 |
    | 1.0 | 20,000 | 0.833 | 0.906 |
    | 1.0 | 50,000 | 0.657 | 0.801 |
    | 1.0 | 200,000 | 0.484 | 0.684 |

    So with 50,000 originals and a CDN in front (traffic flatter than Zipf 1.0), more than half of all requests, including the ones the output cache could answer, fetch or hash the original. A 5 GB output cache of 50 KB images holds 100,000 entries, so the output cache isn't what limits this.
  - **Before #1019** the records lived in the output cache, bounded by bytes and kept by W-TinyLFU. They were evicted in bursts (`image_plug-zi90`), but a 5 GB cache kept far more than 10,000 of them, and they survived restarts.
  - **Restarts:** the table is empty after every restart. Without an originals cache, each original in use is downloaded (HTTP/S3) or hashed (local file) once more before its warm output-cache entries can be served. The changelog entry for #1019 mentions this for local files only.
  - **Originals-cache fallback:** a record found only in the originals cache (`Input.metadata/2`) isn't put back in the memory table, so each later request for it reads and decodes the `.meta` file again (still cheap: 708 µs total above).
- **Why:** random eviction can't tell a record used every second from one used once, and the limit isn't tied to the output cache's size, so the record table becomes the working-set limit for the whole cache.
- **Suggested fix**, roughly in order of payoff:
  - Size the default from the output cache, for example one record per 25–50 KB of `max_size_bytes` (a 5 GB cache: 100,000–200,000 records, 70–200 MB), or at least warn when `cache_stats` shows record misses with output-cache hits.
  - Evict by recency, not at random: store a coarse last-used tick in the row (`:ets.update_element/3` on hit, at most once per second per key) and evict the oldest of a few sampled slots. The simulation's LRU column is the ceiling this approaches.
  - Put a record found in the originals cache back into the memory table.
  - For restarts and HTTP without an originals cache: keep a count-bounded on-disk copy of each record (one small file per input key under the output root, outside Admission), read only on a memory miss. One ~1 KB file read costs tens of microseconds against a full download.
- **Open question for Håvard:** should records stay purely in memory (fix the eviction and the default size), or get the on-disk fallback back? The first is enough for local files; the second matters for HTTP/S3 sources after a restart.

### 2. Past 64 downloads in flight, identical requests stop coalescing and each downloads the original

- **Severity:** Medium. It matters in bursts of cold or forgotten originals (finding 1, restarts, a CDN purge, a page of new thumbnails): exactly when coalescing saves the most.
- **Where:** `cache/output_work.ex:19` (`@max_keys 64`) and `:120-121` reply `:busy` for a new key once 64 flights exist, across every image and download flight of the instance. `execution.ex:214-225` (`join_download/1`) then runs `acquire(context, nil)` for each request on its own. `cache/work.ex:6` has the same limit of 64 for source locks (bug hunt 2 covered what it did to cache writes).
- **Evidence (measured):** HTTP source, output cache, no originals cache. N requests for distinct originals on a slow origin (3 s per response) are started first; then 8 identical requests for one more image, from a second, fast origin (200 ms), so connection limits (finding 3) don't interfere:

  | Slow downloads in flight | Origin fetches for the 8 identical requests | Statuses | Wall time of the 8 |
  | ---: | ---: | --- | ---: |
  | 0 | 1 | 8 × 200 | 378 ms |
  | 63 | 1 | 8 × 200 | 422 ms |
  | 64 | 8 | 8 × 200 | 402 ms |
  | 100 | 8 | 8 × 200 | 408 ms |

  From the 64th flight on, every identical request downloads the original itself. Downloads hold flights without using the CPU, so 64 slow downloads are easy to reach well below the processing pool's limits (`max_queue` 64 plus `max_concurrency`).
- **Suggested fix:** raise the cap to something tied to real limits (for example `max_queue + max_concurrency` for image flights, and a separate, larger cap for download flights, which cost only a map entry and a monitor), or count only flights with waiters toward it. Both caps protect the coordinator's state size, which is small per key; 1,024 waiters are already allowed.
- **Open question for Håvard:** is there a reason the download flights share the 64 image-flight slots? A burst of slow downloads currently also stops coalescing for renders of already-downloaded originals.

### 3. One origin address gets at most 50 connections; other requests to it queue, then 504

- **Severity:** Medium for deployments behind which one origin (one S3 endpoint, one asset host) serves most originals.
- **Where:** `source/http/pinned_target.ex:150-160` starts each pinned Finch pool with Finch's defaults (`size: 50`, `count: 1`); `source/req_stream.ex:529-543` passes only Req's `pool_options/1`, which can't set a size; the HTTP source's options have no pool size. Source fetches run before a processing-pool slot is taken, so nothing bounds them below 50 either.
- **Evidence (measured):** same setup as finding 2, but the 8 identical requests go to the **same** origin address as the slow downloads:

  | Slow downloads in flight | Statuses of the 8 | Wall time of the 8 |
  | ---: | --- | ---: |
  | 0 | 8 × 200 | 421 ms |
  | 63 | 8 × 200 | 4,552 ms |
  | 64 | 8 × 200 | 4,511 ms |
  | 100 | 8 × 504 | 5,010 ms |

  A 200 ms image takes 4.5 s while 50 connections are busy, and fails once the wait passes `pool_timeout` (5 s), with the CPU idle. Bug hunt 4 found this pool from the crash side (fixed: a full pool now returns `:pool_timeout`) and listed a configurable size as optional; nothing tracks the performance side.
- **Suggested fix:** expose the pool size (and `count`) as HTTP and S3 source options, with a default derived from the processing pool (for example 2–4 × `max_concurrency`, since downloads overlap processing). HTTP/2 origins avoid it already (`protocols: [:http2]`); the docs could say that a busy HTTP/1.1 origin is limited to 50 concurrent fetches per address.

### 4. Each cache write makes about 17 file-server calls; two of Admission's are no-ops

- **Severity:** Low. About 0.4 ms of avoidable work per write, all off the request, about 0.07 ms of it inside the per-root Admission process.
- **Where:**
  - `cache/file_system/store.ex:171` and `:208`: `File.mkdir_p(paths.dir)` on every `open_sink`/`open_linked_sink`. Elixir's `mkdir_p` walks from `/` and makes every ancestor, with a `make_dir` and a `dir?` for each, through the VM-wide file server. `checked_partition/2` (`:764-771`) already caches that the partition was validated, but not that it exists.
  - `store.ex:591-598`: the metadata temp file is written with `File.write/3`, not raw, so it opens an I/O server.
  - `store.ex:370-374`: `commit_prepared_sink/2` renames both temp files, then `cleanup_sink_state/1` in its `after` deletes both temp paths again. They no longer exist, so each commit makes two `rm` calls that fail with `:enoent`, inside Admission (`admission.ex:522`).
- **Evidence (measured):** messages received by `:file_server_2`, traced over 50 renders with a cache write each (no evictions): 19.3 per request (`make_dir` 5, `read_file_info` 9.2, `rename` 2, `delete` 2, `open` 1), against 2.0 per warm hit (the `open` and `read_file_info` that `Plug.Test`'s `send_file` makes). Microbenchmarks on this VM:

  | Call | Cost |
  | --- | ---: |
  | `File.mkdir_p/1` on an existing 5-level directory | 177 µs |
  | `:prim_file.make_dir/1` on it (`:eexist`) | 22 µs |
  | `File.write/3` of 1 KB metadata | 160 µs |
  | `:file.write_file/3` with `:raw` | 75 µs |
  | `File.rm/1` of a missing file | 34 µs |

- **Suggested fix:** create a partition directory once (record it in `CheckedDirs` after a successful `:prim_file.make_dir`, and retry the open with `mkdir_p` only on `:enoent`); write the metadata with `[:raw, :binary, :exclusive]`; drop the two temp paths from the state after the renames so the cleanup skips them.

### 5. A record-only publication starts a writer process from the request

- **Severity:** Low. 21 µs on the request and one of a root's 64 writer slots, for an ETS insert.
- **Where:** `cache/publication.ex:37-43` and `:50-75`. Since #1019 a record write (`Cache.remember_source/3`, an ETS insert) is a plain function, but `publish/4` still hands it off whenever a cache root exists: `Writers.start_child/2` (a `DynamicSupervisor` call), `Work.transfer/3`, and the source lease stays held until the writer runs. This happens for every new original without an originals cache and every refreshed record (`execution/source_cache.ex:380-399`, `:401-413`).
- **Evidence (measured):** 20,000 publications of a record-sized write: 21.5 µs each through `Publication.publish/4`, 5.0 µs inline under the publication lock (`Work.publish/3`), 0.1 µs for the bare insert. The writer slots are shared with output writes, which are dropped with `:writer_limit` when all 64 are taken.
- **Suggested fix:** run a write that touches no disk (no `{:staged, …}` original, no originals-cache refresh) inline under the publication lock, as `publish/4` already does when no cache root exists.

## Pass 4 findings: status on main

- **#1, renders before admission on a full cache:** fixed. Misses and flight waiters count as sightings (`7fcc069`, `image_plug-ojn6`).
- **#2, rejected writes written and synced:** mostly fixed. Admission decides before the sync and a rejected body is deleted unsynced (`4141c02`, `image_plug-idxs`). The body is still written to the page cache and hashed; `bench/full_cache.exs` shows 0.6 ms of writer time per rejected write against 3 ms per admitted one, so the rest isn't worth a pre-write gate.
- **#3, progressive JPEG cost:** fixed (`3159427`, `image_plug-7r5m`).
- **#4, warm local-file check:** the open is skipped when the stat evidence is unchanged (`770b5ba`, `image_plug-kvk8`). Carrying the checked path from `resolve` to `fetch` was measured and dropped (`image_plug-wu02`).
- **#5, followers wait for the original's fsync:** still in the code (`cache/publication.ex:50-66`); tracked in the deferred `image_plug-e4a.8.23`.
- **#6, victim sampling:** won't fix (`image_plug-ajcy`). Measured here: a `decide` on an idle Admission takes 31 µs, and Admission absorbs about 290,000 miss sightings per second, so it isn't near a limit.
- **#7, leftovers:** spool writes are batched (`31c07b6`, `image_plug-e4a.8.10`); the source record is now an ETS read, not a second metadata file read (`0784b6b`); `telemetry_opts` is computed once (`d286d5f`, `image_plug-513q`); Admission rows, sketch and sweep memory are trimmed (`image_plug-d6im`).
- **#8, benchmark breakage:** fixed, and `bench/full_cache.exs` added (`13e7f9f`, `image_plug-59os`).
