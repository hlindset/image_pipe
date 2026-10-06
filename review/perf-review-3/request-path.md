# Performance review 3: request path

Scope: the Plug request lifecycle from parse through delivery, as a warm request sees it. That covers parse, source resolve and revalidation, source-record and output cache reads, representation, the conditional gate, and the response. Reviewed at `main` 259fb05. No code was changed. Paths are relative to `image_pipe/lib/image_pipe/` unless they start with `image_pipe_url/`.

## How this was measured

Everything ran against the real code in this container (Elixir 1.20.4, OTP 29, 4 vCPU, shared).

- **Warm-hit loop.** This is the setup from `bench/warm_requests.exs`: a local `ImagePipe.Source.File` source, a bounded `Cache.FileSystem`, and HEAD requests for `/w=300/format=webp/src/image.jpg` (32 KB WebP) through `ImagePipe.Plug.call/2`. Eight copies of the source were used for the multi-source runs.
- **CPU per request.** This is whole-VM CPU (`:erlang.statistics(:runtime)`) with scheduler busy-wait off (`+sbwt none +sbwtdcpu none +sbwtdio none`), taking the median of 5 interleaved rounds of 2,000 requests.
- **Concurrency.** 4,000 HEAD requests across 8 tasks, either all for one source or spread over 8 sources.
- **What-if patches.** Each patch was temporarily applied behind a `:persistent_term` flag, benchmarked interleaved with the baseline in the same VM, and then reverted. They bound what a real fix can win; they are not the fix.
- **Counts and callers.** Erlang call tracing with `caller_line` match specs, `tprof`, receive tracing on the singleton processes, and per-stage durations from the `[:image_pipe, …, :stop]` events.

### Baseline on main

| | CPU | wall |
|---|---|---|
| warm HEAD hit | 710–810 µs | 930–1,040 µs |
| 304 for a matching `If-None-Match` | 540–600 µs | 750–830 µs |

Both are well down from pass 2 (1.3–1.6 ms CPU per hit). Throughput is **about 1,500–1,600 req/s for one popular source**, against **2,200–2,700 req/s across 8 sources**.

Stage durations for a warm hit (wall, from telemetry):

| stage | µs |
|---|---|
| parse | 57 |
| source resolve | 62 |
| source stage (revalidate the file, inside resolve/fetch) | 127 |
| cache lookups (source record about 109, output entry about 196) | 306 |
| send | 38 |
| everything else (representation, headers, policy, spans) | about 250 |
| **request** | **842** |

## Findings, ranked by payoff against risk

### 1. One hot source serializes on the `Work` lock even though waiters revalidate anyway

- **Severity:** High. Measured.
- **Where:** `execution/source_cache.ex:43-70` (`acquire` always runs `Work.run`) and `cache/work.ex:18-60` (a lock and an unlock call to the VM-wide `ImagePipe.Cache.Work` GenServer, keyed per source).
- **Evidence:**
  - A local file source has no freshness, so every warm hit revalidates it (`status` returns `:requires_validation`, then `fetch` stats the file). Receive tracing shows one `:lock` and one `:unlock` call to `Cache.Work` per request.
  - Concurrent requests for the same source queue behind one holder. A waiter that gets the lock as `:coalesced` re-reads the record (lines 56-57), finds it still needs validation (`validated_on_every_use?`, lines 72-80), and stats the file itself. The lock serializes the work but deduplicates nothing.
  - What-if patch: skip `Work.run` when `validated_on_every_use?(previous, source)` and call `status`/`fetch` directly. Writes still go through `Work.publish`.

    | | baseline | patched |
    |---|---|---|
    | 1 source, 8 tasks | 1,501 req/s | **2,291 req/s (+53%)** |
    | 8 sources, 8 tasks | 2,194 req/s | 2,278 req/s |
    | sequential CPU per hit | 751 µs | 708 µs (−6%) |

    With the patch, one hot source reaches the same ceiling as eight distinct ones.
