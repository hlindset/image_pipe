# Bug hunt 4: request handling

Scope: the Plug mount, URL parsing and option bounds, signing and expiry, preset lookup, error responses, request-level response headers (Cache-Control, ETag, conditional GET, CORS), the processing pool and streamed delivery, in `image_pipe` and `image_pipe_url` at `main` db4fe3c8. The 415 that perf pass 3 saw on large private-cache originals was re-checked (see below).

How it was checked: both projects compiled in this cloud session (Elixir 1.20.4, OTP 29, 4 cores, prebuilt libvips 8.18.7). I swept every URL option alone against 56 edge values (about 3,700 requests through `ImagePipe.Plug.call/2`) and timed a set of expensive combinations on `woman.jpg` and `beach.jpg`. Cache headers were probed with scratch wire tests against an HTTP source (`req_options: [plug: origin]`) and the test `ForwardRouter`. The pool and delivery path was reviewed in parallel and each candidate there was reproduced with a scratch test. Scratch files were not committed.

## Earlier findings

All eight findings in `bug-hunt-3/request-handling.md` are fixed on main: 5b957192 (bounded values and work limits), 5302ecb2 (pool keeps capacity until timed-out workers finish), d55d501c (mount stripped by segment count), 22eae722 (NUL source is 400), 35826be3 (no preset lookup after a failed parse), 7faf2c63 and 1b14364c (host `Cache-Control` capped at `expires`), c517a35f (ignored options labelled in a 400 body). The pushed beads (`refs/dolt/data`, last bead created 2026-10-05) hold none of hunt 3's request-handling items, so I deduped against the report and main.

The sweep found no 500 and no raise for any single option at any edge value: every request returned 200, 400 or 422 in under 3 s on `woman.jpg`.

## The 415 on large private-cache originals: fixed

