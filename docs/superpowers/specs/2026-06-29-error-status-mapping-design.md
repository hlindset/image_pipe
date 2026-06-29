# Customizable internal-error → HTTP-status mapping

**Issue:** [#267](https://github.com/hlindset/image_pipe/issues/267) (transform side) unified with [#160](https://github.com/hlindset/image_pipe/issues/160) (source side)
**Date:** 2026-06-29
**Status:** design approved, pending spec review

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
  `{:source, reason}` tag but flattened at the mapping. Separately, a
  trickling-origin timeout is rewrapped as `{:encode, _}` → **500**, losing its
  source-liveness identity (it should be 504).

These are the same problem on two paths: a rich internal reason collapsed to a
coarse status. We solve them with **one mechanism**.

## Decision summary

1. **Mechanism — a neutral, status-bearing *client-error class* carried in
   failure reasons.** This is the principled generalization of the existing
   `{:bad_request, _}` → 400 slice. A producing layer (transform op, parser,
   source) expresses *intent* by the reason it emits; `Sender` resolves every
   reason through **one** classifier → default-status table.
2. **Unify #267 and #160** in this change: both paths route through the same
   classifier. Source reasons get a per-class default table; the
   session boundary preserves source identity instead of rewrapping to
   `{:encode, _}`.
3. **Source default table is imgproxy-shaped** (incl. upstream-4xx passthrough).
   imgproxy is the primary compat target, so the *neutral* default matches it —
   native and imgproxy agree, and **no host config is required** today.
4. **Host override (Option A) is deferred**, but the design lands the single
   seam (`resolve_status/2`) it slots into, so adding it later touches only that
   function plus a new behaviour module and option validation — **zero changes
   to producers, the class vocabulary, or the default table.**

### Rejected alternatives

- **Parser-attached error policy on the `Plan`.** Clean for parser-originated
  quirks (IIIF), but source-transport failures originate in
  `ImagePipe.Source.*`, not the parser — a plan-attached policy would declare
  statuses for failures it doesn't produce. Fails the unify-#160 requirement.
- **Shipping the host `error_status` behaviour now.** No concrete consumer:
  native and imgproxy both want the imgproxy-shaped table, and IIIF expresses
  its 400s by *producing* the `:bad_request` class. Per the CLAUDE.md validation
  guideline ("add the validation when the future caller appears"), deferred.

## Two axes: status (class-keyed) and message (reason-keyed)

Status and message are resolved **independently**, so a small status vocabulary
coexists with distinct, specific response copy:

- **Status** comes from the class — a small, product-neutral set of classes.
- **Message** comes from the *reason* — a finer-grained table that keeps copy
  specific (and may interpolate dynamic detail like an upstream status code),
  falling back to a class-default string only when no specific row matches.

This avoids collapsing every 422 (or every 404) to one generic body.

### Class → status (the small table)

A small, product-neutral set of client-facing classes. Most are plain atoms;
`{:passthrough, code}` carries a dynamic upstream status.

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
| `:server_error` | 500 | (path-specific: `error encoding image`, `cache error`, `configuration error`, …) |
| `{:passthrough, code}` | `code` | `upstream error` |

The class-default message is used only when `message_for/1` has no specific row.
Most reasons *do* have a specific row (see the per-axis message columns below).

### Reason → message (the specific table)

`message_for/1` maps the full reason to user-facing copy. Distinct per reason,
may interpolate dynamic detail, and is the single reviewable home for response
body strings.

**Sensitivity guardrail:** messages are generic-but-distinct and must **never
embed the source URL, query string, or any secret** — the telemetry sensitivity
rule applies to response bodies too. `"upstream responded 503"` is fine; echoing
the source URL is not.

### Can a custom message be passed?

Yes, at three levels (prefer the first two):

1. **Centralized `message_for/1` row** (default) — add/edit a reason→message
   mapping; keeps copy in one Response-layer place. Dynamic interpolation (e.g.
   the upstream code) lives here.
2. **Host override** (deferred Option A) — `status_for/2` returns
   `{status, message}`, so a host customizes status *and* copy.
3. **Producer-carried message** (e.g. `{:bad_request, {detail, msg}}`) —
   technically supportable but **discouraged**: it pushes HTTP-response copy into
   transform/source producers and muddies the boundary. Keep copy in Response.

The class atoms are just atoms in tagged tuples — **producers depend on no new
module**; only `Sender`/`ErrorStatus` knows the class→status and reason→message
tables. This mirrors how `{:bad_request, _}` already works.

## Architecture

### Module home and boundaries

- **`ImagePipe.Response.ErrorStatus`** (new, in the `Response` boundary) owns
  `classify/1` (reason → class), `default_status_code/1` (class → status),
  `message_for/1` (reason → message), and the `resolve_status/2` seam that
  combines them into `{status, message}`. This same module is where the deferred
  host `@callback status_for/2` behaviour will later live.
- Producers (transform ops, `ImagePipe.Source.*`, the session boundary) emit
  plain tagged tuples — **no boundary edges change.** Transform stays
  dependency-free of Response; Response already depends on the neutral
  `ImagePipe.Error`.

### The seam

```elixir
# ImagePipe.Response.ErrorStatus
def resolve_status(reason) do
  status = reason |> classify() |> default_status_code()   # class-keyed (coarse)
  message = message_for(reason)                            # reason-keyed (specific)
  {status, message}
end

# (deferred Option A — the only edit needed to add host override:)
def resolve_status(reason, opts) do
  class = classify(reason)
  with mod when not is_nil(mod) <- host_policy(opts),
       {status, message} <- mod.status_for(class, reason) do
    {status, message}                                       # host customizes both axes
  else
    _ -> {default_status_code(class), message_for(reason)}
  end
end
```

`Sender.handle_processing_error/3` collapses its pure status-mapping clauses
into: `classify → resolve_status → send (headers + content-type + status +
message)`. The reason→class mapping preserves every current status (see tables
below); only the transform-default and source families change behavior.

### What stays special (NOT folded into the pure mapping)

The encode/render *exception* paths do more than pick a status — they log a
stacktrace and `mark_send_processing_error/1` (conn private). They keep their
current structure; the classifier unifies only the **pure** status mappings
(transform, source, decode, input-limit, plan-validation, unsupported-output).
The `{:render, inner}` unwrapping (recursively re-dispatching `:decode`,
`:source`, `:input_limit`, … inner reasons) is preserved.

## Mapping tables

### Transform / plan side (#267)

| Reason | Class | Status | Message (`message_for/1`) | Change |
|---|---|---|---|---|
| `{:transform_error, {:bad_request, _}}` | `:bad_request` | 400 | `bad request` (or a per-detail row, e.g. upscale) | migrated into vocabulary (was a one-off clause) |
| `{:transform_error, _other}` | `:unprocessable` | 422 | `invalid image transform` | unchanged |
| `@plan_validation_error_tags` (`:unprojectable_operation_for_cache_adapter`, `:detector_unavailable`, …) | `:unprocessable` | 422 | `invalid image transform` | unchanged |
| `:empty_pipeline_plan` | `:unprocessable` | 422 | `invalid image transform` | unchanged |
| `{:unsupported_output_format, _}` | `:unsupported_output` | 501 | `requested output format is not supported by this server` | unchanged |
| `{:decode, _}`, `{:unsupported_source_format, _}`, `:source_format_required` | `:unsupported_media` | 415 | `source response is not a supported image` | unchanged |
| `{:input_limit, _}` | `:payload_too_large` | 413 | `source image is too large` | unchanged |
| `{:encode, _}` / `{:cache_write, _}` / `{:config, _}` | `:server_error` | 500 | `error encoding image` / `cache error` / `configuration error` | unchanged (keeps stacktrace logging) |

Today's two transform/source bodies (`invalid image transform`,
`invalid image source`) are **preserved as distinct** reason-keyed messages —
the reason-keyed table is exactly what prevents them collapsing to one string.