- **Suggested fix:** don't take the per-source lock when the previous record must be validated on every use. The lock still pays off for the first fetch (`previous == nil`) and for records with remaining freshness, where coalesced waiters really do reuse the holder's result. `publish_coordinated` (lines 165-174) already takes the publication lock only for writes. A lease-less publish uses `Work.publish(key, nil, …)` (`cache/work.ex:82-84`), so publication stays ordered.
- **Caveat:** for a remote `no-cache` origin this changes N serialized conditional requests into N concurrent ones. The count is the same, but the burst shape at the origin changes. If that matters, restrict the bypass to local sources (`copy?: false`).
- **Relation to pass 2:** pass 2 #4 measured the `Work` lock only sequentially and judged it "not the throughput ceiling" because pass 2 #1 dominated then. With #1 fixed, it is now the single-source ceiling.

### 2. Every warm hit makes six synchronous calls to the VM-wide file server, through `Path.safe_relative/2`

- **Severity:** Medium–High. Measured in parts; the end-to-end what-if was not run (see below).
- **Where:**
  - `cache/file_system/store.ex:954-967` (`paths_from_hash`) calls `validate_under_root` (lines 1097-1108) on both cache reads, the source record and the output entry.
  - `source/file.ex:203-209` (`safe_path`) runs during resolve and again during the revalidating fetch.
  - Both call `Path.safe_relative/2`. That is `:filelib.safe_relative_path/2`, which runs `:file.read_link/1` per path segment. `:file.read_link` is a `gen_server` call to `file_server_2`, a single process for the whole VM.
- **Evidence:**
  - Tracing shows 6 `file_server_2` `:read_link` calls per warm hit: 2×2 for the `xx/yy` partition dirs and 2×1 for the source file name.
  - `:file.read_link/1` costs **about 10 µs** per call. That is about 60 µs per hit spent waiting on another process.
  - `Store.paths_from_hash/2` costs **40 µs** per call, so about 80 µs per hit for the two reads. Inside it, `Path.safe_relative/2` takes 15 µs, `Path.expand` ×2 plus `relative_to` take 5 µs, and the two `Path.join` calls take 2.3 µs. Plain binary concatenation of the same paths takes 0.5 µs.
  - During the 8-source concurrent run, `file_server_2` had a non-empty queue in 62% of 2 ms samples (mean 0.86, max 3). It is the third-busiest process after `Admission` and the dirty signal handler (157 reductions per request).
  - `tprof` puts `:filename.join1b/4` (438 calls per hit), `:os.type/0` (67) and `:erlang.system_info/1` (81) near the top. All three come from the `Path` work here.
- **Not measured:** a what-if that removed the symlink check was declined here as a security change, so the end-to-end win is inferred from the parts. The parts suggest about 10% of CPU and part of the gap between wall time and CPU time.
- **Suggested fix (keeping the guarantee):**
  - **Cache store:** check each `{root, prefix, first, second}` partition directory once and remember the result. An ETS set owned by the cache's supervisor works, as does a `:persistent_term` set. There are at most 65,536 entries, and they are created by the cache itself in `open_sink`. Then build `dir`/`meta_path` with binary concatenation. A symlink swapped in after the check is already a time-of-check race today, so memoizing doesn't open a new window, but Håvard should confirm that reading of the threat model.
  - **File source:** `safe_path` already rejects `..` and separators in `valid_segment?`, so only the symlink resolution needs `read_link`. Resolve once per request and pass the resolved path from resolve to fetch, which halves it. Or, if symlinks under the root are meant to be followed, document that and use `Path.safe_relative/1`. That second option is a policy decision, not a performance one.
  - Either way, call `:prim_file.read_link/1` rather than `:file.read_link/1` if a per-request check stays. It does the same check without routing through `file_server_2`.

### 3. Two Admission hit casts per warm hit, and Admission is the busiest process under load

