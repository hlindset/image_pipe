# Test coverage gaps, round 1

Report only: no tests were added, no beads were filed. Checked against `main` at `6a87579` (2026-10-21).

## Coverage run

| Project | Tool | Line coverage | Result |
|---|---|---|---|
| `image_pipe` | `mix coveralls.json` | 93.0% | 4,305/4,306 passed, 32 excluded by tag |
| `image_pipe_url` | `mix test --cover` | 93.5% | 661/661 passed |
| `image_pipe_server` | `mix test --cover` | 94.0% | 200 passed, 1 skipped |

The one `image_pipe` failure is environment-only: `pinning_test.exs:440` ("a silent origin on every resolved address fails by fetch_timeout") needs an IPv6 loopback, which the cloud container doesn't have. It is ignored here. The cloud session built the CI libvips (with JPEG XL), so no JXL failures showed up this time.

Each project's coverage counts only its own modules, so a miss in the `image_pipe_url` run was checked against `image_pipe`'s tests before it was reported. Several were reached there (preset cycles, `Keys` inspect redaction, decrypt without keys, most parser messages) and are listed under URL "Not findings".

Coverage was only the starting point. Most findings below are about behaviour that runs in tests but is never asserted, documented contracts with no test, ordering guarantees a refactor could break silently, and CI lanes that never run.

## Top findings

Ranked by what would break silently for users. IDs point to the sections below.

| ID | Severity | Gap |
|---|---|---|
| RH-1 + IP-1 | high | Watermark assets have their own `max_body_bytes`, `max_input_pixels` and `max_input_frames` checks, and no test sets any of them. A `wm-src64` asset could bypass every input limit unnoticed. |
| URL-1 + RH-4 | high | Nothing pins "verify the signature before parsing or calling the preset lookup". Every 403 test uses valid options and no test mounts `keys:` with `preset_lookup:`. |
| SC-1 | high | A stored original whose byte identity no longer matches the current record (`input.ex:144`) is never tested. A regression would cache v1 pixels under v2's key and strong ETag. |
| SRV-1 | high | The container smoke test greps for `WARNING` (Logger prints `[warning]`) and only requests PNG, so a release that can't encode AVIF passes CI. |
| SRV-2 | high | No server test shows `[url]` keys reach the running instance or that an unsigned URL is refused. |
| SC-2 | medium-high | No restart test for an instance with only an output cache, the same class as bug-hunt-6 #1. |
| URL-2 | medium-high | The builder ↔ parser property never generates presets, defaults, `unset`, watermarks or most option families, which is where hunts 5 and 6 found their divergences. |
| RH-3 | medium | A conditional request that arrives first in a SWR window isn't tested to start the refresh; behind a CDN the original could stay stale. |
| SC-3 | medium | A 401/403/404/410 from the origin should invalidate the record and original; only the failure-to-invalidate path is tested. |
| SC-4 | medium | Credential stripping on a same-host redirect that changes scheme or port isn't asserted. |
| IP-2 | medium | The sequential-safety gate's property-test half is missing for most streaming operations, and the equivalence check samples only 25 pixels. |
| IP-3 | medium | Detector fallback tests assert only `{:ok, _}`; the documented invalid-result → 500 / `no-store` behaviour is untested. |
| IP-4 + SRV-3 | medium | The `:image_vision` lane never runs in CI, and its face test passes on `[]`. |
| IP-5, IP-6 | medium | WebP/AVIF alpha, AVIF high bit depth, and the 16-bit and gray ICC conversions are never checked end to end. |
| IP-7 | medium | Deferred orientation properties use only `flip=h` and no anchor, focus or percentage offsets. |
| RH-5 | medium-low | `Vary` is never asserted on a 304 or HEAD response. |
| URL-3, URL-5 | medium | Order-insensitivity is property-tested on one fixed group; a missing diagnostic message would turn a 400 into a 500. |
| SRV-4, SRV-5, SRV-6 | medium | Library changes don't trigger the server image build; the fiddle's Elixir tests never run in CI; the SVG fuzz crate has drifted and its seeds are never replayed. |

## Overlaps between areas

These were found independently from two directions and are kept in both places, since each section has a different suggested test:

- RH-1 (`max_body_bytes`) and IP-1 (pixel and frame limits) are both watermark asset limits. One "asset limits" describe block in `watermark_wire_test.exs` would cover both.
- URL-1 and RH-4 are the same ordering contract; URL-1 has the fuller test list.
- IP-4 and SRV-3 are the same unrun `:image_vision` lane.
- The default telemetry prefix in async `composite_test.exs` appears in IP-13 and SRV-17.
- Shared `/tmp` roots in async tests appear in RH-11 and SC-11.

## Code that looks dead rather than untested

AGENTS.md says to delete unreachable code instead of testing it. These came up as uncovered and look unreachable from real callers. Each needs a quick confirmation before deleting:

- `SourceEncryption:117` and `Signature.Keys:22` (non-binary token or key) (URL "Not findings")
- `Parser.message_for(:empty_segment)`, never produced (URL-5)
- `InputColorManagement` Radiance branch and `encoder.ex:418` (IP-13)
- S3 refresh entry DOWN clause at `entry.ex:120` (SC-8)
- Possibly `source_cache.ex:693` `check_size!` (SC-10) and the `minimize_metadata` error branch (IP-10). Both are questions for Håvard in the text.

## Questions for Håvard

Each one is also written into its finding.

1. RH-1: should a staged watermark larger than a later-lowered `max_body_bytes` be refused, as it is now?
2. RH-3: should a stale request whose output entry was evicted answer 304 when the ETag still matches? Today it always sends a full 200.
3. RH-6: the 410 for an expired URL caps the host's `Cache-Control`, but `cdn-http-cache.md` says it is kept. Which is right? Fixing the doc looks simpler.
4. RH-7: should a crashed processing worker answer 503 or stay at 500?
5. SC-3: after a 404 during SWR, should cached outputs for that source keep being served until they expire?
6. SC-10: can `check_size!` ever be reached?
7. IP-2: is the property-test half of the sequential-safety gate meant to be waived for simple per-pixel operations? If so, AGENTS.md should say so.
8. IP-4 / SRV-3: is it deliberate that no CI job runs the `:image_vision` lane?
9. IP-5: what AVIF bit depth should `hdr=preserve` produce?
10. IP-10: can `minimize_metadata` return an error tuple at all?
11. URL-1: should an expired, unsigned URL on a signing mount answer 403 rather than 410? That is what the code does now.
12. URL-4: can `url_test.exs:632` be tightened to `{:ok, []}`?
13. SRV-11: should port-in-use and read-only cache root failures at boot become one-line `ConfigError`-style messages?

## Request handling (RH)

Overall: this area is well tested. Status mapping (`ErrorStatus`), `Conditional`, CORS, debug headers, HEAD, Retry-After, host Cache-Control on errors, expires capping, preset lookup failures, signature matrix, telemetry prefix discipline (all default-prefix handlers in async tests filter by `self()`), and summary logging all have wire-level coverage. The gaps below are what's left, ranked by impact if they regressed silently.

### RH-1. The `max_body_bytes` limit on watermark assets has no test

**Severity:** high (request safety limit on a second source path)

**Where:** `image_pipe/lib/image_pipe/execution/watermarks.ex:216-242` (`read/2`, both the staged-file branch and the stream branch). Should be covered in `image_pipe/test/image_pipe/api/watermark_wire_test.exs` (or `watermark_cache_wire_test.exs` for the staged path).

**Evidence:** watermark assets are read whole into memory, and `read/2` enforces `max_body_bytes` itself (`size > limit -> {:error, {:source, :body_too_large}}` for a staged file, a raised `StreamError(:body_too_large)` for a stream). Coverage marks lines 220 (`body_too_large` on the staged path), 222 and 242 (`:invalid_body`) as never executed. `grep -rn max_body_bytes test/image_pipe/api/watermark*.exs` returns nothing. No test anywhere sets a body limit smaller than a watermark asset. The main source limit is well tested (`coordinated_cache_wire_test.exs` "generation limits apply…", `telemetry_test.exs` "fetch_decode stop metadata reports source_error for body-size limit"), but this code is separate. If someone dropped the check, a `wm-src64=` asset (request-chosen when `request_watermarks: true`) could buffer an unbounded body in memory.

**Suggested test:** in `watermark_wire_test.exs`, mount with `max_body_bytes` set between the main image's size and a larger asset's size. Assert that `wm=<large>` answers `413 "source response exceeds the size limit"` while the plain request answers 200. Cover the input-cache (staged file) branch too: either a second case in `watermark_cache_wire_test.exs` with an input cache so the asset is staged first and the limit is then lowered (restart pattern from `coordinated_cache_wire_test.exs`), or a test that pins whatever the intended behaviour is. **Question for Håvard:** for a staged asset larger than a *later-lowered* `max_body_bytes`, should the asset be refused (as now) like a main-source input hit is (`request(constrained, 8).status == 413`)?

### RH-2. A watermark request source that no source can serve isn't tested to fail before the main source is fetched

**Severity:** medium (documented ordering of request-safety checks)

**Where:** `image_pipe/lib/image_pipe/execution.ex:44-58` (`with_prepared/6`: policy → `watermark_sources` → `resolve_source`) and `execution/watermarks.ex:59-63` (`plan_asset({:src, …})` → `Source.Parser.translate/2`). Test belongs in `image_pipe/test/image_pipe/api/watermark_wire_test.exs` ("request sources").

**Evidence:** the `with_prepared` doc says "The output policy and watermark plan are checked before `resolve_source` runs, so their errors return before any source access." The watermark half has no test. `watermark_wire_test.exs` "parse failures return before any source access" covers only `wm=unknown` and `wm-src64` on a gated mount. Both are *parser* errors. It doesn't cover a `wm-src64=` that decodes to an unsupported scheme (`ftp://…`), an empty string, or one with a NUL byte. Those fail in `plan_asset`, as `{:invalid_source, _}` (400 `invalid source`). `grep -rn wm-src64 test` finds only `mark.png`/`logo.png`/`missing.png` assets and telemetry-redaction tests. If the `with` steps were reordered, the main source would be fetched (and possibly staged) before the 400.

**Suggested test:** in the "request sources" describe, send `wm-src64=#{Base.url_encode64("ftp://x/mark.png", padding: false)}` (and a NUL-byte variant) on the `request_watermarks: true` mount. Assert `{400, "invalid source"}`, `refute_received {:origin_fetch, _}`, and with an observed cache `refute_received {:cache_lookup, _, _}`.

### RH-3. A conditional request that arrives first in a stale-while-revalidate window isn't tested to start the refresh

**Severity:** medium (CDN revalidation traffic could keep a stale original forever)

**Where:** `image_pipe/lib/image_pipe/plug/runner.ex:146` (`headers = not context.stale? and conditional?(conn) and …`) and `execution.ex:308-319` (`open/1` for a stale context calls `refresh(context)` on a hit). Test belongs in `image_pipe/test/image_pipe/api/coordinated_cache_wire_test.exs`.

**Evidence:** the early-304 gate is skipped for a stale context, so the request goes through `Execution.open/1`, which starts the background refresh and then answers 304 from `serve_output/2`. The only test that combines SWR with `If-None-Match` is "SWR responds before a blocked refresh completes" (`coordinated_cache_wire_test.exs:503-525`). In that test the refresh was already started by an earlier *unconditional* request, and the conditional only checks for 304 and `refute_received {:blocked, _other_worker}`. Deleting `not context.stale?` from the runner would answer the conditional early with a 304 and never refresh, and no test would fail. Behind a CDN, most requests in the SWR window are conditional revalidations, so the original would stay stale.

**Suggested test:** copy the SWR setup (`control: "public, max-age=1, stale-while-revalidate=30"`), warm with one request, advance `now`, set `block: true, version: 2`, then send the *first* stale-window request with `If-None-Match: <first etag>`. Assert status 304, then `assert_receive {:blocked, worker}` (the refresh started). Release the worker, `Caches.await_writes`, and check that the next plain request returns the new bytes.

Related, lower priority: a stale context whose output entry was evicted (`open/1` `:miss` branch) always answers 200, even when the revalidated ETag matches. That's correct but wasteful. **Question for Håvard:** is a 304 wanted there?

### RH-4. No test shows that the preset lookup isn't called for requests that fail the signature check

**Severity:** medium (documented security ordering, and a DB-amplification risk)

**Where:** `image_pipe/lib/image_pipe/plug/request.ex:253-258` (verify → lex → decrypt → presets → parse). `image_pipe/lib/image_pipe/preset_lookup.ex` moduledoc: "`ImagePipe.Plug` calls `c:fetch/2` while parsing a request, after signature verification". Test belongs in `image_pipe/test/image_pipe/preset_lookup_test.exs`.

**Evidence:** `preset_lookup_test.exs` covers malformed options (line 195), too many names (172), and the failure statuses. It never configures `keys:`. `grep -n 'keys\|sig\|403' test/image_pipe/preset_lookup_test.exs` returns nothing. The fixture `ImagePipe.Test.PresetLookup` already sends `{:preset_fetch, names}` on every call, so the assertion is cheap. If verification moved after the lookup, unsigned traffic could drive arbitrary backend queries on a signed mount. The same applies to an `enc/` token that no key decrypts (404 before lookup).

**Suggested test:** mount with `keys: [key]` plus a lookup. Request `/preset=card/src/photo.png` unsigned and with `sig=AAAA…`, and assert 403 and `refute_received {:preset_fetch, _}`. Then send a correctly signed request and `assert_received {:preset_fetch, ["card"]}`, so the refute can't pass trivially. Optionally add an encrypted-source mount with a token no key decrypts (404, no fetch).

### RH-5. Vary is never checked on 304 or HEAD responses

**Severity:** medium-low (CDN correctness for negotiated responses)

**Where:** `image_pipe/lib/image_pipe/response/sender.ex:29,474-480` (`@not_modified_header_allowlist ~w(age cache-control date etag expires vary)`) and `runner.ex:333-342`. Tests: `image_pipe/test/image_pipe/cdn_http_cache_wire_test.exs`, `image_pipe/test/image_pipe/api_wire_test.exs`.

