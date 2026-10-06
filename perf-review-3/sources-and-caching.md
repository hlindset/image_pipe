# Performance review 3: sources and caching

Repo `hlindset/image_pipe` at `259fb05` (main, 2026-10-06). Paths are relative to `image_pipe/lib/image_pipe/`.

All measurements ran in a 4-core cloud container (ext4 on a virtio disk, Elixir 1.20.4, OTP 29, resolver `8.8.8.8` with `timeout:2 attempts:3` and no local DNS cache), from `image_pipe/` with `mix run`. Microbenchmarks report the best of five rounds unless a percentile is given. End-to-end numbers vary by about ±15% between runs, so compare within a table. Each finding says whether it was **measured** or **inferred**.

## Where things stand

Most of round two landed. A warm output-cache hit for a local file now costs about 0.8–0.9 ms through `ImagePipe.Plug.call/2` (`bench/warm_requests.exs get`: 987 µs; `head`: 821 µs; 8 concurrent clients: 491 µs wall per request, about 2,000 requests per second). Round two measured 1.7–2.0 ms.

| Benchmark | Round 2 | Now |
| --- | ---: | ---: |
| Admission hit (`bench/admission_hits.exs`, 20k / 100k entries) | 72–80 µs | 8.5 / 8.7 µs |
| Boot scan, 20k entries | 5.2–5.7 s | 1.5 s |
| Boot scan, 100k entries | 31.4 s | 7.7 s |
| Input-pool write of a cold 10 MB original (`cache.write(input)`) | 29.3 ms | 21.1 ms |
| Cache lookups per warm local-file request | 3 | 2 |

The biggest costs left in this area are on HTTP origins that send no lifetime, where every request revalidates. Two of the findings below (1 and 2) are about that path, and they compound.

## Ranked findings