- **Severity:** Medium. Measured.
- **Where:** `cache/file_system/store.ex:252` (`Store.get`, output entry) and `:673` (`Store.metadata_hit`, source record). Both call `Admission.hit` (`cache/file_system/admission.ex:447`).
- **Evidence:**
  - Receive tracing shows 2 `{:cast, :hit}` per warm hit, 1 per 304.
  - Under the 8-source concurrent run, the Admission process used **456 reductions per request**, more than any other process outside the request itself. On 4 cores it competes directly with the requests.
  - Pass 2 measured −15% CPU for removing all three casts that existed then. The source-record read now reads metadata only, which fixed pass 2 #1, but it was deliberately kept counting as a hit (`metadata_hit`, commit bb816de "Report metadata-only cache misses to Admission too").
- **Suggested fix:** decide whether source-index entries need hit promotion at all. They are tiny and read on every request for their source, so they would almost never be evicted by size-aware admission anyway. Alternatively, batch hits per request process: accumulate the hit descriptors and send one cast at the end of the request. Pass 2 #2 recommended the same decision. Still open.

### 4. The source record's cache state is recomputed seven times per request, with a recompiled regex each time

- **Severity:** Medium–Low. Measured in isolation.
- **Where:**
  - `source/record.ex:36-37`. `Record.state/2` runs `Origin.cache_state`, which is `CacheState.from_headers`, parsing the origin headers from scratch.
  - Call sites per warm hit: `SourceCache.status/3` 4×, from `execution.ex:171` and `source_cache.ex:60`, plus both sides of `unchanged_record?` (`source_cache.ex:271-272`). Then `validated_on_every_use?` 1×, `SourceCache.storable?` 1×, and `Execution.record_state` 1× (`execution.ex:543`).
  - Inside it, `source/cache_state.ex:197` uses an inline `~r/\A[0-9]+\z/`. On OTP 28+ that is recompiled on every call, 8 times per hit.
- **Evidence:**
  - `Record.state/2` costs **5.9 µs** per call with the real record, so about 41 µs per hit (5%).
  - The inline regex costs 2.4 µs per call, against 0.67 µs for a precompiled one and 0.09 µs for a binary digit scan. That is about 19 µs per hit.
- **Suggested fix:**
  - Use a digit scan (or `Integer.parse` with a full-consumption check) in `CacheState.seconds/2`.
  - Compute the state once per request where the record doesn't change. For example, `prepare_remote` can pass the state alongside the record into `acquire`, `storable?`, and `source_state`. Alternatively, store the parsed directives on `Origin` when it is built, so `from_headers` only does arithmetic.

### 5. Remaining recompiled regexes on the hot path

