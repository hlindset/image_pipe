# HTTP error-status contract

Beads `image_plug-b8e`. Draft for agreement; nothing here is implemented.

## Summary

ImagePipe's error statuses have no written contract. The source mapping in
`ImagePipe.Response.ErrorStatus` was carried over unchanged from imgproxy's
`fetcher/errors.go`, and the decode and limit statuses were added later without
a stated principle. imgproxy's choices aren't a reason in themselves; each
status below stands on its own rationale. The result has several gaps: missing local
files return `422`, unreachable origins return `404`, and an origin's `401` or
`403` reaches the client verbatim.

Proposal:

- Write down one principle and a status table, and publish it as
  `docs/errors.md`.
- Adopt the principle below: status reflects who can fix the failure, and what
  the client needs to know is limited by source concealment.
- Change the mappings marked in bold below. The rest of the current behavior
  stays and gets a documented rationale.
- Delete the unreachable cache-hit `500` branch.

Host configurability is out of scope, as the issue requires. `image_plug-6q9`
(a development placeholder image) is deferred until this lands.

## Principle

1. **4xx: the request cannot succeed as written against this deployment.**
   Includes a source that doesn't exist, from the client's point of view, and a
   source that exists but is not an image ImagePipe will process.
2. **5xx: ImagePipe, its host configuration, or the origin failed.** The same
   request may succeed later or elsewhere.
3. **Source concealment wins over diagnostic precision.** The client learns
   "not found", "not processable", or "upstream failed", never an origin status
   code, credential state, or path policy. Telemetry keeps the precise reason
   (`Error.tag/1`); only the response collapses.
4. **One failure class, one status.** Two reasons meaning the same thing to a
   client (the source is too large, whether in bytes or in pixels) share a
   status.
5. **Statuses borrowed from request-body semantics are accepted.** `413` and
   `415` strictly describe the client's request body, which a `GET` doesn't
   have. They are kept because they tell the client and operator more than a
   blanket `422`: "too large" and "not an image" call for different fixes.
   Consistency with principle 4 matters more than strict RFC reading.
6. **Missing capability is `501`.** A well-formed request for something this
   deployment isn't built or configured to do (an output encoder, a detector)
   may succeed on another deployment.

## Current and proposed statuses

Changes are in **bold**.

### Request phase (`ImagePipe.Plug.Errors`)

| Reason | Now | Proposed | Rationale |
| --- | --- | --- | --- |
| Parse diagnostics (`:invalid_request`) | 400 | 400 | Malformed URL |
| `:signature_without_keys` | 400 | 400 | Request uses a feature this mount doesn't configure |
| `:missing_signature`, `:invalid_signature` | 403 | 403 | Terse, no oracle |
| `:expired` | 404 | **410** | Checked after signature verification, and the expiry is in the URL itself, so saying so reveals nothing. `410` tells clients and CDNs the URL won't come back. |
| `:invalid_concealed_source` | 404 | 404 | Concealment |
| `{:invalid_source, _}`, `{:invalid_output, _}` | 400 | 400 | Malformed request |
| Method other than GET/HEAD/OPTIONS | 405 | 405 | With `Allow` |

### Source phase (`ErrorStatus.classify/1`)

| Reason | Now | Proposed | Rationale |
| --- | --- | --- | --- |
| `:not_found` (File, Mounts, S3) | 422 | **404** | Bare atom isn't a class lead, falls to the `422` default. Bug. |
| `:denied_path`, `:denied_bucket`, `:denied_host`, `:denied_scheme`, `:denied_address`, `:invalid_object` | 422 | **404** | Mount and network policy is concealed like `invalid_concealed_source` |
| Path is a directory or other non-regular file, or a path component is a file (`enotdir`), or the name is too long | 422 | **404** | No image at that path. Reported as `:not_found`. |
| `:unreadable`: `eacces` on a parent directory, `eloop`, `eio`, other `stat` errors | 422 | **500** | Host filesystem misconfiguration or fault; the client can't fix it |
| `:credentials_unavailable` | 422 | **500** | Host infrastructure failure |
| `{:bad_status, 404 \| 410}` | passthrough | 404 | Unchanged in effect |
| `{:bad_status, 401 \| 403}` | passthrough | **404** | Concealment. S3 also answers `403` for missing keys without `ListBucket`. |
| `{:bad_status, other 4xx}` (400, 429, …) | passthrough | **502** | The client can't fix an origin rejecting ImagePipe's fetch |
| `{:bad_status, 5xx}` | 502 | 502 | |
| `{:bad_status, 1xx/3xx}` | 404 | **502** | An origin answering with an unfollowed or invalid status is an upstream failure |
| `:connect_error` | 404 | **502** | Unreachable origin is a gateway failure, not absence |
| `:too_many_redirects`, `:redirect_not_followed`, `:invalid_redirect` | 404 | **502** | Same |
| `:receive_timeout` | 504 | 504 | The one true gateway timeout |
| `:truncated_body`, connection resets, `:version_mismatch`, `:*_not_modified` | 502 | 502 | |
| `:body_too_large` | 422 | **413** | Principle 4: same class as `input_limit` |
| `:invalid_body`, `:invalid_stream_chunk`, `:stream_exception` | 422 | **502** | Upstream sent a broken response |
| `:invalid_adapter_*`, `:missing_adapter` | 500 | 500 | Host configuration |
| Unrecognized host-adapter reason | 422 | **502** | An unknown source failure is not the client's fault |

