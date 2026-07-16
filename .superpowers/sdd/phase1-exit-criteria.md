# Phase 1 exit criteria — imgproxy dialect inversion

Cross-check of the design spec's 13 phase-1 exit criteria
(`docs/superpowers/specs/2026-07-15-imgproxy-dialect-inversion-design.md`,
§Exit criteria) against the tree at the end of R11 (Task 26).

**Verdict: 11 of 13 hold. Two do not — #1 and #10.** Both are recorded below
with what specifically fails, not smoothed over. Neither blocks phase 1's
premise (the dialect serves imgproxy URLs with zero pixel divergence across
162 × 2 differential constellations and 263 × 2 wire cases); both are real
defects that a phase-2 plan, or a fix wave before it, must own.

A criterion marked ✅ means its evidence was run or read at this commit. Where
a criterion is partly satisfied it is marked ⚠️ and its unsatisfied half is
stated — a partial is not a pass.

---

## 1. ✅ End-to-end request service — RESOLVED (was ⚠️ PARTIAL)

> **Update (branch-closing fix wave):** the one non-holding clause below was
> ruled FIX-NOW and is fixed. The byte-identity ETag-suppression decision was
> relocated from the framework-only `Request.HTTPCache` to
> `ImagePipe.Representation.build/3` / `Representation.response_headers/1`, the
> one seam both dialects reach. A `byte_identity: :none` source now withholds
> the `ETag` and sends `Cache-Control: no-store` on **all three** stacks
> (framework unchanged and byte-identical; imgproxy and shipped `Dialect.Native`
> fixed). Proven on the observable response by
> `test/image_pipe/dialect/byte_identity_cache_headers_test.exs` (imgproxy
> streamed + `/info`, native streamed + blurhash) with RED-before evidence. The
> criterion now holds. The original diagnosis is kept below as the record.

> `ImagePipe.Dialect.Imgproxy` serves real requests end-to-end: full option
> surface, `/info/`, signing + salts, `expires`, `-` pipelines, presets,
> base64/`enc`/plain sources, `@ext`, negotiation + `Vary`, ETag/304 before
> fetch, cache hit/miss, streamed delivery.

**Holds** for every clause except one. Evidence: `imgproxy_wire_smoke_test.exs`,
`imgproxy_wire_conformance_test.exs` (dual-run, 149 + 114), `info_wire_test.exs`,
`error_paths_test.exs`, `mount_test.exs`.

**Does not hold: "ETag/304 before fetch" is unsound for a source with no byte
identity.** Found in R11 while probing telemetry; verified across all three
stacks.

For a source resolving `cache_semantics.byte_identity: :none` (reachable with
the shipped `Source.HTTP`, `Source.File`, and `Source.S3` adapters whenever the
origin supplies no validator):

| Stack | `ETag` | `Cache-Control` |
| --- | --- | --- |
| framework | *(none)* | `no-store` |
| `Dialect.Imgproxy` | `"ipr1-3k20cj54dS…"` | `max-age=0, private, must-revalidate` |
| `Dialect.Native` | `"ipr1-XkRwmvDXJp…"` | `max-age=0, private, must-revalidate` |

A conditional GET against such a source **304s on the dialect** even when the
origin's bytes have changed, and shared caches store what the framework marks
`no-store`. The dialect's ETag is derived from `Resolved.identity` — addressing
identity, i.e. cache-*key* material — which is exactly the key/ETag conflation
AGENTS.md's cache guidelines warn against.

**Root cause is structural, and it is the D5 shape again**: the gate lives in
`Request.HttpCache.do_generated_etag/4` / `cache_control_without_etag/2`, which
only `ImagePipe.Plug` routes through. No dialect can reach it, so every dialect
gets it wrong. Same treatment indicated as the colour-carry stamp: relocate the
gate to a core seam both stacks call.

