# Bug hunt 5: request handling

Scope: the Plug mount, URL parsing and option bounds (including the new `kernel` and `priority` options), request-level response headers and error responses, the per-request summary log line, and the processing pool with low priority and streamed delivery, in `image_pipe` and `image_pipe_url` at `main` 8edf03b.

How it was checked: compiled in this cloud session (4 cores, libvips built by the session hook). Findings were reproduced with scratch tests through `ImagePipe.Plug.call/2` (File source and HTTP origins via `req_options: [plug: origin]`), a StreamData property test over the pool's bookkeeping, and direct libvips timings. Scratch files were not committed.

## Earlier findings

All eight findings in `bug-hunt-4/request-handling.md` are fixed on main: b7cc5c6 (no-store kept on expiring URLs), e2bc590 (503 when processing times out during an overlapped download), 58867c2 (materialize before pixelate), 605fe6c and b4cd8a0 (blur work bounded by pixels × sigma², buffering before blur and sharpen), 18cc51c (lenient host `Cache-Control` parsing), 6491508 (no-store on 5xx), 2f69295 (stream that finishes past its deadline), 83ae6a7 (overlap repro bench). Hunt 4's CPU table re-timed on main: `blur=1000` and `w=8000/h=8000/enlarge/blur=1000` now answer 422 in milliseconds, and the 23 s `sharpen=10/w=8000/h=8000/enlarge` case takes 2.5 s.

The open beads (DoltHub, pulled 2026-10-19) hold no request-handling bug matching anything below.

## Summary

| # | Finding | Severity |
|---|---------|----------|
| 1 | A request-chosen AVIF `effort`, with `autoquality` and `max-bytes`, costs minutes of CPU | High |
| 2 | An overlapped request takes two pool turns and can get a 503 after its work finished | Medium |
| 3 | An overlap that times out in the queue waits a second full `queue_timeout` | Low–Medium |
| 4 | Presigned credentials in a percent-encoded `src64`/`wm-src64` reach the log | Low–Medium |
| 5 | A `src` URL that decodes to invalid UTF-8 drops the summary line | Low |
| 6 | The overlap's fixed 60 s await ignores the pool's configured deadlines | Low |
| 7 | 4xx responses on expiring URLs keep the host's `Cache-Control` uncapped | Low |
| 8 | A HEAD cache miss logs body bytes that were never sent | Low (cosmetic) |

## 1. A request-chosen AVIF `effort`, with `autoquality` and `max-bytes`, costs minutes of CPU

- **Severity:** High. Anyone who can make requests (or holds one signed URL with these options) keeps cores busy for minutes per request. The 503 comes long before the work stops: a pool keeps the slot until the encode finishes, and a mount without a pool answers 503 at 60 s while the encode carries on.
- **Where:**
  - `image_pipe_url/lib/image_pipe/plan/output/avif_options.ex:14`: `effort` accepts `0..9` from the URL (`avif-options=effort:9`); the server default is 3 (`image_pipe/lib/image_pipe/config.ex:62`) and nothing caps a request's value.
  - `image_pipe/lib/image_pipe/output/encode_search.ex:38,43`: a quality search runs up to 6 encodes, and `max-bytes` adds up to 5 of its own (8978a93), each a full encode at the requested effort.
  - Output size is only limited by `max_result_pixels` (40 MP by default).
- **Evidence** (`woman.jpg`, default config, inline mount, 4 cores):

  | Path options | Result |
  |---|---|
  | `w=4000/h=4000/enlarge/format=avif` | 200, 1.0 s |
  | `w=4000/h=4000/enlarge/format=avif/avif-options=effort:9` | 200, 25.6 s |
  | `w=8000/h=8000/enlarge/format=avif/avif-options=effort:9` | 503 "image processing timeout" at 61 s |
  | `w=4000/h=4000/enlarge/format=avif/avif-options=effort:9/autoquality=99/max-bytes=1000` | 503 at 61 s |
  | `w=8000/h=8000/enlarge/format=avif/autoquality=99/max-bytes=1000` (default effort) | 200, 35.5 s |
  | `w=8000/h=8000/enlarge/format=webp/autoquality=99/max-bytes=1000` | 200, 26.6 s |

  One AVIF encode of the 40 MP result (7746×5164) directly in libvips: effort 3 takes 1.9 s, effort 9 takes 46.3 s. With up to 11 encodes in a search, one request is several minutes of CPU. The 61 s 503s on the inline mount are the delivery coordinator's 60 s `prepare` call timeout (`delivery/coordinator.ex:25`), not a deadline on the work.
- **Suggested fix:** bound the product rather than each value, as 605fe6c did for blur: reject (422) or lower the effort when `output pixels × encodes × effort cost` exceeds a budget, or add a host option for the highest effort a request may ask for (defaulting to the configured effort), and cap the search's encodes for large outputs (for example, search on a downscaled copy and encode the final quality once).
  - **Question for Håvard:** should a request be able to raise `effort` above the server's default at all, or only lower it?

