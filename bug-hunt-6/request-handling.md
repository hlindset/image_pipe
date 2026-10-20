# Bug hunt 6: request handling

Scope: the Plug mount and runner, URL parsing and option bounds, error responses and their cache headers, the request summary log and `request_path` redaction, and the processing pool with the new overlap continuation, in `image_pipe` and `image_pipe_url` at `main` fe70ecc.

How it was checked: compiled in this cloud session (4 cores, libvips 8.18.7 built by the session hook). Findings were reproduced with scratch tests through `ImagePipe.Plug.call/2` (an HTTP origin via `req_options: [plug: origin]`, inline mount, with and without a `ProcessingPool`), with the default logger attached. A StreamData fuzz sent 7,500 requests built from about 1,200 option segments harvested from the tests and docs (1 to 6 segments with random `-` group separators, three sources, three `Accept` values, presets, named and URL watermarks) and found no 5xx and no raise. Scratch files were not committed.

## Earlier findings

Status of `bug-hunt-5/request-handling.md` on main:

| # | Hunt 5 finding | Status |
|---|---|---|
| 1 | Request AVIF `effort` with `autoquality`/`max-bytes` costs minutes | Partly fixed. d2a9f72 adds `max_effort`: `avif-options=effort:9` now answers 400 in 23 ms. The search itself at the default effort is unchanged: on the inline mount, `w=8000/h=8000/enlarge/format=avif/autoquality=99/max-bytes=1000` took 47.3 s, the same with `format=webp` 31.6 s, and `max-bytes=1000` alone 27.8 s (WebP) and 27.2 s (AVIF). |
| 2 | Overlapped request takes two pool turns | Partly fixed. bfaf924 readmits the encode as a continuation at the front of the queue with the first turn's deadline. Bead `image_plug-4yol` (hand the turn on) is still open. |
| 3 | Overlap that times out in the queue waits twice | Fixed (18f2f54): only `:overloaded` falls back, and an overlap error answers without another turn. |
| 4 | Percent-encoded `src64` credentials reach the log | Fixed (1bb703b). Confirmed: both spellings from hunt 5 now log `src64/REDACTED`. |
| 5 | Invalid UTF-8 in a `src` URL drops the summary line | Fixed (1bb703b, `String.replace_invalid/2`). Confirmed: the line is logged with `�`. |
| 6 | Overlap's fixed 60 s await | Fixed: `Overlap.wait/1` waits `:infinity` when a pool bounds the turn. |
| 7 | 4xx on expiring URLs keep the host `Cache-Control` | Fixed (974171a). Confirmed: the 404 now carries `public, max-age=3600, must-revalidate`. |
| 8 | HEAD cache miss logs body bytes | Fixed (4a7b765). Confirmed: no size on the HEAD line. |

The open beads (DoltHub, pulled 2026-10-20) hold no request-handling bug matching the findings below.

## Summary

| # | Finding | Severity |
|---|---------|----------|
| 1 | Per-operation work limits multiply by the number of groups | Medium–High |
| 2 | Client errors (400, 413, 415, 422) log at `error` and count as `processing_error` | Low–Medium |
| 3 | `request_path` redaction spends about 30 ms on a crafted 10 KB path before the signature check | Low |

## 1. Per-operation work limits multiply by the number of groups

- **Severity:** Medium–High. One unsigned request (or one signed URL) keeps a core busy for minutes, well past any deadline. Same class as hunt 4 finding 4 and hunt 5 finding 1, through a different door.
- **Where:**
  - `image_pipe/lib/image_pipe/transform/work_limits.ex:25`: `blur/2` checks `pixels × sigma²` against `max_blur_work` for one operation. Nothing sums it over the request. `max_intermediate_pixels` is also checked per step.
  - `image_pipe_url/lib/image_pipe/api/path.ex:27`: the only bound on how many groups a URL may have is the 64-segment lexer cap, so a URL can hold about 30 groups (`op/-/op/-/...`). Multi-group presets (`"small" => "w=64/-/pad=4"`) multiply further.
  - `image_pipe/docs/deployment.md:82-91` describes `max_blur_work` as the limit on a blur, and the numbers there (sigma 632 on 10 MP, 200 on 100 MP) only hold per group.
