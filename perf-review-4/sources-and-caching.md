# Performance review 4: sources and caching

Repo `hlindset/image_pipe` at `8edf03b8` (main, 2026-10-19). Paths are relative to `image_pipe/lib/image_pipe/`.

Measurements ran in a 4-core cloud container (Intel Xeon 2.1 GHz, Firecracker VM, Elixir 1.20.4, OTP 29), from `image_pipe/` with `MIX_ENV=dev mix run`. File syscalls are slow on this VM (a raw `open`+`close` costs 27.5 µs, a raw `read_file` of a 1 KB file 14.6 µs), so absolute I/O numbers overstate a bare-metal host; compare within a table. Each finding says whether it was **measured** or **inferred**. The throwaway scripts are described in each finding so the numbers can be reproduced.

## Where things stand

Round three's request-path findings all landed except the spool buffering. A warm output-cache hit for a local file now costs 768 µs (`bench/warm_requests.exs get`), 563 µs for `head`, and 345 µs wall per request with 8 clients (round three, in a different container: 987 / 821 / 491 µs). A warm hit makes no calls to the VM-wide file server anymore (traced: the only `file_server` calls left come from `Plug.Test`'s `send_file`).

The biggest costs left are not on the warm path. They show up once the output cache is **full**, which is its steady state in production: a newly popular image is rendered several times before Admission keeps it, every rejected render still writes and fsyncs its body, and requests that waited on the first render all render again. Findings 1–3 are about that, and they compound.

## Ranked findings

| # | Finding | Impact | Evidence | Status |
| --- | --- | --- | --- | --- |
| 1 | On a full cache, a new image is rendered about six times before it's kept, and waiting requests each render it again | High | Measured | New |
| 2 | Writes Admission rejects still write, fsync and publish-prepare the whole body | Medium | Measured | New |
| 3 | The render cost estimate is about 10× low for progressive JPEGs, which skews admission and eviction | Medium | Measured | New |
| 4 | A warm local-file check resolves the path twice and opens the file to see that it's readable | Low | Measured | New |
| 5 | Requests for other sizes of a new original wait for its fsync before they start | Low | Measured | Remainder of round 3 #4 |
| 6 | Admission spends most of a commit sampling victims | Low | Measured (profiled) | New |
| 7 | Still open from earlier rounds | Low | Checked in code | Repeats |
| 8 | Benchmark breakage | — | Measured | New |

---

### 1. On a full cache, a new image is rendered about six times before it's kept, and waiting requests each render it again

- **Severity:** High for any deployment whose output cache has filled up. Every newly popular image costs several full renders, and a burst of identical requests renders it once per request.
- **Where:**
  - `cache/file_system/store.ex:118-151` (`get/2`) and `:413-423` (`metadata_hit/2`) report a lookup to Admission only on a **hit** (`maybe_cast_hit/2`). A miss records nothing.
  - `cache/file_system/admission.ex:317-332` (`handle_call({:commit, …})`) records the only other sighting, so a key's frequency counts commits and hits, not requests.
  - `cache/file_system/admission.ex:411-419` (`gate/3`) and `cache/file_system/policy.ex:62-65` (`admit?/3`) reject a candidate whose `frequency × cost / size` isn't above its victims'.
  - `cache/writer.ex:147-159` completes the output flight with `:ready` whatever the commit's result, and `execution.ex:471` and `:487-492` (`cached_or_make/2`) send every waiter that then misses to `make/2`, uncoordinated.
- **Evidence (measured):** a 2 MB output cache filled with 62 entries of 32 KB (cost 100 ms, each read three times), then requests for a 10 MB progressive JPEG from a local file source (`/w=300/format=webp`), libvips operation cache off.
  - Sequential requests:

    | Request | Time | Output write |
    | --- | ---: | --- |
    | 1–5 | 702–881 ms each | rejected, `score_too_low` |
    | 6 | 733 ms | admitted |
    | 7 on | 0.6–1.3 ms | hits |

    With the cap set to exactly the filled size, the image's source record was rejected too (11 rejected writes in all), so 7 of the first requests also re-read and re-hashed the 10 MB original.
  - Eight identical requests at once, on the same full cache: one led the output flight and seven waited (`:waiting` 7, `:ready` 7), then all seven rendered anyway. 8 renders, 8 source fetches, 2.4 s wall for the round, against about 0.75 s for one render. The 5 rejected and 1 admitted writes came from those 8 renders.
  - Bug hunt 1's `image_plug-e4a.3.6` (closed) noted that "admission rejection is known only at commit, so those waiters still release at the end". This is what that costs: the waiters don't just wait, they all render afterwards.
