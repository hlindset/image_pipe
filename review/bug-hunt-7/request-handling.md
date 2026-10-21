# Bug hunt 7: request handling

Scope: the Plug mount and runner, URL parsing and its limits, the work a single request can cause, error responses, conditional requests, request telemetry (the new cut-at-source request path and `:source_url`), the processing pool, overlap, and delivery, in `image_pipe` and `image_pipe_url` at `main` 6a87579.

How it was checked: compiled in this cloud session (4 cores, 16 GB, libvips 8.18.7 built by the session hook, Elixir 1.20.4 / OTP 29.1.1). Findings 1 to 3 were reproduced with scratch tests through `ImagePipe.Plug.call/2` on an inline mount with an `ImagePipe.Source.File` source. Findings 4 and 5 were checked by reading the code. Scratch files were not committed.

## Earlier findings

Status of `bug-hunt-6/request-handling.md` on main:

| # | Hunt 6 finding | Status |
|---|---|---|
| 1 | Per-operation work limits multiply by the number of groups | Fixed for blur, progressive blur, and sharpen (ccd23d5): `WorkLimits.convolution/2` now sums their work in `State.blur_work` across the request. Other operations still multiply; see finding 2 below. |
| 2 | Client errors log at `error` and count as `processing_error` | Fixed (dd82510): the summary line is `:error` only for `5xx` or a `200` whose stream failed; `invalid_source` and `too_many_presets` map to `:parser_error`, and both `400` clauses put a `reason`. |
| 3 | `request_path` redaction spends about 30 ms on a crafted path | Fixed. 6c4a18c made the heuristic linear, and 1354270 replaced it: the path is now cut at the first source marker and `wm-src64=` values become `REDACTED`, with nothing decoded. |

The beads on DoltHub (pulled 2026-10-21) hold nothing matching the findings below.

## Summary

| # | Finding | Severity |
|---|---------|----------|
| 1 | A request with nine or more watermark groups crashes the whole VM | Critical |
| 2 | Non-convolution operations still multiply by the number of groups (pixelate: 38 s for one request) | Medium |
| 3 | Watermark assets are read whole into memory before the pool admits the request | Medium (with `request_watermarks: true`) |
| 4 | `:source_url` redacts only eight parameter names, and concealed sources are now logged decrypted | Low–Medium |
| 5 | A standard-base64 `wm-src64` value logs its tail segments | Low |

## 1. A request with nine or more watermark groups crashes the whole VM