- **Evidence** (`woman.jpg`, 4000×2667, inline mount, 4 cores, each case one request):

  | Path options | Result |
  |---|---|
  | `blur=600` (1 group, inside the limit) | 200, 1.2 s |
  | `blur=600/-/blur=600/-/blur=600/-/blur=600` (4 groups) | 200, 4.1 s |
  | 16 groups of `blur=600` | 200, 15.7 s |
  | 32 groups of `blur=600` | 200, 30.9 s |
  | 32 groups of `sharpen=10` | 200, 2.7 s (vs 0.14 s for one) |
  | `w=7700/h=5200/enlarge/-/blur=316` (40 MP, at the limit) | 200, 14.2 s |
  | `w=7700/h=5200/enlarge/-/` + 8 groups of `blur=316` | inline mount: 503 at 61 s. With a `ProcessingPool` (`max_concurrency: 1`, default 30 s `processing_timeout`): 503 at 30.2 s, and the pool slot stayed taken until 101.8 s. |

  The work is linear in the group count. Every group is accepted at parse time and passes the per-operation check, since each blur sees the same 40 MP frame. With the lazy pipeline the whole chain runs inside the encode, a single libvips operation from the pool's point of view, so the processing deadline answers the client but doesn't free the slot. `rotate=37` repeated stops at 16 groups with a 422 (the frame grows past `max_intermediate_pixels`), so the intermediate limit already bounds rotation but not blur or sharpen.
- **Suggested fix:** give the request one work budget instead of a budget per operation: accumulate `pixels × sigma²` (and a comparable cost for sharpen and other convolutions) in `Transform.State` and fail with the existing 422 once the sum passes `max_blur_work`. Alternatively, or as well, cap the number of groups after preset expansion (a `max_groups` host option, or a fixed bound like 8) and reject more with a 400 before the source is fetched.
  - **Question for Håvard:** do you want a request-wide budget (keeps long useful chains possible, more code), a group cap (simple, rejects early), or both? A group cap alone still allows about 8 × the per-blur limit.

## 2. Client errors (400, 413, 415, 422) log at `error` and count as `processing_error`

- **Severity:** Low–Medium. Any client can produce error-level log lines at request rate with ordinary bad requests, which pages operators and drowns real 5xx. The OTel request span is also marked as an error, and `[:request]` metrics tagged by `:result` count these as processing failures.
- **Where:**
  - `image_pipe/lib/image_pipe/telemetry.ex:273`: `request_result/1` maps every reason it doesn't list to `:processing_error`, including `{:invalid_source, _}` (400), `{:preset, :too_many_presets}` (400), `{:transform, {:bad_request, _}}` (400), `{:transform, _}` (422: blur work, intermediate pixels), `{:page_out_of_range, _, _}` (422), `{:input_limit, _}` (413), `{:decode, _}` and `:source_format_required` (415).
  - `image_pipe/lib/image_pipe/telemetry/logger.ex:144`: `status > 0 and result == :processing_error` logs at `:error` whatever the status. The comment above it says 4xx is a warning and this clause is for "a response that failed after its headers went out", which is the 200 with a failed stream.
  - The docs promise warning: `image_pipe/docs/telemetry.md:33`, `image_pipe_server/docs/server-configuration.md:428` (`log_requests` "at `warning` for a `4xx`"), `image_pipe_server/docs/server-deployment.md:432`. `docs/telemetry-events.md:74` defines `:processing_error` as "decoding, processing, encoding, or streaming failed", which doesn't cover an invalid source URL or too many presets.
- **Evidence** (default logger, `level: :info`):

  ```
  [error]   GET /w=10/src/notimage.jpg 415 80ms error=decode reason="source response is not a supported image" ...
  [error]   GET /blur=1000/src/beach.jpg 422 30ms error=transform reason="blur exceeds the work limit" ...
  [error]   GET /w=1/src/https://h/�.jpg?X-Amz-Signature=REDACTED 400 24ms error=invalid_source
  [warning] GET /w=10/src/missing.jpg 404 2ms error=source reason="source not found" ...
  [warning] GET /w=nope/src/beach.jpg 400 0ms error=invalid_request reason="invalid value: ..."
  ```

  `{:preset, :too_many_presets}` takes the same path (checked in code, not run). The `invalid_source` line also has no `reason=`, since `Errors.send/2` doesn't put one for that clause (or for `invalid_output`).
