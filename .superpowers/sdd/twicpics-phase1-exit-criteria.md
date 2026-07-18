# TwicPics dialect inversion: Phase-1 exit criteria

Cross-check of the Phase-1 exit gate in
`docs/superpowers/specs/2026-07-17-twicpics-dialect-inversion-design.md`
for the tree at `041a097572a1fbde5ca6d40961346ba6917a05ac` plus the
Task 14 documentation, configuration, telemetry-contract, and architecture
corrections.

The unique phase-base subject resolves to:

```text
bdb421ab32da06fc1047faf66565d99dde827325  TwicPics oracle prerequisite: shadowing and no-enlarge baseline
```

The subject occurs exactly once in `git log HEAD`. The phase-1 comparison arm
remains live. This report doesn't start parser retirement or the shadowing fix.

## 1. Dual wire coverage

**Criterion:** every TwicPics-specific wire case executes through both arms
unless the inventory records an explicit phase-2 gate.

**Status: passes.** One shared body defines the 49 pre-phase cases and ten added
life-cycle cases inside generated Framework and Dialect modules in
`test/image_pipe/twic_pics_wire_conformance_test.exs`. Each arm runs 59 cases.
Nine singleton cross-arm tests bring the file to 127 tests.

Evidence:

- `ebae5842` converted the original 49-case framework file into the dual-run
  contract and added ten shared lifecycle cases plus eight cross-arm cases.
- `0cfb5059` added the ETag classifier test and tightened the strong-validator
  comparisons.
- Task 11's deliberate dialect-500 mutation failed exactly 49 dialect copies
  while all 49 framework copies stayed green. The first shared-body dual run
  passed 98 tests; the final file passed 127.
- No `@stack == :framework`, `@arm == :framework`, or matching conditional
  gates exist in the shared test body.

## 2. Hosted SaaS baseline for both arms

**Criterion:** every recorded constellation executes through both arms. Both
arms pass every default-lane SaaS verdict. The baseline triage case executes
explicitly without an upstream-parity claim.

**Status: passes.** `7a036fe3` changed
`test/image_pipe/twicpics_differential_conformance_test.exs` and its Harness to
generate one test per `{arm, constellation}` pair. The authored census is 39:
34 `:equal`, five `:diverges`, and one triage marker. The triage marker is a
subset of the authored 39, not a 40th case.

- Default lane: 38 cases per arm. Each arm passes 33 `:equal` fixtures and all
  five accepted divergences inside their existing two-sided bands.
- Explicit `twicpics_triage` lane: both arm copies of
  `resize_shadow_relative_then_absolute` execute and fail with local 200×200
  versus the committed TwicPics 340×340 fixture. This is quarantine evidence,
  not an upstream-parity claim.
- The five monitored divergences and the one quarantine remain documented in
  `docs/twicpics_support_matrix.md`. No tolerance, verdict, source, fixture,
  manifest, or report value changed in phase 1 after the base.

## 3. Exact local cross-arm census

**Criterion:** the two local arms match exactly.

**Status: passes.** `test/image_pipe/twicpics_cross_arm_conformance_test.exs`
generates exactly 39 local comparisons from `Constellations.all/0`, including
the quarantined shadow case. Every pair requires equal status, content type,
dimensions, bands, and threshold-zero pixel buffers. Six deterministic PNG
cases additionally require equal body SHA-256 values.

Task 12 recorded 39/39 exact comparisons plus the order self-check. This local
exact net consults no SaaS tolerance or divergence band.

## 4. Literal order remains observable

**Criterion:** order-discriminating cases prove that the harness hasn't
normalized the TwicPics chain.

**Status: passes.** Evidence spans each layer:

- `cb783d72`: RequestBuilder retains different complete step terms for focus
  before versus after resize and pins the quarantined relative-then-absolute
  chain as two literal steps.
- `38573db4` and `ac4e2abf`: Pipeline/PointFlow execute and measure ordered
  steps without a shared Plan resolver marker.
- The original wire case `focus resolves against the running frame at its
  chain position` runs through both arms and compares different pixel outputs
  for the two orders.
- The cross-arm file renders the focus-before and focus-after paths
  within each arm and requires nonzero pixel differences.
- Task 12's dialect path-order mutation caused both the affected exact case and
  the dialect order self-check to fail.

## 5. Per-arm isolation

**Criterion:** each arm owns separate initialized config, cache, source probe,
and counters.

