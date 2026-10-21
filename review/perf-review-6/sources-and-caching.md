# Performance review 6: sources and caching

Repo `hlindset/image_pipe` at `6a87579` (main, 2026-10-21, after #1056 "Keep cache entry metadata in memory for hits"). Paths are relative to `image_pipe/lib/image_pipe/`.

Measurements ran in a 4-core cloud container (Elixir 1.20.4, OTP 29, libvips 8.18.7 built as CI does), from `image_pipe/` with `MIX_ENV=dev mix run`. File syscalls and SHA-256 (about 350 MB/s here) are slow on this VM, so absolute numbers overstate a bare-metal host; compare within a table. Each finding says whether it was **measured** or **inferred**. The throwaway scripts are described in each finding; none are in the repo.

## Where things stand

All five pass 5 findings are addressed on main (details at the end). The record table's sampled eviction now matches an exact LRU within 0.3 points, so the regression from #1019 is gone apart from the documented re-download after a restart. A warm output-cache hit costs 641 µs p50 for an HTTP original with a fresh record and about 786 µs for a local file (`bench/warm_requests.exs get`), in line with pass 5.

Nothing this round is high severity. The biggest remaining cost is on origins that are revalidated on every use: each origin request spends several hundred microseconds in Req's pipeline, more than the rest of the warm hit. The other findings are small per-request or per-write costs and one scaling note on the startup scan.

Two suspicions were checked and ruled out, so nobody needs to look again:

- **Source records don't pin response packets.** Header values from Mint are sub-binaries, but they're under 64 bytes and are copied when the record goes into ETS (`:binary.referenced_byte_size/1` = 29 for every value). Binary memory stayed flat at about 3.5 MB whether 50 or 1,000 originals were remembered.
- **The record table's memory matches its docs, roughly.** One HTTP record row takes 1,368 bytes of ETS memory, so the 1,000,000-record cap is about 1.37 GB, a bit over the "about 1 GB" in `cache.ex:112-116` and the docs.

## Ranked findings

| # | Finding | Impact | Evidence | Status |
| --- | --- | --- | --- | --- |
| 1 | Each origin request spends 300–500 µs in Req's pipeline, which doubles a warm hit on a revalidated origin | Medium for `no-cache`/`max-age=0` origins, low otherwise | Measured | New |
| 2 | The startup scan takes about 18 s per 100,000 entries, and hits during it read metadata inside Admission | Low | Measured | Follow-up to pass 2 #6 |
| 3 | A warm hit parses the same record's cache headers four times | Low | Measured | New |
| 4 | Staged originals are spooled through an I/O server process | Low | Measured | New |
| 5 | The HTTP/S3 fetch context is canonicalized and hashed twice per request | Low | Profiled | New |

---

### 1. Each origin request spends 300–500 µs in Req's pipeline, which doubles a warm hit on a revalidated origin

- **Severity:** Medium for HTTP or S3 origins whose responses are revalidated on every use (`no-cache`, `max-age=0`, or no freshness at all): every warm request makes a conditional request. Low for others, where it's paid only on cold fetches next to a download and a render.
- **Where:**
  - `source/req_stream.ex:251-260` (`build_request/4`): every attempt builds a fresh `Req.new/1` request, appends steps, attaches tracing and pinning.
  - `source/req_stream.ex:271-295` (`send_request/1`): each request spawns a monitored relay that runs `Req.request/1` and forwards every message.
  - `source/http/pinned_target.ex:73-93` (`pin/2`): per request, `term_to_binary` + MD5 + `Module.concat` of the pool options, and `live_first/2` runs an `:ets.select_count` with an unbound key (a full scan of the pinned-pool table).
- **Evidence (measured):**
  - **Warm output-cache hit, HTTP original, loopback origin with zero latency** (2,000 requests after 300 warm-up, `/w=300/format=webp`):

    | Origin `cache-control` | p50 | p90 |
    | --- | ---: | ---: |
    | `public, max-age=3600` (record fresh, no origin request) | 762 µs | 1,195 µs |
    | `no-cache` (one conditional request, origin answers 304) | 1,719 µs | 2,513 µs |

    The revalidation adds about 960 µs, of which the origin's own work (Bandit answering 304 on loopback) is a small part.
  - **Per-request client overhead**, small 200 response from a loopback Bandit origin, 3,000 sequential requests after 300 warm-up:

    | Client | µs per request |
    | --- | ---: |
    | `ReqStream.open/2` + drain (pinned, as the HTTP source does) | 546 |
    | `ReqStream.open/2` + drain (unpinned) | 515 |
    | `Req.request/1`, `into: :self` | 718 |
    | `Req.request/1`, plain | 734 |
    | `Finch.request/2` | 228 |
    | `Finch.async_request/2` + receive loop | 214 |

    `bench/source_fetch.exs` agrees: 618 µs per fetch serially, 228 µs per fetch at 8 concurrent (CPU-bound on 4 cores). Under `tprof` the cost is spread across Req's option handling and steps (`Keyword`, `Map`, `String.downcase`, URI parsing, regex runs that OTP 28+ rebuilds on each use), with no single hot spot; `fprof` puts about a quarter of the caller's time in `build_request/4`. Pinning itself costs little (546 vs 515 µs).
  - Large bodies aren't affected: a 1 MB body takes 1,238 µs through `ReqStream` and 1,218 µs through Finch, and the per-chunk relay hop is cheap (10 MB arrives in about 6 messages on loopback).
- **Suggested fix**, roughly in order of payoff:
  - Build the `Req.Request` once per source configuration (it only changes in URL, conditional headers, timeouts and pinning) and keep it, so a fetch does `Req.merge/2` of the per-request parts instead of `Req.new/1` plus steps.
  - For the conditional request in particular, consider calling Finch directly: it has no body to stream, no redirects to follow and a known header set. That would cut the revalidation to roughly the 214–228 µs a bare Finch request costs here.
  - Smaller: key `PinnedPools.live?/4` so the lookup is a bound-key read (for example a second table keyed by `{scheme, address, port, hostname}`), and memoize the pool name for a set of pool options in a persistent term.
- **Open question for Håvard:** how common are revalidate-every-time origins in the deployments you care about? If they're rare, this is low priority; if an S3 bucket or CMS serves `no-cache`, it's the largest per-request cost left on the warm path.

### 2. The startup scan takes about 18 s per 100,000 entries, and hits during it read metadata inside Admission

- **Severity:** Low. Requests are served during the scan, but Admission's accounting lags, and the new default sizes (record table and memo sized from `max_size_bytes`) are aimed at caches of 100,000–200,000 entries.
- **Where:** `cache/file_system/admission.ex:142-171` (`scan_directory/2`, `list_entries/1`: lists every partition, then applies batches of 500); `:268-276` (`handle_cast({:hit, …})`) and `:299-306` (`stored?/2`): a hit on a key the scan hasn't counted yet makes Admission read and decode that entry's `.meta` file in its own process.
- **Evidence (measured):** fake caches of empty bodies with valid metadata and body filenames, scanned by a real instance, with a client casting hits for random keys during the scan:

  | Entries | Scan time | Per entry | `read_descriptor/1` per untracked hit | Max Admission queue |
  | ---: | ---: | ---: | ---: | ---: |
  | 20,000 | 3.3 s | 166 µs | 157 µs | 29 |
  | 100,000 | 17.6 s | 176 µs | 235 µs | 19 |

  The scan is linear, and faster than pass 2's 5.5 s per 20,000. The queue stayed small here because one client couldn't outrun Admission, but each untracked hit costs Admission a metadata read, so at a few thousand hits per second after a restart (or on a network filesystem, where a read is closer to 1 ms) Admission spends the scan reading metadata, and `decide/4` calls from writers wait behind those reads (their timeout is 5 s, `store.ex:274`).
- **Suggested fix:** while the scan runs, record untracked hits in the existing `scan_changes`-style table (key hash and descriptor from the hit) and resolve them when the scan's batch for that partition arrives, instead of reading the metadata per hit. Alternatively, apply each partition group's entries as soon as its listing finishes rather than after the whole tree is listed, which shortens the window in which hits are untracked.
- **Open question for Håvard:** is a 20–40 s accounting window after a restart of a 5–10 GB cache acceptable? If yes, this can stay as a note.

### 3. A warm hit parses the same record's cache headers four times

- **Severity:** Low. About 30 µs of a 640 µs warm hit (about 5%).
- **Where:** `Source.Record.state/2` (`source/record.ex`) calls `Origin.cache_state/3` → `CacheState.from_headers/4` (`source/cache_state.ex:28-48`), which splits and downcases `cache-control` and parses `date` (and `expires`, `age`) every time. On one warm hit it runs from `SourceCache.status/3` (`execution/source_cache.ex:49-50`, via `resolve_record/2`), from `Execution.storable?/1` (`execution.ex:410-415` → `SourceCache.storable?/2`), from `Execution.source_state/1` (`execution.ex:712-759`, which also calls `CacheState.current_age/3`), and once more on the response-headers path.
- **Evidence (measured):** `fprof` of 100 warm hits counts 4 `from_headers/4` calls per request; with a record from a real fetch (`cache-control: public, max-age=3600`, `date`, `etag`, `vary`, `content-type`, `content-length`), `Origin.cache_state/3` takes 7.1 µs and `CacheState.current_age/3` 2.1 µs (20,000 calls each).
- **Suggested fix:** the headers of a record never change, so parse them once: keep the parsed directives and dates in the record when it's built (`Record.new/4`, `Record.refresh/2`), or compute `Record.state/2` once per request in `Execution` and pass it on. Policy and `stable?` come from the source and can stay arguments.

### 4. Staged originals are spooled through an I/O server process

- **Severity:** Low. About 1.3 ms per 10 MB downloaded, on the request path of every cold HTTP/S3 original.
- **Where:** `execution/source_cache.ex:563-583` (`spool/5`): `File.open(path, [:read, :write, :binary, :exclusive])` has no `:raw`, so every `:file.pwrite/3` (`:641-646`), the `pread`s in `Overlap.select/4` (`execution/overlap.ex:165-166`) and the final `read_file_info/1` (`:611-616`) are messages to a file I/O server. All of them run in the process that opened the file, so `:raw` is safe. `File.chmod/2` (`:566`) also goes through the VM-wide file server.
- **Evidence (measured):** writing 10.5 MB in 64 KiB `pwrite`s, as `spool_file/4` batches them, plus open, chmod, stat and close, median of 41 runs: 3,541 µs through the I/O server, 2,214 µs with `:raw`.
- **Suggested fix:** open the spool file with `:raw`, and create it with mode 0600 directly (`:file.open/2` can't set a mode, but `:prim_file.write_file_info/2` with `mode` or keeping the private staging directory's 0700 makes the chmod unnecessary).

### 5. The HTTP/S3 fetch context is canonicalized and hashed twice per request

- **Severity:** Low. A few percent of a warm hit for HTTP and S3 originals.
- **Where:** `source.ex:205-235` (`prepare_cache_context/2`) runs `MaterialDigest.of(context)` over the adapter's options and prepared fetch options to version the byte identity; then `representation.ex:87-96` (`input_key/3`) canonicalizes and hashes the same `context` again as `fetch_context`. Both run on every request, including warm hits, and the result only changes when the configuration or frozen credentials do.
- **Evidence (profiled):** under `fprof` (which inflates small functions), `prepare_cache_context/2` is 2.8% and `input_key/3` 3.1% of a warm HTTP hit. Not measured in isolation.
- **Suggested fix:** compute the context digest once in `prepare_cache_context/2` and pass it to `input_key/3`, or memoize it per source configuration (a persistent term keyed by the adapter options), since the options are static host configuration.

## Pass 5 findings: status on main

- **#1, forgotten source records:** fixed (`051275d`, `48c81ac`, PR #1020). A record read from the originals cache goes back into memory, the table evicts the least recently used of sampled slots, and `max_remembered_originals` defaults to one record per 50 KB of the output cache (10,000 to 1,000,000). Re-simulated with the real `RecentTable` (limit 10,000, 600,000 Zipf requests, first 200,000 as warm-up), its hit ratio matches an exact LRU:

  | Zipf exponent | Originals | `RecentTable` | Exact LRU |
  | --- | ---: | ---: | ---: |
  | 0.8 | 50,000 | 0.584 | 0.587 |
  | 1.0 | 50,000 | 0.800 | 0.802 |
  | 0.8 | 200,000 | 0.375 | 0.377 |
  | 1.0 | 200,000 | 0.682 | 0.684 |

  The re-download after a restart without an originals cache remains, and is now documented (`docs/caching-and-freshness.md`). The on-disk fallback wasn't built.
- **#2, download flights capped at 64:** fixed (`b271826`, PR #1024): the download coordinator allows 4,096 flights; image flights keep 64 in their own coordinator.
- **#3, 50 connections per origin address:** fixed (`a1d9806`, PR #1029): `pool_size` is configurable for HTTP and S3 sources, default still 50.
- **#4, file-server calls per cache write:** fixed (`02a9ae2`, PR #1048): partitions are made only on `:enoent`, metadata is written raw, and a commit deletes only a linked body's temp.
- **#5, record-only publication in a writer:** fixed (`ac20d18`, PR #1043): `{:memory, fun}` writes run in the request under the publication lock.