- **Suggested fix:** make the logger's error clause specific to its purpose: `:error` for `status >= 500`, or for `status == 200 and result == :processing_error` (the failed stream). Separately, map `{:invalid_source, _}` and `{:preset, :too_many_presets}` to `:parser_error` (or `:plan_error`) in `request_result/1`, and add `Summary.put(%{reason: ...})` to the `invalid_source` and `invalid_output` clauses of `Errors.send/2`.
  - **Question for Håvard:** should an origin that serves a non-image (415) or an oversized image (413) stay at `error`, since the operator may need to act on it? If so, it would be worth saying in the docs that those 4xx are the exception.

## 3. `request_path` redaction spends about 30 ms on a crafted 10 KB path before the signature check

- **Severity:** Low. A cost amplification for unauthenticated clients on signed mounts: the redaction runs on every request before `Security.verify/3`, so the signature doesn't protect it.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:331-354` (`redact_segment_list/1` and `joined_presigned/4`). For each `wm-src64=` token that doesn't decode to a presigned URL by itself, `joined_presigned/4` joins up to 64 following base64-looking segments, and `base64_presigned?/1` decodes the whole joined string again at each step, in up to 8 spellings × 3 alphabets. The cost per token is quadratic in the 64-segment window, so the docstring's "linear in the path's length" holds only with a large constant.
- **Evidence** (`ImagePipe.Telemetry.request_path/2` alone, no other load; 10,000 bytes is Bandit's default request-line limit):

  | Path shape | Size | Time |
  |---|---|---|
  | 30 × (`wm-src64=AAA` + 64 segments `AAAA`) + `/src/x.jpg` | 10,000 B | 30.1 ms |
  | 800 × `wm-src64=AAA` | 10,410 B | 3.1 ms |
  | one 9,000-byte `wm-src64` token | 9,020 B | 0.6 ms |
  | `src64/` + 9,900 bytes | 9,911 B | 0.6 ms |

  A normal request path takes microseconds here, so one crafted request costs about as much as a few thousand ordinary ones.
- **Suggested fix:** decode the joined token incrementally, or decode only at a segment that can end a token (one with `=`, `.`, or followed by a non-base64 segment). A simpler bound: stop joining once the joined token is longer than the longest base64 a `wm-src64` value can hold, or redact a `wm-src64` run whole when any decoded prefix contains `?` and a credential name.

## Checked and found correct

- Error cache headers: a 4xx on an expiring URL is capped at `expires`, every 5xx is `no-store`, the 410 for an expired URL comes from `Processing.prepare` before the early-304 gate, and parse errors (malformed, bad signature) keep the host's header as 974171a intends.
- The new effort limit: `effort` above `max_effort` is a 400 before the source is fetched, only the explicit format's options are checked when there is one, and JPEG/PNG options (no `effort` field) pass through `validate_effort/3` without a lookup.
- Overlap and pool: a continuation is admitted ahead of normal and low waiters, keeps the first turn's deadline, isn't turned away as overloaded, and answers `{:processing, :timeout}` when that deadline has passed; an overlap error answers without a second turn. A queue timeout during the overlap no longer re-queues.
- The redaction fixes from hunt 5 (percent-encoded and slash-terminated `src64`, invalid UTF-8 in `src`), HEAD byte counts, and `Retry-After` read without a pool call.
- Identity: every host output setting that changes bytes (`quality`, per-format options, `strip_color_profile`, `preserve_hdr`, `skip_processing_formats`) is in `Policy.identity_material/1`, so a config change moves the ETag and the cache key. `filename`, `attachment`, `debug`, and `priority` stay out.
- `Content-Disposition` covers every source format a skipped original can have (`:svg` can't be skipped), so `Disposition.render/2` can't fail on delivery.
- Fuzzing (7,500 requests, described at the top): no 5xx, no raise, no crash in the diagnostic renderer across presets, watermarks, group separators, and `Accept` values.