**Status: passes.** The wire `Arm.call/4` initializes the selected entry point
per request. Cache-hit and conditional helpers create fresh cache tables and
source adapters inside each arm's branch. Differential `Harness.plug_opts/1`
initializes separate framework and dialect option sets. The tests don't reuse
a warmed cache, source probe, or mailbox assertion across arms.

Evidence is in `ebae5842`, `0cfb5059`, and `7a036fe3`, with the focused helpers
in `twic_pics_wire_conformance_test.exs` and
`test/support/image_pipe/test/twicpics_differential/harness.ex`.

## 6. Telemetry isolation and semantic parity

**Criterion:** telemetry handlers use a unique per-test, per-arm private
prefix, attach only below that prefix, and detach during cleanup.

**Status: passes.** `test/image_pipe/twic_pics_telemetry_contract_test.exs`
runs six scenarios through both arms: miss, hit, 304, parse error, streamed
failure, and owner cancellation. `observe/3` builds a prefix containing the arm,
scenario, and a unique integer. `attach_many/4` subscribes only to that prefix.
An `after` block always detaches the handler.

`99b0ec8a` added the contract and `041a0975` preserved terminal result and
storage semantics after review. The comparison pins stage order plus `result`,
`error`, `status`, `operation`, and `index`. It normalizes only the private
parser wrapper's two known raw error tags, `:error` and
`:unsupported_transform`, while preserving their raw result and status fields.
It collapses only adjacent duplicate callbacks. A wrong-dialect `:decode`
mutation failed the semantic comparison, and widening the normalizer to accept
that tag failed the focused suite at 10 of 11 passing.

## 7. Representative lifecycle surface

**Criterion:** cache hit/miss, conditional, HEAD, CORS, method, output
negotiation, debug, safety limit, detector, error, and telemetry behavior have
observable dual coverage.

**Status: passes.** The dual wire body has ten shared life-cycle cases. They
cover HEAD, OPTIONS, unsupported methods, CORS, an early strong 304, cache behavior,
storage-header and cookie identity, detector identity, input pixel limits, and
a private telemetry prefix. The original 49 cases add
explicit and automatic output, `Vary`, debug headers, invalid input, result
clamping, focus/detector behavior, and cache reuse.

Adjacent dialect evidence:

- `cc06b306` and `b970baff`: self-contained Plug lifecycle and side-effect
  boundaries.
- `99b0ec8a`: ContractKit cache/request-safety coverage and the nine-row error
  matrix.
- `041a0975`: request-stop terminal result and storage contract preservation.

## 8. Dependency inversion

**Criterion:** the dialect depends on core toolkit boundaries without the
framework Parser, Request, Resolver, Renderer, another dialect, or a root Plan.

**Status: passes.** `test/image_pipe/architecture_boundary_test.exs` requires
`ImagePipe.Dialect.TwicPics` to have exactly 15 dependencies and zero exports.
It also pins `ImagePipe.Dialect.SharedConfig` to the exact Cache, Format,
Source, and Telemetry dependency set with zero exports. A negative scan rejects
TwicPics product references from the shared config module. AST checks scan the root file and every file under
`lib/image_pipe/dialect/twic_pics/` for root `%ImagePipe.Plan{}` construction,
framework-stack references, and sibling-dialect references. Separate core
scans reject references back to the dialect.

The focused architecture and telemetry contracts landed in `99b0ec8a` and
their review corrections in `041a0975`. Injecting a TwicPics reference into
`SharedConfig` failed the architecture suite at 45 of 46 passing.

## 9. Frozen hosted-oracle data

**Criterion:** fixtures, sources, manifest, and committed report remain
unchanged from the unique phase base.

**Status: passes.** The exact command is:

```shell
phase_subject='TwicPics oracle prerequisite: shadowing and no-enlarge baseline'
phase_base_matches=$(git log --format='%H%x09%s' HEAD | awk -F '\t' -v subject="$phase_subject" '$2 == subject {print $1}')
phase_base_count=$(printf '%s\n' "$phase_base_matches" | sed '/^$/d' | wc -l | tr -d ' ')
test "$phase_base_count" -eq 1
phase_base="$phase_base_matches"
git diff --exit-code "$phase_base" -- \
  test/support/image_pipe/test/twicpics_differential/fixtures \
  test/support/image_pipe/test/twicpics_differential/sources \
  test/support/image_pipe/test/twicpics_differential/manifest.exs \
  test/support/image_pipe/test/twicpics_differential/REPORT.md
```

Observed result: one phase-base commit and an empty diff.

## 10. Documentation and retirement inventory

**Criterion:** changed documentation reflects the dialect architecture. Vale
reports no findings. The inventory classifies future parser and strategy
retirement.