**Not introduced by this project** — `Dialect.Native` ships it today. Not fixed
in R11: it is a correctness change to a shipped dialect with a design decision
in it (where the gate lives, what a dialect passes `Representation.build/2`),
and it deserves the ruling D5 got rather than a last-batch patch.

Recorded in `docs/imgproxy_support_matrix.md` § Dialect-stack divergences.

## 2. ✅ Dual-run differential suite green on both arms

`test/image_pipe/imgproxy_differential_conformance_test.exs` — 162
constellations × 2 arms. Fixtures unchanged, **no re-bake** (`git status
test/support/image_pipe/test/imgproxy_differential/` clean across the branch).
Landed d91bbc0f.

## 3. ✅ Dual-run wire suite green on both arms + cross-arm body hash

`imgproxy_wire_conformance_test.exs` (7ab479d8) + `imgproxy_cross_arm_body_test.exs`
(7c7e5673, raw body-hash equality, byte-exact). Combined with #2: 594 passed,
2 excluded.

Caveat, stated because the criterion's "149 × 2" implies uniform coverage:
**~30 cases run framework-only**, gated `if @stack == :framework` on config keys
the dialect has no equivalent for. Each carries a stated reason. They are where
a parity gap can still hide.

## 4. ✅ ContractKit.CacheKey + ContractKit.RequestSafety pass against the dialect

`test/image_pipe/dialect/imgproxy_contract_test.exs` (f2ff3e34).

## 5. ✅ Orientation matrix, including the auto-rotate-OFF arm (G1 closed)

`test/image_pipe/dialect/imgproxy/orientation_matrix_test.exs` (e1a05a61,
commit subject records "closes G1").

## 6. ✅ Error-path matrix passes

`test/image_pipe/dialect/imgproxy/error_paths_test.exs` (9ada1ee4) — 8 tests.

Scope stated honestly: **rows 1–7 of native's 9 are ported; rows 8 and 9 are
not.** Their subject is core `ImagePipe.Delivery`/`Coordinator` (shared by both
dialects since D3), native's own rows 8/9 never call `Native.call/2` either, and
neither is reachable through a dialect at the wire level — `Plug.Test`'s chunked
adapter drains the stream inside `Sender.send_result/3`, so no caller holds a
`%PreparedStream{}` to cancel or issues `next/1` after `:done`. Recorded in the
file's moduledoc. Row 2 is ported *better* than native's: driven end to end
through `Imgproxy.call/2` via the `:chain` seam, with a positive control proving
its refutations are observations rather than silence.

## 7. ✅ Grammar-module tests pass against both the original and the copy

`test/parser/imgproxy/` — 506 passed (11 properties, 495 tests), dual-run across
`Parser.Imgproxy.*` and `Dialect.Imgproxy.*`. Copy fidelity including error
paths.

Dual-run **proven, not asserted** (R6): the implementer deliberately broke the
dialect's `option_grammar.ex` and reran — exactly one arm went red. R6's fix
commit (28cc2300) then re-armed two assertions the conversion had disarmed
(a `%Signature{}` weakened to a bare map, and the AES-key redaction that had
lost its only test).

The spec says "~211"; the real number is 506 because the count includes the
framework arm and properties.

## 8. ✅ `-` pipeline scoping pinned

`pipeline_scoping_test.exs` + `pipeline_carry_test.exs` (6558ccf3, c6c1ab98,
1b3c93aa): per-pipeline re-seed, per-pipeline flush, and a carry that never
leaks into a pipeline with no resize of its own.

## 9. ✅ D3's gate resolved — Outcome A, full unification

> either `Request.SourceSession` runs on `ImagePipe.Delivery` with
> application-shutdown termination proven by test, or Extraction A is
> dialects-only with the exact blocker recorded. The core primitive gained no
> supervised mode.

**User ruling: Outcome A — full unification** (`.superpowers/sdd/d3-audit-report.md`
§9). App-tree-shutdown-independent-of-owner-liveness ruled OUT OF CONTRACT.