### Source side (#160) — imgproxy-shaped default

Source reasons reach `Sender` as `{:source, reason}` (and, for the streaming
prepare path, as session reasons — see next table). Current reasons produced by
`ImagePipe.Source.ReqStream` / `WrappedStream` are already distinct and carry
the upstream code, so plumbing is light.

| Source reason | Class | Status | Message (`message_for/1`) | imgproxy parity |
|---|---|---|---|---|
| `:connect_error` (unreachable / unknown scheme) | `:not_found` | 404 | `source unreachable` | ✅ 404 |
| `:too_many_redirects`, `:redirect_not_followed`, `:invalid_redirect` | `:not_found` | 404 | `too many redirects` / `redirect not followed` / `invalid redirect` | ✅ 404 |
| `{:bad_status, code}`, `code in 400..499` | `{:passthrough, code}` | echo `code` | `upstream responded #{code}` | ✅ passthrough |
| `{:bad_status, code}`, `code in 500..599` | `:bad_gateway` | 502 | `upstream responded #{code}` | ✅ 502 |
| `{:bad_status, code}`, other | `:bad_gateway` | 502 | `upstream responded #{code}` | fallback |
| `:receive_timeout` | `:gateway_timeout` | 504 | `source timeout` | ✅ 504 |
| `:body_too_large` | `:unprocessable` | 422 | `source image is too large` | ✅ 422 (oversized) |
| `:invalid_body`, `:invalid_stream_chunk`, `:stream_exception` | `:unprocessable` | 422 | `incomplete source response` | ✅ 422 (incomplete) |
| `:invalid_adapter_result`, `:invalid_adapter_config` | `:server_error` | 500 | `configuration error` | host-adapter misconfig, not a fetch class |