**Status: passes.** `docs/twicpics_support_matrix.md` now describes the ordered
Request, local PointFlow, and dialect Pipeline. It labels the framework arm as
temporary phase-1 comparison coverage. It retains the Task 2 facts: 39 hosted
fixtures, five monitored divergences, and the quarantined shadow case under
issue #464. It doesn't claim shadowing fixed.

The matrix also records that both temporary local arms return 200×200 for the
shadow quarantine, removes the unsupported claim that `focus=center` equals an
implicit default, and marks `output=auto` partial. Hosted TwicPics selected
WebP for the reviewed Chrome Accept header while ImagePipe's configurable,
Accept-only default selected AVIF. Phase 2 owns that compatibility decision.

`.superpowers/sdd/twicpics-phase1-test-inventory.md` classifies the target
surface. It covers 25 PlanBuilder cases, 12 Resolver/PointFlow cases, 45 leaf
cases, eight wrapper cases, and 49 original wire cases. The wrapper disposition
is seven `DELETE` cases and one `PORT` for mount-time `autoquality` validation.
It also covers the strategy and marker SDK, both Fiddle call sites, generic
framework cases, live consumers, cache-key strategy pins, tooling, and live
documentation. Each entry uses `PORT`, `REPOINT`, or `DELETE` with its required
evidence. Closure review added explicit dispositions for the Parser and
Transform boundaries. It also enumerates every Plan strategy-validation case
plus Directive constructor and key material. Separate rows cover request-runner
and fixed-driver fixtures, dialect pipeline comments, ordered-spike and vendor
fixtures, error-status and resize-planning cleanup, and architecture assertions.
The lexical gate searches the bare `:deferred` marker and qualified strategy
terms. A syntax-aware root-Plan resolver-field check completes the Phase-2
gate. That check excludes unrelated IIIF, HTTP address, telemetry, and
host-option resolvers.

Vale command and observed result:

```shell
mise exec -- vale \
  docs/twicpics_support_matrix.md \
  .superpowers/sdd/twicpics-phase1-test-inventory.md \
  .superpowers/sdd/twicpics-phase1-exit-criteria.md
```

Observed result: `0 errors, 0 warnings, 0 suggestions` across all three files.
The ignored Task 14 report also passes with no findings.

## 11. Focused evidence gate

The Task 14 focused command uses the required direct-Mix PATH convention:

```shell
export PATH="$(mise where elixir)/bin:$PATH" && mix test \
  test/image_pipe/twic_pics_wire_conformance_test.exs \
  test/image_pipe/twicpics_differential_conformance_test.exs \
  test/image_pipe/twicpics_cross_arm_conformance_test.exs \
  test/image_pipe/twic_pics_telemetry_contract_test.exs \
  test/image_pipe/architecture_boundary_test.exs
```

Observed result: `302 passed, 2 excluded`, with exit 0. The exclusions are the
framework and dialect copies of the quarantined shadow constellation.

The focused configuration, telemetry, and architecture regression gate passed
67 tests. Removing the `autoquality` validation made the exact configuration
test fail with 9 of 10 passing. Before the fix, the combined RED run failed the
new `autoquality` and wrong-dialect telemetry cases with 19 of 21 passing.

## 12. Full repository gate

Command:

```shell
export PATH="$(mise where elixir)/bin:$PATH" && mise run precommit
```

Observed result: exit 0. Format, warnings-as-errors compilation, strict Credo,
Dialyzer, exact ExDNA, and the full ExUnit suite all passed. The final ExUnit
summary was `4100 passed, 10 excluded`.

The standalone warnings-as-errors compile, strict Credo, and exact ExDNA gates
also passed. Credo checked 658 source files with no issues. ExDNA found no
duplication across 273 files.

`mise run precommit:fiddle` passed the same library gate and the complete Fiddle
suite. Fiddle ExUnit passed 17 tests. `Vitest` passed 314 tests across nine
files. Svelte reported no errors or warnings. Formatting, lint, and both builds
passed.
`fiddle/mix.lock` remained unchanged.

No JXL `Failed to write VipsImage to buffer` failure occurred, so the Vix
repair path wasn't used.

## Final phase-1 verdict

All Phase-1 exit criteria pass at the corrected Task 14 scope. The only
production change adds the missing dialect mount-time validation for invalid
`autoquality` combinations. The framework comparison arm, legacy parser,
strategy SDK, Fiddle mount, bake parse gate, and frozen oracle remain
unchanged. Phase 2 hasn't started.