**Topology change.** `Request.SourceSession`, its producer, and
`Request.SourceSessionSupervisor` are DELETED; the supervisor's child entry is
gone from `application.ex`. The framework and both dialects now share
`ImagePipe.Delivery`. The core primitive gained **no supervised mode** — the
criterion's standing constraint held. Task 3 was split into 3a (widen the
primitive) + 3b (migrate the framework) after 3a's escalation proved the original
premise false (`Delivery.stream/5` could not carry the framework; 4 verified
gaps). Landed b7858657..45492093.

**Accepted cancellation-semantics change (the G6 delta).** Cancellation is now
graceful-halt + a ~1s backstop rather than force-kill. Baseline A's cache-abort
lands ~1s after owner death, inside its 2s budget. This is the one place the new
topology is measurably slower, and it was accepted as part of the ruling.

**Bracket-cleanup evidence (the user's added requirement, beyond plan text).**
A lifecycle test proves graceful owner-down runs the producer's decode/bracket
cleanup **exactly once** — not merely "producer terminates + sink aborts".
**Mutation-verified**: a force-kill mutation turns the bracket test RED *while
Baseline A stays GREEN*. That empirically **demonstrates** the audit's §6d gap
rather than asserting it: Baseline A cannot catch a bracket-cleanup regression;
the new test can. This is the single strongest piece of evidence the run
produced, and it exists only because the user added the requirement.

**Baselines.** Baseline B DELETED citing the ruling (b7858657, deleted not
edited). Baselines A + OTel parentage byte-UNCHANGED and green through the whole
migration (`git numstat 7e249e4e..HEAD` = 0 lines over both).

## 10. ⚠️ Telemetry contract test — PARTIAL

> Telemetry contract test green on both arms (stage names, ordering, error
> stages), each using a private `telemetry_prefix`.

`test/image_pipe/imgproxy_telemetry_contract_test.exs` (bca53068) — 14 passed:
six scenarios (image cache miss, cache hit, 304, `/info/`, streamed error after
preparation, owner cancellation) × two arms, plus two stage-set measurements.
Every test uses a unique private `telemetry_prefix`. Dual-run **proven**: adding
a framework-only stage to `@shared_stages` turns exactly one arm red.

**The "error stages" clause does not hold on the dialect arm.** Measured: a
dialect request that fails *before* delivery emits **no `:result` on any stage**.
A 502 emits `[:source, :fetch, :stop] = :ok` and nothing else; the framework
emits `[:source, :fetch_decode, :stop] = :source_error` plus `[:send]` and
`[:request]`. The dialect's `[:request, :stop]` metadata is `%{status: …}` with
no `:result` at all, so `Telemetry.Logger`'s `outcome/1` renders **every** dialect
request `:ok` and `level_for/3` never escalates. Failures *after* delivery starts
do surface, on the core-owned `[:deliver]` span (`:processing_error`) — scenario 5
pins it, on both arms.

The test is green because it asserts the shared contract and *states* the
divergence in a pinned list rather than blessing it. Calling that a pass on
"error stages" would be exactly the "green checkmark over a claim the code does
not support" this project has been bitten by four times.

**The spec's own telemetry claim, by contrast, HOLDS and is now verified**: the
dialect emits the same standard stage names as native — `ImgproxyTelemetryStageSetTest`
asserts by measurement that `Dialect.Imgproxy` emits *exactly* the stage
**sequence** `Dialect.Native` does. Consequently **no Logger or `Trace.Capture`
list change is needed**, checked rather than assumed against both surfaces:
every stage the dialect emits is already in `@group_span_events` and
`@span_stages`, and the dialect introduces no new event name and no new metadata
key.

Also measured, and neither fixed nor asserted: the framework emits **seven**
stages no dialect does (`[:send]`, `[:source, :fetch_decode]`,
`[:transform, :execute]`, `[:transform, :input_color_management]`,
`[:transform, :materialize]`, `[:output, :negotiate]`, `[:encode]`), six owned by
framework-only modules; `[:output, :clamp]` is not emitted; and `[:parse, :stop]`'s
`:result` means different things on the two arms (the framework's `[:parse]` span
encloses `PlanBuilder.to_plan/2`, the dialect's `check_geometry/1` runs after the
span closes). All shared with `Dialect.Native`. Recorded in the support matrix.

## 11. ✅ Boundary + architecture tests enforce the acid test

`test/image_pipe/architecture_boundary_test.exs` — 37 passed. Adds
`ImagePipe.Dialect.Imgproxy`'s pinned `deps:` (14, incl. `ImagePipe.Config`,
which native does not take) and `exports: [SourceScheme]`. **Mutation-verified**:
dropping one dep from the pinned list turns the new test red.