**Evidence:** RFC 9110 §15.4.5 requires a 304 to carry the `Vary` the 200 would carry. `docs/cdn-http-cache.md` says "A `HEAD` response carries the same `ETag`, `Cache-Control`, and `Vary` as the matching `GET`" and, for cookie partitions, "`private` … on cache hits and `304` responses". Grepping 20 lines after every `status == 304` assertion found checks for `etag`, `cache-control`, `content-type == []`, `content-disposition == []` and CORS, but never `vary`. The HEAD comparisons (`cdn_http_cache_wire_test.exs:248`, `delivery_controls_wire_test.exs:114`) also leave out `vary`. Removing `vary` from the allowlist would pass the suite.

**Suggested test:** in `cdn_http_cache_wire_test.exs`, on an automatic-format path with `storage_inputs: [{:header, "x-tenant"}]`, check both the early 304 (matching ETag) and the post-cache-hit 304 (`If-None-Match: *`): `get_resp_header(conn, "vary") == ["x-tenant, Accept"]` and the same `cache-control` as the 200. Add `"vary"` to the HEAD-vs-GET header loop in `delivery_controls_wire_test.exs` with an automatic path.

### RH-6. The 410 for an expired URL caps the host's Cache-Control, while the docs say it is kept; nothing pins either behaviour

**Severity:** low-medium (doc/code mismatch with no test)

**Where:** `runner.ex:124` (`{:error, reason} -> send_error(limit_error_to_expiry(conn, request, config), …)`), `processing.ex:66-68` (`check_expires` runs inside `Execution.with_prepared`), `response/cache_policy.ex:238-247`. Docs: `docs/cdn-http-cache.md`, "Headers set by the host": "An error found while parsing the URL keeps the earlier `Cache-Control` unchanged. That covers … an expired URL …". Test belongs in `image_pipe/test/image_pipe/api/expires_cache_control_wire_test.exs`.

**Evidence:** `:expired` comes from `Processing.prepare/3`, which returns through `handle_request`'s error branch. That branch calls `limit_error_to_expiry`, so a host `public, max-age=86400` on a 410 becomes `public, max-age=0, must-revalidate` (`cap_control(…, 0, max(0, expires - now))`). The docs say it's left unchanged. "a host Cache-Control on a client error is capped" (`expires_cache_control_wire_test.exs:139`) covers 404 and 400 only. The 410 tests (`api_wire_test.exs` "expires gate", `request_safety_test.exs`) assert only the status.

**Suggested test:** in `expires_cache_control_wire_test.exs`, advance the clock past `@expires`, set the host `cache-control`, and assert 410 plus whichever header is intended. **Question for Håvard:** which one is right? Capping is harmless (an expired URL stays expired), so fixing the doc sentence may be the simpler change.

### RH-7. Processing-worker crashes (`{:processing, :worker_down}`) and the overlap's failure exits have no wire test, and their status isn't in the contract

**Severity:** low-medium

**Where:** `execution/overlap.ex:197-221,230` (all reported uncovered: `{:DOWN …} -> {:exit, reason}`, `completed(state, {:exit, _}) -> {:processing, :worker_down}`, `completed(state, nil) -> {:session, :timeout}`, the `:shutdown, {:processing, _}` catch). `processing_pool.ex:154`. `delivery/coordinator.ex:495` (`producer_down_reason({:shutdown, {:processing, _}})`, uncovered). `response/error_status.ex:264-266`. Tests: `image_pipe/test/image_pipe/api/source_overlap_wire_test.exs`, `image_pipe/test/image_pipe/response/error_status_test.exs`.

**Evidence:** `ErrorStatus.classify({:processing, reason})` maps only `[:timeout, :overloaded, :queue_timeout, :unavailable]` to 503. `:worker_down` falls through to `:server_error` → `500 "internal server error"`, and the `[:request]` result is `:processing_error`. `processing_pool_test.exs:217` checks only the pool's return value. No wire test sends a request whose worker dies, and `docs/errors.md` doesn't say which status a crashed worker gets. The `{:session, {:producer_down, _}}` reason for a crashed unpooled producer also maps to 500 untested. `error_status.ex:217` (`{:processing, :unavailable}` message) is uncovered too.

**Suggested test:** add `{:processing, :worker_down}` and `{:processing, :unavailable}` to `error_status_test.exs` with their intended status. In `source_overlap_wire_test.exs`, use a source fixture that kills the speculative worker (e.g. `Process.exit(self(), :kill)` inside a decode hook) and assert the response status and that the pool slot is released (`ProcessingPool.stats`). **Question for Håvard:** should a crashed worker be 503 (transient, like a timeout) or stay 500?

### RH-8. `StreamPull.translate/1` exit-wrapped `StreamError` branches are uncovered (source status vs 500)

**Severity:** low-medium

**Where:** `image_pipe/lib/image_pipe/delivery/stream_pull.ex:75-77` (uncovered: `:exit, {%StreamError{}, _}`, `:exit, %StreamError{}`, and the generic `kind, reason -> {:encode, …}`). Test: `image_pipe/test/image_pipe/delivery/` (a new `stream_pull_test.exs`) or `api_error_paths_test.exs`.

**Evidence:** the moduledoc says a `StreamError` escaping a pumped stream "must keep the source's domain status (such as 502 or 413) rather than degrading to the 500 an `{:encode, _}` tag would produce". The `rescue` form is covered. The two `:exit` forms, which a source stream running in a linked or monitored process produces, and the throw fallback are not. If they regressed, a truncated or oversized origin body would read as `500 error encoding image`, with error-level logging, instead of 502/413.

**Suggested test:** unit-test `StreamPull.translate/1` with `fn -> exit({%StreamError{reason: :truncated_body}, []}) end`, `fn -> exit(%StreamError{reason: :body_too_large}) end`, and `fn -> throw(:x) end`, asserting `{:error, {:source, :truncated_body}}`, `{:error, {:source, :body_too_large}}`, and `{:error, {:encode, {:throw, :x}, []}}`. This is a public-within-repo pure helper, so a direct test is fine. Better still, assert the wire status for a source stream that exits this way.

### RH-9. Coordinator cleanup on cancel, error, and shutdown is uncovered for the pooled and terminate paths

**Severity:** low-medium (could leak cache sinks or pool slots)

**Where:** `image_pipe/lib/image_pipe/delivery/coordinator.ex`. Coverage misses: 184-186 (producer `:DOWN` `:normal/:shutdown` while a cancel is pending), 369-373 (the producer answers `{:error, _}` to a pending cancel → `stop_producer` + `abort_cache_sink`), 461-462 (`stop_producer` with a pool: `request_halt` + `ProcessingPool.cancel`), 262-278 (every `terminate/2` clause except `:normal`, i.e. `cleanup_shutdown` → abort sink), 287-291 (`call_session` exit translations). Tests: `image_pipe/test/image_pipe/delivery/delivery_lifecycle_test.exs`, `delivery/processing_controls_test.exs`.

**Evidence:** `delivery_lifecycle_test.exs` and `api_error_paths_test.exs` rows 2/5/8 cover owner death and explicit cancel after a chunk, both on the unpooled force-kill path. No test exercises a coordinator that is itself shut down (e.g. by a supervisor or `GenServer.stop(coord, :shutdown)`). Its `terminate/2` is the only thing that aborts the staged cache sink and frees a pooled producer in that case. `docs/streaming-failures.md` promises the work stops, the slot is freed, and the partial cache entry is discarded.

**Suggested test:** in `delivery_lifecycle_test.exs`, start `Delivery.stream/4` with a `CacheObserver` key and a pooled config, take the first chunk, then `GenServer.stop(coordinator, :shutdown)` (pid from `:sys.get_state` on the prepared stream's closure owner, or expose it via `Process.info(self(), :links)`/monitor). Assert `{:cache_abort, hash}`, `%{active: 0} = ProcessingPool.stats(pool)`, and producer `:DOWN`. Add a case where `build_fun` returns an error while a cancel is pending (369-373).

### RH-10. Sender mid-stream failure branches are uncovered: a cached file failing during the fallback copy, and `next/0` raising

**Severity:** low

**Where:** `image_pipe/lib/image_pipe/response/sender.ex:283-289` (`send_open_file_chunks`: client error halt, and the `rescue` → `cached_body_read_error` → `:processing_error`), `sender.ex:321-322` (`continue_prepared_stream` `rescue` → `{:encode, {exception, stack}}` + processing_error mark). Tests: `image_pipe/test/image_pipe/response_sender_test.exs`, `image_pipe/test/image_pipe/plug/stream_abort_wire_test.exs`.

**Evidence:** `stream_abort_wire_test.exs` covers an evicted body served through the open descriptor and `send_file` failing, but not the open descriptor failing partway (the docs list "A cached image can't be read partway through, such as after a disk error" under failures after headers). `response_sender_test.exs` covers `next` returning `{:error, _}` and exiting, but not raising. That rescue alone turns a raise into an aborted stream instead of a crash after headers.

**Suggested test:** in `response_sender_test.exs`, add `next: fn -> raise "boom" end` and assert `conn.private.image_pipe_send_result == :processing_error`, cancel called, and the `[:deliver, :stop]` metadata `stream_phase: :encode` (using the existing `self()`-filtered handler). For 283-289, feed `send_body/2` a `%Cache.File{}` whose stream raises (delete/truncate the file after open, or a fake `File` stream) through the `send_open_file` path.

### RH-11. CacheObserver and several async tests use shared `/tmp` roots named with VM-local unique integers

**Severity:** low (cross-VM flakiness, e.g. parallel worktrees)

**Where:** `image_pipe/test/support/image_pipe/test/cache_observer.ex:38` (`Path.join(System.tmp_dir!(), "cache-observer-#{System.unique_integer([:positive])}")`), `test/image_pipe/cache_test.exs:107,139` (fixed names `image_pipe_overlapping_roots`, `image_pipe_cache_init`), `api/coordinated_cache_wire_test.exs:12`, and others (52 `System.tmp_dir` uses in 43 test files).

**Evidence:** `System.unique_integer/1` is unique only within one VM, so two `mix test` runs at once (this repo provisions worktrees for parallel agents) can pick the same root. One run's `on_exit` `File.rm_rf` then deletes the other's live cache, and a root left by an interrupted run (`on_exit` skipped) can hand a later run pre-existing entries. That's an unexpected cache hit where a test does `assert_received :origin_fetch`. `CacheObserver` is the harness behind most "never touches cache" assertions in this area. The two `cache_test.exs` roots use fixed names, so any two concurrent runs collide.

**Suggested test change:** use ExUnit's `@tag :tmp_dir` (it lives under the project directory, so it's unique per worktree) or add `System.pid()`/a random suffix to these roots, and make `CacheObserver.observe/2` `File.rm_rf!` the root before creating it.

### RH-12. Weak or missing assertions on request-level contracts

**Severity:** low

**Where and evidence:**
- `image_pipe/test/image_pipe/instance_test.exs:221`: `assert request(path, instance: ctx.name).status != 200`. A signed URL on a mount without keys has a documented status (`400`, "sig is not accepted: no signing keys are configured", `plug/errors.ex:37-48`), and `!= 200` would also accept a 500 crash. The `:signature_without_keys` 400 body is never asserted anywhere in `image_pipe` (`api_wire_test.exs` "no keys configured, sig= present" checks only the status).
- `image_pipe/test/image_pipe/telemetry_test.exs:598`: `assert is_atom(metadata.error)` for the parse/source/processing cases. The expected tags are known (`:invalid_request`, `:source`, `:decode`), so a wrong tag passes.
- `Telemetry.request_result/1` maps signature failures (`:missing_signature`, `:invalid_signature`, `:signature_without_keys`) to `:parser_error` (`telemetry.ex:256-265`). No test asserts this for a Plug request (`run_test.exs:269-277` covers `:expired` through `run/4` only). That result drives the summary and Logger level.
- `image_pipe/test/image_pipe/api/skip_processing_wire_test.exs:78`: `skipped.status >= 400` where 413 is the contract.
- `runner.ex:373` (Retry-After when the pool has no value) and `:293` (non-Vary policy headers on an error response) are uncovered. `processing_controls_wire_test.exs` "processing deadlines return 503" doesn't `refute` a `retry-after` on a timeout 503, and the docs promise one only for overloaded/queued.

**Suggested test:** tighten these to exact values: `== 400` plus `resp_body =~ "sig is not accepted"`, `metadata.error == expected_tag` per case, `== 413`. Add a `[:request, :stop]` `result: :parser_error, status: 403` assertion to the existing signature-matrix tests (with a private `telemetry_prefix`), and `get_resp_header(timed, "retry-after") == []` to the deadline test.

### Checked and found adequately covered

`ErrorStatus` class/message tables; error bodies never echo URLs; 5xx `no-store` vs 4xx host `Cache-Control`; expiring-URL capping for 404/400; early and post-hit 304 (GET and HEAD, `*` only on a hit, weak match, mixed `*`); host privacy headers suppressing the ETag; cachebuster/storage_inputs changing the key but not the ETag; `Vary` merge with host values on success and on errors after processing; no `Vary` when nothing can be negotiated; CORS on 200/hit/304/405/OPTIONS; debug-header gating, signature coverage of `debug`, and hit replay; ignored-options header; Retry-After values; preset lookup failure statuses and ordering vs malformed options; detection strictness statuses; `effort` limit 400 before fetch; inline-mount cache rejection; Plug/instance option validation; summary/request-path redaction; HTTP/1.1 and HTTP/2 stream aborts. In async tests, telemetry handlers on default-prefix events filter by `self()` (`response_sender_test.exs`), and tests touching global logger/tracer state are `async: false`.

## Sources and caching (SC)

### SC-1. A stored original whose byte identity doesn't match the current record is never tested (wrong image could be cached)

**Severity:** high

