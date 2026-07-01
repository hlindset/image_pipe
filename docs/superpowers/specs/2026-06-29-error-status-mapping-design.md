# Customizable internal-error → HTTP-status mapping

**Issue:** [#267](https://github.com/hlindset/image_pipe/issues/267) (transform side) unified with [#160](https://github.com/hlindset/image_pipe/issues/160) (source side)
**Date:** 2026-06-29
**Status:** design approved (revised after 4-lens parallel review), pending final spec review

## Problem

`ImagePipe.Response.Sender` is the single place that maps an internal failure
reason to a client-facing HTTP status. Today it does so with a scatter of
per-tag clauses, and two whole failure *families* are flattened to a single
status that loses information already carried in the reason:

- **Transform side (#267):** every transform-execution failure →
  **422 "invalid image transform"**, except the one `{:transform_error,
  {:bad_request, _}}` slice (added for IIIF in #253) → **400**. There is no
  general way for a transform op — or a dialect parser — to request a different
  client status for a request that only turns out invalid at execution time.
- **Source side (#160):** every `{:source, _}` failure →
  **422 "invalid image source"**, whereas upstream imgproxy (the primary compat
  target) returns a range of codes by failure class (404 / 502 / 504 / 4xx
  passthrough). The distinguishing reason is already carried in the
  `{:source, reason}` tag but flattened at the mapping.

These are the same problem on two paths: a rich internal reason collapsed to a
coarse status. We solve them with **one mechanism**.

## Decision summary

1. **Mechanism — an internal, status-bearing *client-error class*** carried in
   failure reasons. This generalizes the existing `{:bad_request, _}` → 400
   slice. A producing layer (transform op, parser, source) expresses *intent* by
   the reason it emits; `Sender` resolves every reason through **one** classifier
   → status table. The class set is an HTTP-response concern and lives in
   `Response`, not a "neutral vocabulary" reusable elsewhere (see Architecture).
2. **Unify #267 and #160** through that one classifier. Both the transform path
   and the source path route through it, including the two *separate* source-error
   rendering sites (streaming and resolve-time — see "Two source-error paths").
3. **Source default table is imgproxy-shaped** (incl. upstream-4xx passthrough),
   verified line-for-line against imgproxy `fetcher/errors.go` /
   `imagedata/errors.go`. imgproxy is the primary compat target, so the default
   matches it — native and imgproxy agree, **no host config required** today.
4. **Wire one non-`Resize` producer now: IIIF out-of-bounds-region → 400.** This
   proves the vocabulary generalizes past the lone `Resize` producer and fixes a
   live doc-vs-code mismatch (the IIIF matrix already promises 400; `crop.ex`
   returns 422). See "New producer".
5. **Host override (Option A) is deferred**, but the design threads `opts`
   through the call chain and lands the `resolve_status/2` seam **now**, so
   adding it later touches only that function plus a behaviour module and option
   validation — no further `Sender` call-chain edits.

### Rejected / out-of-scope

- **Parser-attached error policy on the `Plan`** — clean for parser-originated
  quirks (IIIF) but source-transport failures originate in `ImagePipe.Source.*`,
  not the parser; fails the unify-#160 requirement.
- **Shipping the host `error_status` behaviour now** — no concrete consumer:
  native and imgproxy both want the imgproxy-shaped table, and IIIF expresses its
  400s by *producing* `:bad_request`. Per the CLAUDE.md validation guideline,
  deferred.
- **The 60s `{:session, :timeout}` backstop stays 500, out of scope.** The #160
  trickling-origin case does **not** reach this reason (see "Session boundary");
  this backstop is a genuinely wedged session (e.g. a stuck encode), classified
  as an internal error. Its `normalize_session_prepare_error/1` handling is
  left untouched.
- **IIIF unsupported-format-token → 400** remains deferred (a parse-time path,
  separable from the runtime classifier). Only the runtime OOB-region producer
  is wired here.

## Two axes: status (class-keyed) and message (reason-keyed)

Status and message are resolved **independently**:

- **Status** comes from the class — a small set keyed for the host-override seam.
- **Message** comes from the *reason* — a finer table keeping copy specific (and
  interpolating dynamic detail like an upstream status code), falling back to a
  class-default string only when no specific row matches.

The driver for keying them separately is **override granularity**, not
vocabulary size: status is the axis the deferred host behaviour overrides
(by class), while message rendering stays centralized in Response. A single
`reason → {status, message}` table would not give that seam a stable, small,
host-facing key. The class layer earns its place via (a) that host seam and
(b) `{:passthrough, code}`, whose status *is* the carried code — not via dedup.

### Class → status (the small table)

| Class | Status | Class-default message (fallback only) |
|---|---|---|
| `:bad_request` | 400 | `bad request` |
| `:unprocessable` | 422 | `unprocessable image request` |
| `:not_found` | 404 | `source not found` |
| `:bad_gateway` | 502 | `bad gateway` |
| `:gateway_timeout` | 504 | `source timeout` |
| `:payload_too_large` | 413 | `source image is too large` |
| `:unsupported_media` | 415 | `source response is not a supported image` |
| `:unsupported_output` | 501 | `requested output format is not supported by this server` |
| `:server_error` | 500 | (path-specific: `error encoding image`, `cache error`, `configuration error`) |
| `{:passthrough, code}` | `code` (clamped, see below) | `upstream error` |

**`{:passthrough, code}` valid-range guard (BLOCKER fix).** `classify/1` emits
`{:passthrough, code}` **only** when `code in 400..499` (matching imgproxy's
4xx-passthrough). `default_status_code/1` defensively floors:
`code when code in 100..599 -> code; _ -> 502`, so `Sender` can never hand
`Plug.Conn.send_resp/3` an out-of-range status even if a future producer
mis-tags. The range is stated explicitly so the guard is intentional, not
incidental.

### Reason → message (the specific table)

`message_for/1` maps the full reason to user-facing copy — distinct per reason,
may interpolate dynamic detail, the single reviewable home for response bodies.

**Sensitivity guardrail:** messages are generic-but-distinct and must **never
embed the source URL, query string, or any secret**. The reason tuples carry no
URL (the URL lives in `req_options`, never in the reason — confirmed across
`ReqStream`/`WrappedStream`/`Source`), so `"upstream responded 503"` is safe;
host-adapter reasons are treated as untrusted (below).

### Can a custom message be passed? Producers carry *detail as data*, not prose

The line is **not** HTTP coupling — a producer is already across it the moment it
emits a class like `:bad_request`. The line is **data vs. prose**:

- A class and a *detail atom* are a closed, enumerable vocabulary
  (`:bad_request`, `:region_out_of_bounds`, `{:bad_status, code}`) —
  classification reduced to data, reviewable as a bounded set.
- A message string is open-ended *copy*. Scattering prose across producers causes
  wording drift, removes the single audit point, and defeats the no-URL check.

A producer expresses specificity by carrying **structured detail**, and
`message_for/1` renders the copy from it — no prose in producers:

```elixir
# producer (transform op) emits data, not a string:
{:error, {:bad_request, :region_out_of_bounds}}

# Response owns the copy, keyed on that detail (interpolating dynamic bits):
def message_for({:transform_error, {:bad_request, :region_out_of_bounds}}),
  do: "requested region is outside the image"
def message_for({:source, {:bad_status, code}}), do: "upstream responded #{code}"
```

A custom message is "passed" by adding a `message_for/1` row keyed on the
producer's detail; the deferred host override (`status_for/2 → {status,
message}`) is the second avenue.

### Custom reason atoms — the extension contract

Producers introduce **custom reason atoms** freely; the *class* component routes
them, the detail atom is open:

- **The class set is the closed contract** (`:bad_request`, `:not_found`,
  `:bad_gateway`, `:gateway_timeout`, `:payload_too_large`, `:unsupported_media`,
  `:unsupported_output`, `:server_error`, `{:passthrough, code}`); **detail atoms
  are the open extension point.** A producer emitting `{:bad_request,
  <any_atom>}` routes to 400 for *any* detail — **no core `classify/1` edit for
  the status.** It also renders the class-default message immediately; a specific
  message is an optional `message_for/1` row.
- A dialect parser isolates its own quirk as `{:bad_request, :some_dialect_atom}`
  and it routes neutrally — the quirk stays in the adapter, the core never
  enumerates dialect reasons (CLAUDE.md namespace discipline).
- **Limit:** a custom reason needing a status *outside* the class set (e.g. 409)
  requires deliberately adding a class — a real, rare API decision, not a
  per-reason edit.

To make this **uniform across producers**, `classify/1` resolves in this order:

1. **Class-leading reason** — if the reason (or the inner reason under
   `{:transform_error, _}` / `{:source, _}` / `{:render, _}`) leads with a known
   class atom — `{<class>, _detail}` — route by that class. This subsumes today's
   `{:bad_request, _}` handling and lets a transform op, a parser, **or a host
   source adapter** assert a status by emitting `{<known_class>, <custom_atom>}`.
   The class atom names are kept **deliberately distinct** from the core domain
   reason tags (`:bad_status`, `:connect_error`, `:decode`, `:input_limit`,
   `:unsupported_output_format`, …) so a domain reason can never be mistaken for a
   class lead — verified no collision today; a producer test pins it.
2. **Enumerated domain table** — the bare core reasons (`:connect_error`,
   `:receive_timeout`, `{:bad_status, code}`, decode/input-limit/encode tags, …)
   map as tabulated below.
3. **Neutral fallback** — any unrecognized reason → `:unprocessable` (422) for a
   `{:source, _}`, else `:server_error` (500). The total-function guarantee.

So "passing a custom reason" is: emit `{<class>, <your_atom>}`. Status is correct
for free; message is correct-but-generic for free; bespoke copy is one optional
row.

**Host source-adapter reasons are untrusted input, not a prose channel.** A host
`ImagePipe.Source` adapter may return an arbitrary error reason; its string is
**not echoed verbatim** (could embed a URL/credential). Such reasons map through
`message_for/1`'s catch-all to a neutral message like any other.

## Architecture

### Module home and boundaries

- **`ImagePipe.Response.ErrorStatus`** (new, in the `Response` boundary) owns
  `classify/1` (reason → class), `default_status_code/1` (class → status),
  `message_for/1` (reason → message), and the `resolve_status/2` seam that
  combines them into `{status, message}`. Everything here is HTTP-coupled
  (status integers, response copy); it is **not** a neutral vocabulary and does
  not belong in `ImagePipe.Error`. This same module is where the deferred host
  `@callback status_for/2` will live.
- **Do not export `ErrorStatus`** from the `Response` boundary. Only `Sender`
  (same boundary) and the unit test call it; keep the boundary narrow. The unit
  test must not force an export.
- Producers (transform ops, `ImagePipe.Source.*`) emit plain tagged tuples — **no
  boundary edges change.** Verified: `transform/chain.ex:77` wraps an op's
  `{:error, {:bad_request, _}}` into `{:transform_error, …}`; the `Transform`
  boundary (`deps: [Plan, Telemetry]`) has no edge to `Response`. Source emits
  `{:source, reason}` likewise.

### Total classification (unrecognized-reason fallback)

`classify/1` must be **total** — this is step 3 of the resolution order in
"Custom reason atoms" above. Host source adapters are an untrusted boundary
(CLAUDE.md: "Return values from host-implementable behaviours") and may return
arbitrary `{:source, reason}`:

- Enumerated adapter-wiring reasons (step 2) — `:invalid_adapter_result`,
  `:invalid_adapter_config`, `:missing_adapter` → `:server_error` (500).
- **Any other / unrecognized `{:source, reason}`** (step 3) → `:unprocessable`
  (422), the safe neutral default (today's behavior).
- Any other unrecognized top-level reason (step 3) → `:server_error` (500).

These catch-alls are legitimate boundary handling (untrusted host return), **not**
impossible-misuse guards — they exist because a real external caller can produce
the value. Note a host adapter that *wants* a specific status uses step 1:
returning `{:source, {:not_found, :my_detail}}` routes to 404, not the neutral
422 fallback.

### The seam (opts threaded now)

`Sender.handle_processing_error/3` takes no `opts` today, and the error clause in
`send_result/3` drops `_opts`. To make Option A genuinely local later, **thread
`opts` now**: `send_result → handle_processing_error → resolve_status`. We call
the `/2` arity today with no host policy.

```elixir
# ImagePipe.Response.ErrorStatus
def resolve_status(reason, opts \\ []) do
  class = classify(reason)
  with mod when not is_nil(mod) <- host_policy(opts),   # nil today
       {status, message} <- mod.status_for(class, reason) do
    {status, message}
  else
    _ -> {default_status_code(class), message_for(reason)}
  end
end
```

When Option A ships, the only edits are: implement `host_policy/1` (read +
validate the mount option) and add the `@callback status_for/2`. The `class`
type then becomes a **public, stable** host-facing type (incl. `{:passthrough,
code}`) — a deliberate API commitment noted now. The host gets `{status,
message}` control of both axes (it cannot partially override status-only while
keeping our interpolated message — acceptable for the deferred design).

### What stays special (NOT folded into the pure mapping)

The encode/render *exception* paths log a stacktrace and
`mark_send_processing_error/1` (conn private). They keep their current structure;
the classifier unifies only the **pure** status mappings. The `{:render, inner}`
unwrapping stays a **pre-classify dispatch arm** that recursively re-enters
`handle_processing_error` (so `{:render, {:source, :receive_timeout}}` resolves
via the inner `{:source, _}` → 504); it must not be collapsed into
`classify({:render, …})`.

## Two source-error paths (BLOCKER fix)

Source failures render at **two** sites; both must route through the new table:

1. **Streaming/prepare path** — reaches `handle_processing_error(conn, {:source,
   error}, …)` → delegates to `send_source_error/3`.
2. **Resolve-time path** — `plug.ex:121` calls `Sender.send_source_error(conn,
   error)` **directly**, bypassing `handle_processing_error`; today a standalone
   `send_resp(422, "invalid image source")`.

Fix: rewrite **`send_source_error/3` itself** to `resolve_status({:source,
error}, opts)` and render from that. Both call sites then get the imgproxy-shaped
table. Otherwise #160 is only half-fixed (streaming path gets new codes, resolve
path stays 422).

## Mapping tables

### Transform / plan side (#267)

| Reason | Class | Status | Message | Change |
|---|---|---|---|---|
| `{:transform_error, {:bad_request, :upscale_required}}` | `:bad_request` | 400 | `upscaling requires the ^ prefix` | migrated into vocabulary |
| `{:transform_error, {:bad_request, :region_out_of_bounds}}` | `:bad_request` | 400 | `requested region is outside the image` | **new producer** (see below) |
| `{:transform_error, {:bad_request, _}}` (other detail) | `:bad_request` | 400 | `bad request` | generalized |
| `{:transform_error, _other}` | `:unprocessable` | 422 | `invalid image transform` | unchanged |
| `@plan_validation_error_tags`, `:empty_pipeline_plan` | `:unprocessable` | 422 | `invalid image transform` | unchanged |
| `{:unsupported_output_format, _}` | `:unsupported_output` | 501 | `requested output format is not supported by this server` | unchanged |
| `{:decode, _}`, `{:unsupported_source_format, _}`, `:source_format_required` | `:unsupported_media` | 415 | `source response is not a supported image` | unchanged |
| `{:input_limit, _}` | `:payload_too_large` | 413 | `source image is too large` | unchanged |
| `{:encode, _}` / `{:cache_write, _}` / `{:config, _}` | `:server_error` | 500 | path-specific | unchanged (keeps stacktrace logging) |

Today's two bodies (`invalid image transform`, `invalid image source`) are
**preserved as distinct** reason-keyed messages.

### Source side (#160) — imgproxy-shaped default

Source reasons reach `Sender` as `{:source, reason}` (both paths above). Current
reasons (`ReqStream` / `WrappedStream` / `Source`) are already distinct and carry
the upstream code, so plumbing is light.

| Source reason | Class | Status | Message | imgproxy parity |
|---|---|---|---|---|
| `:connect_error` (unreachable / unknown scheme) | `:not_found` | 404 | `source unreachable` | ✅ `errors.go:37,57` |
| `:too_many_redirects`, `:redirect_not_followed`, `:invalid_redirect` | `:not_found` | 404 | reason-specific | ✅ `errors.go:109` |
| `{:bad_status, code}`, `code in 400..499` | `{:passthrough, code}` | echo `code` | `upstream responded #{code}` | ✅ `errors.go:88-91` |
| `{:bad_status, code}`, `code in 500..599` | `:bad_gateway` | 502 | `upstream responded #{code}` | ✅ `errors.go:93` |
| `{:bad_status, code}`, otherwise (incl. `< 400`) | `:not_found` | 404 | `upstream responded #{code}` | ✅ imgproxy default `statusCode = 404` (`errors.go:89`) |
| `:receive_timeout` | `:gateway_timeout` | 504 | `source timeout` | ✅ `errors.go:131` |
| `:body_too_large` | `:unprocessable` | 422 | `source image is too large` | ✅ `imagedata/errors.go:17` (oversized) |
| `:invalid_body`, `:invalid_stream_chunk`, `:stream_exception` | `:unprocessable` | 422 | `incomplete source response` | ✅ `errors.go:171` (incomplete) |
| `:invalid_adapter_result`, `:invalid_adapter_config`, `:missing_adapter` | `:server_error` | 500 | `configuration error` | host-adapter misconfig (not a fetch class) |
| any other `{:source, reason}` | `:unprocessable` | 422 | class-default | neutral fallback (untrusted host return) |

The "otherwise `{:bad_status}`" row is 404 (imgproxy's literal default for
`< 400`), corrected from an earlier 502; this cell is effectively unreachable
(only non-2xx/3xx reach `:bad_status`) but matches imgproxy and stays within the
passthrough guard's range.

## New producer: IIIF out-of-bounds-region → 400

The IIIF matrix (`docs/iiif_3_support_matrix.md:29,122`) already documents a
wholly-out-of-bounds region as **400** via `{:transform_error, {:bad_request,
_}}`, but no code emits it — `crop.ex` clamps/clips and a wholly-outside region
surfaces as `{:transform_error, {Crop, _}}` → **422**. IIIF 3.0 (`spec.md:192`)
says such a request *should* be 400.

Wire it: the coordinate-region crop path (`Transform.Operation.Crop`'s
`crop_from`-coordinate branch, `crop.ex:270-288`, reached from
`Plan.Operation.CropRegion` via `plan_executor`) detects a region **wholly
outside the image** (zero overlap / zero-area after clip) and returns
`{:error, {:bad_request, :region_out_of_bounds}}` **before** clamping. Partial
overlap still clips → 200; zero `w`/`h` is already a parse-time 400.

**Cross-target flag (compat reviewer, final diff review):** the region-crop op is
**shared** — IIIF *and* TwicPics both build `CropRegion` → `Crop`. A
wholly-outside region is genuinely unsatisfiable (zero pixels), so 400 is a
defensible *neutral* rule for both. The final review's compatibility lens **must**
confirm this does not regress TwicPics (check `twicpics` docs + the differential
suite for any wholly-outside-region fixture/expectation); if TwicPics needs
clamp-to-edge instead, the OOB→400 decision becomes parser-gated rather than
unconditional in the shared op. This is the one place "wire it now" touches a
second compat target.

## Session boundary (revised — the trickle case is already source-tagged)

The #160 "trickling-origin → wrong status" headline is fixed by the **source
table alone**, not by re-tagging session errors:

- A trickling origin trips the **per-message** `receive_timeout` (~5s) in
  `ReqStream.next_message/2` → `raise StreamError, reason: :receive_timeout`;
  `source_session.ex` `producer_down_reason` maps it to **`{:source,
  :receive_timeout}`**, which flows through `normalize_session_prepare_error/1`
  unchanged and now resolves via the source row → **504**. No session re-tag
  needed.
- `{:session, :timeout}` is the **60s `GenServer.call` backstop** — a genuinely
  wedged session (e.g. a stuck/non-streamable encode), not source liveness.
  imgproxy's *whole-request* timeout is 503, but this is an internal stall:
  **leave it at its current 500** (`{:encode, RuntimeError}` path, with its
  stacktrace logging). `normalize_session_prepare_error/1` is **untouched** by
  this change.

So the source-read deadline (504) and the wedged-session backstop (500) stay
distinct, and the runner change for #160 is *nil* — the fix is the source row +
routing both source-error sites through it.

## Out of scope (enabled, not delivered here)

- **IIIF unsupported-format-token → 400** — a parse-time path
  (`handle_error/2`), separable from the runtime classifier.
- **IIIF `^`-upscale-unsupported → 501.** ImagePipe supports `^` upscaling today,
  so this is unreachable now; but a future IIIF deployment that *disables* `^`
  upscale must return **501** (`:unsupported_output`'s slot), **not** the
  `:bad_request` → 400 the upscale path otherwise uses (IIIF `spec.md:222`). Noted
  so the future wiring doesn't reflexively emit 400.
- **The host `error_status` behaviour** (Option A) — the deferred extension point
  on `ImagePipe.Response.ErrorStatus`.

## Testing strategy

Wire-level (real `ImagePipe.call/2`) tests asserting the user-visible status and
body for each changed family, per CLAUDE.md test guidelines:

- **Transform:** `{:bad_request, :upscale_required}` → 400 still holds after
  migration; a generic transform error → 422; **the new IIIF OOB-region request
  → 400** with the distinct body (a real IIIF wire request whose region is
  wholly outside the source).
- **Source (#160):** one representative request per source row — unreachable →
  404, upstream 5xx → 502, **upstream 4xx → that 4xx (passthrough)**, receive
  timeout → 504, oversized **byte** body → 422. Assert status + `text/plain`
  body, and the failure returns **before cache write** (no successful entry
  cached — `refute_received` the origin-fetch/commit idiom).
- **Both source sites:** cover the **resolve-time** path (`plug.ex`
  `send_source_error`) *and* the streaming path, so the rewrite of
  `send_source_error/3` is exercised on both.
- **Render-wrapped source:** `{:render, {:source, :receive_timeout}}` → 504,
  pinning the pre-classify unwrap still routes correctly.
- **Byte-vs-pixel limits:** an oversized **byte** body → 422 (`:body_too_large`)
  and an oversized **pixel** image → 413 (`:input_limit`) in separate tests, so
  they aren't conflated.
- **Session backstop unchanged:** (optional) a wedged-session `{:session,
  :timeout}` still → 500, documenting it's deliberately untouched.
- **`message_for/1` contract test** (re-scoped — *not* a status mapping pin):
  assert the message table produces **distinct, non-URL-bearing** copy per
  reason (incl. `{:bad_status, code}` interpolating the code). Status is left to
  the wire tests. Delete if it ever degrades into a parity pin.
- **No** impossible-misuse / name-policing / post-migration parity tests.

Telemetry assertions use a unique `telemetry_prefix` (global-handler discipline).

## Telemetry / observability

- **No event renames** → no Logger/OTel-Capture subscription edits.
- **Emitted `status` values change** on the source path (422 → 404/502/504/
  passthrough) — that *is* the feature; `conn.status` is the observable.
- **Emitted error *tags* are unchanged:** `plug.ex` `processing_error_tag({:source,
  error}) → Error.tag(error)` already emits the inner reason atom
  (`:receive_timeout`, `:connect_error`, …), which the status remap does not
  alter. Since the session backstop is left at 500, its previously-`{:encode,…}`
  tag is also unchanged.
- `Sender.stream_error_tag/1` / `stream_error_phase/1` derive from the reason and
  are unaffected. If a telemetry test asserts the new `status`, use a unique
  prefix.

## Docs to update (same change)

- **`docs/imgproxy_support_matrix.md`** — **behavioral** axis: add/adjust the
  source-fetch-failure status rows (404/502/504/passthrough/422), parity-confirmed
  against `fetcher/errors.go` / `imagedata/errors.go`. Do **not** claim error-
  *body* parity (imgproxy uses one uniform "Source is unreachable" string; we use
  distinct copy — a deliberate, product-neutral divergence). Do **not** assert
  imgproxy parity on the pre-existing `:unsupported_output` → 501 / source-format
  → 415 rows (imgproxy is 422 there; those are unchanged, out-of-scope
  divergences).
- **`docs/iiif_3_support_matrix.md`** — **behavioral** axis: the OOB-region row
  becomes truthful (now actually 400, was 422). The upscale 400's *implementation*
  generalizes (unchanged behavior). Reword the "Status mapping" note to describe
  the general mechanism rather than the bespoke `Sender` clause.
- **`docs/twicpics_*`** (if a wholly-outside-region behavior is documented) —
  reflect the shared-op OOB→400 outcome, per the cross-target flag.

## Execution recommendation

Per CLAUDE.md's calibrated default: this is a **sequential dependency chain in a
few shared files within one boundary** (new `ErrorStatus` → `Sender` collapse +
opts threading + `send_source_error` rewrite → shared `Crop` OOB producer →
matrices → tests). **Inline execution, test-first (TDD), with one final parallel
review of the complete diff.** The final review **must** include a compatibility
(imgproxy + IIIF + TwicPics) lens — this is an observable-compat change touching
two targets. The session-backstop and trickle-timeout tests (process timing) and
the matrix parity updates (judgment vs. the local imgproxy checkout) are
inline-only regardless.

## Risks

- **Observable status change** (422 → 404/502/504/passthrough on source;
  422 → 400 on IIIF OOB). Greenfield, no back-compat concern; wire tests pin the
  new contract.
- **Passthrough leaks upstream 4xx** by default — matches the primary compat
  target (imgproxy); suppressing it is exactly the future consumer the deferred
  Option A serves.
- **Shared `Crop` OOB→400 could regress TwicPics** — gated by the final compat
  review; fall back to parser-gated OOB if TwicPics needs clamp-to-edge.
