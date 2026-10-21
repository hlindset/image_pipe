# Performance review 6: request path

Scope: the Plug request lifecycle from parse through delivery, as a warm request sees it: parse, output negotiation, source resolve and revalidation, the in-memory source records, the output cache read, representation, the conditional gate, and the response. Reviewed at `main` 6a87579 (after PR #1056, the metadata memo). No code was kept. Paths are relative to `image_pipe/lib/image_pipe/`.

## How this was measured

Everything ran against the real code in this container (Elixir 1.20.4, OTP 29, 4 vCPU, shared), with the libvips the cloud session hook builds, and the release's VM flags (`+sbwt none +sbwtdcpu none +sbwtdio very_short`).

- **Setup.** As in pass 5: one supervised instance per source setup, each with a 1 GB output cache and a 1 GB originals cache, requests through `ImagePipe.Plug.call/2` for `/w=300/format=webp/src/imageN.jpg` (N = 0..7, copies of `priv/static/images/waterfall.jpg`, 10.7 MB). Sources: **file** (`Source.File`, `verify: :stat`), **http_fresh** (`Source.HTTP` against a local Bandit origin with `max-age=3600` and an ETag) and **http_nocache** (`no-cache`, so every request revalidates). Findings 1 and 2 also use `/w=300/src/image0.jpg` (no `format`, so the output is negotiated) with a Chrome `Accept` header: `image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8`.
- **CPU per request** is whole-VM CPU (`:erlang.statistics(:runtime)`), **wall** is the loop's wall time; medians of 5–7 rounds of 1,500–2,000 requests.
- **What-if patches** sat behind a `:persistent_term` flag, were measured interleaved with the baseline in the same VM, and were reverted. They bound what a fix can win.
- **Isolated costs** come from compiled-module micro-benchmarks (20,000–30,000 iterations) fed with arguments captured from a real request by call tracing. Call counts and callers come from `tprof` and call tracing with `caller_line`.

**This VM is about twice as slow as pass 5's.** To tell a slower machine from a regression, `fe70ecc` (the commit pass 5 reviewed) was built in a worktree and run interleaved with `main`, two rounds each:

| case | fe70ecc (pass 5) | main |
|---|---|---|
| file HEAD hit, wall | 751 / 695 µs | 731 / 674 µs |
| file early 304, wall | 437 / 452 µs | 444 / 468 µs |
| http_fresh HEAD hit, wall | 799 / 884 µs | 667 / 744 µs |
| http_fresh early 304, wall | 276 / 298 µs | 285 / 317 µs |
| http_nocache HEAD hit, wall | 2,638 / 2,581 µs | 2,419 / 2,327 µs |

No regression: the 304s are unchanged within noise, and the HTTP HEAD hit is about 15% faster (the metadata memo, PR #1056). Compare the numbers below with each other, not with pass 5's tables.

A harness note for later passes: `Plug.Test` sends every response to the calling process as a message. Left in the mailbox they make every GC scan them, and over a long run they tripled the measured time (an http_fresh 304 went from 250 to 790 µs). The harness flushes the mailbox after each request. Pass 5's harness may not have, which would make its pass 4 comparison unreliable too.

### Baseline on main

| source | case | CPU | wall |
|---|---|---|---|
| file | warm HEAD hit | 813 µs (731–870) | 610 µs (530–678) |
| file | early 304 | 461 µs (413–537) | 400 µs (363–526) |
| http_fresh | warm HEAD hit | 760 µs (729–840) | 797 µs (703–879) |
| http_fresh | early 304 | 275 µs (230–324) | 279 µs (233–328) |
| http_nocache | warm HEAD hit | 2,004 µs | 2,242 µs |
| http_nocache | early 304 | 1,553 µs | 1,827 µs |

Throughput (8 tasks, 4,000 requests, 3 rounds; noisy on this VM):

| source | HEAD, 1 source | HEAD, 8 sources | 304, 1 source | 304, 8 sources |
|---|---|---|---|---|
| file | 6,140–6,520 req/s | 6,240–6,660 req/s | 9,050–10,520 req/s | 10,320–11,330 req/s |
| http_fresh | 5,600–5,660 req/s | 5,680–5,920 req/s | 10,860–16,500 req/s | 12,100–13,020 req/s |
| http_nocache | 2,280–2,650 req/s | 1,600–1,800 req/s | 3,320–3,690 req/s | 2,720–2,970 req/s |

Where an http_fresh early 304 spends its time (inside the request span, median 181 µs; each piece measured alone with that request's arguments):

| piece | cost |
|---|---|
| `Plug.Request.parse/2` | 27–44 µs, of which `Telemetry.source_url/1` is 7–9 µs (finding 2) |
| `Representation.build/3` | 24–31 µs (finding 4) |
| `Representation.input_key/3` | 9.4 µs |
| `SourceCache.status/3` + `Execution.source_state/1` | 9.6 + 9.9 µs, nearly all `Record.state/2` (finding 3) |
| `Processing.prepare/3` (explicit format) | 5.7 µs |
| `Response.CachePolicy.generate/6` | 4.7 µs |
| `Source.resolve/3` | 6.6 µs (file source: 53 µs, its `SafePath` read_link, kept by decision) |
| `Cache.source_record/2` | 2.3 µs |
| `Source.prepare_cache_context/2` | 1.7 µs |
| send | 12 µs |

A warm HEAD hit adds the output-cache read: `Store.get/3` 95 µs in isolation, nearly all the body's `open`, `fstat` and `close` now that the metadata comes from the memo. `FileSystem.open/3` adds 1–9 µs of metadata checks on top.

## Findings, ranked by payoff against risk

### 1. Negotiating the output format from a browser's `Accept` costs 50–60 µs, about a third of an early 304

- **Severity:** Medium. Measured end to end.
- **Where:** `output/negotiation.ex:18` (`modern_candidates/3`), called once per request from `output/policy.ex:158` whenever the request has no explicit format and AVIF or WebP is enabled, which is the default. Inside it: `acceptable?/2` (`negotiation.ex:62`) re-canonicalizes every `Accept` entry once per candidate format, `parse_quality/1` (`negotiation.ex:129-132`) matches `@qvalue_pattern` for every entry, and `Format.canonical_mime_type/1` (`format.ex:120`) downcases and searches the format table each time.
- **Evidence:**
  - In isolation, `modern_candidates/3` with Chrome's `Accept` takes **49–58 µs** (`image/webp,*/*`: 17.5 µs; `*/*`: 8.3 µs). Its pieces: 14 `canonical_mime_type/1` calls (8 µs for six of them), six qvalue regex matches (12.7 µs: on OTP 28 and later a regex in a module attribute is rebuilt at every use, which the comment in `source/cache_state.ex` already notes), six `Plug.Conn.Utils.media_type/1` (7.5 µs), and `split_entries/4` building each entry a byte at a time.
  - End to end, http_fresh, early 304 with the same `Accept`: auto format **406 µs** wall, `format=webp` 292 µs, `format=webp` without `Accept` 286 µs. A call-count diff between the auto and explicit requests contains only negotiation code (226 extra `String.Unicode.downcase/3`, 65 `split_entries/4`, 49 `Enum.find_list/3`, ...).
  - What-if (negotiation result memoized per `Accept` string, so it costs nothing), interleaved, 5 rounds:

    | | baseline | negotiation free |
    |---|---|---|
    | http_fresh, auto + `Accept`, early 304 | 387 µs wall | 308 µs (−20%) |
    | file, auto + `Accept`, early 304 | 626 µs wall | 507 µs (−19%) |

    With findings 2 and 3 patched as well: 242 µs (−37%) and 413 µs (−34%).
  - A rewrite sketch (split on `,`, canonicalize each entry once, read `q` without a regex, compare against the two modern MIME types) gives the same answers on these three headers in **16 µs**, 5.4 µs and 2.1 µs.
- **Suggested fix:** parse the header once into `{canonical_mime, q}` pairs, then look up `image/avif` and `image/webp` in that list. Read the qvalue with a binary match (`"0"`, `"0."` plus up to three digits, `"1"`, `"1."` plus up to three zeros), as `CacheState.digits?/1` does, instead of the regex. Browsers send a handful of distinct `Accept` values, so a small memo keyed by the header string (and the mount's `format_order`/`auto_*` options) would make it nearly free; that needs a bound and an owner, so the parser rewrite comes first. Test first: a property test that the new parser and the current one agree on generated `Accept` headers (entries, parameters, quoted values, `q` edge cases such as `q=0.`, `q=1.000`, `q=1.5`, `q=abc`).
- **Open question for Håvard:** does the deployment's CDN (Bunny) forward the client's `Accept` unchanged, or normalize it? A normalized header, such as `image/avif,image/webp`, costs about 6 µs today, so the payoff depends on what reaches the server.

### 2. `Telemetry.source_url/1` rebuilds two regexes on every request

- **Severity:** Low. Measured in isolation. New since PR #1055 (1354270, today).
- **Where:** `telemetry.ex:325-337`, the `~r/[\x00-\x1F\x7F]/` and `~r{\A((?:[A-Za-z]...)?//)[^/]*@}` literals at lines 329 and 333. Called once per request from `plug/request.ex:55`, and once per watermark source (`:52`), whether or not any telemetry handler is attached.
- **Evidence:**
  - On OTP 28 and later a regex literal is compiled again at every use (`:re.import/1` shows up twice per request in `tprof`, next to `URI.parse/1`'s own).
  - `source_url("image0.jpg")` **7.4 µs**, about a quarter of the 27 µs parse. A URL source 5.9 µs; one with userinfo and a query 19.4 µs.
  - A version with binary scans (`:binary.match/2` for `//`, the authority's last `@`, and a byte scan for control characters) gives the same output on those inputs in 1.3, 2.3 and about 5 µs.
  - End to end the 6 µs is inside this VM's noise, so it isn't shown separately; it is part of the "all" what-if in finding 1.
- **Suggested fix:** replace both regexes with binary scans, keeping the userinfo rule exact: only an authority that follows `//` and ends before the first `/`, and only up to its last `@`. Test first: a property test comparing the new function against the current one on generated URLs and paths, including control bytes, invalid UTF-8, `@` in the path or query, and schemeless `//host` sources.
- **Related:** `Origin.validator_headers/1` and `compatible_validator?/2` (`source/origin.ex:107` and `:157`) rebuild an ETag regex on every revalidation, 2 µs each. That only matters next to a 1 ms origin round trip, so it isn't worth a change on its own, but the same rewrite would cover it.

### 3. A request re-derives its original's freshness from the stored headers 2–8 times

- **Severity:** Low. Measured in isolation.
- **Where:** `source/record.ex:27-37` (`Record.state/2`, which runs `CacheState.from_headers/4`: it splits and parses `Cache-Control` and parses `Date`, `Age` and `Expires` with `HTTPDate.parse/2`). Its callers on one request: `SourceCache.status/3` (`execution/source_cache.ex:49-50`), `SourceCache.storable?/2` (`:467-469`, from `Execution.storable?/1` on the output lookup), `validated_on_every_use?/2` (`:174-175`) and `Execution.source_state/1` (`execution.ex:758`, for the response headers).
- **Evidence:**
  - `Origin.cache_state/3` for the http_fresh record takes **6.4 µs**; for a file record 1.3 µs.
  - Calls per request: http_fresh early 304 2, HEAD hit 3; file 304 3, HEAD hit 4; **http_nocache revalidation 8** (`status/3` four times, from `resolve_record/2`, `acquire_locked/7` and twice from `unchanged_record?/4`, plus `storable?/2`, `validated_on_every_use?/2` and `source_state/1`). That is 13–19 µs on an HTTP hit and about 40–50 µs on a revalidation.
  - The result depends only on the record, the source's cache semantics (static configuration) and `now`, which only `CacheState.status/2` reads, so it is the same every time within a request.
- **Suggested fix:** compute the state once where the record enters the request (`resolve_record/2` and the acquisition paths) and carry it with the record, for example on `Acquisition`, so `status`, `storable?` and `source_state` read it. A larger version keeps the state in the source-records table with the record, keyed by the semantics it was computed for, so a warm request doesn't parse the headers at all. Test first: the existing freshness and wire tests cover the behavior; add a test that a record whose state is carried and one recomputed give the same response headers.

### 4. The cache key and the ETag serialize and hash the same 1.5 KB of key data twice

- **Severity:** Low. Measured with a what-if patch. Needs Håvard's decision, because it changes every cache key.
- **Where:** `representation.ex:56-75` (`build/3`): `hex(canonical)` digests the whole key data, then `etag(Keyword.delete(canonical, :storage_only))` serializes and digests almost all of it again. Runs once per request, 304 included.
- **Evidence:**
  - For this request the canonical key data serializes to 1,470 bytes (the group is a 29-field map). `build/3` takes 24–29 µs: canonicalize 3.5 µs, then twice `term_to_binary(…, [:deterministic])` (5.1 µs) and SHA-256 (4.5–5.3 µs on this VM).
  - What-if: digest the ETag material once, and derive the key from that digest plus the serialized `storage_only` (`sha256(etag_digest <> term_to_binary(storage_only))`). Three interleaved rounds: **27.8 / 23.6 / 29.2 µs → 17.9 / 16.6 / 15.5 µs**, about 10 µs per request.
  - The ETag value doesn't change. The key changes for every entry, so existing output-cache entries miss once after the upgrade.
- **Suggested fix:** as in the what-if, with a `Changed` changelog entry that says existing entries are regenerated. The key still covers every input it does today, so the cache-key property tests keep their meaning. `input_key/3` (9.4 µs, two digests of 400 bytes) could get the same treatment but gains less.
- **Open question for Håvard:** is 10 µs per request worth one cold output cache on upgrade? It could ride along with the next release that changes keys for another reason.

## Fixed or decided since pass 5 (verified on main)

- **#1, a fresh record read from the originals cache was never put back in memory:** fixed in 051275d (PR #1020). `SourceCache.lookup/3` falls back to `recall/2` (`execution/source_cache.ex:30-44`), which puts the record back with `Cache.recall_source/3` and `put_new`, so a newer published record isn't overwritten.
- **#2, a full record table mostly forgot `:ets.first/1`:** fixed in 051275d and moved into `Cache.RecentTable` (48c81ac). Eviction now drops the least recently used of five sampled occupied slots, with up to 16 tries (`cache/recent_table.ex:57-83`). `max_remembered_originals` now defaults to one per 50 KB of the output cache, at least 10,000.
- **#3, every output-cache hit read and decoded the metadata file:** fixed in PR #1056 (4cfda5f). `Cache.FileSystem.Memo` keeps recently hit entries' metadata in a per-root ETS table owned by Admission, with epochs against racing changes; a hit reads only the body (`cache/file_system/store.ex:440-469`). The interleaved comparison above shows the HTTP HEAD hit about 15% faster than at `fe70ecc`.
- Also landed and relevant: source records published without a cache writer (PR #1043), output entries no longer storing the source record (9d7cca1), fewer file-server calls on cache writes (PR #1048).

## Checked and fine

- **Metadata checks on a memo hit.** `FileSystem.decode_entry/2` still validates the remembered metadata, parses `created_at` and rebuilds `Debug.Info` on every hit, and `Sender.send_cache_entry/6` runs `Entry.cacheable_headers/1` again. Together 1–9 µs against a 95 µs body open; not worth a memo of the decoded entry.
- **Validation of adapter results.** `Source.valid_cache_semantics?/1` runs `NimbleOptions.validate/2` on the resolved policy every request (`source.ex:544`): 0.35–0.7 µs, and it guards a host-implementable behaviour's return value.
- **The validation cohort digest.** A revalidation digests the adapter, fetch, semantics, record and four config keys (`execution/source_cache.ex:156-166`): 12 µs, next to a 1 ms origin round trip. It could digest the static parts once if finding 3's change touches this code anyway.
- **http_nocache revalidation** is still dominated by Req/Mint and the in-VM origin: the fetch span is about 1 ms of a 1.6 ms request.
- **`Config.fetch_instance!/2`, `Plug.Config.resolve/1`** (1.9 µs with `drop_refused/1`), **`Telemetry.span/4` with nothing attached** (5–8 per request), **`Source.runtime_opts/1`** (2–3 `Keyword.take/2` per request), **`URI.parse/1`** in source translation: each a microsecond or two.
- **Mailbox-sensitive receives.** Suspected from the `Plug.Test` slowdown above, but each request-path function measured alone with 50,000 queued messages slowed only as much as GC does; the slowdown is the heap, not a selective receive. A Bandit connection process has an empty mailbox, so this is a harness issue only.

## Suggested order

1. **#1 (Accept negotiation).** A parser rewrite behind a property test, about 35–40 µs off every negotiated request, which is most of the default traffic.
2. **#2 (regex-free `source_url/1`).** Small and self-contained; it also undoes a cost added today.
3. **#3 (freshness once per request).** Larger change through `SourceCache`; it pays most on revalidating sources.
4. **#4 (one serialization for key and ETag)** only if Håvard accepts a cold output cache on upgrade, ideally batched with another key change.
