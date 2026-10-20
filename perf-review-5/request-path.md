# Performance review 5: request path

Scope: the Plug request lifecycle from parse through delivery, as a warm request sees it: parse, source resolve and revalidation, the in-memory source records, the output cache read, representation, the conditional gate, and the response. Reviewed at `main` fe70ecc (after PR #1019, which moved source records into memory). No code was changed. Paths are relative to `image_pipe/lib/image_pipe/`.

## How this was measured

Everything ran against the real code in this container (Elixir 1.20.4, OTP 29, 4 vCPU Firecracker VM, shared), with the libvips build the cloud session hook installs.

- **Setup.** One supervised `ImagePipe` instance with a 1 GB output cache, a 1 GB originals cache (`input_cache`) and the default `max_remembered_originals` (10 000). Requests for `/w=300/format=webp/src/imageN.jpg` (N = 0..7, each a copy of `priv/static/images/waterfall.jpg`, 10.7 MB) through `ImagePipe.Plug.call/2`. Three source setups, as in pass 4:
  - **file:** `ImagePipe.Source.File`, default options (`verify: :stat`).
  - **http_fresh:** `ImagePipe.Source.HTTP` against a local Bandit origin sending `Cache-Control: public, max-age=3600` and an ETag.
  - **http_nocache:** the same origin with `Cache-Control: no-cache`, so every request revalidates.
- **VM flags.** The server release's current flags, `+sbwt none +sbwtdcpu none +sbwtdio very_short` (`image_pipe_server/rel/vm.args.eex`), unless a line says otherwise.
- **CPU per request** is whole-VM CPU (`:erlang.statistics(:runtime)`, so it includes dirty I/O spinning), the median of 7 interleaved rounds of 2,000 requests. **Throughput** is 4,000 requests across 8 tasks, for one source or spread over 8.
- **What-if patches** were applied behind a `:persistent_term` flag, measured interleaved with the baseline in the same VM, and reverted. They bound what a fix can win; they are not the fix.
- **Counts and callers** come from `tprof` and Erlang call tracing with `caller_line`. Micro-benchmarks ran as compiled module code (not `erl_eval`), 20,000 iterations.

### Baseline on main

| source | case | CPU | wall |
|---|---|---|---|
| file | warm HEAD hit | 568 µs (528–617) | 368 µs (328–390) |
| file | warm GET hit | 788 µs | 556 µs |
| file | early 304 | 273 µs (238–302) | 220 µs (200–255) |
| http_fresh | warm HEAD hit | 497 µs | 388 µs |
| http_fresh | early 304 | 113 µs | 114 µs |
| http_nocache | warm HEAD hit | 1,266 µs | 1,271 µs |
| http_nocache | early 304 | 798 µs | 881 µs |

(GET goes through `Plug.Test`, whose `send_file` reads the body into memory; under Bandit it is a `sendfile`. Use HEAD to compare request-path work.)

| source | HEAD, 1 source | HEAD, 8 sources | 304, 1 source | 304, 8 sources |
|---|---|---|---|---|
| file | 9,860–10,680 req/s | 9,440–10,540 req/s | 20,150–22,930 req/s | 21,030–22,660 req/s |
| http_fresh | 9,530–9,630 req/s | 8,650–9,620 req/s | 24,880–29,490 req/s | 29,080–31,090 req/s |
| http_nocache | 3,990–4,320 req/s | 3,690–3,730 req/s | 5,940–6,470 req/s | 5,860–6,300 req/s |

Pass 4 measured 650–795 µs wall per file-source HEAD hit, 440–540 µs per 304, and 3,750–4,800 req/s for HEAD on one source. The request path is now about 45% faster per request and twice the throughput, from pass 4 #1 (PR #947) and #2 (PR #954), plus the in-memory source records (PR #1019).

Stage durations (wall, median, from telemetry):

| stage | file HEAD | file 304 | http_fresh HEAD | http_fresh 304 |
|---|---|---|---|---|
| parse | 47 | 55 | 56 | 50 |
| source resolve | 68 | 68 | 26 | 22 |
| source fetch (file revalidation) | 57 | 68 | – | – |
| cache lookup, source record (memory) | 15 | 8 | 16 | 8 |
| cache lookup, output entry | 135 | – | 160 | – |
| send | 40 | 28 | 38 | 23 |
| **request** | **443** | **305** | **473** | **180** |

A warm file-source HEAD hit now makes 7 file calls on dirty I/O schedulers (pass 4: 10): 2 `read_link` (the path check in resolve and again in fetch), 1 `stat`, the metadata `read_file`, and an `open`, `fstat` and `close` of the cached body. An http_fresh hit makes the last 4.

The output-cache lookup is most of what separates a hit from an early 304. In isolation it takes 80–86 µs: `read_file` of the metadata 18 µs, `open` + `fstat` + `close` of the body 49 µs, and about 10 µs of CPU (decode 6 µs, the rest under 1.5 µs each). Inside a request each file call costs more, because the schedulers fall asleep while the request does CPU work between calls.

## Findings, ranked by payoff against risk

### 1. A fresh record read back from the originals cache is never put back in memory, so every request reads it from disk until it goes stale

- **Severity:** Medium. Measured.
- **Where:** `execution/source_cache.ex:31-36` (`lookup/3`: `Cache.source_record(key, config) || Input.metadata(key, config)`), used by `execution.ex:197-209` (`resolve_record/2`). `Input.metadata/2` is `cache/input.ex:44-57`, which reads the originals cache's metadata file through `Store.metadata/2`.
- **Evidence:**
  - Records reach the in-memory table only through a publication (`execution/source_cache.ex:333-414`, `publication/6`, `store/7` and `remember/4`), which runs after a fetch or a revalidation. A record found through the `Input.metadata/2` fallback that is still fresh answers `:fresh` in `resolve_record/2`, so nothing is fetched, nothing is published, and the table stays without it. The next request misses the table again and reads the file again.
  - The table loses records on every restart and deploy (it isn't persisted, as the PR #1019 changelog says) and on eviction (finding 2). After either, each origin image with an originals-cache copy reads that copy's metadata on every request until its freshness runs out. For an origin that sends a long `max-age` or `immutable`, that is effectively forever.
  - Same warm loop, http_fresh, before and after `:ets.delete_all_objects` on the instance's `SourceRecords` table:

    | | record in memory | record lost |
    |---|---|---|
    | early 304 CPU | 141 µs | 294–326 µs |
    | early 304 wall | 143 µs | 274–297 µs |
    | 304 throughput, 8 tasks over 8 sources (3 rounds) | 20,400–25,520 req/s | 12,350–13,240 req/s (−40 to −50%) |
    | HEAD hit throughput, same | 6,540–7,350 req/s | 6,530–6,940 req/s (inside noise) |

    The table stayed empty through all 2,000 requests of each run (`:ets.info(table, :size)` was 0 afterwards).
  - The HEAD hit hides it because the output entry read already costs four file calls. The early 304, the cheapest answer a CDN-fronted deployment gives, doubles.
- **Suggested fix:** in `lookup/3`, when the table misses and `Input.metadata/2` returns a record, put that record in the table. Use `:ets.insert_new/2` (a `SourceRecords.put_new/4` next to `put/4`) so a newer record that a publication wrote between the miss and the read isn't overwritten by the older copy from disk. Test first: with an originals cache and a fresh HTTP original, empty the table, make two requests, and assert that the second finds the record in memory (for example, the table holds it after the first).

### 2. A full source-record table doesn't forget a random record: it mostly forgets the first one in hash order, which costs 7–15 points of hit rate

- **Severity:** Medium. Measured in a model of the table; the miss cost is measured end to end.
- **Where:** `cache/source_records.ex:52-70` (`put/4` and `evict/1`). The `max_remembered_originals` docs (`config.ex:413-424`) and the changelog promise that "a random one is forgotten".
- **Evidence:**
  - `evict/1` picks `:ets.slot(table, :rand.uniform(size) - 1)` and falls back to `:ets.first(table)` when the slot is empty. An ETS hash table has about as many slots as records, and in a freshly filled table 37–39% of them are empty (measured at 1k, 5k, 10k and 20k records). Every such pick evicts `:ets.first/1`, the first record in slot order, instead of a random one.
  - Slot order is fixed by the key's hash, so the same low slots are emptied again and again. A new original whose record lands in a low slot is forgotten at the next insert, while records in high slots are never picked by the fallback. Emptying the low slots also leaves more empty slots to land on: in a model of `put/4` (same table options, 10,000-record limit, 50,000 inserts of new keys), 60% of evictions went through `:ets.first/1`. Of the first 10,000 records, 1,543 survived (uniform random eviction leaves about 67). Of the 10,000 most recent, 2,860 were still there (uniform: about 6,300). It keeps old records and drops new ones.
  - Hit rate of the table with a 10,000 limit under Zipf-distributed requests, 400,000 requests each, same seed, against uniform random eviction (retrying random slots until one holds a record):

    | originals in use | Zipf s | current | uniform random | misses, current vs uniform |
    |---|---|---|---|---|
    | 20,000 | 0.8 | 67.7% | 74.8% | +28% |
    | 40,000 | 0.8 | 46.8% | 57.7% | +26% |
    | 40,000 | 1.0 | 68.5% | 78.4% | +46% |
    | 100,000 | 0.9 | 40.5% | 55.5% | +34% |

  - What a miss costs: for the file source, the original is hashed again. A file-source HEAD hit took 375–434 µs wall with its record in memory and **13.2–13.4 ms wall (15.2–15.4 ms CPU)** with it dropped, for the 10.7 MB test image, about 1.2 ms per MB. For an origin image with an originals-cache copy, a miss falls into finding 1. Without one, the next request revalidates with the origin.
- **Suggested fix:** retry random slots until one holds a record, with a small cap (at about 62% occupancy the expected number of tries is 1.6; a cap of 8 falls through about once in 2,300 evictions), and only then fall back to `:ets.first/1`. Picking a random element of the slot's list instead of its head also keeps records in long chains from being protected. Test with a deterministic seed: fill a table to its limit, insert many new keys, and assert that recently inserted keys survive at about the rate uniform eviction gives, not much lower.
- **Note:** this only matters once more than `max_remembered_originals` originals are in use. With findings 1 and 2 together, an origin record pushed out under churn stays out of memory as long as it's fresh.

### 3. Every output-cache hit reads and decodes the entry's metadata file

- **Severity:** Low–Medium. Measured with a what-if patch; needs Håvard's decision.
- **Where:** `cache/file_system/store.ex:425-432` (`read_entry/1`) and `:499-501` (`read_metadata/1`), called from `Store.get/3` on every lookup.
- **Evidence:**
  - The metadata `read_file` is one of the four file calls of a hit (18 µs in isolation, more inside a request), and its decode is another 6 µs.
  - What-if: keep each decoded metadata map in an ETS table keyed by its path, so a repeat hit skips the `read_file` and the decode. The body `open`, `fstat` and `close` still run, so a deleted or truncated body is still caught. Interleaved, 5 rounds of 2,000:

    | | baseline | metadata in memory |
    |---|---|---|
    | file HEAD hit CPU / wall | 610 / 407 µs | 526 / 352 µs (−14% / −14%) |
    | http_fresh HEAD hit CPU / wall | 546 / 429 µs | 458 / 361 µs (−16% / −16%) |
    | file HEAD, 8 tasks over 8 sources (3 rounds) | 6,200–6,520 req/s | 7,310–9,130 req/s (about +25%) |
    | http_fresh HEAD, same | 6,440–7,500 req/s | 8,480–8,560 req/s (about +20%) |

  - A second what-if that also skipped the body `fstat` (the truncation check) added nothing measurable on top, so it isn't proposed.
- **How this differs from the won't-fix items:** `image_plug-448f` (decode debug info lazily) and `image_plug-ljda` (skip the body open on HEAD) each saved microseconds of CPU. This removes a dirty I/O round trip from every hit, GET included.
- **Open questions for Håvard:** a metadata memo needs answers before it's worth a design note:
  - **Invalidation.** Admission's evictions and deletes, and `refresh_source_record/4`, which rewrites the metadata in place, would have to update the memo. These all run in the local Admission process, so that is one place to hook.
  - **Shared roots.** Another node can evict or replace an entry. Bodies are named by their hash, so a memo pointing at a body another node deleted gets `enoent` at the body open and reads as a miss; one pointing at a body that still exists serves the same bytes. Is that enough, or does a shared root need the memo off?
  - **Memory.** About 1.2 KB of metadata per entry as a binary, more decoded. It would need a bound like `max_remembered_originals`, with the eviction from finding 2 fixed first.

## Fixed or decided since pass 4 (verified on main)

- **#1, the file source opened the original on every revalidation:** fixed (`image_plug-kvk8`, PR #947, `source/file.ex:137-157`). The `open` now runs only in `changed/2`. A warm hit makes no `open` of the original.
- **#2, `+sbwtdio`:** decided and shipped (`image_plug-lksl`, PR #954). The release now runs `+sbwtdio very_short`, and the perf comparison has a cache family (`image_plug-uzzi`, PR #929).
- **#3, skip the body open on HEAD:** won't fix (`image_plug-ljda`).
- **#4, decode debug info lazily:** won't fix (`image_plug-448f`). PR #996 since added a rebuild of the stored `Debug.Info` on every hit (`cache/file_system.ex:162-165`, `current_debug/1`). It costs 0.9 µs, too little to reopen the decision.
- **#5, telemetry regex and `list_handlers`:** the regex is gone (`image_plug-98ui`, `Telemetry.request_path/2` now scans segments). `Summary.open/2` still calls `:telemetry.list_handlers/1` per request (`telemetry/summary.ex:55`), now 0.85 µs with nothing attached. Not re-raised.
- **Source records out of the output cache** (`image_plug-zi90`, PR #1019): the record lookup is now a 0.24 µs ETS read instead of a metadata file read. Findings 1 and 2 are about that table.

## Checked and fine

- **Normal-scheduler busy wait (`+sbwt`).** With `+sbwt none`, the scheduler a request returns to after each dirty file call has to be woken. In a tight loop, a `stat` cost 23 µs wall with the shipped flags and 7 µs with `+sbwt very_short` (a `read_link` 18 vs 4 µs). End to end the gain is small: file 304 wall 220 → 176 µs, file HEAD 368 → 342 µs, and throughput unchanged within noise (the normal schedulers are busy under load anyway). Not worth spinning normal schedulers, which takes CPU from libvips.
- **Small CPU items on a hit, each measured in isolation:** `Store.paths/2` with its hex checks of the key and body filename 1.35 µs, `current_debug/1` 0.9 µs, `Store.registry_name/1` (hash and `Module.concat`) 0.7 µs per Admission cast, `Plug.Config.resolve/1` 0.9 µs, each `Telemetry.span/4` with nothing attached 0.64 µs (8 per hit), `DateTime.from_iso8601/1` 0.22 µs. None is worth a change alone.
- **The two path checks of the file source.** Resolve and fetch each run `SafePath` (a `read_link` each), so file-source resolve is 68 µs against 22–26 µs for HTTP. The fetch-time recheck stays by decision (`image_plug-e4a.15.11`).
- **Rehash after a restart.** The file source hashes each original again on its first request after a restart, unless the originals cache holds a copy: 13 ms for a 10.7 MB original. The PR #1019 changelog documents this.
- **`URI.parse/1`** runs once per HTTP-source request in `Source.Parser.scheme_translate/2` (3.3 µs, a regex inside Elixir's `URI`). Fine.
- **http_nocache revalidation** is still dominated by Req/Mint and the in-VM origin, as in pass 4.

## Suggested order

1. **#1 (put a record read from the originals cache back in memory).** A few lines and a test. It restores the early-304 rate after every restart for origin images with an originals-cache copy.
2. **#2 (retry random slots when evicting a record).** A few lines and a seeded test. It matters once more than `max_remembered_originals` originals are in use, and it makes the docs' "random" true.
3. **#3 (metadata in memory)** only if Håvard wants more hit throughput and the open questions have answers. It would need a design note.