**Where:**
- Code: `lib/image_pipe/cache/input.ex:139-145` (`pin_matching/3`, the `false -> :miss` branch at line 144) and `lib/image_pipe/execution/source_cache.ex` (`store/7` returns `{:staged, ..., then remember}`).
- Tests: `test/image_pipe/cache/input_refresh_test.exs`, `test/image_pipe/api/coordinated_cache_wire_test.exs`.

**Evidence:**
- `input.ex:144` is uncovered. No test opens an original against a record with a different `byte_identity`.
- This can happen in production. When v2 of a source is fetched but its original put is dropped, the `then` callback still updates the in-memory record to v2, so the v1 original stays on disk under the same input key. A put can be dropped by the writer limit, the pending limit, admission rejecting the replacement, or a disk error.
- The `stored.byte_identity == record.byte_identity` comparison is the only thing that stops v1 pixels from being processed and cached under v2's output key and ETag.
- If that comparison regressed (for example, a refactor that only checks `Record.valid?`), the suite would still pass. The result would be a silently wrong cached image with a strong ETag.

**Suggested test:**
- Unit test in `input_refresh_test.exs`: store an original for `record("a", 1000)`. Then assert that `Input.open(key, record("b", 1000), config) == :miss`, and that no pin is left behind: a later eviction or delete of the file succeeds, or the pin count is zero.
- Wire test in `coordinated_cache_wire_test.exs`:
  - First request: the origin serves red (v1) and the original is stored.
  - Next: the origin changes to blue (v2), and v2's original put is forced to drop, for example with input `max_size_bytes` below v2's size or a writer that is full.
  - Then request a *new* variant (different width).
  - Assert that the decoded pixels are blue and that the origin was contacted again.

### SC-2. No test restarts an instance that has only an output cache (documented contract, regression class of bug-hunt-6 #1)

**Severity:** medium-high

**Where:**
- Code: `lib/image_pipe/execution/source_cache.ex:412-413` (`remember/4` clause `{true, nil}`: remembering a record refreshed by a 304 when there is no originals cache).
- Docs: `docs/caching-and-freshness.md`, the restart section.
- Tests: `test/image_pipe/api/coordinated_cache_wire_test.exs:666-715`.

**Evidence:**
- Both restart tests configure an originals cache, so the record is recalled from `Input.metadata`.
- The doc says that after a restart, one download happens and then the cached processed images are served. The output-cache-only path relies on the conditional or full re-download repopulating the record, and the 304 branch of that is `source_cache.ex:412-413`, which is uncovered.
- Bug-hunt-6 #1 (a restart causing a re-download per variant) was fixed in 051275d, but only the originals-cache path got a regression test.

**Suggested test:**
- Wire test with `output_cache` only and no input cache:
  1. Request variants A and B.
  2. Restart the instance: stop and restart the supervised instance so the source records ETS table is gone.
  3. Request A again. Assert exactly one origin contact. Run it twice, once with a 304 origin and once with a 200 origin. Assert the same ETag as before the restart, no `[:transform, :execute]` event (the response is served from the output cache), and a body identical to the one before the restart.
  4. Request B. Assert zero further origin contacts.

### SC-3. A 401/403/404/410 from the origin should invalidate the record and the stored original, but only the failure path is tested

**Severity:** medium

**Where:**
- Code: `lib/image_pipe/execution/source_cache.ex:376-385`. A `{:error, {:source, {:bad_status, s}}}` with s in 401/403/404/410 publishes `invalidation(key, config)`.
- Tests: `test/image_pipe/api/input_cache_failure_wire_test.exs` covers only the case where the invalidation itself fails (admission killed on `:delete`). `coordinated_cache_wire_test.exs` has no 40x tests.

**Evidence:** No test asserts the positive outcome. After the origin answers 404, the original's body file should be gone and the next request should not be served from the stale record or original. If this regressed, a removed or access-revoked image would keep being served for the whole stale-while-revalidate window, and new variants would be rendered from it.

**Suggested test:**
- Wire test in `coordinated_cache_wire_test.exs` with both caches and SWR enabled:
  1. Make the first request (200).
  2. Expire the record's freshness. Have the origin answer 404 for the background refresh, then wait for the refresh's `[:cache, :coordination]` stop event.
  3. Assert that the input cache body is deleted and that a request for a new variant returns 404 without reprocessing old bytes.
- Repeat with 410 and 403, using a parameterised loop rather than one test per status.

**Question for Håvard:** Should an already cached *output* for the same source also stop being served after a 404 during SWR, or is serving cached outputs until they expire the intended contract? The code invalidates the source record and the original, but output entries stay on disk under their keys.

### SC-4. A redirect to the same host with a different scheme or port is not checked for credential stripping

**Severity:** medium (security)

**Where:**
- Code: `lib/image_pipe/source/req_stream.ex`, `redirect_options/2`. It compares `{scheme, downcased host, port}` and otherwise drops `:auth` and `:aws_sigv4` and strips credential headers.
- Tests: `test/image_pipe/source/req_stream_test.exs` (the scheme-downgrade test near line 422) and `test/image_pipe/source/http/pinning_test.exs:244`.

**Evidence:**
- The cross-origin test changes only the host.
- The https→http downgrade test checks that the redirect is followed or rejected, but not that `authorization` and `cookie` headers and SigV4 signing are absent on the second hop.
- A bare `allowed_hosts` entry allows both default ports, so a same-host scheme or port change is reachable whenever `max_redirects > 0`.
- If the comparison regressed to "host only", for example by dropping scheme or port from the tuple, credentials would be sent in plaintext over http or to another service on the same host, and no test would fail.

**Suggested test:** In `req_stream_test.exs`, add two cases with a Bandit or Plug test origin that records the headers it receives on each hop:
- the same host on another port (`localhost:A` → `localhost:B`);
- the same host and port with a different scheme, if the test setup can run TLS; otherwise cover it with the port case and a pure test of the `redirect_options/2` tuple through the public fetch.

For each case, assert that the second hop receives no `authorization` header, no `cookie` header, and no `x-amz-*` signature headers. Also add one case that keeps the scheme, host and port the same but changes the case of the host, and assert that the credentials are kept.

### SC-5. A permission change on a file source is detected only through ctime, and no test covers it

**Severity:** medium

**Where:**
- Code: `lib/image_pipe/source/file.ex`, `fetch/3` (`unchanged?(previous, evidence)` → `{:not_modified, ...}`) and `evidence/4` (weak etag `W/"size-mtime-ctime-inode-dev"`).
- Tests: `test/image_pipe/source/file_test.exs`, `test/image_pipe/api/file_source_cache_wire_test.exs`.

**Evidence:**
- Since 770b5ba, a matching stat skips the `open` entirely. A file whose permissions were revoked, for example with `chmod 000` (or an ACL change that bumps ctime), is reported as `:not_modified`. That is correct only because chmod changes ctime and ctime is part of the evidence.
- No test changes the mode after the first fetch. If ctime were dropped from the evidence, which is a tempting simplification because mtime is the usual validator, a revoked file would keep being served from the cache and no test would notice.

**Suggested test:**
- In `file_test.exs`:
  1. Fetch once and capture the evidence.
  2. `File.chmod!(path, 0o000)`. Set mtime back to the old value with `File.touch!/2` so that only ctime differs.
  3. Fetch again with the previous evidence. Assert the result is not `{:not_modified, _}`: when run as root it is a changed or full fetch, otherwise `{:error, ...}` (unreadable).
- Tag the unreadable assertion `:file_permissions` and skip it when the uid is 0, because the cloud container runs as root.

### SC-6. Coalescing, cooldown, cap and timeout of SWR background refreshes are asserted weakly or not at all

**Severity:** medium-low

**Where:**
- Code: `lib/image_pipe/cache/work.ex`, `handle_call({:refresh, ...})`. Uncovered: line 248 (`:backoff`), line 251 (`:busy` when 16 refreshes are already running), lines 294-297 (`{:expire, ref}` kills a refresh after 60s), and line 287 (DOWN of the owner during a transfer).
- Docs: `docs/cache.md`, "Coordination limits" (16 refreshes, 60s, 1s cooldown).
- Tests: `test/image_pipe/api/coordinated_cache_wire_test.exs:300-326` and `502-527`, `test/image_pipe/cache/work_test.exs`.

**Evidence:**
- The SWR coalescing tests assert `refute_received {:blocked, _}`. That assertion can't fail: a second, uncoalesced refresh would wait on the source lock and receive the cohort's shared result, so it never sends `:blocked`.
- `work_test.exs` covers `:busy` only when the coordinator isn't available.
- None of the three documented limits has a test.

**Suggested test:**
- In the wire tests, replace the refute with an assertion on the `[:cache, :coordination]` event (`operation: :refresh`): exactly one `result: :started` and the rest `result: :coalesced`. Use a private `telemetry_prefix`.
- In `work_test.exs`:
  - Cooldown: start and finish a refresh for a key, then immediately ask again and assert `:backoff`.
  - Cap: start 16 refreshes that block on a message, and assert that the 17th gets `:busy`.
  - Timeout: start a refresh, send the coordinator `{:expire, ref}` (reading `ref` with `:sys.get_state/1`, which "Tests not to write" allows for driving state), and assert that the refresh process gets a `:DOWN` with reason `:killed` and that the key is freed. Don't wait 60s.

### SC-7. Three processing pool paths are uncovered: pool not running, expired on arrival, expired while draining

**Severity:** low-medium

**Where:**
- Code: `lib/image_pipe/processing_pool.ex:607` (the `call` exit maps to `{:processing, :unavailable}`), `:345-346` (a request whose deadline has already passed when it arrives returns a queue timeout), and `:527-528` (draining finds a waiter that has already expired).
- Tests: `test/image_pipe/processing_pool_test.exs`.

**Evidence:**
- All three lines are uncovered. The rest of the pool is well tested.
- Line 607 is the only path to the documented 503 when the pool has crashed or is restarting.
- The expired-in-drain path decides whether a dead waiter takes up a slot.

**Suggested test:**
- Pool not running: stop the supervised pool, then call `run`, and assert `{:error, {:processing, :unavailable}}`. Add one wire test asserting a 503 if none exists.
- Expired on arrival: submit with a deadline already in the past and assert a queue timeout with no work run.
- Expired while draining:
  1. Fill the pool.
  2. Queue a waiter with a short deadline, then expire it explicitly instead of sleeping.
  3. Release a slot and assert that the expired waiter isn't run and the next live waiter is.

### SC-8. S3 refresh cache: re-arming the retry after a failed refresh isn't asserted, and one test waits 6s of real time

**Severity:** low-medium

**Where:**
- Code: `lib/image_pipe/source/s3/refresh_cache/entry.ex` (`schedule_retry` after a failed background refresh; the DOWN clause at line 120).
- Tests: `test/image_pipe/source/s3/refresh_cache_test.exs`.

**Evidence:**
- The test "serves the still-fresh value" checks that the old credentials are still served after a failed refresh, but not that a retry timer was armed. If the timer weren't armed, credentials would expire and every request would fall back to a synchronous fetch.
- The test "short-lived credentials" waits about 6s of real time, which goes against the process-discipline guideline.
- Separately, the DOWN clause at line 120 is unreachable: `Task.async` links the task, the entry doesn't trap exits, and `safe_call` catches everything. Under the AGENTS.md guidance to shrink unsupported surface, that clause is a candidate for deletion, not a test.