- **Why:** W-TinyLFU's sketch is meant to count *requests*, so a key requested five times has frequency five and passes the gate on its first write. Here a request that misses counts nothing until its own render commits, so "requested six times" becomes "rendered six times". Concurrency makes it worse: N requests coalesced behind one render add one sighting, not N. `bench/cache_policy.exs` models one request at a time, where each miss is also a commit, so the simulation can't see either effect.
- **Suggested fix:**
  - Count a sighting for every lookup that misses (a cast like the hit cast, or a bump on an `:atomics`-backed doorkeeper that requests can update without a message), and for every request that joins an output flight as a waiter. A key with eight concurrent requests then reaches the gate with frequency eight.
  - Optionally, when the leader's commit is rejected but it had waiters, complete the flight with something the waiters can act on as a group (promote one waiter to lead the next render) instead of `:ready`. The first change makes this rare.
  - Re-run `bench/cache_policy.exs` with misses counted to confirm the hit ratio doesn't drop on the scan-heavy workloads the doorkeeper protects against.
- **Open question for Håvard:** should a miss count as a full sighting, or only set the doorkeeper bit (so one-hit wonders still need a second request)? The second keeps the current protection and still removes the extra renders for keys requested more than once.

### 2. Writes Admission rejects still write, fsync and publish-prepare the whole body

- **Severity:** Medium on a full cache with long-tail traffic. Each rejected write costs disk bandwidth, an fsync, a writer slot (64 per root) and pending bytes, for nothing.
- **Where:** `cache/sink.ex:195` starts a writer for every storable output. The writer writes every chunk, then `cache/file_system/store.ex:308-324` (`prepare_sink_commit/1`) runs `:file.datasync/1`, writes the `.meta` temp file, and only then asks Admission, which may discard both (`admission.ex:447-453`).
- **Evidence (measured):** synchronous stores of 32 KB entries with random keys into a full cache (`Cache.Sink.store/6`, the same open, write, sync and commit a writer does):

  | Cache | Clients | Stores per second | p50 / p99 per store | Admitted |
  | --- | ---: | ---: | --- | ---: |
  | 2 MB, full | 1 | 672 | 1,363 / 3,163 µs | 0 of 2,000 |
  | 2 MB, full | 8 | 954–1,178 | 6.2–7.9 / 12.7–17.6 ms | 0 of 2,000 |
  | 100 MB, full | 8 | 1,190–1,459 | 5.0–6.0 / 10.9–13.7 ms | 2 of 2,000 |

  Every new key was rejected (equal cost and size, so equal scores), and every one paid the full write and sync first. With finding 1 in place this matters less for repeated keys, but a long tail of first requests still writes everything.