## 2. An overlapped request takes two pool turns and can get a 503 after its work finished

- **Severity:** Medium. With an input cache and a large streamed HTTP original, the leader request decodes and transforms in one pool turn, then queues again for the encode. Under load it gets a 503 after its decode and transform already ran, and the prepared image sits in memory outside the pool's accounting while it waits.
- **Where:**
  - `image_pipe/lib/image_pipe/execution/overlap.ex:198`: the first turn, `ProcessingPool.within` around `Processing.prepare_download`, ends when the overlap task returns.
  - `image_pipe/lib/image_pipe/delivery/coordinator.ex:119`: the encode and stream of that prepared result go through `Delivery.stream`, whose build is wrapped in a second `ProcessingPool.within`, with a fresh admission and deadline.
- **Cause:** the queue is FIFO, so requests that queued while the overlap held the slot go first. An overlap that ended in an error (`{:processing, :timeout}`, `{:session, :timeout}`) also waits for a second turn before its `fn _ -> error end` reports it. Total time can reach about 2 × `processing_timeout` + 2 × `queue_timeout`, against the single turn the Deadlines section of `docs/processing-controls.md` describes.
- **Evidence:** a copy of the `source_overlap_wire_test.exs` setup with a pool `max_concurrency: 1, queue_timeout: 1_000`. The leader's overlap is admitted, a `ProcessingPool.run` holder queues behind it, then the origin continues:

  ```
  after overlap decode: %{active: 1, queued: 0, ...}
  holder queued:        %{active: 1, queued: 1, ...}
  after continue:       %{active: 1, queued: 1, ...}   # leader's encode now queued behind the holder
  LEADER: {503, ["1"], "image processing queue timeout"}
  ```
- **Suggested fix:** hand the overlap's turn on to the encode and stream instead of releasing and acquiring again: let the streaming build run without `within` when given an already-admitted token, or run the encode inside the overlap task's turn. Return an overlap error directly, without a pool turn.

## 3. An overlap that times out in the queue waits a second full `queue_timeout`

- **Severity:** Low–Medium. Clients wait twice the documented longest wait for a turn before their 503.
- **Where:** `image_pipe/lib/image_pipe/execution/overlap.ex:181-182`: `completed/2` maps `:queue_timeout` (and `:overloaded`) to `:skip`, and the normal path then enqueues again through the coordinator's `within` with a new `requested_at`.
- **Evidence:** same harness, `max_concurrency: 1, queue_timeout: 1_000`. A holder takes the slot, the leader's overlap queues, the origin continues, the holder is never released: the leader gets 503 after 2,118 ms with `Retry-After: 1`. With `queue_timeout: 100_000`, the request was still waiting after 65 s, queued again inside `Delivery.stream`.
- **Suggested fix:** return the `queue_timeout` error instead of skipping (skipping still makes sense for `:overloaded`), or give the fallback admission the original `requested_at` so it only gets the remaining budget.

## 4. Presigned credentials in a percent-encoded `src64`/`wm-src64` reach the log

