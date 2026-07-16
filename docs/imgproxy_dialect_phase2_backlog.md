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
**That precondition is met** (phase-2 wave 1, spec P1/P2): every §B gap is
closed, all 156 wire cases and 162 differential constellations dual-run with
zero framework-only gates, and telemetry stage-set parity holds — the dual-run
suites at full coverage are the trust evidence. §A is unblocked and gets its
own implementation plan (wave 2).

---

## B. Correctness / safety gaps — ALL CLOSED (phase-2 wave 1)

Spec: `docs/superpowers/specs/2026-07-16-imgproxy-dialect-phase2-design.md`;
plan: `docs/superpowers/plans/2026-07-16-imgproxy-dialect-phase2-wave1.md`.

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

**Closed — detector support shipped.** The dialect gained the `:detector`
config key (framework schema, `:default` → the bundled composite; ec17fd9b),
seeds it onto the transform state so `{:detect, _}` guides reach
`Crop.execute/2`, and its strict-mode gate is class-aware, mirroring
`ImagePipe.Plug.validate_detector_capability/2` exactly (face-assist stays
excluded from the gate, as on the framework). Two follow-on gaps found and
closed during execution: the neutral `smart_crop_face_detection` flag was never
stamped onto the dialect's `PipelineRequest`, making `{:smart, :face_assist}`
unreachable (2e4ca165, dual-run pixel-verified); and detector *model identity*
now feeds the dialect's cache key AND ETag via `Identity.material/5`'s
representation material, class-aware, mirroring
`Runner.with_detector_identity/2` (408b3eb6 — the identity wire tests were
restructured onto versioned detector modules because the dialect's closed
config surface rightly rejects the framework's DI extension keys). The whole
formerly-framework-only object-detection block (crop pixels, class filter,
objw weights, model identity in key/ETag) is dual-run.

### B2. CORS response headers

**Closed.** `allow_origin` lives in `Dialect.SharedConfig` (framework-verbatim
validation) and both dialects register the exported `Response.CORS.maybe_register/2`
before-send hook at the top of `call/2`, stamping every exit path — image, /info,
304, errors, and the method layer's 204/405 (521786b5; the OPTIONS/405 method
heads landed with B5, ad2cb436). Dual-run in the wire suite (image/304/4xx//info)
plus native focused tests. `Response.CORS` itself is untouched — framework-verbatim
semantics, including the recorded deliberate deltas from upstream.

### B3. Telemetry **stage-set** parity (the remaining half of exit-criterion 10)

**Closed.** The `:result`-on-`[:request]` half of #10 was fixed in phase 1; the
stage-set half is now closed too. Every stage the dialect used to omit fires from
a shared seam on both dialect stacks: `[:output, :clamp]` from the clamp seam
`Output.Clamp.clamp_with_telemetry/4` (commit 4f91b66a); `[:output, :negotiate]`
from `Output.Negotiate.negotiate_output/4` and
`[:transform, :input_color_management]` from
`Transform.InputColorManagement.condition/2` (08322034);
`[:transform, :materialize]` from the shared `Transform.Materializer` delivery
backstop (0de936ed); and `[:send]`, `[:source, :fetch_decode]`,
`[:transform, :execute]`, `[:encode]` from the dialect's own delivery/pipeline
path (f41d0081, which also forces the first encoded chunk so `[:encode]` times the
real encode). This close-out added the currently-dropped clamp/ICM metadata keys
(`source_dimensions`/`dimensions`/`limits`, `working_space`/`imported?`) to
`Telemetry.Trace.Capture`'s `@safe_keys` allowlist so they surface as OTel span
attributes on every stack.

- Recorded: `imgproxy_support_matrix.md` § Observability (all rows resolved,
  stage-set parity reached); `docs/telemetry.md` (each stage documented as firing
  on every stack, plus the OTel span-attribute note). Pinned by
  `ImagePipe.ImgproxyTelemetryStageSetTest`, whose stage-set pin now asserts
  `@framework_only == []`; the two subscription surfaces (`Telemetry.Logger` lists
  + `Telemetry.Trace.Capture`'s `@span_stages`/`@oneshot_stages`) already list all
  events.

### B4. Host-configured `max_result_*` ignored by the dialect

**Closed.** The three keys live in `Dialect.SharedConfig` (framework defaults),
both dialects' `result_limits/2` read them, and `Dialect.Native` gained the
encoder-min composition it lacked (ac8a0d05 + 3c3fd34f with native
request-boundary coverage, mutation-verified). The dialect copies of the
`@default_*` constants are gone; `Request.Options` keeps the framework's own.
A sibling seam discovered during planning closed alongside it:
**B6, `output_capabilities`** — the framework's encoder-capability DI seam,
which gated six wire cases on its own and co-blocked the clamp cases — is now a
`SharedConfig` key too (87bd81e9).

### B5. `OPTIONS /_/…` returns 400, not 204 + `Allow`

**Closed.** Both dialects' `route/2` gained the framework's method heads
(OPTIONS → `CORS.send_options/2` 204 + `Allow`, other non-GET/HEAD →
`Sender.send_method_not_allowed/1` 405 + `Allow`, with the framework's
`:options`/`:method_not_allowed` request-result metadata; ad2cb436). The
method-layer divergence vs upstream imgproxy (405+`Allow` where upstream
404s bare; 204+`Allow` where upstream sends a blank 200; HEAD processed
where upstream answers blank) is recorded in the matrix.

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