- **Suggested fix:** decide before writing. When `Sink.open` runs, the cost estimate is already known and the size can be estimated (or bounded by the encoder's first chunk). If the root is full and the key's frequency is at or below what an average victim scores, skip the writer and record only the sighting. That needs the doorkeeper (already `:atomics`) and a cheap read of the current admission bar, published by Admission after each commit, for example in `:persistent_term` or an `:atomics` cell. The final gate at commit stays as it is.

### 3. The render cost estimate is about 10× low for progressive JPEGs, which skews admission and eviction

- **Severity:** Medium. Admission scores entries by `frequency × cost / size` (`policy.ex`), so an entry whose cost is underestimated tenfold needs ten times the frequency to be admitted and is evicted first. Most web JPEGs are progressive (mozjpeg's default), and so is every JPEG fixture in `priv/static/images/`.
- **Where:** `cache/cost.ex:31-36` says the estimate can't tell baseline from progressive JPEG ("a large baseline source is overestimated"), and `:47` weights every JPEG decode at 1.3 ms per megapixel.
- **Evidence (measured):** CPU time per render with `VIPS_CONCURRENCY=1` (the cost model's own reference), read from `/proc/self/stat` around one request (`/w=300/format=webp`, no cache):

  | Original | Pixels | Estimate (`cost_us`) | Measured CPU | Ratio |
  | --- | ---: | ---: | ---: | ---: |
  | `waterfall.jpg`, progressive | 51.3 MP | 73.9 ms (stored in the entry's metadata) | 740–770 ms | ~10× |
  | `dog_2.jpg`, progressive | 23.0 MP | ~35–40 ms (from the weights) | 420–430 ms | ~11× |

  The render's own debug timings (`decode 19 ms, encode 40 ms, transform 8 ms`) miss the cost too: almost all of it is in `[:transform, :materialize]` (667–770 ms), which they don't report.
- **Suggested fix:** record whether a JPEG source is progressive (libvips exposes `jpeg-multiscan` on the decoded image) in `Debug.Info`, and give it its own decode weight from `bench/cost_calibration.exs`. Or add the materialize step to the features when it runs, since that's where the time goes.
- **Incidental, for the image-processing thread:** a 300 px WebP from a 51 MP progressive JPEG spends about 700 ms materializing the full image. If shrink-on-load could apply before that copy, both the render and this estimate would change.

### 4. A warm local-file check resolves the path twice and opens the file to see that it's readable

- **Severity:** Low. About 40–60 µs of an 811 µs warm request here (p50), less on a host with faster syscalls.
- **Where:** `source/file.ex:108-110` (`resolve/3` runs `safe_path/2`, one `read_link`), `:137-151` (`fetch/3` runs `safe_path/2` again, then `regular_file/1`, then `readable/1`, which opens and closes the file), and `:178` (`MaterialDigest.of(path)` for the evidence on every check). `execution/source_cache.ex:59-90` runs this check on every warm request with the default `verify: :stat`.
- **Evidence (measured):** span durations over 1,000 warm requests for one cached image (p50 / p90): `source.resolve` 37 / 61 µs, `source.fetch` 70 / 102 µs, `source.stage` (the fetch plus the record refresh) 98 / 150 µs, out of `request` 811 / 1,212 µs. Microbenchmarks of the syscalls involved: raw `open`+`close` 27.5 µs, raw `read_file_info` 9.2 µs.
- **Suggested fix:** when the stat evidence matches the stored record (`unchanged?/2` is true), skip `readable/1`: nothing is read on that path, and staging already turns a read failure into `:unreadable`. Carry the checked path from `resolve/3` into `fetch/3` through `Resolved.fetch` instead of checking it again.

### 5. Requests for other sizes of a new original wait for its fsync before they start

- **Severity:** Low. 11–16 ms per 6 MB original on this disk, added to each follower's latency.
- **Where:** `cache/publication.ex:50-66` hands the source lease to the writer (`Work.transfer/3`), and waiters are released only when the writer has synced, renamed and committed the original (`Work.unlock/1` at `:64`), or after `@lease_deadline` (2 s).
- **Status:** round three #4's request-side cost is gone (`71153914` moved the input write off the request). The wait moved to the followers.
- **Evidence (measured):** `bench/source_waiters.exs priv/static/images/dog_2.jpg 20 4` (5.9 MB at 20 MiB/s, followers asking for 800, 400 and 200 px): `store_wait` (follower released minus download finished) 11.1–16.1 ms in every round. Followers then decode from the stored original and finish 125–263 ms after the leader.
- **Suggested fix:** release waiters as soon as the staged file is complete and pinned, giving them the staged path through the lease, and let the writer sync and publish afterwards. The publication lock still orders writes. Keep "sync before rename" for crash safety.

### 6. Admission spends most of a commit sampling victims

- **Severity:** Low. Not a bottleneck at today's write rates, but it's the busiest work in the per-root Admission process.
- **Where:** `cache/file_system/admission.ex:473-519` (`sample_victims/4`, `draw/4`) and `:529-532` (`frequency/2`).
- **Evidence (measured, profiled):** `:tprof` call-time profile of the Admission process during the full-cache runs in finding 2: about 560–590 µs per commit (profiler-inflated; the warm-request profile inflated about 3×, so roughly 150–200 µs real). The top entries are the doorkeeper's Bloom-filter lookups (160 per commit), `phash2` (223), `strong_rand_bytes` plus `Base.encode16` for each draw (16–21 per commit), and the sketch lookups. That puts one root's Admission near 5,000 commits per second; this disk managed 1,200–1,500 stores per second.
- **Suggested fix:** draw random keys as raw bytes compared against hex keys only once, or keep the entries keyed by a random-access index (a tuple or `:atomics` slot per row) so a draw is one `:ets.lookup`. Cache each sampled entry's frequency within one commit. Only worth doing if commits ever approach that ceiling.

### 7. Still open from earlier rounds

Checked in the code at `8edf03b8`; not re-measured unless noted.

- **Spool writes go through an io server and aren't buffered** (`execution/source_cache.ex:546`, `File.open/2` without `:raw`, one `pwrite` per network message). Tracked as `image_plug-e4a.8.10` (open).
- **Two metadata reads per warm hit.** Data point for `image_plug-xdsq.4` (open): on this VM, `cache.lookup` p50 / p90 is 91 / 141 µs for the response and 48 / 80 µs for the source record, and `Store.metadata/2` alone costs 31 µs, of which the raw `read_file` is 14.6 µs and `binary_to_term` of the 911–1,205-byte metadata 3.9–8.2 µs. Together they are about 17% of the warm request.
- **Memory hunt findings 3–5 are unchanged in the code:** Admission rows still hold the full body filename (`admission.ex:570-579`), `PeriodicSweep` still sweeps inside its long-lived GenServer (`periodic_sweep.ex:35-39`), and the sketch is still an `:array` on Admission's heap (`sketch.ex:38`).
- **`Telemetry.telemetry_opts/1`** still runs `Keyword.take/2` over the 43-entry config (0.86 µs per call, 13 calls per warm request, about 11 µs).
- **S3 provider credentials** still go through a GenServer per bucket; `image_plug-e4a.8.7` was closed as not worth it.

### 8. Benchmark breakage

- `bench/source_coordination.exs` no longer starts: its `input_cache` lacks the now-required `max_size_bytes`, and its HTTP source's `allowed_hosts: ["127.0.0.1"]` no longer matches an origin on a random port since `24be9650` ("Match the port in HTTP allowed_hosts"), so every request 404s. With both fixed (`max_size_bytes: 100_000_000`, `allowed_hosts: ["127.0.0.1:#{port}"]`) it confirms round three #2 is fixed: 160 requests for one hot image made 20 origin round trips (`acquired` 20, `coalesced` 140), at 552–572 requests per second against a 10 ms origin.
- There's no benchmark for a full cache. The scripts behind findings 1 and 2 were throwaway; a `bench/full_cache.exs` (fill to the cap, then sequential and concurrent requests for a new image, counting renders and admission results) would catch regressions in both.

## Fixed since round three

Confirmed in the code and, where noted, by measurement:

- Round 3 #1, uncached DNS: `Source.HTTP.DnsCache` keeps answers for 10 s and shares concurrent lookups (`1a5d22cd`, `dc183618`, `03e39b32`).
- Round 3 #2, waiters revalidating again: a validation is shared with queued requests in the same cohort (`23f0aca1`, `4641ac76`), and a local file with `verify: :stat` is checked without the lock. Measured above (finding 8).
- Round 3 #3, symlink checks through the file server (`04623e14`, `6d7f4d8d`). Traced: no file-server calls on a warm hit.
- Round 3 #4, input write before generation: cache writes run in a capped writer off the request (`71153914`). Finding 5 is what's left.
- Round 3 #5, pinned pools keyed by IP: idle pinned pools stop and warm addresses are preferred (`9151409c`).
- Round 3 #6, last chunk waiting for the commit: the coordinator replies `:done` and the writer commits afterwards (`delivery/coordinator.ex:351-362`, `cache/sink.ex:111-119`).
- Round 3 #7: netrc is parsed once per change (`39c728a7`).
- Round 3 #8, the intermittent 415 on a large uncacheable original, was fixed on main (`0afa00f3`, then `12e58a15` and `e2bc5909`).