- **Severity:** Critical. One request kills the BEAM: every in-flight request on the node fails and the node restarts. On a mount with `request_watermarks: true` and no signing keys, any client can send it. With signing it needs one signed URL (or a preset that expands to many watermark groups).
- **Where:**
  - `image_pipe/lib/image_pipe/transform/operation/watermark.ex` (each group's composite) and the executor that chains them: each watermark group adds composite stages to one lazy libvips pipeline, and nothing bounds how many groups draw a watermark. The 64-segment lexer cap (`image_pipe_url/lib/image_pipe/api/path.ex:27`) allows about 31 groups.
  - libvips runs on a BEAM dirty CPU scheduler thread, whose stack is small by default.
- **Evidence:** `dmesg` shows the VM's dirty scheduler thread faulting just below its stack page, the pattern of a stack overflow:

  ```
  erts_dcpus_3[1247]: segfault at 7fc61434dfcc ip 00007fc5cf02b0ce sp 00007fc61434dfc0 error 6
  erts_dcpus_4[517]:  segfault at 7fc7b8264ff8 ip 00007fc779812768 sp 00007fc7b8265000 error 6
  ```

  | Request (inline mount, `request_watermarks: true`, main source `woman.jpg` 1200×800) | Result |
  |---|---|
  | 1 group with `wm-src64` | 200, 0.7 s |
  | 8 groups, each `wm-src64` of a distinct 4832×4760 JPEG | 200, 3.8 to 12.9 s |
  | 9, 10, 11, 12, 16, 20, 24, 31 groups of the same kind | VM segfault, no response |
  | 9 groups with distinct small (1200×800) assets | VM segfault |
  | 9 groups with the same large asset | VM segfault |

  The crash doesn't depend on the asset's size or on the assets being distinct, only on the number of watermarked groups. It happened every time from nine groups on.
- **Suggested fix:** bound the number of watermark composites per request at parse time, after preset expansion, with a `400` before any source access (a small fixed cap, or a host option). Separately, raise the dirty CPU scheduler stack (`+sssdcpu` in `vm.args`/`rel/env.sh` for the server) so a deep libvips pipeline fails less abruptly, and consider materializing the frame between watermark groups so the pipeline depth doesn't grow with them.
  - **Question for Håvard:** does the same happen with named watermarks (`wm=name` in nine groups), which don't need `request_watermarks`? It goes through the same composite, so it likely does, which would make the default configuration exposed whenever a named watermark is configured. Not tested here.
  - **Question for Håvard:** this probably belongs as an `image`/libvips-adjacent note too if the recursion is inside libvips rather than ImagePipe's chaining. Worth a look at whether other long lazy chains (many `bg`, `pad`, or `gradient` groups) reach the same depth.

## 2. Non-convolution operations still multiply by the number of groups

- **Severity:** Medium. The hunt 6 fix covers blur, progressive blur, and sharpen. Other operations that materialize or read the whole frame are still checked per step, so their cost is linear in the group count, and one request can hold a core for longer than the default 30 s processing deadline.
- **Where:** `image_pipe/lib/image_pipe/transform/executor/step.ex:118-128` (`work_limit/2` counts only `Blur`, `ProgressiveBlur`, and `Sharpen`); `max_intermediate_pixels` is checked per step (`WorkLimits.check/1`), so a frame at the limit passes every group.
- **Evidence** (`beach.jpg` 4000×2667, first group `w=10000/h=10000/fit=cover/enlarge`, i.e. a 100 MP frame at the limit, inline mount, one request each):

  | Following groups | Time |
  |---|---|
  | none | 6.0 s (cold), 1.5 s warm |
  | 1 × `pixelate=2` | 1.7 s |
  | 8 × `pixelate=2` | 9.0 s |
  | 30 × `pixelate=2` | 38.1 s |
  | 8 or 30 × `flip=h` | 6.1 to 6.3 s (no growth) |
  | 8 or 30 × `rotate=90` | 1.4 to 6.4 s (no growth, folded into orientation) |
  | 8 × `w=9990/h=9990/fit=cover/enlarge` | 8.0 s (no growth) |

  `pixelate` is listed in `Step.random_access?/1`, so each group materializes the 100 MP frame again before it runs. `trim=auto` and smart or detect crops are random-access too and were not measured.
- **Suggested fix:** count every random-access step against a request budget, as `blur_work` does: add `pixels` per materialization (and per pixelate/trim/smart crop) into one work counter checked against a request-wide limit, or cap the number of groups after preset expansion. The cap would also cover finding 1.
  - **Question for Håvard:** one budget for all heavy steps (rename `max_blur_work` to a general work limit), or a group cap? A group cap of about 8 would bound both this and finding 1.

## 3. Watermark assets are read whole into memory before the pool admits the request

- **Severity:** Medium with `request_watermarks: true`. Each distinct `wm-src64` asset is fetched and held as one binary in a task outside the processing pool, so the pool's concurrency doesn't bound this memory, and one request multiplies origin fetches.
- **Where:** `image_pipe/lib/image_pipe/execution/watermarks.ex:61-63` (`prepare_async/3` starts one task per distinct asset) and `:216-242` (`read/2` reads the whole body, up to `max_body_bytes`, into memory). `Execution.prepare/6` runs this before `ProcessingPool.run/3`.
- **Evidence:** with 8 groups each drawing a distinct 6 MB JPEG, the VM's binary memory peaked 48 MB above the baseline for one request (6 MB per asset), against 6 MB for one asset. With the default `max_body_bytes` (10 MB) and about 30 groups, one request can hold about 300 MB of asset bytes and start 30 origin fetches; concurrent requests multiply that with no admission. (Past 8 groups the request hits finding 1 first, so the 30-group figure is computed, not measured.)
- **Suggested fix:** cap the number of distinct watermark assets per request (the same cap as finding 1 would do), and consider reading assets inside the pool turn, or counting their bytes against a per-request input budget.

## 4. `:source_url` redacts only eight parameter names, and concealed sources are now logged decrypted

- **Severity:** Low–Medium. Telemetry fans out to every handler, including third-party exporters. Since 1354270, an `enc/` source is emitted decrypted as `:source_url`, and a concealed source is exactly where an operator would put a tokenized origin URL.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex` `@credential_params` (`awsaccesskeyid signature sig x-goog-signature x-goog-credential x-amz-signature x-amz-credential x-amz-security-token`) and `source_url/1`, called from `image_pipe/lib/image_pipe/plug/request.ex` `source_metadata/2` on every parsed request.
- **Evidence (code):** a source such as `https://cdn.example/img.jpg?token=SECRET&expires=...` (Bunny CDN token auth, which this project deploys on), `?verify=...` (Cloudflare signed URLs), `?hdnts=...` or `?__token__=...` (Akamai), `?access_token=...`, `?api_key=...`, or a path-embedded token, keeps its value in `:source_url`, the summary line, and the OTel span. Before 1354270, an `enc` source was logged as its opaque token.
- **Suggested fix:** extend the list with the common names above, or let the host add names (a `redact_params` option), or redact every query value of a concealed source by default.
  - **Question for Håvard:** CLAUDE.md now says decrypted sources are emitted on purpose. Is a wider default list enough, or should concealed sources keep their query redacted whole?

## 5. A standard-base64 `wm-src64` value logs its tail segments

- **Severity:** Low. Only a request the parser rejects (400), so only a client's own mistake, but its credential reaches the operator's logs.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex` `cut_path/2`: `"wm-src64=" <> _token` replaces only that one segment.
- **Evidence (code):** a client that encodes a presigned watermark URL in standard base64 sends a value with `/` in it, so the path splits there. `request_path/2` logs `wm-src64=REDACTED/<rest of the base64>/...`, and the rest decodes (with one of four alignments) to the tail of the URL, where `X-Amz-Signature` usually sits. The main `src64` is safe since the path is cut there. The heuristic removed in 1354270 joined those segments on purpose.
- **Suggested fix:** cut the path at the first `wm-src64=` segment the same way as at `src64` (`wm-src64=REDACTED` and nothing after it), which keeps the "nothing decoded" design.

## Checked and found correct

- Hunt 6 fixes: blur and sharpen work is summed per request and checked before materializing; 4xx lines log at `warning`; the path redaction no longer decodes anything.
- `URI.decode/1` in `credential_param?/1` doesn't raise on malformed escapes (`%`, `%zz`) in Elixir 1.18, 1.19, or 1.20, so a crafted query can't crash `request_metadata/1`.
- `Path.diagnostic_path/1` (rewritten in 6c4a18c) masks `sig=`, `wm-enc=`, and an `enc/` tail at the same offsets as before.
- The one-pass `src` percent-decoder (69e6358) rejects a trailing `%` or `%X` and decodes mixed-case hex.
- Error responses: `Errors.send/2` sets `no-store` for every 5xx; parse-time errors keep the host's header; errors after the policy is known carry its `Vary`.
- Early 304: skipped for stale records, uses weak comparison, ignores `*` until a cache hit proves the representation exists, and runs after the `410` for an expired URL.
- Pool, overlap, and delivery: continuations keep their deadline; a processing timeout between chunks fails the next pull; owner death cancels queued turns.