- **Severity:** Low. Measured.
- **Where (per warm hit):**
  - `cache/file_system/store.ex:1085` (`partitions`, 2×) and `:838` (`body_path_from_metadata`, 1×).
  - `source/parser.ex:44` (`@scheme_prefix`, 2×).
  - `image_pipe_url/lib/image_pipe/api/value.ex:75` (dimension, 1× per numeric option).
  - `URI.parse` (2×, from `source/parser.ex:61/65`, Elixir's own regex).
- **Evidence:** module-attribute and inline regexes are re-imported on each use under OTP 28+. That costs 2.4 µs per call, against 0.1–0.2 µs for binary pattern checks. About 14 regex calls per hit is roughly 30 µs, down from about 21 calls and 50 µs in pass 2.
- **Suggested fix:**
  - Replace the hex-hash and digit checks with binary scans or guards.
  - `Source.Parser.do_translate` runs twice per request (resolve and fetch). Carrying the translated source forward would also halve the `URI.parse` calls.
  - Pass 2 #6 recommended the same. It is partly done and still open for these sites.

### 6. Parse is 35–72 µs, mostly list and map churn in plan assembly

- **Severity:** Low. Measured.
- **Where:** `plug/request.ex:15-44` → `image_pipe_url/lib/image_pipe/api/parser.ex`, `Plan.Spec` assembly and `Plan.Spec.Validation`.
- **Evidence:**
  - `Request.parse/2` takes **35 µs** for `/w=300/format=webp/src/…` and **72 µs** for a 2-group, 9-option path with `%20` in the source.
  - `tprof` shows the time spread across `Enum.map/filter/reduce`, `Map.get` and `maps:fold`, with no single hot spot.
  - `OptionSpec.fetch/1` (`image_pipe_url/lib/image_pipe/api/option_spec.ex:688`) is still a linear `Enum.find` over 70 specs. It costs 4.5 µs for 8 keys, against 0.6 µs with a map, and only matters as part of this total.
- **Suggested fix:** a compile-time key→spec map for `OptionSpec.fetch/1` is a cheap trim. The rest only pays off if parse becomes a larger share, for example on a CDN-fronted 304 path. This was first reported in pass 1 and is still open.

### 7. `Telemetry.telemetry_opts/1` scans the whole config 11 times per request

- **Severity:** Low. Measured, end to end inside noise.
- **Where:** `telemetry.ex:376-378`. `Keyword.take(opts, [:telemetry_prefix])` walks all 41 config keys. It is called from `plug/runner.ex:26,96,306`, `cache.ex:199` (2×), `execution/source_cache.ex:71,158`, `source.ex:304,395`, `response/cache_policy.ex:75` and `response/sender.ex:70`.
- **Evidence:** 1.15 µs per call against 0.08 µs for `:lists.keyfind`, so about 13 µs per hit. A what-if patch using `keyfind` moved CPU per hit from 751 to 732 µs (−2.5%, inside noise).
- **Suggested fix:** use `:lists.keyfind(:telemetry_prefix, 1, opts)` in `telemetry_opts/1`. This is a one-line change. Pass 1 #6 and pass 2 #7 recommended the same. Still open.

## Fixed since pass 2 (verified on main)

- **Source record read twice per request (pass 2 #1):** fixed.
  - `SourceCache.acquire` re-reads only when coalesced or when the record has freshness (`execution/source_cache.ex:56-60`).
  - `Cache.source_record` reads metadata only on the file system (`cache.ex:131-160`, `cache/file_system.ex:106-115`).
  - One `[:cache, :lookup]` for the source index per hit, down from two.
- **Request cookies parsed on every request (pass 2 #3):** fixed. `plug/runner.ex:104,124-128` fetches cookies only when `storage_inputs` names one.
- **Publication lock taken when nothing is written (pass 2 #4, first half):** fixed. `publish_coordinated` (`execution/source_cache.ex:165-174`) runs `Work.publish` only for writes. The `Work` run lock is still open; see #1.
- **`Representation.build` digests twice (pass 2 #5):** fixed. One `MaterialDigest.canonical` is shared by key and ETag (`representation.ex:56-79`).
- **Cache metadata `:safe` decode across VMs (pass 2 side finding):** fixed in `store.ex` `safe_term/1`, which loads the app modules and retries.
- **First-pass items** (preset double parse, duplicate cache headers, cache-hit `send_file`, miss-path chunking): still fixed, as pass 2 found.

## Checked and fine

- **Request preparation** (`Request.prepare`: policy, negotiation, source translate, watermark plan) takes 7 µs.
- **Source resolve** for a file source takes 13 µs in isolation, apart from its `safe_path` (#2).
- **Send** for a HEAD hit is 38 µs wall, and 16 µs for a 304.
- **Wall versus CPU:** the 180–250 µs gap per hit is the 6 file-server calls (#2), the 2 `Work` calls (#1), and dirty-IO file NIFs. The dirty signal handler ran 272 reductions per request under load, which is expected for `:raw` file reads.

## Suggested order

1. **#1 (skip the `Work` lock for validated-on-every-use records).** Small, contained, and +53% on a hot source.
2. **#2 (memoize partition validation, resolve the source path once).** It removes the file-server singleton from the hot path. It needs Håvard's call on the symlink threat model.
3. **#3 (drop or batch Admission hits for source-index entries).**
4. **#4, #5 and #7 together.** Cheap CPU trims, test-first friendly.
5. **#6** only if parse cost starts to matter.

A checked-in concurrent single-source mode for `bench/warm_requests.exs` already exists (`get-concurrent`). It would have caught #1 if it reported req/s next to an 8-source run.