Messages stay generic-but-distinct and never embed the source URL —
`upstream responded #{code}` carries the upstream status, not its location.

Judgment calls (confirmed in brainstorming): **4xx passthrough = yes** (echo the
upstream code); **`:body_too_large` stays 422** to match imgproxy's
oversized-body row (not 413); redirect-failure variants normalize to **404**
(imgproxy treats redirect exhaustion as unreachable).

### Session boundary (#160 — trickling-origin fix)

`ImagePipe.Request.Runner.normalize_session_prepare_error/1` currently maps
`{:session, reason}` → `{:encode, RuntimeError…}` → 500, erasing source
identity. It must instead preserve the source-failure class:

| Session reason | Re-tag → class | Status | Rationale |
|---|---|---|---|
| `{:session, :timeout}` | `{:source, :receive_timeout}` → `:gateway_timeout` | 504 | **the headline #160 fix** — trickling/slow-but-alive origin is a source-liveness failure, not an encode error |
| `{:session, {:shutdown, {:owner_down, _}}}`, `{:session, :cancelled}` | retain current client-abort handling | — | client/owner gone; no meaningful error page (not a fetch-class failure) |
| `{:session, {:shutdown, _}}`, `{:session, :noproc}`, `{:session, {:exit, _}}` | `:server_error` | 500 | genuine internal failures; unchanged classification |

The exact non-timeout session-reason routing is refined in the implementation
plan; `:timeout → 504` is the required behavior change. Cleanup (session
stopped, producer killed) is already correct on every path and is unchanged.

## Source-reason enrichment

Most reasons are already distinct and carry the code, so enrichment is small:

- **`{:bad_status, code}` already carries the upstream status** —
  `{:passthrough, code}` is feasible with no new threading.
- Confirm `:connect_error` vs `:receive_timeout` vs the redirect variants stay
  distinct end-to-end through the `{:source, _}` wrap and (where relevant) the
  session boundary, so each lands in its row above rather than collapsing.