**Suggested test:**
- After a failed refresh, read the entry state with `:sys.get_state/1` and assert that a retry timer is set (`Process.read_timer(ref)` is an integer). Then send the entry its own retry message and assert that the fetch runs again (the fetcher's call count goes up).
- Rewrite "short-lived credentials" the same way, by triggering the timer message instead of sleeping.

### SC-9. The staging directory ownership check (another uid) is never exercised

**Severity:** low

**Where:**
- Code: `lib/image_pipe/cache/input.ex`, `private_dir/1` and `make_private/1` (a uid ownership check with a probe file).
- Tests: `test/image_pipe/cache/input_staging_test.exs`.

**Evidence:** The tests cover a staging path that is a symlink and one that is a regular file. They don't cover a directory owned by another uid. That is the shared-`/tmp` attack this check exists for: another local user creates the directory first and reads or replaces staged originals.

**Suggested test:** Tag it so it runs only as root, which the cloud container is. `File.mkdir_p!` the staging directory, then `File.chown!(dir, 65534)` (nobody). Open the input cache or stage a file, and assert that it is refused with the documented error and that nothing is written into the directory.

### SC-10. Falling back from the spool when its write fails (31c07b6) is untested

**Severity:** low

**Where:** `lib/image_pipe/execution/source_cache.ex:644-659` (spool write-failure fallback) and `:693` (the `check_size!` raise).

**Evidence:**
- Both are uncovered. `staging_reason: :write` is never produced in tests, so the telemetry or Logger rendering of that reason is never exercised either.
- The fallback decides whether a full disk degrades to an uncached response (the fail-open guideline) or turns into a 5xx.

**Suggested test:** Point the spool or staging directory at a location that can't be written. As root, a read-only bind isn't available, so use a path whose parent is a regular file, which fails the write rather than the directory check. Make a request and assert 200 with the correct pixels, no input cache entry, and a staging event with `reason: :write` under a private `telemetry_prefix`.

**Question for Håvard:** Is `check_size!` (line 693) reachable when the origin sends more bytes than its Content-Length, or does ReqStream's body limit always catch that first? If it can't be reached, it is a candidate for deletion rather than a test.

### SC-11. Smaller uncovered boundary branches

**Severity:** low

**Where and evidence:**
- `lib/image_pipe/source/req_stream.ex:503, 509, 513`: the transport error mappings `:connection_reset`, `:connection_closed` and `:transport_error` are uncovered. The one retry on a reused connection is tested, but the error a caller sees when the retry also fails is not. Suggested test: an origin that closes the socket mid-body on both attempts, asserting the mapped error tag and a 502.
- `lib/image_pipe/source/http.ex:351`: the "invalid path_pattern" option error and the anchoring of `:extended` patterns are uncovered. This is host configuration and should be rejected at init. Suggested test: a `validate_options` test with a malformed pattern, and an anchoring test where a pattern matches a prefix but not the full path.
- `lib/image_pipe/cache/input.ex:25`: `{:error, :invalid_input_cache}` (malformed input cache configuration) is uncovered. It is a config boundary, so it needs one validation test.
- `test/image_pipe/cache_test.exs` is `async: true` but uses fixed tmp directory names (`image_pipe_overlapping_roots`, `image_pipe_cache_init`). That doesn't fail today, but concurrent runs of the file, or of a module that reuses the names, could collide. Use `System.tmp_dir!/0` with a unique suffix, or the `@tag :tmp_dir` that ExUnit provides.

## Image processing and output (IP)

### IP-1. Watermark assets: no test checks the pixel limit or the frame limit
**Severity:** high (request safety)
**Where:** `lib/image_pipe/decode.ex:204-248` (`watermark/2` → `watermark_detected/4`: `validate_header_pixels`, `validate_container_frames`, `validate_frames`, `validate_pixels`). Tests searched: `test/image_pipe/api/watermark_wire_test.exs`, `watermark_cache_wire_test.exs`, `watermark_storage_wire_test.exs`, `working_limits_wire_test.exs`, `request_safety_test.exs`, `decode_test.exs`, `multi_frame_wire_test.exs`, `gif_source_wire_test.exs`.
**Evidence:** The moduledoc says watermark assets get "the same family allowlist, frame limit, and per-frame pixel limit as `with_image/4`", and `docs/architecture/api_contract.md` §Watermarks says assets resolve "with the main source's limits". No test sets `max_input_pixels` or `max_input_frames` on a request that uses a watermark. The only asset-failure tests use a corrupt asset (415) and a missing asset. Deleting any of the four validators in `watermark_detected/4` would pass the suite. With `request_watermarks` on, that lets a client-chosen `wm-src64` asset bypass the decompression-bomb guard.
**Suggested test:** in `watermark_wire_test.exs`, describe "asset limits":
- A mount with `max_input_pixels` below the asset's pixel count gives `413` for `wm=<asset>`, while the same main source without `wm` gives `200`.
- An animated WebP asset over `max_input_frames` gives `413`, and the `{:loader_open, _}` count from `ImagePipe.Test.DecodeOpens` shows the container walk rejected it before any libvips open.
- The same for a request asset through `wm-src64`.
- Assert `[:source, :fetch_decode]`-style telemetry (`error: :input_limit`) with a private prefix.

### IP-2. Sequential-safety gate: most streaming operations have no property test, and the harness checks only 25 pixels
**Severity:** medium (correctness gate required by AGENTS.md "Transform guidelines")
**Where:** `lib/image_pipe/transform/executor/step.ex:66-77` (operations that `random_access?/1` leaves out) and `test/image_pipe/transform/sequential_access_test.exs`.
**Evidence:** Every operation left out of `random_access?/1` needs an equivalence test from a streamed open plus a property test over input shapes. Coverage per operation:

| Operation | Example test | Property test | Gaps |
|---|---|---|---|
| Crop (anchor, focus point, region), Resize, Watermark | yes | yes | – |
| Duotone | yes | gray inputs only | – |
| Background | `alpha_png_body/0` only | no | The input is a uniform, fully opaque `[0,255,0,255]`, so the flatten is close to an identity. The translucent `compose/3` path (`composite2`, alpha < 255) never runs streamed. |
| ExtendCanvas | 2 cases | no | `fill: :white` (`embed_white/5`) never runs streamed. |
| Brightness, Contrast, Saturation, Gray, Bitonal | 1 case each on beach.jpg | no | No alpha input, no 16-bit input. |
| Colorize | `keep_alpha: false`, no alpha | no | The alpha-flatten branch and `keep_alpha: true` are untested. |
| Gradient | `angle: 0.0` only | no | The 16-bit `blend_float/3` path is untested. |

`assert_sampled_pixels_match/2` compares a 5×5 grid. A dropped or zeroed band of rows from a mis-streamed read would pass unless it hit a sample row. The orientation-flush helper in the same file already compares `write_to_binary` in full.
**Suggested test:** in `sequential_access_test.exs`:
- (a) Replace the sampled compare with a whole-image check, e.g. `Operation.relational(seq, rand, :VIPS_OPERATION_RELATIONAL_NOTEQ)` then `max == 0`. This keeps memory low on beach.jpg.
- (b) Add one table-driven property: `check all op <- member_of([...pointwise ops with generated params...]), w <- 7..96, h <- 7..96, alpha? <- boolean(), deep? <- boolean()`. Build the PNG body as the duotone property does, and include `%Background{color: [r,g,b,a]}` with `a in 0..254`, `%ExtendCanvas{fill: :white}`, `%Colorize{keep_alpha: true}` and gradient angles in 0..359.

Question for Håvard: is "pointwise ops stream trivially" meant to waive the property-test half of the gate? If so, AGENTS.md should say so. As written, the gate isn't met.

### IP-3. Detector contract: the fallback tests only assert `{:ok, _}`, and the invalid-result path never runs
**Severity:** medium
**Where:** `lib/image_pipe/transform/operation/crop.ex:418-433` (`validate_detect_result/1`; line 425 is uncovered, so a non-list or non-tuple adapter result never runs). Tests: `test/image_pipe/transform/crop_operation_test.exs:154,172,189,202`, `test/image_pipe/api/detection_strictness_wire_test.exs`.
**Evidence:** "out-of-image box is dropped, falls back to attention", "detector error falls back", "nil detector falls back" and "malformed detector return (bad box shape) falls back to attention" each assert only `{:ok, %{image: _}}`. They would pass if the crop centred, used the bad box, or anything else. Only "no detections falls back to attention" compares against the `:smart` crop.

The `Detector` moduledoc makes three promises that no test checks:
- A wrong box shape "makes the whole result a detection error".
- Under `detector_required: true` that error is a 500.
- Otherwise the response is sent `no-store` without an ETag.

A regression that treated `:invalid_adapter_result` as "no regions" would cache attention crops under the detector's identity, and nothing would catch it. Detector returns are host-implementable behaviour output, which AGENTS.md "Validation" says to validate at the boundary.
**Suggested test:**
- (a) In `crop_operation_test.exs`, make each fallback test compare the PNG bytes with `%{op | gravity: :smart}`, as the no-detections test does.
- (b) Add a case where `detect/2` returns `:ok` or `{:ok, :nope}`.
- (c) In `detection_strictness_wire_test.exs`, a detector returning `{:ok, [%{label: "face", box: :bad}]}`: 500 under `detector_required: true`; under false, `cache-control: no-store`, no ETag, nothing stored (use the `CacheObserver` already used there).

### IP-4. Bundled image_vision detectors: no CI job runs them, and the tagged tests pass on `[]`
**Severity:** medium
**Where:** `lib/image_pipe/transform/detector/image_vision/face.ex:72-81` and `objects.ex:86-101` (coverage: 11/18 and 17/20 lines missed). Tests: `test/image_pipe/transform/detector/image_vision_test.exs`.
**Evidence:**
- `test_helper.exs` excludes `:image_vision`, and the deps exist only with `IMAGE_VISION=1` (`mix.exs:270`). No workflow in `.github/workflows/` runs `--only image_vision`.
- The vision container smoke test (`image_pipe_server/test/container/smoke.sh:216-245`) checks only status codes for `detect=face` and `detect=car`.
- Even when the tagged tests run, "detect returns face regions" (woman.jpg) asserts `Enum.all?(regions, &match?(...))`, which is true for `[]`. The objects test runs on a black image.

So the adapters' mapping, mainly that `Image.FaceDetection` and `Image.Detection` return `{x, y, w, h}` and not corners, plus the label normalisation, isn't checked. An `image_vision` upgrade that changes the box convention would move every detect crop without a failing test.
**Suggested test:** in the tagged lane:
- Assert `regions != []` for woman.jpg, and that the face box lies inside a hand-measured region of the photo.
- For objects, use a fixture with a known object, such as one of the `priv/static/images` photos, and check the box against the known object.
- Add a scheduled CI job (weekly, like `audit.yml`) running `IMAGE_VISION=1 mix test --only image_vision`.

Question: is the opt-in lane deliberately unrun in CI (because of the Rust/ONNX build cost)?

### IP-5. WebP/AVIF output: alpha and high bit depth are never checked end to end
**Severity:** medium
**Where:** `lib/image_pipe/format.ex:19-20` (`@alpha_formats`, `@hdr_formats`), `lib/image_pipe/output/encoder.ex:305-318` (flatten for formats without alpha), `docs/architecture/api_contract.md` §Metadata ("Only AVIF and PNG keep high bit depth"). Tests: `test/image_pipe/api/layout_matrix_test.exs:87-96`, `color_management_wire_test.exs:190-203`, `format_test.exs:86-101`.
**Evidence:**
- The `"#{layout} as #{format}"` rows for webp and avif assert only status 200. Their only check, on bands, is for JPEG.
- `hdr=preserve` is shown to keep USHORT for PNG and to drop to 8 bits for JPEG. No test requests `format=avif/hdr=preserve` and decodes a deep image.
- No test decodes a transparent source delivered as WebP or AVIF and checks for an alpha band.
- `format_test.exs` pins only the predicate tables.

Breaking either path (for example a cast to 8 bits before AVIF, or alpha flattening for every format) would leave the suite green.
**Suggested test:** in `layout_matrix_test.exs`, run `check_bands/1` and `check_alpha_origin/3` on the webp and avif rows. Assert `Image.has_alpha?(output) == source.alpha?` for webp and avif, and add `hdr=preserve/` avif rows asserting `VipsImage.format(output) == :VIPS_FORMAT_USHORT` for 16-bit layouts.

Question: with the libvips 8.18 heifsave defaults, do you expect a 10- or 12-bit AVIF here? The test should pin whichever is intended.

### IP-6. Colour output: no test runs the 16-bit and gray ICC conversions
**Severity:** medium
**Where:** `lib/image_pipe/output/encoder.ex:453-466`. Lines 453 (`standard_profile` → `"sGrey"`) and 462-464 (`icc_depth` → 16 for GREY16, RGB16 and scRGB) are uncovered. Tests: `color_management_wire_test.exs`, `colour_conversion_wire_test.exs`, `srgb_profile_wire_test.exs`.
**Evidence:**
- No test converts a tagged gray image to standard space. A gray source with a non-sRGB gray profile under `profile=strip` takes the sGrey branch.
- No test runs `icc_transform`, `icc_export` or `to_standard` at depth 16. That would be a wide-gamut 16-bit source (a P3 RGB16 layout exists in `layout_matrix_test`, but only into PNG with both `profile=preserve` and `hdr=preserve`, which takes the keep path) under `hdr=preserve` with `profile=strip`.

A wrong `depth:` would quietly quantise 16-bit output to 8-bit precision while keeping the USHORT container.
**Suggested test:** in `color_management_wire_test.exs`:
- (a) A `p3_16` source with `format=png/hdr=preserve/profile=strip`: the output is USHORT, untagged, and a saturated P3 red maps to the expected sRGB16 value within ±257 × 1 level. Also check that values are not all multiples of 257, which would show 8-bit precision.
- (b) A gray PNG tagged with a non-sRGB gray ICC under `profile=strip`: output is untagged B_W and its pixel matches `icc_transform(..., "sGrey")`.

### IP-7. Deferred orientation: vertical flips and percentage offsets aren't tested end to end
**Severity:** medium
**Where:** `lib/image_pipe/transform/executor/geometry.ex:245-317` (`compensate_crop/2`; line 316, `split_offset({:scale, _})`, is uncovered, so a percentage `anchor-offset` under pending orientation never ran). `lib/image_pipe/transform/orientation.ex` lines 147 (`flip_y` of a focus point), 220, 246-247 and 255-256 (anchor remaps) are uncovered. Tests: `test/image_pipe/deferred_orientation_property_test.exs`, `test/image_pipe/api/orientation_matrix_test.exs`, the imgproxy reference EXIF cases.
**Evidence:**
- The no-geometry property only ever uses `flip=h` (`mirror` → `"/flip=h"`).
- The crop/resize property has no user rotate or flip, and its `geometry_path/0` is a fixed list of 11 region, centred-crop and resize paths, with no anchors, `focus` or `anchor-offset`.
- `orientation_matrix_test` uses EXIF 1, 6 and 8 only, at a 40-level / 5% tolerance.
- The imgproxy cases cover mirrored EXIF with `anchor=top`, a few `focus` cases and pixel offsets, never `flip=v`/`hv` or percentage offsets combined with a compensated crop.

A sign error in `apply_flip_y` for focus points (`1.0 - fy`, line 147) would not fail any test.
**Suggested test:** extend `geometry_path/0` with:
- `crop=60,40/anchor=bottom-right/anchor-offset=7,5`
- `crop=60,40/anchor=top/anchor-offset=10pct,5pct`
- `crop=60,40/focus=0.2,0.8`
- `w=50/h=50/fit=cover/focus=0.7,0.3`

Also add a user-orientation generator (`rotate=0|90|180|270` × `flip=none|h|v|hv`) to the crop/resize leg, comparing against the twin built with the same rotate and flip. Keep the existing ±1px and interior-pixel oracle.

### IP-8. Five of the eight resize kernels never run
**Severity:** low-medium
**Where:** `lib/image_pipe/transform/operation/resize.ex:93-100`. The cubic, mitchell, lanczos2, mks2013 and mks2021 clauses are uncovered. Test: `test/image_pipe/api/resize_kernel_wire_test.exs:13-24` (nearest and linear only).
**Evidence:** `kernel=` accepts eight values, which change pixels and enter identity. Only nearest, linear and the default lanczos3 run. A swapped mapping (for example `:mks2013 -> :VIPS_KERNEL_MKS2021`) would pass.
**Suggested test:** a table in `resize_kernel_wire_test.exs`: for each kernel, the `w=300/kernel=K` response decodes equal to `Operation.resize(source_after_same_shrink, scale, kernel: :VIPS_KERNEL_K)`, using the existing nearest reference helper at line 38 as the template.

### IP-9. URL encoder options that no test ever encodes
**Severity:** low-medium
**Where:** `lib/image_pipe/output/encoder.ex:164-196` (`encoder_tokens/1`). Tests: `test/image_pipe/api/quality_wire_test.exs`, `test/image_pipe/output/encoder_options_encode_test.exs`.
**Evidence:** No test request, and no `encode_to_buffer` call, sets:
- JPEG `subsample:*`, `overshoot-deringing`, `optimize-scans` (`trellis-quant` appears only in one unit encode)
- WebP `near-lossless` (`smart-subsample` and `preset` only in one unit encode)
- PNG `interlace`

libvips rejects an unknown `[name=value]` argument, so a token rename (dash or underscore, or a libvips rename) would turn each of these URLs into a 500 without any test failing. The decodable-only assertions also don't show that an option has any effect.
**Suggested test:** a table in `quality_wire_test.exs`: each documented field in the api_contract encoder-options table gives `200` and bytes that differ from the format default. Where a header can show the effect, check it: JPEG `subsample:off` → the decoded `jpeg-chroma-subsample` header is `"4:4:4"`; `progressive` → `interlaced`.

### IP-10. The strip-metadata fallback never runs
**Severity:** low
**Where:** `lib/image_pipe/output/encoder.ex:527-536,564-570` (`remove_fields/2` and `icc_fields/1` are uncovered). Tests: `test/image_pipe/api/metadata_wire_test.exs:30-42`.
**Evidence:** The malformed-date tests reach the `rescue` in `minimize_metadata/2` (which calls `Image.remove_metadata/1`), not the `{:error, _}` branch. The branch that keeps the ICC profile while dropping EXIF, XMP and IPTC under `profile=preserve` is never run. If it dropped or leaked the profile, nothing would notice.
**Suggested test:** in `metadata_wire_test.exs`, a source on which `Image.minimize_metadata/2` returns `{:error, _}`. If no real input does that, delete the branch instead (AGENTS.md "Prefer shrinking unsupported API surface").

Question: can `minimize_metadata` return an error tuple at all, now that the raising cases are rescued?

### IP-11. The combined autoquality + `max-bytes` search has no property test
**Severity:** low-medium
**Where:** `lib/image_pipe/output/encode_search.ex` (objective phase, then cap and confirm phases, with `@default_cap_iterations`). Tests: `test/image_pipe/output/encode_search_property_test.exs`.
**Evidence:** Both properties run one objective alone. The combined path's guarantees appear only in example tests (`encode_search_test.exs:181-263`):
- a `:hit` fits the byte budget
- the quality is within the bracket
- the result is never below what `max_bytes` alone would ship

Earlier hunts found bugs exactly here (bug-hunt-6 "autoquality + max-bytes ships a lower quality than max-bytes alone").
**Suggested test:** a third property using the existing generators: `rqs` plus `budget`. Assert:
- `meta.quality` is within the bracket
- `if meta.outcome == :hit, do: meta.bytes <= budget`
- under monotone curves (no jitter), `meta.quality >= search(:none, budget, ...).quality`

### IP-12. Two goldens and two imgproxy references are too small for their tolerance budget
**Severity:** low
**Where:** `test/support/image_pipe/test/golden/cases.ex:229-234` (`strip_cover_small`, 8×8×3 = 192 samples) and `:261-266` (`crop_centered_shrunk_webp`, 10×8×3 = 240). `imgproxy_reference/cases.ex:2235-2248` (`strip_fit_width`, 100×1×3 = 300; `strip_fit_box`, 400×2×3 = 2,400).
**Evidence:** All of these use `{2, 64}`. On the 192- and 240-sample goldens, 27-33% of samples may differ by more than Δ2 and still pass. `crop_centered_shrunk_webp` exists to catch a one-pixel centring shift on a shrunk WebP decode, and a 10×8 frame shifted by a pixel may not exceed 64 samples. Every other golden has at least 30,000 samples, where 64 is about 0.2%.
**Suggested test:** set `{2, 0}` (or `{2, 2}`) on these cases. Optionally, make `PixelSuite.check_pixels/3` refuse a budget above about 1% of the sample count so new tiny cases can't repeat this.

### IP-13. Smaller items
**Severity:** low
- **Default telemetry prefix in an async test.** `test/image_pipe/transform/detector/composite_test.exs:276-301` (`async: true`) attaches `[:image_pipe, :transform, :detect, :model, :stop]` and passes `telemetry_prefix: [:image_pipe]`. AGENTS.md "Process discipline" asks for a private prefix. The `assert_received` matches pinned detector modules, so the flake risk is small, but the rule is broken. Use `[__MODULE__, :model_span]` as the test at line 195 does.
- **Real backoff timers stay armed in the warmup retry test.** `test/image_pipe/transform/detector/warmup_test.exs` ("a failing warmup keeps retrying") sends `:retry` by hand while each failure's real `Process.send_after` (100, 200, 400 ms…) stays armed. If the loop stalls for more than 100 ms under CI load, a real timer adds an attempt, success arrives a round early, and `refute_received {:DOWN, ...}` fails. Make the backoff base an option (for example `backoff_base_ms: :infinity` in tests) or cancel the timer.
- **An unreachable Radiance branch.** `lib/image_pipe/transform/input_color_management.ex:146-151` (`rad2float`, line 149 uncovered) can't run: `Format.Detector` has no Radiance signature, so `.hdr` sources are rejected as `:unknown` before libvips. Delete the branch rather than test it (AGENTS.md "Prefer shrinking unsupported API surface"). The same applies to `encoder.ex:418` (`not Format.supports_color_profile?`, uncovered): every output format supports profiles.
- **Rebuffer budgets cover only blur.** `work_budget_test.exs` budgets blur → enlarge and blur → pixelate. It doesn't budget the other `rebuffer?` producers in `step.ex:105-109` and `rotate.ex:28` (sharpen → resize, `rotate=30` → `w=`), which the step comment credits with 14× and 20× speedups. If one stopped setting `rebuffer?`, the result would only be slower, and no test would fail. Add two budget lines.
- **`SrgbProfile`'s cache cap is untested.** The `@cap` of 256 profiles "keeps the answer … independent of which profiles the node saw first" (`srgb_profile.ex:10-12`), and no test covers it. It would need `persistent_term` isolation; low value.

## URL builder, grammar, signing, presets (URL)

Overall the suite is thorough. Each bug-hunt finding (hunts 3–6) got a regression example. The gaps below are mostly about **ordering contracts**, and about **properties that are narrower than the bug classes the hunts found**.

Coverage misses in the `image_pipe_url` run that turned out to be reached by `image_pipe` tests, so they are not findings:
- `Plan.Presets:69` cycle detection: covered by `image_pipe/test/image_pipe/api/preset_composition_test.exs:387` (static `a→a`, `a→b→a`) and `preset_lookup_test.exs` (looked-up `card↔loop` → 500).
- The `Inspect` impl for `Signature.Keys`: covered by `image_pipe/test/image_pipe/api_test.exs:38` (`refute inspect(ImagePipe.Plug.init(keys: …)) =~ "deadbeef"`).
- `SourceEncryption:104` (decrypt with encryption disabled): covered by `source_encryption_wire_test.exs:102`. The `:117` miss (decrypt of a non-binary token) and `Signature.Keys:22` (a non-binary key) are unreachable from in-repo callers. Under AGENTS.md "shrink unsupported surface" they are candidates for deletion, not for tests.
- `invalid_rotation`, `invalid_flip`, `invalid_progressive_blur` and `invalid_orientation` messages: reached by `image_pipe` wire tests (`retained_effects_wire_test.exs:159`, `pixel_effects_wire_test.exs:502`, `orientation_policy_wire_test.exs:150`). `invalid_max_bytes` is reached by `quality_wire_test.exs:319`.

### URL-1. Nothing pins "verify the signature before parsing or calling the preset lookup"

**Severity:** high. A refactor that parses, or calls the lookup, before checking the signature would turn the parser into an oracle for unsigned clients (400 diagnostics instead of 403). It would also let anyone trigger a `PresetLookup.fetch/2` (a DB or backend hit) with unsigned URLs, a cheap DoS amplifier. The current suite would stay green.

**Where:** `image_pipe/lib/image_pipe/plug/request.ex:14-24` (order: `Security.verify` → `Path.extract` → `decrypt_source` → `presets/2` (lookup) → `Parser.parse`). The contract is in `docs/architecture/api_contract.md` ("A host preset lookup resolves names … after signature verification") and in the `ImagePipe.PresetLookup` moduledoc ("calls `c:fetch/2` while parsing a request, after signature verification").

**Evidence:**
- Every 403 test uses a URL whose options are valid, so it passes whether the parse runs first or second:
  - `api_wire_test.exs:635-650`: `/w=64/src/...`.
  - `api/request_safety_test.exs:39-41`: `/w=64/...` and `sig=AAAA…/w=64/...`.
  - `url_wire_test.exs:98, 207`: tampered but valid options.
- Two tests do check that the signature comes first, but only against token decryption, not against option parsing or the lookup: `plug/source_encryption_test.exs:41` and `source_encryption_wire_test.exs:112`.
- No test configures both `keys:` and `preset_lookup:`. `grep -rn preset_lookup image_pipe/test` finds only `preset_lookup_test.exs` (no keys), `watermark_wire_test.exs:406` (no keys) and `summary_test.exs:127` (no keys).

**Suggested test** (wire, in `api_wire_test.exs` "signature matrix" or `request_safety_test.exs`). Mount with `keys:`, `preset_lookup: {ImagePipe.Test.PresetLookup, test_pid: self(), presets: %{"card" => "w=30"}}` and a `CacheObserver`, then request:
- `/w=bogus/src/x.jpg` (no sig)
- `/sig=<43×A>/fit=nope/-/-/src/x.jpg`
- `/preset=card/src/x.jpg` (no sig)
- `/preset=unknown/src/x.jpg` (no sig)
- `/expires=1/w=10/src/x.jpg` (no sig, expired)

For each, assert status 403, body exactly `"invalid signature"`, `refute_received {:preset_fetch, _}`, no source fetch and no cache lookup. The expired case pins 403-before-410, which follows from the code order; that answer is worth confirming.

### URL-2. The builder ↔ parser equivalence property never generates presets, request defaults, `unset`, watermarks or most option families

**Severity:** medium-high. Hunts 5 and 6 found about seven builder/server divergences in exactly these areas (unset-only groups, family modifiers, issue-location numbering, `validate_known` stubs, pipeline presets with unset groups). Each was fixed with one example test. The generated property that should guard the whole class cannot see any of them.

**Where:** `image_pipe_url/test/image_pipe/url_test.exs:146-174` (`"random multi-group plans parse back to the spec the builder resolves"`) and its generators at `:315-376`.

**Evidence:**
- It always parses with `presets: %{}` and calls `Plan.to_spec(plan.plan)` with no presets or defaults.
- `group_options/0` never produces any of these:
  - `presets:`, `:unset` values
  - `watermark*`
  - `detect`, `focus`, `region`, `anchor_offset`
  - `extend*`, `crop_ratio*`, `trim_symmetry`
  - `min_*`, `zoom`, `kernel`, `progressive_blur`, `duotone`, `monochrome`
- `output_options/0` never produces `format_qualities`, encoder options, `terminal`, `dpi`, `color_profile`, `hdr` or `max_bytes`.
- In the `{{:error, _}, {:error, _}}` case it compares nothing, so the builder and the server can disagree on the reasons or locations of their errors (hunt 5 #6 and #7 were of this kind).
- The only other builder-vs-parser property that uses presets fixes them to `w=`/`h=` (`image_pipe/test/image_pipe/presets_test.exs:261`).

**Suggested test:** extend that property, or add a sibling with `max_runs` around 300:
- Draw random presets: single-group and pipeline, with `unset` values and nested references.
- Draw random request defaults, and `unset` values in plan groups.
- Validate with `validate_against: [presets: P, request_defaults: D]`, and parse the generated URL with the compiled presets and defaults.
- Compare `Plan.to_spec(plan, compiled.presets, compiled.request_defaults)` with `Parser.parse`.
- On `{:error, _}` vs `{:error, _}`, compare the sorted `{reason, locations}` after mapping URL keys to builder names. On success, compare `IP.URL.validate/1` warnings with `spec.ignored`.

This is essentially the hunt-6 fuzzer committed as a property.

### URL-3. The order-insensitivity properties cover one fixed group; the "stable fixed point" property is a tautology

**Severity:** medium. Order-insensitivity is the first rule of the API guidelines. A new option whose merge is order-dependent (a family modifier processed before its principal, or a request option whose group position matters) would not be caught unless it happened to be in the fixed list.

**Where:** `image_pipe_url/test/image_pipe/api/canonical_property_test.exs`:
- `:55`: one fixed list of 31 segments.
- `:118-125`: the `@stability_bases` property.
- `:128`, `:144`: request-only permutations.
- `watermark_test.exs:73`: watermark options only.

**Evidence:**
- No property permutes options inside more than one group.
- None moves request-scoped options (`format`, `q`, `filename`…) between groups. The contract says the position of a request option is irrelevant; that is tested only by examples at `parser_test.exs:1229` and `:759-776`.
- None mixes these with others: `rotate`, `flip`, `gray`, `bitonal`, `focus`, `region`, `detect` (it appears in only one base), `trim=color,tol`, `wm-*`, `preset=` (the separate property at `parser_test.exs:1416` shuffles one preset in one group), or `key=unset`.
- The `:118` property asserts `{:ok, ^canonical} = parse(permutation)` twice on the same input. The second assertion only re-checks determinism, not a fixed point. There is no Spec→URL serializer, so a true fixed point cannot be checked this way.

**Suggested test:**
- Generate a random list of groups, each a random subset of mutually compatible option families. Use one segment per family, drawn from a table of valid spellings that covers every `OptionSpec` key. Add request options that a generator places in random groups, plus optional `preset=` and `X=unset`.
- Assert that shuffling within each group, and moving request options to any group, gives the same `Parser.parse` result, comparing `term_to_binary` to catch float `-0.0`/int splits.
- Drop the duplicate assertion in `:118`, or rename the property.

### URL-4. The builder never checks that inherited inert options drop without a warning

**Severity:** medium-low. The `Issue` moduledoc promises that checks "report only options the plan sets itself, not ones that a preset or the request defaults supply". If `Plan`'s `written?/4` callback regressed, every builder user with a preset like `fit=cover` would get spurious `inert_option` warnings. `image_url/2` would log them at `:debug` and `url_with_issues/3` would return them, and no test would fail.

**Where:** `image_pipe_url/lib/image_pipe/plan.ex:178-200` (`spec/4`, `written?/4`). The parser-side counterpart is tested at `parser_test.exs:850` ("inherited inert options are dropped without a report").

**Evidence:**
- The builder test closest to this scenario, `url_test.exs:618-638` ("presets may set options that do nothing on their own…"), asserts `{:ok, _warnings}` and discards the list. Its merged group (`w=auto, h=10, fit=cover, detect=face`) also has nothing inert, so it doesn't exercise the drop at all.
- The other builder tests with presets either have no inert option (`url_test.exs:381`, `presets_test.exs:12,108,163`) or have the plan write the inert option itself.

**Suggested test:**
- `IP.URL.config(validate_against: [presets: %{"cover" => "fit=cover"}, request_defaults: "jpeg-options=progressive"])` with `group(presets: ["cover"], blur: 1) |> output(format: :webp)` should give `assert IP.URL.validate(plan) == {:ok, []}`.
- The same plan written with `fit: :cover` in the group should give exactly one `inert_option` at `{:group, 0, :fit}`.
- Also tighten `url_test.exs:632` to `{:ok, []}` (please confirm that this is the intended result).

### URL-5. A table that claims to check every diagnostic message has a clause covers 20 of about 60 reasons, and five message clauses are reached by no test anywhere

**Severity:** medium. `Parser.message_for/1` and `requirement_message/1` have no fallback. If a value parser starts returning a new reason, or a requirement atom is renamed, the request raises `FunctionClauseError`: a 500 instead of a 400 for a malformed URL.

**Where:** `image_pipe_url/lib/image_pipe/api/parser.ex:536-569, 588-727`. The test is `image_pipe_url/test/image_pipe/api/diagnostic_test.exs:105-140`; its comment says "Every reason a real OptionSpec-driven value parse … can produce — completeness is asserted here".

**Evidence** (url coverage misses, checked against both test trees with grep):
- `message_for(:invalid_page | :invalid_metadata | :invalid_color_profile | :invalid_hdr | :invalid_dpi)` (`parser.ex:695, 703, 705, 708, 715`) are reached by no test in either project. Their value parsers are unit-tested directly (`option_spec_test.exs:400-440`), but no request carrying such a value is ever parsed.
- `semantic_message(:auto_dimension)` and `requirement_message(:crop | :crop_ratio | :box | :canvas | :watermark | :watermark_tile)` (`:541, 560-567`) render only when an inert option sits beside an error ("an error response also lists the URL's inert options"). That path is tested only for `:resize` and `:guide`; grep finds no "requires crop", "requires wm" or "auto dimension has no" in any test.
- `message_for(:empty_segment)` (`:592`) is dead: the parser never produces that reason. Empty fragment segments become `unknown_option`. This is a deletion candidate.

**Suggested test:** replace the hand-picked table with one row per `OptionSpec.all()` key (except `preset`). Each row uses a malformed value (`key=!`, or `key=` for flags with `=x`) and asserts `{:error, {:invalid_request, [%Diagnostic{message: m}]}}` with `m != ""`. Add one row per requirement atom that pairs the inert option with an unrelated error (for example `crop-ratio=3:2` + `w=bad`), and assert both diagnostics are present with non-empty messages. A single wire assertion (`status == 400` for `/meta=bogus/src/x.jpg`) would pin the HTTP side.

### URL-6. A preset lookup that exits (a timeout, a dead GenServer) is untested, and extra names in its result are not checked to be ignored

**Severity:** medium-low. The most common real backend failure is a `GenServer.call`/`Repo` timeout, which is an exit, not a raise. Only `:raise` and `{:error, _}` are exercised. The documented "Names in the returned map that were not requested are ignored" is also untested. That rule is what stops a lookup result from shadowing a static preset or pre-empting a later batch.

**Where:**
- `image_pipe/lib/image_pipe/presets.ex:93-104`: the `catch :exit` branch at `:102` is the only miss in `presets.ex` in the coverage run.
- `take_fragments/2` at `:106-120`.
- The test backend is `image_pipe/test/support/image_pipe/test/preset_lookup.ex`, which has no exit mode.
- The tests are in `preset_lookup_test.exs:131-156`.

**Evidence:** the `:reply` option can't express an exit, and every `:presets` reply is passed through `Map.take(presets, names)`, so a reply with extra names never occurs.

**Suggested test:**
- Add an `:exit` option to the test backend (`exit(:timeout)`) and add `{[exit: true], 503}` to the "lookup failures" table.
- Add a case where `reply: {:ok, %{"card" => "preset=base", "base" => "w=99", "framed" => "w=1"}}` with static `framed`: `base` must still be fetched in a second batch (`assert_received {:preset_fetch, ["base"]}`) and static `framed` must win. This needs a reply function keyed by names; a small extension of the support module.

### URL-7. A static preset whose leading-`unset` encoder options exceed `max_effort` is not covered

**Severity:** low. `preset_efforts!/2` is meant to reject at config time a preset or request default above `max_effort`, because otherwise most requests that use it fail with 400. The `{:unset, options}` unwrapping is never exercised, so `webp-options=unset,effort:6` with a lower webp limit could silently stop being caught.

**Where:** `image_pipe/lib/image_pipe/config.ex:635-657`. The `effort({:unset, options})` clause at `:656` is a miss in the coverage run.

**Suggested test:** in `image_pipe/test/image_pipe/api/config_test.exs`, assert that `ImagePipe.config(presets: %{"p" => "webp-options=unset,effort:6"}, max_effort: [webp: 4])` raises an `ArgumentError` naming `preset "p"`.

### URL-8. Concealed-token framing edges: no test for a non-canonical spelling, an empty ciphertext, or valid MAC with bad padding

**Severity:** low. Each check is backed by the MAC, so tampering is still rejected. But the contract says "The token is canonical unpadded base64url", and `canonical_token/2` and the unpad failure branch have no test. A refactor could drop either unnoticed.

**Where:** `image_pipe_url/lib/image_pipe/security/source_encryption.ex:146-168` (`canonical_token/2`, `split_payload/1`) and `.../cbc.ex:28-37` (`unpad/1`; the `false -> :error` at `:37` is a url-coverage miss). The tests are `image_pipe_url/test/image_pipe/security/source_encryption_test.exs:110-148`.

**Evidence:**
- The malformed list tests padding (`token <> "="`), version 2, a short tag and bit flips.
- It doesn't test a token whose last character only changes the unused trailing bits. These exist for payloads of 113 bytes and up (two or more CBC blocks); the signature test already does the same for signatures at `signature_test.exs:117`.
- It doesn't test a 49-byte payload (version + IV + tag, no ciphertext).
- It doesn't test an authenticated ciphertext with invalid PKCS#7 padding. "rejects authenticated empty and invalid UTF-8" builds its ciphertext through `CBC.encrypt`, which always pads correctly.

**Suggested test:**
- Encrypt a source of 20 or more bytes, flip the unused low bits of the last char, assert `:invalid_concealed_source`.
- Frame `<<1, iv::16-bytes, tag::32-bytes>>` and assert it is rejected.
- With the HKDF-derived key, AES-encrypt a block whose last byte is `0` or `17` without padding, compute the tag the way `CBC.tag` does, and assert `decrypt/2` returns `{:error, :invalid_concealed_source}` and doesn't raise.

### URL-9. The builder's 64-segment limit is never tested at the boundary

**Severity:** low. If `<=` became `<`, the builder would refuse URLs the server accepts. The only builder tests use 33 groups (65 segments) and 70 groups.

**Where:** `image_pipe_url/lib/image_pipe/api/url.ex:56, 175`. The tests are `url_test.exs:258` and `url_with_issues_test.exs:149`. The parser side is tested at exactly 64 (`diagnostic_test.exs:67`).

**Suggested test:** 32 `group(gray: true)` calls (63 segments) plus one output option (64 segments) should give `{:ok, url}`, and the URL should parse. Add one more output option to get `{:error, :too_many_options}`. Signed and `encrypt_source: true` variants confirm that `sig=` and `enc` aren't counted.

### URL-10. `url/3` with `iv:` on a configuration that has encryption keys but `encrypt_source: false`

**Severity:** low. The documented error is `{:error, :source_encryption_disabled}` whenever "the configuration doesn't have `encrypt_source: true`". The only test (`url_test.exs:84`) uses a configuration with no keys at all. A refactor that switched the check to "encryption keys present" would encrypt sources the caller asked to leave plain, and nothing would catch it.

**Where:** `image_pipe_url/lib/image_pipe/api/url.ex:110-118`.

**Suggested test:** with `IP.URL.config(keys: [k], source_encryption_keys: [s])`, `IP.URL.url(IP.URL.new(c), "a.jpg", iv: :random)` should return `{:error, :source_encryption_disabled}`, and the default call should still give `/src/a.jpg` (the watermark source stays in `wm-src64`).

### URL-11. `URL.Helpers` misuse that raises at compile time is untested

**Severity:** low (a compile-time developer experience). Each of these miss paths would otherwise give a confusing `FunctionClauseError` or silent acceptance:
- `on_invalid` other than `:warn`/`:raise`
- unknown `use` options
- `config:`/`instance:` given together
- `image_url/2` without `use`
- `new:` given twice
- an unknown call kind

Separately, nothing asserts that render-time warnings (as opposed to errors) are logged at `:debug` and don't raise under `on_invalid: :raise`, which the docs state.

**Where:** `image_pipe_url/lib/image_pipe/url/helpers.ex:89, 94, 116, 189, 215, 221, 229` (url-coverage misses) and `report/3` at `:338-349`. The tests are in `image_pipe_url/test/image_pipe/url/helpers_test.exs`.

**Suggested test:** one `Code.compile_string` per raise path with `assert_raise ArgumentError, ~r/…/`. Add one `StrictPage` call with a repaired option (`group: [blur: 1, blur: 2]`) that returns the URL without raising, checked with `capture_log(level: :debug)`.

### Not findings (checked, fine)

- **Signature unit matrix:** wrong key, truncated or long signatures, padded or non-canonical last character, a missing signature with keys, a signature without keys, rotation index, a duplicate slash, and an encoder that uses only the first key (`signature_test.exs`, `api_wire_test.exs:633-678`, `summary_test.exs:317` for `sig_key`).
- **Encryption:** RFC vector, protocol vector, rotation, deterministic/random/explicit IV, salted watermark IVs, the disabled-mount 400, unauthenticated tokens as 404, and no secrets in responses or telemetry.
- **Presets:** pipeline errors, precedence, unset families, unset-only groups (the bug-hunt-6 #1 regression is now at `parser_test.exs:1531, 1560`), static `wm-enc` decryptability (hunt-6 #2/#3 at `config_test.exs:429-470`), lookup statuses and limits, and ETag changes when a looked-up preset changes.
- **Flakiness:** no test in this area writes `Application` env or `:persistent_term`. The only `:persistent_term` writer is `Builder.Options.compiled/2`, which is idempotent. Telemetry tests here use private prefixes.

## Server, SVG, CI and test hygiene (SRV)

### SRV-1. The container smoke test can't see a Logger warning, and it checks PNG output only, so an image that can't encode AVIF, WebP, or JPEG passes CI

**Severity:** high

**Where:** `image_pipe_server/test/container/smoke.sh:60-64`, `:66-83`; `image_pipe_server/lib/image_pipe_server/warmup.ex:275,303`; `image_pipe_server/Dockerfile:167-170`; `image_pipe_server/config/config.exs:16-19`

**Evidence:**
- The startup check is `docker logs "$name" 2>&1 | grep -q 'WARNING'`, which is case-sensitive. The release's text formatter prints `$date $time $metadata[$level] $message`, so a Logger warning comes out as `[warning] ...`. The repo's own test relies on that lowercase form (`application_test.exs:184`, `assert line =~ "[warning] slow"`). Uppercase `WARNING` only matches GLib's `VIPS-WARNING **` lines.
- `Warmup.run/1` encodes jpeg, png, webp, and avif at boot. When one fails it only calls `Logger.warning("warmup: #{format} failed: ...")`, and the server still turns healthy.
- The smoke test only asks for `format=png` (`check_png pic.png|pic.jxl|pic.svg`).
- AVIF encoding depends on the runtime-stage packages `libheif-plugin-aomenc` and `libheif-plugin-dav1d` (`Dockerfile:169`). If one is dropped or renamed, or the libvips build loses an encoder, warmup logs `[warning] warmup: avif failed`, the smoke test passes, and real traffic breaks, because `Accept` negotiation prefers AVIF.

**Suggested test:**
- Make the grep case-insensitive and anchored to level markers, for example `grep -Eq '\[(warning|error)\]|WARNING'`.
- Add a `check_format` helper that requests `format=avif`, `format=webp`, and `format=jpeg` and checks each one's magic bytes: `ftypavif` at offset 4, `RIFF....WEBP`, `ffd8ff`.
- Add one request with `Accept: image/avif,image/webp` and no `format=`, and assert `content-type: image/avif`.
- For the JSON container, also fail on `"level":"warning"`.

### SRV-2. No server test shows that `[url]` signing and encryption keys reach the running instance, or that the server rejects an unsigned URL

**Severity:** high

**Where:** `image_pipe_server/lib/image_pipe_server/config.ex:439-452` (`image_pipe!/2` merges `Keyword.get(sections, :url, [])` into `ImagePipe.config/1`); `image_pipe_server/test/image_pipe_server/config_test.exs:41-55,331-344,496-503,585-604`; `image_pipe_server/test/image_pipe_server/router_test.exs:16-25`; `image_pipe/docs/building-server-urls.md:18-25,79`

**Evidence:**
- Every server test that touches `url.keys` or `url.source_encryption_keys` stops at `Config.options!/1`, which covers conversion, error text, and `_FILE` reading. No test asserts on `config.image_pipe` for keys. The six `config.image_pipe.options[...]` assertions cover `processing_pool`, `watermarks`, `request_watermarks`, and `quality` only.
- `router_test.exs` builds its mount with `ImagePipe.Plug.init(sources: ...)` and no keys. `smoke.sh` sets no keys either.
- If a refactor of `image_pipe!/2` dropped or misordered the `url` options, the server would serve unsigned URLs and no test would fail.
- The README's main use case is an `image_pipe_url` app signing with `IPS_URL__KEYS`, and it has no end-to-end check.
- `presets` and `request_defaults`, which the walkthrough also says the app and server must agree on (`building-server-urls.md:135`), are likewise only checked as converted values (`config_test.exs:58-70`).

**Suggested test:**
- Write a wire-level test in `application_test.exs` or a new `signing_wire_test.exs`:
  1. Build `Config.load!(%{"IPS_CONFIG_TOML" => toml, "IPS_URL__KEYS" => hex}, ...)` with a file source.
  2. Start `App.http_child(config, {Router, App.router_options(config, drain)})` and the ImagePipe instance (`App.children/2` or `start_supervised!`).
  3. Request a path signed with `ImagePipe.URL`/`ImagePipe.Security` using the same hex key and expect 200. Expect 403 for the unsigned path.
- Do the same with `source_encryption_keys` and an `enc/` path.
- Do the same with a preset defined in the TOML file and used in the URL.

### SRV-3. The `:image_vision` tests never run in any CI workflow, so the real-model detector adapters are tested only by the release-time container smoke test

**Severity:** medium

**Where:** `image_pipe/test/test_helper.exs:54-58` (`exclude: [:image_vision] ++ ...`); `image_pipe/test/image_pipe/transform/detector/image_vision_test.exs:38,84,104-113,127-148`; `image_pipe/mix.exs:262-279`; `.github/workflows/elixir.yml:199,206`; `image_pipe/lib/image_pipe/transform/detector/image_vision/{face,model,objects}.ex`

**Evidence:**
- The lane needs `IMAGE_VISION=1` at `mix deps.get` time, and no workflow sets it for `image_pipe`. A repo-wide `grep -rn IMAGE_VISION .github` finds it only in the server image build args.
- So these tests never run anywhere: the drift guard ("supported_classes matches the model's labels"), "warmup propagates corrupt model errors", and the real `Face.detect`/`Objects.detect` routing.
- The default lane's versions are conditional no-ops. For example, `image_vision_test.exs:33` iterates `for adapter <- [Face, Objects], not adapter.available?([])`, which asserts nothing when the dependency is present.
- `image_pipe_server` tests never build with `IMAGE_VISION=1` either. The server's `instance!/2` check of `detector_warmup` classes against a real detector (`config.ex:455-459`) is covered only for the "detector not available" path (`config_test.exs:467-471`).

**Suggested test:** add an `image_vision` job to `elixir.yml`. It would run on pushes to `main`, nightly, or on PRs that touch `image_pipe/lib/image_pipe/transform/detector/**` or `mix.lock`, and run `IMAGE_VISION=1 mix deps.get && mix test --only image_vision` with the HuggingFace model cache saved by `actions/cache`. In the same job, `image_pipe_server` could run `IMAGE_VISION=1 mix test` with a config test asserting that `detector_warmup = ["unicorn"]` fails with a message naming `processing.detector_warmup`.

**Question for Håvard:** is the lane meant to be run by hand only? If so, the comment at `mix.exs:268-269` should say CI never runs it.

### SRV-4. The Server image workflow (Docker build and smoke test) ignores changes to `image_pipe/lib/**` and `image_pipe_url/lib/**`

**Severity:** medium

**Where:** `.github/workflows/server-image.yml:172-194`; compare with `.github/workflows/server.yml:6-20`; `.github/workflows/release-server.yml:134`

**Evidence:**
- `server-image.yml`'s path filter lists the library manifests and `image_pipe/priv/icc/**`, but not `image_pipe/lib/**` or `image_pipe_url/lib/**`. Its header says Server CI already tests that code.
- Server CI tests it only in `MIX_ENV=test` with the sibling path deps, the vix-bundled libvips, and no release.
- None of these are exercised on a library PR:
  - `MIX_ENV=prod` compilation.
  - `RELEASE_MODE=interactive`.
  - The source-built libvips with JPEG XL, highway, and its disabled loaders.
  - `:code.priv_dir` lookups in a release (for example `output/color_profile.ex:28`).
  - The vision variant's offline `detect=face`, `detect=car`, and `anchor=smart-face` checks (`smoke.sh:216-249`).
- A library change that breaks any of these first shows up in `release-server.yml`'s smoke step, at release time.

**Suggested fix:** add `image_pipe/lib/**`, `image_pipe_url/lib/**`, and `image_pipe/priv/**` to `image_paths`. To save runner time, add them only for the `base` amd64 row, or for PRs labelled `perf`/`full-ci`. Alternatively, run the smoke test nightly on `main`, since `performance.yml` already builds a main image nightly.

### SRV-5. The fiddle's Elixir suite never runs in CI

**Severity:** medium

**Where:** `.github/workflows/lint.yml:18` (triggers on `fiddle/**`), `:96-163`; `mise.toml:113-125` (`precommit:fiddle`); `fiddle/test/image_pipe_fiddle_web/api_wire_test.exs`, `wire_test.exs`, `fiddle/test/image_pipe_fiddle/sources_test.exs`

**Evidence:**
- `lint.yml` fetches the fiddle's deps, then runs `mix format --check-formatted` and the JS check, format, lint, test, and build steps.
- It never runs `mix compile --warnings-as-errors` or `mix test` in `fiddle/`, and no other workflow mentions the fiddle.
- The fiddle's 18 Elixir tests go through the library's real mount: the signing helper, concealed paths, presets, watermarks, `info`/BlurHash/debug terminals, and the configured sources. AGENTS.md requires the fiddle to track every URL option change.
- So a library change that breaks the demo, or a fiddle controller that no longer compiles, is caught only by a local `mise run precommit:fiddle`.

**Suggested fix:** add `cd fiddle && mise exec -- mix compile --warnings-as-errors` and `MIX_ENV=test mise exec -- mix test` steps to the lint job, whose fiddle deps are already cached, or add a small `fiddle.yml` that runs on `fiddle/**`, `image_pipe/lib/**`, and `image_pipe_url/lib/**`.

### SRV-6. The SVG fuzz crate is never built in CI, Dependabot doesn't update it, and it has already drifted from the NIF; its regression seeds are never replayed

**Severity:** medium

**Where:** `image_pipe_svg/native/image_pipe_svg_nif/fuzz/Cargo.toml:15-19`; `image_pipe_svg/native/image_pipe_svg_nif/Cargo.toml:14-15`; `image_pipe_svg/native/image_pipe_svg_nif/fuzz/src/lib.rs` (compiles `../../src/{cost,entities,parse,render}.rs` directly); `.github/dependabot.yml:24-38`; `.github/workflows/svg.yml` (the Rust tests step runs `cargo test` in the NIF crate only); `image_pipe_svg/native/image_pipe_svg_nif/fuzz/seeds/{render,expansion,templates}/`

**Evidence:**
- The NIF declares `imagesize = "0.15"`; its `Cargo.lock` has 0.15.0. The fuzz crate declares `imagesize = "0.13"`; its lock has 0.13.0 as the direct dependency.
- So the fuzz targets check `parse.rs`'s embedded-image sniffing (`imagesize::image_type`, `imagesize::blob_size`, `parse.rs:192-245`) against a different `imagesize` than the one that ships.
- Dependabot's cargo entry lists only `/image_pipe_svg/native/image_pipe_svg_nif`, and no workflow builds `fuzz/`.
- Once `parse.rs` uses an API newer than 0.13, the fuzz crate stops compiling and nobody finds out.
- The 40 render and expansion seeds are minimized cases from the PR #856 reviews (`nonfinite_curve`, `stroked_curve_chain`, `huge_arc_radius`, `mask_default_units`, `duplicate_id`, and others). Nothing replays them on a PR. Only some have ExUnit counterparts in `image_pipe_svg/test/image_pipe/svg_test.exs`.

**Suggested test:**
- Add a stable-Rust `#[test]` in the NIF crate, beside `prescan_tests.rs`, that reads every file under `fuzz/seeds/render` and `fuzz/seeds/expansion` and runs `parse::parse` with the default limits, then `cost::estimate` and `render::render` at 64×64. It would assert no panic, and for `expansion`, that the node count stays within the 4-per-element bound that the fuzz target checks.
- Add `cargo check --manifest-path fuzz/Cargo.toml` (stable can type-check `libfuzzer-sys` targets) to the svg lint job.
- Add `/image_pipe_svg/native/image_pipe_svg_nif/fuzz` to Dependabot's cargo directories, or make the fuzz crate take `imagesize` and `resvg` via `workspace = true`.

### SRV-7. The cgroup CPU-quota and glibc-allocator branches of `rel/env.sh` never run in a test

**Severity:** medium

**Where:** `image_pipe_server/rel/env.sh.eex:35-45` (`IMAGE_PIPE_ALLOCATOR`/`MALLOC_ARENA_MAX`), `:47-64` (`VIPS_CONCURRENCY` from `cpu.max` or `cpu.cfs_*`), `:10-13` (`RELEASE_DISTRIBUTION=name`); `image_pipe_server/test/container/smoke.sh:38-42,98-107,183-209`

**Evidence:**
- The smoke container runs without `--cpus`, so `cpu.max` reads `max` and the quota branch is skipped. The `$(((quota + period - 1) / period))` arithmetic and the cgroup v1 fallback never execute.
- The smoke test checks only the jemalloc path (`LD_PRELOAD`, `MALLOC_CONF`). The glibc fallback (`IMAGE_PIPE_ALLOCATOR=glibc` sets `MALLOC_ARENA_MAX=2` and no preload) and the `name` distribution branch are never exercised.
- An error in the quota arithmetic makes `env.sh` fail under `set -e`-less sh with a syntax error, or exports a wrong `VIPS_CONCURRENCY`. Either way it's found only in production on a CPU-limited pod.

**Suggested test:** in `smoke.sh`, run the existing `$name-dist`-style container with `--cpus 1.5` and assert that beam's `/proc/<pid>/environ` holds `VIPS_CONCURRENCY=2`. Run one with `-e IMAGE_PIPE_ALLOCATOR=glibc` and assert `MALLOC_ARENA_MAX=2` and no `LD_PRELOAD=`, reusing the `beam_env` reader at `smoke.sh:100-101`. Optionally run one with `-e VIPS_CONCURRENCY=3 --cpus 1` and assert the explicit value wins.

### SRV-8. The Docker `HEALTHCHECK` port selection and the `health_port` listener are never exercised in a release

**Severity:** medium-low

**Where:** `image_pipe_server/Dockerfile:211-214`; `image_pipe_server/docs/server-deployment.md:146-151`; `image_pipe_server/test/container/smoke.sh:38-55`

**Evidence:**
- The HEALTHCHECK shell picks `IPS_SERVER__HEALTH_PORT` when it isn't `0`, and otherwise `IPS_SERVER__PORT` (default 8080). The deployment guide documents that behaviour.
- Every smoke container uses neither variable. So the `[ "$port" != 0 ] || port=...` logic, the health listener in a real release (`App.health_child/2`), and a non-default `IPS_SERVER__PORT` are untested.
- If either branch broke, containers would never turn healthy, which matters most on Swarm-style platforms that restart unhealthy containers.

**Suggested test:** add a container to `smoke.sh` with `-e IPS_SERVER__PORT=9090 -e IPS_SERVER__HEALTH_PORT=9091`. Wait for `healthy`, then from inside the container (`docker exec ... curl`) assert that `:9091/health/live` answers `ok`, `:9091/w=2/src/pic.png` answers 404, and `:9090/w=4/format=png/src/pic.png` answers 200.

### SRV-9. Stats wiring with an input cache is untested at both the application and endpoint level

**Severity:** medium-low

**Where:** `image_pipe_server/lib/image_pipe_server/application.ex:157-175` (`stats_options/1`, `disk_child/1`), `:180-195` (`health_child/2` passes `stats_options(config)`); `image_pipe_server/lib/image_pipe_server/stats.ex:85-89` (`Map.fetch!(roots, cache)`); `image_pipe_server/test/image_pipe_server/stats_test.exs:13-48,163-164`; `image_pipe_server/test/image_pipe_server/application_test.exs:108-130`

**Evidence:**
- `stats_test.exs` starts an instance with only `cache:` and passes a hand-built `roots: %{output: ...}`. The only assertion about input is `refute Map.has_key?(body, "input")`.
- `application_test.exs` builds a config with both caches but without `[stats]`, so the children list never contains `ImagePipeServer.Stats.Disk`.
- These are never asserted:
  - The `:cache → :output` and `:input_cache → :input` mapping in `stats_options/1`.
  - The `Enum.uniq` of shared roots.
  - The rule that the disk child starts after the instance ("which creates the cache roots", `application.ex:118`).
  - The health listener getting the same stats.
- If the server's key mapping and `ImagePipe.Cache.stats/1`'s names (`image_pipe/lib/image_pipe/cache.ex:247`) ever diverged, `read_snapshot/3` would raise `KeyError` and `/stats` would answer 500.

**Suggested test:** in `application_test.exs`, add:

```elixir
config = Config.build!(Config.options!(%{"cache" => both, "stats" => %{"enabled" => true, "token" => "t"}}))
```

Then assert three things:
- `App.stats_options(config).roots == %{output: out, input: in}`.
- `App.children/2` places `{ImagePipeServer.Stats.Disk, _}` right after `{ImagePipe, _}`.
- `App.health_child(config, drain)` carries `stats:`.

In `stats_test.exs`, start the instance with `input_cache:` too, and assert that `/stats` has an `"input"` object and `/metrics` has `cache="input"` samples.

### SRV-10. The pre-boot log and tracing settings in `config/runtime.exs` are only partly asserted

**Severity:** medium-low

**Where:** `image_pipe_server/config/runtime.exs:3-27`; `image_pipe_server/test/image_pipe_server/log_handler_test.exs:316-350`; `image_pipe_server/lib/image_pipe_server/application.ex:28-30`

**Evidence:**
- The bug-hunt-5 #6 fix (commit `771a1e6`) applies `log_level`, `log_colors`, and `log_format` before dependencies start.
- `LogHandlerTest.release_logger_config/1` reads `config.exs` merged with `runtime.exs` for `:prod`. It asserts only that a `:formatter` key exists for non-text formats, plus the overload options.
- These are never asserted: `config :logger, level:` from `[telemetry] log_level`; `:default_formatter, colors: [enabled: true]` for `log_colors = true`; the tracing branch (`:image_pipe_server, tracing: true` and `:opentelemetry, traces_exporter: :otlp` when `OTEL_EXPORTER_OTLP_ENDPOINT` is set).
- In the test env, `runtime.exs` skips this block (`config_env() != :test`). So `Application.start/2`'s `attach_tracer` branch never runs, and `Tracing.settings/1` (unit-tested) is never tested in its real caller.

**Suggested test:** make `release_logger_config` return the whole merged keyword and take an env map. It sets each variable with `System.put_env` and deletes it in `after`, since the module is already `async: false`. Then assert:
- `[telemetry] log_level = "warning"` gives `config[:logger][:level] == :warning`.
- `log_colors = true` gives `get_in(config, [:logger, :default_formatter, :colors]) == [enabled: true]`.
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://c:4318` gives `config[:image_pipe_server][:tracing] == true` and `config[:opentelemetry][:traces_exporter] == :otlp`.
- With no OTEL variables, tracing is `false`.

### SRV-11. Boot failures after the configuration is valid are untested

**Severity:** medium-low

**Where:** `image_pipe_server/lib/image_pipe_server/application.ex:34-39,86-97`; `image_pipe_server/lib/image_pipe_server/warmup.ex:265-308`; `image_pipe_server/docs/server-deployment.md:120-121`; `image_pipe_server/docs/server-configuration.md:124-127`

**Evidence:**
- Only `ConfigError` is turned into a one-line message and `System.halt(1)`, which `application_test.exs:69-85` and `smoke.sh:166-179` test.
- Some realistic operator mistakes surface only when children start:
  - `server.port` or a fixed `health_port` already in use (Bandit returns `eaddrinuse`).
  - A cache root on the read-only root filesystem, for example `root = "/var/cache/out"` without a volume, with `--read-only` (the instance's `Owner.claim` does `File.mkdir_p`, `image_pipe/lib/image_pipe/cache/file_system/owner.ex:65`).
- What the operator sees for these isn't asserted anywhere: a crash report, "Kernel pid terminated", an exit status, or a boot loop.
- `Warmup`'s comment says "A failure is logged and doesn't stop the server", but only `{:error, _}` is handled. A raise inside `ImagePipe.run/4`, or in `Image.new!`/`Image.write!` in `run/1`, propagates out of `start_link/1` and fails the supervisor.

**Suggested test:**
- Add a subprocess test like the existing `mix run` one, with `[server] port = <a port held open by the test>`. Assert a non-zero exit, and decide whether the output should be one line naming `server.port`.
- Add a smoke case that runs with `[cache.output] root = "/var/cache/out"` under `--read-only` and asserts the documented outcome.

**Question for Håvard:** should these become `ConfigError`-style one-liners too?

### SRV-12. Timing races in the server's listener tests

**Severity:** low

**Where:** `image_pipe_server/test/image_pipe_server/application_test.exs:247-254` and `:325-329` (`receive_timeout: 500`), `:374-383` (`SlowPlug` with `Process.sleep(300)`); `image_pipe_server/test/image_pipe_server/stats/disk_test.exs:59-62` (`disk_age_seconds: 0`)

**Evidence:**
- **500 ms receive timeout.** Both connection-cap tests use `receive_timeout: 500` on the first requests through a fresh listener. The same file says that "the first request through a fresh listener can take longer than the default receive timeout on a loaded CI runner" (`:396-397`) and raises that wait to 2 s.
  - In the cap test, the regression the test guards already fails fast without the short timeout: an acceptor at its cap closes the socket after 5 retries of `max_connections_retry_wait: 50` (`:240`).
- **Fixed sleep in a plug.** `SlowPlug` uses `Process.sleep(300)`, which is a fixed delay against `shutdown_timeout: 10` and `5_000`.
- **Wall-clock age.** The disk test asserts `disk_age_seconds == 0`, which flips to 1 when more than a second passes between the setup `df` and the read (`disk.ex:29`, truncated seconds).

**Suggested fix:**
- Raise the cap test's `receive_timeout` to 2 000 ms. For the health-listener test, also set `max_connections_retry_wait: 50` on the main listener, so a shared listener would fail by closing instead of by timing out.
- Make `SlowPlug` block on `receive do :finish -> ... end` and have the "finish within the grace period" test send `:finish` once `stop_supervised` is running in a Task. The cut-off test then needs no sleep at all.
- Assert `age in 0..1`.

### SRV-13. `TracingTest` is `async: true` but attaches the global tracer and flips global `persistent_term` flags

**Severity:** low

**Where:** `image_pipe_server/test/image_pipe_server/tracing_test.exs:1-10`; `image_pipe/lib/image_pipe/telemetry.ex:211-247`; `image_pipe/lib/image_pipe/telemetry/trace.ex:27-31`

**Evidence:**
- "the tracer attaches" calls `ImagePipe.Telemetry.attach_tracer()` and `detach_tracer()`. That attaches VM-wide `:telemetry` handlers on `[:image_pipe, ...]`, and calls `Trace.set_attached/1` and `set_extract_inbound/1`, which write `:persistent_term`. All of this happens while the other async server modules (`RouterTest`, `StatsTest`, `ApplicationTest`) make real ImagePipe requests.
- Those requests get traced, and `ReqStep` (`trace/req_step.ex:41`) changes behaviour while `attached?` is true.
- Attaching mid-span can deliver a `:stop` with no `:start` to the handler. If the assertion fails, `detach_tracer` never runs (it isn't in `on_exit`).
- The library's equivalent tests (`image_pipe/test/image_pipe/telemetry/trace/attach_test.exs`) are `async: false` and detach in `on_exit`.

**Suggested fix:** move that one test into an `async: false` module and use `on_exit(&ImagePipe.Telemetry.detach_tracer/0)`. The `Tracing.settings/1` tests can stay async.

### SRV-14. The server test suite takes the developer's `IPS_*` environment

**Severity:** low

**Where:** `image_pipe_server/lib/image_pipe_server/application.ex:88-92` (`Config.load!(System.get_env(), ...)`); `image_pipe_server/config/test.exs:3-4`; `image_pipe_server/test/image_pipe_server/application_test.exs:74-78`; `image_pipe_server/test/image_pipe_server/config/tree_test.exs:181`

**Evidence:**
- The application under test boots from `test/support/server.toml` merged with every `IPS_*` variable in the shell. An exported `IPS_SERVER__PORT`, `IPS_URL__KEYS`, or `IPS_SERVER__AUTH_TOKEN` changes the "running application" tests. For example, an auth token makes `serves an image from the configured File mount` answer 401.
- The subprocess boot test passes `env:` additions on top of the inherited environment. A shell with `IPS_CONFIG_TOML` set makes it fail with "both IPS_CONFIG and IPS_CONFIG_TOML are set" instead of the expected message.
- Separately, `tree_test.exs:181` decides `@tag skip:` at compile time with `System.cmd("id", ["-u"])`. The library probes the precondition at runtime in `test_helper.exs` (`:file_permissions`).

**Suggested fix:**
- Pass `{"IPS_CONFIG_TOML", nil}` (`System.cmd` unsets `nil` values) and any other `IPS_` variables found in `System.get_env()` as `nil` in the subprocess test.
- For the booted app, have `config/test.exs` point at `server.toml` and document that `IPS_*` must be unset, or have `Application.config!/0` drop `IPS_*` variables when `default_config_path` comes from the test config.
- Move the root check into `test_helper.exs` as an excluded `:file_permissions` tag, like the library.

### SRV-15. The SVG "never reads files or fetches URLs" test can fail through only one of its four hrefs

**Severity:** low

**Where:** `image_pipe_svg/test/image_pipe/svg_test.exs:446-464`; `image_pipe_svg/native/image_pipe_svg_nif/src/parse.rs:254-262`

**Evidence:**
- **Relative href.** `"canary.png"` is relative. A resolver that loaded relative paths would look in the process's working directory (`image_pipe_svg/`), not in `tmp_dir`, where the canary is. So that case passes either way.
- **Network href.** `"http://127.0.0.1:1/x.png"` points at a port nothing listens on. A fetch fails, the image is still empty, and the test passes.
- **CSS case.** `fill: url('...')` can only name a paint server, not an image, so it can't draw the canary.
- Only the absolute-path `<image>` case, and perhaps `file://`, would catch a resolver regression, such as someone swapping `resolve_string: |_, _| None` for usvg's default.
- External `<use href="other.svg#x">` and `<feImage href="...">` aren't covered.

**Suggested test:**
- Use `Path.relative_to_cwd(canary)` for the relative case.
- Replace the port-1 URL with a `:gen_tcp.listen(0, ...)` socket the test owns, and assert `:gen_tcp.accept(listen, 200) == {:error, :timeout}` after the render.
- Add `<filter><feImage href="#{canary}"/></filter>` and `<use href="#{canary_svg}#r"/>` cases with a red canary SVG.

### SRV-16. The precompiled SVG NIFs are published without ever being loaded

**Severity:** low

**Where:** `.github/workflows/release-svg.yml:46-81,113-155`; `image_pipe_svg/lib/image_pipe/svg/native.ex:219-236`

**Evidence:**
- The release builds seven targets × three NIF versions, downloads checksums, and publishes to Hex. No job installs the package from the built artifacts and calls `ImagePipe.SVG.versions/0`.
- The Linux GNU artifact is loaded only later, by the server release image (`IMAGE_PIPE_LIBS=hex`).
- The musl, macOS, and Windows artifacts are never loaded by CI, so a target that links but fails `dlopen` (for example a musl build needing a glibc symbol) ships.

**Suggested test:** after the build matrix, add a job per OS family (ubuntu, alpine container, macos, windows) that points `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH` at the downloaded artifacts and `force_build: false`, then runs `mix run -e 'IO.inspect(ImagePipe.SVG.versions())'` in `image_pipe_svg`.

### SRV-17. Minor hygiene in the library and URL suites

**Severity:** low

**Where:** `image_pipe/test/image_pipe/transform/detector/composite_test.exs:274-302`; `image_pipe_url/test/image_pipe/api/watermark_test.exs:73-79`; `image_pipe/test/test_helper.exs:52-55` against explicit `, 1_000` waits

**Evidence:**
- **Default prefix in an async test.** `CompositeTest` is `async: true` and attaches `:telemetry_test.attach_event_handlers` on the default-prefix `[:image_pipe, :transform, :detect, :model, :stop]` with `telemetry_prefix: [:image_pipe]`. That's the pattern AGENTS.md's process-discipline rule forbids.
  - The assertions match the test-only `FaceChild`/`ObjectChild` modules, so it can't false-pass today. A future `refute_received` or count assertion would flake.
- **Shuffle outside StreamData.** The watermark order property uses `constant(options) |> map(&Enum.shuffle/1)`. The permutation comes from the process RNG, not StreamData, so a failure doesn't shrink and generation isn't tied to the property's own seed.
- **Short explicit waits.** `image_pipe`'s `test_helper.exs` raises `assert_receive_timeout` to 2 000 ms "under CI scheduler load". Six cross-process waits still pass an explicit `, 1_000`, which is lower than the default:
  - `api/file_source_cache_wire_test.exs:87`
  - `api/processing_controls_wire_test.exs:107`
  - `cache/work_test.exs:151`
  - `plug_test.exs:1034`
  - `source/s3/refresh_cache_test.exs:365`
  - `cache/file_system/reconciliation_test.exs:61,67`

**Suggested fix:**
- Pass a unique prefix, as `crop_operation_test.exs:240-262` does, in `CompositeTest`.
- Generate permutations from StreamData, for example by sorting the options by a generated `list_of(integer(), length: 6)`.
- Drop the explicit `1_000`s so they inherit the 2 000 ms default.

### Checked and found sound

- **No-assertion tests.** A scan of all 3,488 `test`/`property` blocks across the five projects found none without an assertion. The three hits delegate to asserting helpers (`api/layout_matrix_test.exs:80`, `api_golden_test.exs:34`, `api_imgproxy_reference_test.exs:39`).
- **Sleeps and liveness checks.** There's no `Process.alive?` in any test. The library's three remaining `Process.sleep`s hold a pool slot after the queue is observed, or stand in for a slow DNS lookup, and race nothing.
- **Global state in async library tests.** Global state is mutated only in `async: false` modules (`logger_test`, `summary_test`, `log_handler_test`, the fiddle's `sources_test`). `svg_source_wire_test`'s `:persistent_term.erase` uses a per-`tmp_dir` key.
- **Telemetry in async library tests.** Async telemetry tests use private prefixes, or filter on `self() == test_pid` (`response_sender_test.exs:544-555`).
- **Whole-image suites.** The imgproxy reference and golden suites are excluded from the partitioned run but run in their own step on PRs (`elixir.yml:204-209`, newest toolchain, partition 1).
- **Server config coverage.** The `[server]`, `[telemetry]`, `[stats]`, and `[cache]` keys, TOML redaction, `_FILE` handling, Kubernetes service links, and the generated reference staying in sync (`reference_test.exs:69-72`) are all well covered.