| # | Finding | Impact | Evidence | Status |
| --- | --- | --- | --- | --- |
| 1 | Every revalidation pays two uncached DNS lookups, with 2 s stalls | High | Measured | Repeat (round 1 #5, round 2 #4), half fixed |
| 2 | Requests that wait on a hot key's revalidation each revalidate again | High | Measured | New |
| 3 | Each cache lookup still resolves symlinks through the VM-wide file server | Medium | Measured | Repeat (round 2 #2), half fixed |
| 4 | A cold original's input write, with a 10 MB `datasync`, still runs before generation | Medium | Measured | Repeat (round 2 #5), half fixed |
| 5 | Pinned pools are keyed by IP, so rotating DNS defeats keep-alive and pools never close | Medium | Measured (loopback) | Repeat (round 1 #7) |
| 6 | The response's last chunk waits for the output cache commit | Low | Measured | New |
| 7 | Small per-request costs: spool writes, S3 credentials, netrc, the single `Work` server | Low | Measured | Partly repeats round 1 |
| 8 | Incidental: an intermittent 415 on a large uncacheable HTTP original | Correctness | Measured | New |

---

### 1. Every revalidation pays two uncached DNS lookups, with 2 s stalls

- **Severity:** High for HTTP sources whose origin sends no `max-age` or `Expires` (the default policy revalidates them on every request), and for every cold miss.
- **Where:** `source/http/target_guard.ex:49-61` (`default_resolver/1`), used from `source/http.ex:462` unless the host passes `:address_resolver`.
- **Status:** Round two's "run A and AAAA concurrently" landed (`4fb028a`). The cache did not, and the stalls below weren't visible in round two's averages.
- **Evidence (measured):**
  - `default_resolver/1`, 150 calls per host:

    | Host | p50 | p90 | p99 | max | calls over 1 s |
    | --- | ---: | ---: | ---: | ---: | ---: |
    | `localhost` | 2.4 ms | 3.0 ms | 7.5 ms | 2,005 ms | 1 |
    | `github.com` | 2.1 ms | 17.3 ms | 2,004 ms | 2,005 ms | 2 |
    | `hex.pm` | 2.4 ms | 7.1 ms | 2,005 ms | 2,005 ms | 3 |

    About 1–2% of lookups hit the resolver's 2 s retry timeout.
  - End to end: a warm request for a 10 MB original on a loopback Bandit origin that answers `304` (`Cache-Control: public`, an `ETag`, no lifetime). The processed image is already cached.

    | Setup | µs per request (5 rounds of 1,000) | `source.fetch` p50 / max |
    | --- | ---: | ---: |
    | Default resolver | 20,500–66,400 | 3.1 ms / 2,006 ms |
    | `address_resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end` | 1,490–1,700 | 0.58 ms / 1.2 ms |
    | `cache_policy: [freshness: {:force, 3600}]` (no revalidation) | 750–860 | — |

    DNS is about 90% of a revalidating request's average cost here. Because of finding 2, one stall also holds every concurrent request for the same image.
  - A host with nscd or systemd-resolved would see smaller numbers (inferred), but a container image usually has neither, and `image_pipe_server` ships as one.
- **Suggested fix:** keep a small default TTL cache in front of `default_resolver/1`, keyed by host, in ETS, bounded in size, with a 30–60 s TTL (or the record TTL if `:inet_res` is used directly). Run the address policy on every answer, cached or not, so DNS-rebinding protection is unchanged. Cache negative answers briefly too. Hosts that already pass `:address_resolver` keep their own behavior.

### 2. Requests that wait on a hot key's revalidation each revalidate again

- **Severity:** High for popular images on origins without a lifetime, and for local files with the default `verify: :stat`. It turns per-key single-flight into a serial queue of origin round trips.
- **Where:** `execution/source_cache.ex:43-64` (`acquire/5`) and `:72-79` (`validated_on_every_use?/2`).
- **Evidence (measured):** 1,600 warm requests for one image, its processed result already cached. "Coalesced" is the `[:cache, :coordination]` result; "fetches" counts `[:source, :fetch, :stop]`.

  | Source | Clients | Requests per second | Coordination | Fetches |
  | --- | ---: | ---: | --- | ---: |
  | Local file, default policy | 1 | 1,050–1,100 | 1,600 acquired | 1,600 |
  | Local file, default policy | 8 | 1,390–1,780 | 1 acquired, 1,599 coalesced | 1,600 |
  | Local file, forced freshness | 8 | 2,580–2,810 | none | 0 |
  | HTTP origin answering 304, fixed resolver | 1 | 570–615 | 1,600 acquired | 1,600 |
  | HTTP origin answering 304, fixed resolver | 8 | 970–1,000 | 1 acquired, 1,599 coalesced | 1,600 |

  With eight clients, every request but the first queued behind the key's lock, then ran its own revalidation once it got the lock. The HTTP case is capped by one loopback round trip at a time. With the default resolver (finding 1), each queued request adds about 2.5 ms of DNS, which caps a hot image near 300–400 requests per second for the whole node however many cores it has (inferred from the two measurements). One 2 s DNS stall blocks the whole queue for that image.
- **Why it happens:** when `outcome == :coalesced`, `acquire/5` looks the record up again, which is right. But a record that must be validated on every use has `fresh_until <= received_at`, so `status/3` says `:requires_validation` and the waiter fetches again, even though the holder finished validating after the waiter arrived.
- **Suggested fix:** let a coalesced waiter accept a record whose validation finished after the waiter started waiting. For example, record the monotonic time before `Work.run` and treat a looked-up record with `received_at` at or after the waiter's arrival as current for that request. This matches what a shared cache may do with a response that completed after the request was received (RFC 9111, section 4). A cheaper variant: hand the holder's `{:ok, acquisition}` to the waiters through `Work` instead of a re-lookup.

### 3. Each cache lookup still resolves symlinks through the VM-wide file server

- **Severity:** Medium under concurrency. It's serialized across the whole VM.
- **Where:** `cache/file_system/store.ex:954-966` (`paths_from_hash/2`) and `:1097-1108` (`validate_under_root/2`, which calls `Path.safe_relative/2`); also `source/file.ex:203-210` (`safe_path/2`).
- **Status:** Round two's raw `.meta` reads and raw stats landed (`87cbaa8`). The symlink check on every path did not.
- **Evidence (measured):**
  - Tracing `gen:do_call/4` during one warm request found 6 `read_link` calls to `:file_server_2` for a local-file source and 4 for an HTTP source: two per cache lookup, two per `Source.File` path check.
  - `Store.paths/2` costs 24–34 µs per call. In a `:tprof` call-time profile of `Store.metadata/2`, `:filename.join1b/4` alone ran 107 times per call (from `Path.expand/1` twice, `Path.relative_to/3`, and `Path.safe_relative/2`). `Store.metadata/2` as a whole costs 74 µs, of which the raw read of a 505-byte `.meta` is 14 µs and `binary_to_term` is 2.7 µs.
  - Concurrency, 8,000 calls spread over 64 keys:

    | Operation | 1 process | 4 processes | 8 processes |
    | --- | ---: | ---: | ---: |
    | `Store.paths/2`, µs per call (wall) | 34.0 | 26.3 | 23.3 |
    | Lexical join of the same paths | 2.6 | 1.7 | 0.7 |

    The checked version barely scales, because every call queues on `:file_server_2`.
  - Telemetry: the two `cache.lookup` spans take 135 µs each (p50) of a 936 µs warm request.
- **Suggested fix:** as round two proposed. The partition names come from a hex hash, so a lexical check is enough for `..` and absolute paths. Verify that the root's partition directories aren't symlinks once, when `open_sink` creates them and at boot, and remember that, instead of resolving links on every read. Precompute the expanded root once in the validated options. Keep a test that a symlinked partition directory is refused. For `Source.File`, the same applies to the configured root. The per-request path under it still needs a check, but `:file.read_link_info/2` with `:raw` avoids the file server.

### 4. A cold original's input write, with a 10 MB `datasync`, still runs before generation

- **Severity:** Medium. About 21 ms per 10 MB original on a cold miss with the input pool on, inside the per-source lock and before the response is generated.
- **Where:** `execution/source_cache.ex:150-176` (`fetch/6` calls `publish_coordinated/6` before returning) and `cache/file_system/store.ex:460-471` (`prepare_sink_commit/1` runs `:file.datasync/1` on the linked body).
- **Status:** Round two's "link instead of copy" landed (`e7328b5`): the spool is hard-linked into the pool, not re-read and re-hashed. The sync and the ordering remain.
- **Evidence (measured):** `bench/coordinated_cache.exs two-pool`: `cache.write(input)` 21.1 ms for the 10,671,398-byte original (round two: 29.3 ms). Round two measured `datasync` alone at 12.7 ms for 10 MB on this disk type, against 2.2 ms for the write. `source.stage` was 143.6 ms and `source.fetch` 84.9 ms. Stage also includes the overlapped decode, so not all of the gap is waste.
- **Suggested fix:** return the acquisition to the caller first and run the input publish (sync, rename, Admission commit) after the lock is released, or in a task the lease keeps alive. Waiters already read the spooled path through the lease. Keep "sync before rename" for crash safety; only move it off the critical path.

### 5. Pinned pools are keyed by IP, so rotating DNS defeats keep-alive and pools never close

- **Severity:** Medium for HTTP origins behind CDNs or load balancers that rotate DNS answers. It costs a new TCP (and TLS) handshake per new address and leaks pools.
- **Where:** `source/http/pinned_target.ex:30-56` (`connect/6` and `pin/2` rewrite the URL host to the chosen IP, so Finch keys the pool by IP) and `:69-91` (`named_pool/1`; the pool options set no `pool_max_idle_time`).
- **Status:** Round one item 7, unchanged.
- **Evidence (measured, loopback):** small fetches through `ReqStream.open/2` against one Bandit origin.

  | Resolver answer | Fetches | New TCP connections | Processes left behind (client and server) |
  | --- | ---: | ---: | ---: |
  | Always `127.0.0.1` | 400 | 1 | 11 |
  | One random address from about 1,000 loopback addresses | 1,000 | 636 | 1,908 |

  Each new address opened a connection and a pool that stays open, because Finch's default idle time is `:infinity`. On a real network every new connection adds a round trip, and for HTTPS a TLS handshake (inferred). With finding 1's cache in place the answer is stable for the TTL, which helps, but a long-running node still accumulates one pool per address it ever saw.
- **Suggested fix:** sort the vetted addresses into a stable order before connecting, so the same address is tried first while it stays in the answer. Set `pool_max_idle_time` (for example 60 s) on the named pools so pools for retired addresses close. Optionally key the pool by hostname and pass the pinned address through Mint's connect options, if the Finch version in use allows it.

### 6. The response's last chunk waits for the output cache commit

- **Severity:** Low. About 1.5 ms per cold miss, more under disk contention.
- **Where:** `delivery/coordinator.ex:321-333` (`handle_producer_result({:ok, :done}, …)` calls `Cache.commit_sink/2`, which syncs and renames, before `GenServer.reply(from, :done)`).
- **Evidence (measured):** open, write and commit of a 32 KB output: p50 1,464 µs, p90 1,984 µs, max 4.4 ms (300 writes, bounded and unbounded alike). In the cold benchmark with four concurrent requests, `cache.write(output)` averaged 4–9 ms per write. The client has every body byte by then but waits for the chunked terminator.
- **Suggested fix:** reply `:done` first and commit afterwards in the coordinator, keeping `OutputWork.complete/2` after the commit so coalesced waiters still read a committed entry.

### 7. Small per-request costs

Each is low on its own; together they are tens of microseconds per request.

- **Spool writes go through an io server.** `execution/source_cache.ex:387-398` opens the spool with `File.open/2` without `:raw`, so every chunk is a message round trip. Writing and hashing 10 MB: 4 KB chunks 30–33 ms through the io server and 24–27 ms raw; 16 KB chunks 15–16 ms against 13.7–14 ms; 64 KB chunks 12–12.6 ms against 11.1–11.4 ms (measured). A loopback origin delivered the 10 MB body in 8–11 chunks of about 1.2 MB, so it doesn't show there. HTTPS delivers TLS records of at most 16 KB (inferred), which lands in the middle rows. Fix: open with `:raw` and buffer about 64 KB per write. Round one listed both.
- **S3 provider credentials go through one GenServer per bucket on every request**, including warm hits (`source/s3.ex:292-297` from `prepare_cache_context`, then `source/s3/credentials.ex:31-37` and `refresh_cache/entry.ex:49-50`). `Credentials.fetch/3` costs 6.6 µs with one process and 4.3 µs per call with eight (measured), and hashes `term_to_binary` of the provider options on every call to build the key. Fix: publish the current credentials to ETS or `persistent_term` on refresh. Round one item 8.
- **`auth: :netrc` re-reads and parses the netrc file on every request** (`source/auth.ex:16-20`). Not measured. Fix: cache the parsed file by path and mtime.
- **`ImagePipe.Cache.Work` is one VM-wide GenServer**, and a revalidating request makes two calls to it (lock and unlock). `Work.run/3` with distinct keys topped out at about 120,000 runs per second from 1 to 16 processes (8.0–8.6 µs each, measured). It isn't close to the limit at today's 1,000–3,000 warm requests per second per node, but `handle_call({:lock, …})` also sums waiters across all locks on every call (`cache/work.ex:111-112`). Fix, if it ever matters: partition `Work` by key hash.
- **`Telemetry.telemetry_opts/1` runs `Keyword.take/2` over the 41-entry config** 13 times per warm request (`telemetry.ex:376-378`), about 520 filter steps. Probably 10–20 µs (inferred from a tracing profile, which inflates it). Fix: put `:telemetry_prefix` into the context once.

### 8. Incidental: an intermittent 415 on a large uncacheable HTTP original

Not a performance issue, but it turned up while benchmarking and belongs to this area.

- **Severity:** Correctness. About 1% of requests in the runs below.
- **What happened (measured):** an origin serving the 10 MB `waterfall.jpg` with Plug's default `Cache-Control: max-age=0, private, must-revalidate` (so nothing is stored and every request downloads and processes the original again). Sequential requests from one client returned `415 source response is not a supported image` on 2–3 of every 300 requests in each of four runs. The failing request logged `transform materialize: materialize_error` at 25.746 s and then `source stage: ok` at 25.750 s: the decode failed while the download was still being staged. The same runs with `Cache-Control: public` (which answer `304`) never failed.
- **Which originals (measured, fixed resolver, same origin setup):**

  | Original | Size | Failed requests |
  | --- | ---: | ---: |
  | `beach.jpg` | 851 KB (below the overlap threshold) | 0 of 300 |
  | `dog_2.jpg` | 6.1 MB | 0 of 300 |
  | `waterfall.jpg` (5850×8775) | 10.7 MB | 3 of 300 |

  So DNS isn't involved, and it shows only on the largest original.
- **Possible cause (inferred, not confirmed):** the overlapped decode (`execution/overlap.ex`) reading a spool file that's still growing. Only originals over 1 MB with a `Content-Length` take that path. The failure only on the largest image (the longest download and the earliest relative start of the decode) fits that, but `dog_2.jpg` also takes the path and didn't fail.
- **Suggested next step:** a bug-hunt pass on `Overlap` and `Source.Download`, starting from this reproduction: a Bandit origin that sends `waterfall.jpg` with `Cache-Control: private`, and 300 sequential requests to `/w=300/format=webp/src/image.jpg`.

## Fixed since round two

Confirmed in the code and, where the table above says so, by measurement:

- The Admission doorkeeper hashes with `phash2` (`f129098`). Hits cost 8.5–8.7 µs, flat from 20k to 100k entries.
- Cache metadata is read and files are stat'ed with `:raw` (`87cbaa8`).
- The source record is read from metadata without opening the body (`c27f392`), the second lookup is skipped unless the lock was contended (`93795ba`, `6e987ef`), and the publication lock is taken only when there is something to write (`f4a7a2b`). An unchanged record is not rewritten: `cache.write` ran 0 times per 300 revalidating requests.
- The A and AAAA lookups run concurrently (`4fb028a`).
- Staged originals are linked into the input pool instead of copied (`e7328b5`).
- The boot scan walks the tree once, reads partitions concurrently, and skips the second metadata read (`4c8bdfa`, `f8815d9`).
- The key and the ETag share one canonicalization (`938d494`, `69e4d00`).
- `bench/coordinated_cache.exs` and `bench/warm_requests.exs` run again and drain their mailboxes (`31af175`, `f6f61f0`, `d2fcb1f`).

## Notes on the benchmarks

- `bench/admission_hits.exs 100000` prints its result and then crashes in its `after` block: `File.rm_rf!/1` fails with "file already exists" because the Admission process is still running and writes its state directory while the tree is removed. Stopping the process before the cleanup would fix it.
- None of the existing benches covers an HTTP origin that revalidates (findings 1 and 2). The script used here (a Bandit origin answering `304` to `If-None-Match`, run with and without a fixed `:address_resolver`, at 1 and 8 clients) was throwaway. It could become `bench/revalidation.exs` if that helps.
- An origin built on Plug sends `Cache-Control: max-age=0, private, must-revalidate` unless the plug sets its own. A benchmark origin that forgets this measures the uncacheable path (full download and processing on every request) instead of revalidation.