The "no core file names a dialect" check needed **no** new assertion: its
`dialect_references/1` filters on the substring `"ImagePipe.Dialect"`, which
`"ImagePipe.Dialect.Imgproxy"` contains. Verified by reading the predicate, not
by observing the test's silence. Its name (and the sibling glob test's) was
generalized from "the native dialect" to "a dialect" to match what it enforces.

## 12. ✅ `mise run precommit` green — after fixing a real failure it exposed

**It was NOT green when first run in R11**: `mix dialyzer` reported **6 errors**,
all in `lib/image_pipe/dialect/imgproxy.ex`, all cascading from one root.

Pre-existing, introduced by Task 17 (`4ab6dbd9`, the inverted chain) and never
caught because that batch's gate ran format/compile/credo/tests but **not
dialyzer**. This is exactly why the criterion names the full gate.

**Root cause**: `Pipeline.run/4` and `Pipeline.decode_request/2` specced their
request parameter as `%{pipelines: [PipelineRequest.t()]}`. In Elixir typespecs
that shorthand means a **closed** map with exactly one key — which `%Request{}`,
eleven fields, can never satisfy. The contract was unsatisfiable by its only
production caller. The three `unused_fun` errors were downstream: dialyzer had
concluded the code after the failing call was unreachable.

**Fix** (this commit): a named `t:pipelined_request/0` opening the map with
`optional(any()) => any()`. Structural rather than `Request.t()` is deliberate
and preserved — the pipeline tests drive `run/4` with a bare `%{pipelines: [...]}`,
which an open map still accepts and `Request.t()` would have broken.
`Dialect.Native.Pipeline` was never affected: it specs `Request.t()` directly.

Gate at this commit, with `PATH="$(mise where elixir)/bin:$PATH"`:
`mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo --strict` (8512 mods/funs, no issues), `mix dialyzer`
(**Total errors: 0**), ExDNA, and the full `mix test` — all exit 0.

## 13. ✅ Support matrix stage/order rows synced

`docs/imgproxy_support_matrix.md`, this commit. Per AGENTS.md, by axis:

