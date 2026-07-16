# imgproxy dialect inversion — phase 2 backlog

Phase 1 (PR #458) built `ImagePipe.Dialect.Imgproxy` as a self-contained inverted
Plug alongside the frozen framework stack, with the differential suite (162
constellations × 2 arms) and the wire suite (270 cases — 120 shared × 2 arms,
plus 30 framework-only) dual-running both arms at zero divergence. It
deferred a set of items — deliberately, each recorded where it was found. This
is the single entry point that consolidates them; the authoritative detail for
each lives in the linked committed doc.

**Durable sources:** the design spec
(`docs/superpowers/specs/2026-07-15-imgproxy-dialect-inversion-design.md`), the
conformance doc (`docs/imgproxy_support_matrix.md` § Dialect-stack divergences),
and the phase-1 exit-criteria cross-check
(`.superpowers/sdd/phase1-exit-criteria.md`).

---

## A. The phase-2 deliverable proper — retire `Parser.Imgproxy`

Spec decision **D1**: phase 1 *copies* the imgproxy grammar into the dialect and
runs both arms; phase 2 *deletes the framework originals* so the dialect copies
become the sole implementation.

Scope:
- Delete `lib/image_pipe/parser/imgproxy/**` (the framework parser + its
  grammar), and `ImagePipe.Plug`'s imgproxy wiring if it has no other consumer.
- Drop the **framework arm** from every dual-run test (grammar tests under
  `test/parser/imgproxy/`, the wire suite, the differential suite). Spec D2: "the
  dual-run harness drops the framework arm for free" — the dialect arm stays and
  becomes the sole assertion.
- Remove the now-obsolete ExDNA copy-ignores for the phase-1 copies from
  `.credo.exs` **and** `mise.toml` (the leaf structs, grammar modules, `Assembly`,
  `Config` source-schemes, `Identity` helpers). Keep only the ignores for
  duplication that genuinely survives (see item F / #457).
- Update `SourceInventory` consumers and any `@moduledoc` prose that names the
  retired modules.

Reversibility note: this is the one-way step D1 was structured to defer. Land it
only once the dialect has been running in production or is otherwise trusted.

---

## B. Deferred correctness / safety gaps (ordered by severity)

### B1. Object detection (`g:obj:*`) — detector support

**The request-safety half is closed.** `Dialect.Imgproxy.Config` now has
`detector_required` (boolean, default `false` — the framework's exact default),
and `Dialect.Imgproxy`'s `route_image` gates on it alongside `check_geometry/1`:
an object-detect request under `detector_required: true` is rejected 422 before
any source fetch or cache access, mirroring `ImagePipe.Plug`'s
`validate_detector_capability/2` and its `{:error, {:detector, :unavailable}}`
reason. The pre-fetch guarantee is dual-run in the wire suite, asserting the
access sequence (no source resolve, no cache lookup, no origin fetch), with a
`detector_required: false` no-divergence guard beside it.

**What remains: detector support itself.** The dialect carries no detector and
has no `:detector` config seam, so `g:obj:*`/`g:objw:*` always fall back to
attention cropping. On stock config that matches the framework, which degrades
the same way when no detector is configured — the gap bites only a host that
configured a real detector on the framework stack.

- Recorded: `imgproxy_support_matrix.md` (§ Dialect-stack divergences, the
  `g:obj` row).
- Fix shape: add a `:detector` config seam, thread detector model identity into
  the cache key (the framework's `Runner.with_detector_identity/2`), and run the
  detector in the dialect's pipeline. Then un-gate the framework-only
  object-detection block in the wire suite (object-guided crop pixels, the class
  filter, objw weights, detector identity in the cache key).

### B2. CORS response headers

`ImagePipe.Plug` calls `CORS.maybe_register/2` and stamps
`Access-Control-Allow-Origin` on **every** response; the dialect has zero CORS
handling and no `allow_origin` config key. A cross-origin deployment migrating
from the framework arm silently loses CORS.

- Recorded: `imgproxy_support_matrix.md` § Dialect-stack divergences → Behavioral;
  exit-criteria (third framework-only-gate instance).
- Fix shape: give the dialect a CORS config surface + response stamping. Consider
  whether `Response.CORS` can be shared by both Plugs (it's framework-only today).

### B3. Telemetry **stage-set** parity (the remaining half of exit-criterion 10)

The `:result`-on-`[:request]` half of #10 was **fixed** in phase 1. What remains:
the dialect emits **7 fewer stage spans** than the framework — `[:send]`,
`[:source, :fetch_decode]`, `[:transform, :execute]`,
`[:transform, :input_color_management]`, `[:transform, :materialize]`,
`[:output, :negotiate]`, `[:encode]` — and never emits `[:output, :clamp]`.

- Recorded: `imgproxy_support_matrix.md` § Observability;
  `phase1-exit-criteria.md` #10 (resolved header + stage-set caveat). Pinned by
  `ImagePipe.ImgproxyTelemetryStageSetTest` — **update that pin if you close any
  of it**, and keep the two subscription surfaces in sync (`Telemetry.Logger`
  lists + `Telemetry.Trace.Capture`'s `@span_stages`/`@safe_keys`).
- Fix shape: emit the missing spans from the dialect's own pipeline/delivery
  path, or route more of it through the core-owned spans.

### B4. Host-configured `max_result_*` ignored by the dialect

The dialect uses hardcoded `@default_max_result_{width,height,pixels}`
(8192/8192/40M) where the framework honors host-configured
`max_result_width`/`height`/`pixels` (`ImagePipe.Request.Options`). Default
behavior is identical; a host that *sets* these gets them on the framework arm
and silently ignored on the dialect arm.

- Recorded: `imgproxy_support_matrix.md` (limitScale / result-cap row).
- Fix shape: add the three keys to `Dialect.Imgproxy.Config` and thread them into
  `result_limits/1`. (Note the `@default_*` constants triplicate — see item F.)

### B5. `OPTIONS /_/…` returns 400, not 204 + `Allow`

The dialect has no HTTP-method layer, so an `OPTIONS` preflight 400s where the
framework returns `204` + `Allow` (and CORS headers — ties to B2).

- Recorded: `imgproxy_support_matrix.md` § Dialect-stack divergences.
- Fix shape: an early method branch in `Dialect.Imgproxy.call/2` (mirror
  `ImagePipe.Plug`'s `do_call` OPTIONS/method-not-allowed heads).

---

## C. Deferred design-simplification / test-coverage candidates

### C1. Collapse the unobservable two-fallback padding/canvas distinction

Phase 1 established (and both reviewers confirmed) that the "padding falls back to
request dpr / canvas falls back to 1.0" distinction is **unobservable**:
`resize_rule_requested?` includes `not is_nil(dpr)`, so the fallback clause only
fires when dpr is nil, where both fall back to 1.0. True of the framework arm too.
It was kept for parity fidelity in phase 1.

- Recorded: `phase1-exit-criteria.md` (simplification candidate); the design spec's
  D5 discussion.
- Fix shape: once `Parser.Imgproxy` is retired (A), simplify the carry so the two
  fallbacks are a single 1.0, and correct the spec/docs that describe a
  distinction that does not exist.

### C2. `{:session, :timeout}` prepare-timeout has no RED-able test through `stream/5`

`{:session, :timeout}` is the only prepare error that leaves the coordinator
alive; `Delivery.stream/5` hard-codes a 60s timeout, so the reclamation fix from
D3 is pinned at the `Coordinator` level plus a contract test, not through
`stream/5`. Closing it properly means deciding whether the prepare timeout should
be a real host option (phase 1 deliberately declined to invent one).

- Recorded: `phase1-exit-criteria.md`.

---

## F. Rides with the TwicPics inversion (not phase 2 proper) — #457

Promoting the two product-neutral chain helpers (`resolve_output/3`;
`cache_headers`/`vary_headers`, which needs a `Response → Representation` edge)
into core, and settling the ExDNA-visibility strategy for the chain module, is
deferred to the **TwicPics inversion** — where the boundary-graph ADR has three
real dialects. The goal is unreachable at N=2 (the ExDNA ignore is file-level and
the structural mirrors — `negotiate`'s policy branch, `generate`'s
`Delivery.stream` case — cannot be shared between two top-level dialect
boundaries). `result_limits` is **not** a clean imgproxy↔native mirror (only its
`@default_*` constants triplicate — see B4).

- Tracked: GitHub issue #457; breadcrumbed in `.credo.exs`'s ExDNA-ignore comment
  for `dialect/imgproxy.ex`.

---

## Not a gap — recorded so it isn't re-investigated

- **Expired request → 400** (not upstream imgproxy's 404): a *deliberate,
  documented* divergence, pinned by the wire suite. `imgproxy_support_matrix.md`.
- **The three native bugs and D5 found during phase 1 are fixed** (orphaned trace
  spans, `cost_us: 0`, decode-preflight axis synthesis, colour-carry). Do not
  re-open.