- **Severity:** Low–Medium. The `[:request]` path, and so the summary line and every telemetry handler, carries base64 that decodes to the origin's signature. The docstring promises redaction "in every base64 spelling of a `src64` URL, including ones the parser rejects".
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:343` (`redact_tail("src64", …)`), `:320` (`wm-src64`), and `base64_presigned?/1` at `:354`, which tries the token raw, without one `.ext`, and in three base64 alphabets, but never percent-decoded and never with a trailing `/` removed.
- **Evidence** (default logger attached, source URL `https://h/a.jpg?X-Amz-Signature=secret`):
  - `GET /w=1/src64/aHR0cHM6Ly9oL2EuanBnP1gtQW16LVNpZ25hdHVyZT1zZWNyZXQ%3D` logs `[warning] GET /w=1/src64/aHR0…ZXQ%3D 400 4ms error=invalid_request reason="invalid base64url value"`. That's standard base64 with `=` as `%3D`, which is what `encodeURIComponent(btoa(url))` gives. `%2B`/`%2F` for `+`/`/` miss the same way.
  - The same token with a trailing `/` logs `reason="src64 value may not contain a slash"` with the base64 intact (depending on the token's length).
  - `wm-src64=<standard base64 with %3D>/src/beach.jpg` is also logged unredacted.
- **Suggested fix:** in `base64_presigned?/1`, also try the URI-decoded token and the token with trailing slashes removed. More robust: redact the whole tail whenever any candidate decodes to a URL with a credential parameter.

## 5. A `src` URL that decodes to invalid UTF-8 drops the summary line

- **Severity:** Low. The request is unaffected, but a client can keep its requests out of the summary log.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:333-341` (`redact_tail("src", …)` logs a credential-bearing `src` URL percent-decoded) with the rendering in `image_pipe/lib/image_pipe/telemetry/logger.ex:282`.
- **Cause:** `%FF` decodes to the raw byte `0xFF`. Logger's formatter rejects the message ("bad return value from Logger formatter"), so the line is dropped and only a debug-level formatter error remains.
- **Evidence:** `GET /w=1/src/https://h/%FF.jpg%3FX-Amz-Signature%3Ds` returns 400 and `capture_log` returns `""`; `GET /w=1/src/nope.jpg` logs normally. Logging `<<0xFF>>` directly reproduces the formatter error.
- **Suggested fix:** when the decoded URL isn't `String.valid?/1`, log the raw tail with only the credential values replaced, or run the message through `String.replace_invalid/2` before logging.

## 6. The overlap's fixed 60 s await ignores the pool's configured deadlines

- **Severity:** Low (partly confirmed).
- **Where:** `image_pipe/lib/image_pipe/execution/overlap.ex:117`: `await(state.task, 60_000)`.
- **Cause:** `queue_timeout` and `processing_timeout` have no upper bound. With their sum above about 60 s, an overlapped request becomes `{:session, :timeout}` at 60 s while other requests get the full configured deadline, and because of finding 2 that error then waits for another pool turn.
- **Evidence:** in the 65 s run from finding 3 the request was in `Delivery.stream`'s second pool wait; the 60 s branch itself firing was not observed.
- **Suggested fix:** with a pool configured, rely on the pool's deadlines (await `:infinity`), as `Delivery.prepare_timeout/1` already does.

## 7. 4xx responses on expiring URLs keep the host's `Cache-Control` uncapped

- **Severity:** Low. A shared cache keeps a 404 (or 400) for the host's full lifetime, after the URL has expired and the server would answer 410.
- **Where:** `image_pipe/lib/image_pipe/plug/errors.ex:79-92`: errors never go through `CachePolicy.limit_to_expiry`; 6491508 replaces the host header only on 5xx.
- **Evidence:** host sets `cache-control: public, max-age=86400` and `etag: "host"`; `GET /expires=<now+3600>/w=50/src/missing.jpg` returns 404 with `cache-control: public, max-age=86400`, `etag: "host"`, `vary: Accept`. A 502 gets `no-store` but still carries the host's `etag: "host"`, a validator on an error body.
- **Suggested fix:** when the request has `expires`, cap a host `Cache-Control` on 4xx with the same `cap_control/3` the image path uses. Optionally drop a host `ETag` on error statuses.
  - **Question for Håvard:** hunt 4 left 4xx host-controlled on purpose; is capping them at `expires` still in line with that, or should it stay documented as is?

## 8. A HEAD cache miss logs body bytes that were never sent

- **Severity:** Low (cosmetic).
- **Where:** `image_pipe/lib/image_pipe/response/sender.ex:345`: the streamed chunk path calls `Summary.add_bytes`; `Plug.Conn.chunk/2` sends nothing for HEAD but returns `{:ok, conn}`.
- **Evidence:** the first `HEAD /w=33/format=png/src/beach.jpg` (a streamed miss) logs `HEAD … 200 168ms 2.0kB cache=miss …`; the second HEAD (a hit) logs no size, since `send_body/2`'s HEAD clauses skip `add_bytes`.
- **Suggested fix:** skip `Summary.add_bytes` for HEAD in the chunk path.

## Checked and found correct

- New options: `kernel` and `priority` reject bad and differently-cased values with 400 before source access, `unset` and duplicates across groups behave like other options, an inert `kernel` (no resize intent) is dropped from identity, and `priority` stays out of the cache key and ETag.
- Recent header fixes hold: `no-store` survives a host `Cache-Control` on expiring URLs for unstorable origins, degraded output and `storage: :deny`; host `Cache-Control` with `immutable`, `stale-while-revalidate`, `s-maxage`, odd case, quoting and non-integer values is capped correctly; every 5xx gets `no-store` and no generated ETag.
- A 304 carries the same `Cache-Control`, `ETag` and `Vary` as its 200, including under `expires` (remaining lifetime) and `If-None-Match: *` on a hit. Junk `If-None-Match` lists don't crash; weak comparison is used; `*` only matches a proven hit.
- HEAD fills the cache and sends the same cache headers as GET; CORS headers are stamped on 204 OPTIONS, 304, errors and 200s; `filename` is restricted to `[A-Za-z0-9._-]+`, so `Content-Disposition` can't be injected.
- Summary redaction for `src` tails (malformed escapes, `;`, `#`, mixed case and double-encoded names), valid and padded `src64`, and the query string; error reasons come from fixed tables; a 100 KB path logs without crashing.
- Pool bookkeeping under a 150-run StreamData property (random `max_concurrency` 1–3, low cap 1–4, `max_queue` 0–3; start normal/low, finish, raise, owner death, cancel): active and queued counts stay consistent, no normal request waits while a slot is free, no low request waits while both a normal and a low slot are free, and everything drains to zero. Strict priority, eviction of the newest low waiter only when the queue is full, `queue_timeout` for low waiters, admission and execute spans stopped on every path.
- `Retry-After` is sent only for `overloaded` and `queue_timeout`, as `ceil(queue_timeout / 1000)`, and is left off when the pool is unavailable.