- **stage/order** (the spec's expected axis): stage 4 `colorspaceToProcessing`
  now names `Dialect.Imgproxy.Pipeline.run/4` alongside `Executor.execute/3`, and
  records the **D5 relocation** — `Output.Encoder.color_result/2` read
  `imagepipe-icc-*` headers written only by a `defp` in the frozen
  `Request.Processor`, unreachable from any dialect, so **every dialect encoded
  profiled sources with wrong pixels** (an `scp:0` P3 source off by **113** on a
  0-255 channel). Moved to `Transform.InputColorManagement.stamp_carry/1`;
  `Request.Processor` delegates; both dialects call it. Stage 8 `cropToResult`
  no longer says `fill_down` is "reachable only through the imgproxy resolution
  strategy" — `Dialect.Imgproxy.Assembly` emits `down: true` with no strategy at
  all. Stages 6 and 12 name both stacks' cap/carry mechanisms.
- **surface**: a new "Two stacks serve imgproxy URLs" section (mount shapes,
  config shapes) and a new **Dialect-stack divergences** section enumerating the
  ETag/`no-store` unsoundness (#1), `OPTIONS` → 400 vs 204+`Allow`, ignored host
  `max_result_*`, dialect-only `/info` caching, deliberately different cache
  keys/ETags across stacks, the telemetry gaps (#10), and the unverified
  surfaces.
- **behavioral/pixel**: no change intended and none found — which is what the
  dual-run nets in #2 and #3 prove.

`docs/imgproxy_path_api.md`: mount-point note (the dialect mounts directly; the
framework selects via `parser:` and namespaces under `:imgproxy`), plus the
prefix/`/info`/query-string signing semantics `mount_test.exs` pins.

`docs/telemetry.md:860` already named `ImagePipe.Delivery` — synced by an
earlier task; re-checked, no `SourceSession` reference remains in `docs/`
outside historical plan files.

---

## Docs debt closed en route

The spec, the plan, and the controller's dispatches all described padding and
canvas as having **different** effective-DPR fallbacks ("padding falls back to
request dpr; canvas falls back to 1.0"). Controller-verified: the distinction is
**unobservable**. `plan_builder.ex:409-415`'s `resize_rule_requested?` includes
`not is_nil(request.dpr)`, so a set dpr always emits a resize, the carry is
never nil, and the `{:effective, fb, _}` fallback clause is reachable *only* when
dpr is nil — where both fall back to 1.0. True of the framework arm too
(`resolver.ex:151-168`); not a port bug. The parity structure was kept for phase
1 (simplifying during a parity port is how subtle divergence ships), and is a
phase-2 simplification candidate.

## Not covered by any criterion, recorded so it is not lost

- **Object detection (`g:obj:*`) is unverified on the dialect arm.** The grammar
  accepts the URL; no dual-run case exercises it, and **two of the uncovered
  cases are request-*safety* tests**.
- **Four bugs this project found in the shipped `Dialect.Native`, all fixed**:
  orphaned trace spans (no trace context threaded → delivery spans landed in a
  different trace); `cost_us: 0` on every cache entry (mis-scoring admission —
  and the first fix missed a second instance on the BlurHash path); the decode-
  preflight axis synthesis (diverging from the chain path on non-proportional
  single-axis resizes; `rs:fit:1:0/dpr:0.4` crashed with `ArithmeticError` on a
  parser-VALID request the framework serves); and the input-colour preamble it
  never ran. Two more shipped-Native defects were recorded above: the
  ETag/`no-store` unsoundness (#1) is now **fixed** in the branch-closing fix
  wave (see #1); the pre-delivery telemetry silence (#10) stays open (deferred).
- **CORS is a framework-`Plug`-only gate — the third framework-only-gate
  instance, deferred to phase 2.** `ImagePipe.Plug` stamps
  `Access-Control-Allow-Origin` on every response when `allow_origin` is set
  (`plug.ex` → `CORS.maybe_register/2`); the inverted dialect stacks
  (`Dialect.Imgproxy`, `Dialect.Native`) never route through `ImagePipe.Plug` and
  have **no** CORS handling at all — no `allow_origin` key, no `Response.CORS`, no
  preflight, and `Access-Control-Allow-Origin` on **no** response. This joins the
  ETag/`no-store` gate (#1, now fixed) and the host `max_result_*` clamps
  (recorded under #13) as the class of correctness/feature gates that live only in
  the framework path. Unlike #1, the CORS *feature* is a fair phase-2 deferral (a
  host can add CORS in its own router meanwhile); it is now recorded in
  `docs/imgproxy_support_matrix.md` § Dialect-stack divergences and § CORS
  response headers so the gap is not a doc claim outliving the code.
- **`{:session, :timeout}` prepare-timeout reclamation has no RED-able test
  through `stream/5`** — `Delivery.stream/5` hard-codes a 60s timeout. Pinned at
  the `Coordinator` level instead. Closing it properly means deciding whether the
  prepare timeout should be a real host option (open design question from 3b).

## ⛔ END OF PHASE 1

Phase 2 (`Parser.Imgproxy` retirement) gets its own plan against the same spec.
Not started.