The File source's `:unreadable` today comes only from `File.stat/1`, which
follows symlinks and needs search permission on parent directories but not read
permission on the file. So a regular file with mode `000` passes `fetch/3` and
fails later in decode as `{:decode, {:peek_failed, :eacces}}`, answering `415`
"not a supported image". Measured on macOS:

| Path | Result today |
| --- | --- |
| missing file | `{:source, :not_found}` → 422 |
| directory | `{:source, :unreadable}` → 422 |
| `a.jpg/x` (`enotdir`) | `{:source, :unreadable}` → 422 |
| regular file, mode `000` | fetch succeeds; `{:decode, {:peek_failed, :eacces}}` → 415 |

Proposed: `File.fetch/3` maps non-regular files, `enotdir`, and `enametoolong`
to `:not_found`, and everything else from `stat` to `:unreadable` (`500`). A
read failure at peek becomes a server error rather than a decode verdict.

The generic message for all `404` source cases becomes `"source not found"`,
and `"upstream responded #{code}"` goes away (it leaks the origin status).

### Decode, transform, output, processing

| Reason | Now | Proposed | Rationale |
| --- | --- | --- | --- |
| `{:decode, _}`, `:source_format_required` | 415 | 415 | Not an image ImagePipe accepts |
| `{:decode, {:peek_failed, posix}}` (source file exists but can't be read) | 415 | **500** | A read failure is not "not an image". See the File source note below. |
| `{:input_limit, _}` (pixels, frames) | 413 | 413 | |
| `{:page_out_of_range, _, _}` | 422 | 422 | In flight on `docs/page-selection` |
| `{:transform, {:bad_request, _}}` | 400 | 400 | Request geometry is impossible for this image |
| `{:transform, _}` | 422 | 422 | |
| `{:detector, :unavailable}` | 422 | **501** | Principle 6 |
| `{:unsupported_output_format, _}` | 501 | 501 | RFC 9110: the server lacks the functionality; another deployment may have it |
| `{:encode, _}` | 500 | 500 | |
| `{:processing, :timeout}` | 504 | **503** | ImagePipe's own work timed out; `504` stays reserved for a slow origin so the two can be told apart |
| `{:processing, :overloaded \| :queue_timeout \| :unavailable}` | 503 | 503 | |
| Anything unrecognized | 500 | 500 | |

### Cache

A cache hit whose stored entry fails `Entry.cacheable_headers/1` or
`Disposition.render/2` answers `500 "cache error"`
(`Response.Sender.send_cache_error/2`). That branch is unreachable: cache reads
already validate entries (`Cache.validate_fetched_entry/1`) and treat an invalid
one as a read error, which becomes a miss. Proposed: delete the branch.

## Mechanism

- Add explicit `source_domain_class/1` clauses for the first-party reasons above
  (`:not_found`, `:denied_*`, `:unreadable`, `:credentials_unavailable`), and
  a `{:decode, {:peek_failed, _}}` clause ahead of the general decode clause. The
  rule that a bare class atom isn't a class lead stays.
- Delete the `{:passthrough, code}` class. Its only producer is the upstream-4xx
  rule this note removes, and host configurability needs its own use case.
- Keep the `{class, detail}` class-lead form as the host source-adapter
  contract and document it in `docs/sources.md`. It is currently undocumented.
- `ImagePipe.Execution.SourceCache` invalidation on `{:bad_status, 401|403|404|410}` keys
  on the reason, not the response status, so it is unaffected.
- Fix the moduledoc's dead reference to
  `docs/superpowers/specs/2026-06-29-error-status-mapping-design.md`.

## Tests

- `error_status_test.exs`: table-driven over every reason above.
- A compact wire test (`test/image_pipe/api/error_status_wire_test.exs`) through
  `ImagePipe.Plug.call/2`: missing file and directory → 404, unreadable file
  → 500, expired URL → 410, detection without a detector → 501, origin 403 → 404 with no code in
  the body, connect error → 502, oversize body → 413, undecodable → 415,
  unsupported explicit output → 501.
- Update the tests that pin today's statuses (`source_transport_wire_test.exs`,
  `http_test.exs`, `telemetry_test.exs`, and others found by
  `grep connect_error\|body_too_large\|bad_status`).

## Docs

- New `docs/errors.md` with the table and principles, linked from
  `docs/index.md`.
- Adjust status mentions in `processing-controls.md` (timeout 504 → 503),
  `content-aware-gravity.md` (detector unavailable 422 → 501), and `sources.md`
  (adapter error contract).
- Telemetry is unaffected apart from the `status` value on the request stop
  event. Event names and error tags don't change.