- No new source reason atoms are introduced beyond what `ReqStream` /
  `WrappedStream` already emit; this is a **classification** change, not a
  source-protocol change.

## Out of scope (enabled, but not delivered here)

The mechanism *enables* these but they are separate IIIF-parser work, tracked by
IIIF's own issues — listing them so the boundary is explicit:

- IIIF **out-of-bounds region → 400** ([matrix:29](../../iiif_3_support_matrix.md))
  and **unsupported-format-token → 400** ([matrix:76](../../iiif_3_support_matrix.md))
  — once this lands, the `CropRegion` op / IIIF format path can emit the
  `:bad_request` class to realize them. Not wired in #267.
- The **host `error_status` behaviour** (Option A). Documented as the deferred
  extension point on `ImagePipe.Response.ErrorStatus`.

## Testing strategy

Wire-level (real `ImagePipe.call/2`) tests asserting the user-visible status for
each changed family, per the CLAUDE.md test guidelines:

- **Transform:** the existing `{:bad_request, _}` → 400 (Resize `enlargement:
  :reject`) still 400 after migration; a generic transform error still 422.
- **Source (#160):** one representative request per source row — unreachable →
  404, upstream 5xx → 502, upstream 4xx → that 4xx (passthrough), receive
  timeout → 504, oversized body → 422. Use a controllable test origin /
  source adapter; assert status + `text/plain` body, and that the failure
  returns *before* cache write (no successful entry cached).
- **Session timeout:** a trickling origin that outlives `receive_timeout` per
  message but trips the session call timeout → **504**, not 500; assert session
  stopped / producer killed (monitor + `:DOWN`), no `Process.sleep`.
- **Classifier unit:** `ErrorStatus.resolve_status/1` — every reason → expected
  `{status, message}`, asserting both axes: the class-keyed status *and* the
  reason-keyed message (including `{:bad_status, code}` echoing the code into
  both the passthrough status and the `upstream responded #{code}` message, and
  that the two transform/source 422 bodies remain distinct). Keep it a focused
  example test; no impossible-misuse struct building.
- **Wire message assertions:** the representative wire tests above assert the
  response *body* too, pinning that distinct reasons keep distinct copy and that
  no message embeds a source URL.
- **No** post-migration parity/characterization pins (deleted once green per
  CLAUDE.md).

Telemetry assertions, if any, use a unique `telemetry_prefix` (global-handler
discipline).

## Telemetry / observability

`Sender`'s existing per-failure `Logger` lines are preserved (relabeled to the
class where it reads cleaner). The delivery telemetry already records `status`
and an `Error.tag`-derived error tag (`stream_error_tag/1`); the richer source
statuses flow through unchanged — no event renames, so no Logger/OTel-Capture
sync is required. The deferred Logger/OTel sync rule only triggers if we add or
rename an event, which this change does not.

## Docs to update (same change)

- **`docs/imgproxy_support_matrix.md`** — the source-fetch-failure status table
  is now realized (404/502/504/passthrough/422). This is a **behavioral** axis
  change: add/adjust the source-status rows and note parity. Compatibility
  reviewer (imgproxy lens) confirms against `fetcher/errors.go` in the local
  `/Users/hlindset/src/imgproxy` checkout.
- **`docs/iiif_3_support_matrix.md`** — the "Status mapping" 400 note is now
  served by the general mechanism rather than a bespoke `Sender` clause; reword
  the divergence note accordingly (the no-`^` upscale 400 is unchanged in
  behavior). Surface axis: none; behavioral: the 400 path is unchanged, only its
  implementation generalizes — keep the note accurate.

## Risks

- **Behavior change is observable** (statuses move 422 → 404/502/504/passthrough
  on the source path). Greenfield, no back-compat concern, but the wire tests
  above pin the new contract.
- **Passthrough leaks upstream 4xx** to clients by default. This matches the
  primary compat target (imgproxy); a host wanting to suppress it is exactly the
  future consumer the deferred Option A serves.