The cause found in `overlap-415/README.md` (the spool's prefix `pread` moved the write position on a non-raw handle) was fixed in 0afa00f3 "Write source chunks at explicit spool offsets": `append/4` now uses `:file.pwrite(io, size, bytes)` (`image_pipe/lib/image_pipe/execution/source_cache.ex:539`), and `test/image_pipe/api/source_overlap_wire_test.exs` gained a regression test.

I re-ran the original reproduction on main. `bench/overlap_decode_repro.exs` no longer starts (see finding 8), so I ran a copy patched to use an instance:

| Mode | Requests | Overlaps | Failures |
| --- | ---: | ---: | ---: |
| burst (forces >1 MiB before the overlap selects; every overlap failed before the fix) | 150 | 88 | 0 |
| auto (unpaced, like the original `send_file` origin) | 150 | 3 | 0 |

Every staged file matched the streamed digest. Nothing to file.

## Summary

| # | Finding | Severity |
|---|---------|----------|
| 1 | An expiring URL with a host `Cache-Control` turns `no-store` into a public lifetime | High |
| 2 | A processing timeout during an overlapped download crashes the request | Medium |
| 3 | Large `pixelate` sizes answer 415 "not a supported image" | Medium |
| 4 | In-bounds values still let one request run 20–30+ s of CPU | Medium |
| 5 | Host `Cache-Control` parsing under `expires` raises or skips the cap | Low |
| 6 | Error responses keep the host's `Cache-Control` | Low |
| 7 | A stream that finishes at its deadline loses its final reply | Low |
| 8 | The overlap 415 reproduction bench no longer starts | Low (tooling) |

## 1. An expiring URL with a host `Cache-Control` turns `no-store` into a public lifetime

- **Severity:** High. An image whose origin says `no-store` or `private` gets a shared-cacheable `public, max-age=…` header, so a CDN stores and serves it to other users until the URL expires. It needs an expiring URL and an earlier plug that sets `Cache-Control`, a common setup.
- **Where:** `image_pipe/lib/image_pipe/response/cache_policy.ex:191-199` (the `{true, _control}` branch of `limit_to_expiry/6`), together with `no_store/1` at `:427`.
- **Cause:** when a response may not be stored (origin `no-store`/`private`/no freshness, or a degraded detection fallback), `no_store/1` puts `cache-control: no-store` in `representation_headers`, which the Sender treats as authoritative over the host's header. That's why `no-store` normally wins. `limit_to_expiry/6` then sees a host `Cache-Control`, caps the host's value, and `List.keystore`s it into both `headers` and `representation_headers`, replacing the `no-store`. `cap_control/3` only preserves `no-store` when it's in the string it caps, which is the host's, not the policy's.
- **Evidence** (HTTP source via `req_options: [plug: origin]`, `GET /format=png/src/a.png`, host plug sets `cache-control: public, max-age=86400`, same results in `:validators` and `:auto`):

  | Origin `Cache-Control` | No `expires` | `expires=now+600` |
  |---|---|---|
  | `no-store` | `no-store` | `public, max-age=600, must-revalidate` |
  | `private, max-age=600` | `no-store` | `public, max-age=600, must-revalidate` |
  | none | `no-store` | `public, max-age=600, must-revalidate` |

  Without the host header, the expiring URL keeps `no-store`. The configured `storage: :deny` case isn't affected the same way: there the host's header already wins without `expires` (`denied_storage_headers/1`), so capping it is consistent.
- **Suggested fix:** in `limit_to_expiry/6`, return `prepared` unchanged when it already carries `no-store` (check `representation_headers`/`headers` before the host branch), or run the expiry cap before `limit_to_source/6`'s `no_store/1`. Add a wire test: origin `no-store`, host `Cache-Control`, `expires` → `no-store`, and the same for a degraded detection fallback.

## 2. A processing timeout during an overlapped download crashes the request

- **Severity:** Medium. The request process exits (500 under Bandit, plus a GenServer crash report) where a 503 `{:processing, :timeout}` is expected. It needs a processing pool, an input cache, an HTTP origin with `Content-Length` over 1 MiB and a streamable image, and a download still running when `processing_timeout` (default 30 s) passes during overlap. A slow origin for a large image is enough.
- **Where:**
  - `image_pipe/lib/image_pipe/execution/overlap.ex:156`: `ProcessingPool.within(pool, download, config, fun)` makes the `Source.Download` GenServer the job's owner.
  - `image_pipe/lib/image_pipe/processing_pool.ex:145` (`within/4` passes the owner as the notification target) and `:276` (the active deadline sends `{:processing_timeout, worker}` to it).
  - `image_pipe/lib/image_pipe/source/download.ex:110-125`: `handle_info/2` only matches `:DOWN`.
- **Cause:** at the deadline the pool sends `{:processing_timeout, task_pid}` to the Download process, which has no clause for it and dies with `FunctionClauseError`. The request process is inside `GenServer.call(download, {:advance, n})` (or `:finish`) in `SourceCache.spool_file`, so the call exits and the exit escapes `ImagePipe.Plug.call/2`.
- **Evidence:** scratch test based on `source_overlap_wire_test.exs` (`PacedSourceOrigin`, `waterfall.jpg`, `cache` and `input_cache`, `http_cache: :auto`) plus a pool `max_concurrency: 2, processing_timeout: 200`. Hold the origin, wait 600 ms, release it:

  ```
  [error] GenServer #PID<0.488.0> terminating
  ** (FunctionClauseError) no function clause matching in ImagePipe.Source.Download.handle_info/2
      lib/image_pipe/source/download.ex:110: ImagePipe.Source.Download.handle_info({:processing_timeout, #PID<0.489.0>}, %{...})
  ```

  The caller then exited with `GenServer.call(#PID<..>, {:advance, 524306}, 5000) ** (EXIT) ... FunctionClauseError`. The pool ended at `active: 0, queued: 0`, so no capacity leaked.
- **Suggested fix:** have Overlap pass a notification target it owns (an internal `within/5` with `self()` or an alias); the release already turns the result into `{:error, {:processing, :timeout}}`, so the message can be dropped there. Ignoring `{:processing_timeout, _}` in Download also works. Add a wire test like the reproduction that asserts 503.

## 3. Large `pixelate` sizes answer 415 "not a supported image"

- **Severity:** Medium. A valid request on a valid image gets a status that blames the source, logged as a decode failure (`error: :decode`), which misleads alerting and anyone debugging the origin.
- **Where:** `image_pipe/lib/image_pipe/transform/operation/pixelate.ex:59-67` (`mirror_embed/5`), `image_pipe/lib/image_pipe/transform/executor/step.ex:59-66` (`Pixelate` isn't listed as random-access), and the materializer mapping copy failures to `{:decode, _}` (`transform/materializer.ex:31`).
- **Cause:** pixelate pads the image up to a multiple of the block size with `extend_mode: :mirror`. Mirroring past the bottom edge reads rows backwards. On a sequential (streamed) decode that works while the padding fits libvips' line cache, and fails once it doesn't. The failure surfaces at `copy_memory` as "Failed to memory copy image", which becomes `{:decode, _}` and 415. `sequential_access_test.exs:142` proves pixelate streaming only for `size: 8`.
- **Evidence** (`GET /pixelate=N/format=jpeg/src/IMG`, default config):

  | N | beach.jpg (4000×2667) | cooking.png | concert.jpeg |
  |---|---|---|---|
  | 2000 | 415 | 415 | 200 |
  | 3000 | 200 | 200 | 200 |
  | 5000, 2147483647 | 415 | 200 | 200 |

  The same pipeline outside ImagePipe: embed-mirror → shrink → zoom → crop on `Image.open(..., access: :sequential)` fails for size 2000 and 4000 with `{:error, "Failed to memory copy image"}`, and succeeds with the default (random) access.
- **Suggested fix:** classify `Pixelate` as random-access in `Step.random_access?/1`, or only when the padding is more than a few rows (`target_height - height`). Extend the sequential-equivalence test to large sizes (`size` near the image's longer side). Separately, a materialize failure after a successful decode could be reported as a transform error (422) rather than 415, but that touches the documented "materialization failures are decode failures" rule, so Håvard decides.

## 4. In-bounds values still let one request run 20–30+ s of CPU

- **Severity:** Medium. Hunt 3's fix bounds values and intermediate pixels, but the allowed corner still costs tens of seconds of CPU per request. On a mount without a processing pool there's no deadline at all. Anyone who can make requests (or holds one signed URL with these options) can keep cores busy.
- **Where:** `image_pipe_url/lib/image_pipe/plan/value_bounds.ex` (`blur?` allows sigma up to 1000, `sharpen?` up to 10), with `max_intermediate_pixels` defaulting to 100 MP (`image_pipe/lib/image_pipe/config.ex:166`).
- **Evidence** (wall time, 4-core container, default config, no pool, my harness gave up at 30 s):

  | Path options | woman.jpg | beach.jpg |
  |---|---|---|
  | `blur=1000` | 1.8 s | 17.5 s |
  | `sharpen=10/w=8000/h=8000/enlarge` | 23.6 s | 23.5 s |
  | `w=8000/h=8000/enlarge/blur=1000` | > 30 s | > 30 s |
  | `zoom=200/w=40/enlarge` | 3.0 s | 3.1 s |
  | `rotate=45/w=8000/enlarge` | 3.3 s | 4.1 s |

  The cases hunt 3 listed (`pad=10000`, `w=50000/h=50000/enlarge`, `w=100/dpr=500/enlarge`) now fail fast with 422.
- **Suggested fix:** blur cost grows with sigma times pixels, so bound the product rather than each value. For example, scale the effective sigma with the downscale already applied, or reject (422) when `sigma × output pixels` exceeds a budget. Lowering the sigma cap to a few hundred (hunt 3's suggestion; imgproxy caps blur too) removes most of it.
  - **Question for Håvard:** is a deadline on mounts without a pool wanted (for example a default `processing_timeout`), or is "add a pool" the documented answer for public mounts?

## 5. Host `Cache-Control` parsing under `expires` raises or skips the cap

- **Severity:** Low. The header comes from the host app, but each variant is valid HTTP.
- **Where:** `image_pipe/lib/image_pipe/response/cache_policy.ex:252-256` (`directive_seconds/2`) and `cap_control/3`.
- **Cause:** directives are matched case-sensitively and their values parsed with `String.to_integer/1`.
- **Evidence** (`GET /images/expires=now+600/w=10/src/cmyk.jpg` through `ForwardRouter`, host header set first):

  | Host `Cache-Control` | Result |
  |---|---|
  | `public, max-age="86400"` | raises `ArgumentError`, so every expiring URL on the mount is a 500 |
  | `public, max-age=86400.5` | raises `ArgumentError` |
  | `public, MAX-AGE=86400` | `public, MAX-AGE=86400, must-revalidate`, not capped |
  | `public` | `public, must-revalidate`, no `max-age`; `public` allows heuristic freshness, so a cache may keep it past the expiry |

- **Suggested fix:** compare directive names case-insensitively, accept quoted values, treat unparsable values as absent (or drop them), and add `max-age=<remaining>` when the host gave none. Add cases to the existing expiry wire test.

## 6. Error responses keep the host's `Cache-Control`

- **Severity:** Low. A host that sets a long public lifetime for its image route also gets it on 400, 404, 502, 503 and 504, so a CDN keeps serving a transient overload or origin outage for as long as the host's lifetime.
- **Where:** `image_pipe/lib/image_pipe/plug/errors.ex:73` and the other `send/2` clauses set no `Cache-Control`; the host's header passes through.
- **Evidence:** with an earlier `cache-control: public, max-age=86400`, `GET /images/w=abc/src/...` returns 400 and `GET /images/w=10/src/images/nope.jpg` returns 404, both with `cache-control: public, max-age=86400`.
- **Suggested fix:** on 5xx (at least 502–504 and 503), replace any host `Cache-Control` with `no-store`, as the policy already does for unstorable images. 4xx could stay host-controlled.
  - **Question for Håvard:** override the host on errors, or document that a host `Cache-Control` applies to errors too?

## 7. A stream that finishes at its deadline loses its final reply

- **Severity:** Low. The response is truncated either way; this misreports it, and `ImagePipe.run/4` returns an odd error.
- **Where:** `image_pipe/lib/image_pipe/processing_pool.ex:253-258` (the `:release` handler rewrites the result to `:timeout` when the deadline has passed but the deadline timer hasn't fired yet) and `image_pipe/lib/image_pipe/delivery/producer.ex:87` (`finish/3` sends a bare `{:error, _}` with the ref of the first demand).
- **Cause:** when release rewrites the result, no `{:processing_timeout, _}` notification is sent (the timer later finds the job gone), and the producer sends the error under a stale ref. The coordinator drops it, waits for the producer to exit `:normal`, and replies `{:error, {:session, {:producer_down, :normal}}}`.
- **Evidence:** pool `max_concurrency: 1, processing_timeout: 300`, a two-chunk `Delivery.stream`. After the first chunk, `:sys.suspend(pool)`, call `next` in a task, wait until the release is queued, sleep 400 ms, `:sys.resume(pool)`. The final `next` returned `{:error, {:session, {:producer_down, :normal}}}`, where `{:error, {:processing, :timeout}}` (or `:done`) was expected. The suspend only widens a real window: the pool's mailbox delay at the deadline.
- **Suggested fix:** have release send the notification when it rewrites the result, or have the producer send the rewritten final reply with the caller and ref of the reply it replaced (`{:reply, caller, ref, error}`).

## 8. The overlap 415 reproduction bench no longer starts

- **Severity:** Low (tooling). The script that reproduces finding e4a.15.7 can't check for a regression.
- **Where:** `image_pipe/bench/overlap_decode_repro.exs:28` and `:156-157`.
- **Cause:** it configures `cache:`/`input_cache:` inline without `max_size_bytes`, and inline configurations with caches now raise (28175e2b "Make an instance the only way to use a cache").
- **Evidence:** `mix run --preload-modules bench/overlap_decode_repro.exs burst 40` fails with `invalid cache config: {:invalid_cache_config, {:missing_required_option, :max_size_bytes}}`; with sizes added it fails with "a configuration with cache or input_cache must be used through an ImagePipe instance".
- **Suggested fix:** start `{ImagePipe, name: ..., ...}` with `max_size_bytes` on both caches, mount with `instance:`, and pass the name to `ImagePipe.run/4`. That is the patch used for the reruns above.

## Checked and found correct

- Signature verification still runs before lexing, accepts only the canonical 43-character spelling, and compares with `:crypto.hash_equals/2`.
- Mount stripping: empty segments after the mount (`/images//w=10/...`) give a 400, a trailing slash after the source gives 404, a query string gives 400.
- Conditional GET: `*` only matches after a cache hit, weak tags match, an unstorable source emits no ETag so it can't get an early 304.
- Preset lookup: fetch errors, non-map results and raises map to 503; cycles and over-limit stored definitions to 500; the lookup is skipped when options don't parse.
- Configured `storage: :deny` with and without `expires`, with and without a host header, behaves as documented.
- Pool and delivery: queue and active deadlines, owner or worker death while queued or active, cancel paths, every admission and execute span stopped, slot release after a raise, pool death mid-job (503), the coordinator's prepare and pull timeouts, output leases committed only on `:done`, nothing cached for truncated or failed streams, abort-after-headers including the Bandit HTTP/2 workaround.
- Every option alone at every swept edge value: no 500, no raise, no request over 3 s on a small image.
