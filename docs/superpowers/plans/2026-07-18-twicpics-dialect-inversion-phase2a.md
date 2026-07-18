# TwicPics dialect inversion Phase 2A: Retire the comparison arm

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to execute this plan task by task. Use superpowers:test-driven-development for every behavior or caller migration. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add and activate a fixed neutral execution driver, then move each consumer onto its surviving stack. Retire `ImagePipe.Parser.TwicPics` and leave one dialect-only TwicPics wire and SaaS net without changing observable behavior.

**Architecture:** `ImagePipe.Transform.Executor` gains a fixed neutral path beside the existing injected-strategy path. The fixed path calls `ImagePipe.Transform.NeutralResolver.resolve/3` and `continue/4` directly. It shares the current preamble, shape-to-state overlay, stage measurement, chain execution, and pipeline-boundary flush behavior.

`%ImagePipe.Plan{resolver: nil}` selects the fixed path. Non-`nil` resolver Plans continue through `ImagePipe.Resolver` until Phase 2C. `ImagePipe.Parser.IIIF` remains an `ImagePipe.Plug` parser and becomes the production proof of the fixed framework path. TwicPics remains a self-contained dialect Plug and doesn't enter the fixed driver.

**Tech Stack:** Elixir/ExUnit, Plug, Vix/libvips, Boundary, mise, Vale, Svelte/Phoenix fiddle.

**Design records:**

- `docs/superpowers/specs/2026-07-17-twicpics-dialect-inversion-design.md`, especially Phase 2A and decisions T9–T15
- `docs/superpowers/plans/2026-07-17-twicpics-dialect-inversion-phase1.md`
- `.superpowers/sdd/twicpics-phase1-exit-criteria.md`
- `.superpowers/sdd/twicpics-phase1-test-inventory.md`
- `docs/superpowers/specs/2026-07-16-imgproxy-dialect-phase2-design.md`
- `docs/superpowers/plans/2026-07-16-imgproxy-dialect-phase2-wave2.md`

<!-- vale off -->

## Global constraints

- **Toolchain:** every direct Mix command must start with `export PATH="$(mise where elixir)/bin:$PATH" && mix …`. `mise run precommit` and `mise run precommit:fiddle` already select the repository toolchain.
- **Phase boundary:** this plan is Phase 2A only. Do not implement the #464 shadow rewrite, change `output=auto`, or close any Phase 2B gap.
- **Keep the strategy SDK:** do not remove or narrow `ImagePipe.Resolver`, `ImagePipe.Plan.resolver`, `ImagePipe.Plan.Operation.Directive`, `:deferred`, resolver behavior versions, cache-key resolver material, the injected executor path, or host strategy documentation. Those changes belong to Phase 2C.
- **IIIF stays on the framework stack:** production IIIF continues through `ImagePipe.Plug` and `ImagePipe.Parser.IIIF`. Do not invert IIIF into a dialect.
- **No oracle authorship changes:** do not run `mise run twic:bake`, `twicpics.gen_fixtures`, or `twicpics.reauthor`. Do not edit `constellations.ex`, `fixtures/`, `sources/`, `manifest.exs`, or `REPORT.md`. Keep all five authored divergence bands, every tolerance, every verdict, and the #464 triage record byte-identical.
- **No fixture regeneration:** a differential failure is an implementation or migration failure. Never re-bake to make it green.
- **No output-policy change:** the dialect keeps the current Accept-only `output=auto` behavior and the documented hosted-TwicPics mismatch.
- **Fiddle lock:** never stage or commit `fiddle/mix.lock`. Run `git diff --exit-code origin/main -- fiddle/mix.lock` before every commit that touches `fiddle/`.
- **Deletion evidence:** each `DELETE` step cites surviving coverage below and repeats that citation in the commit body. Do not replace deleted tests with weaker assertions.
- **Caller evidence:** each `PORT` or `REPOINT` gets a RED run by temporarily failing the named production seam (`R-DIALECT`, `R-PARSE`, `R-PIPELINE`, `R-POINT`, `R-IIIF`, or `R-HARNESS`), followed by a reverted mutation and GREEN. Record the command and failing test names in the implementation notes or commit body.
- **Unexpected GREEN is a stop signal:** if a mutation does not fail the intended caller, fix the test or disposition before continuing.
- **Commits stay green:** use the commit boundaries below. Do not combine the fixed-driver activation, consumer migration, parser deletion, or documentation into one commit.
- **Branch:** execute on a descriptive branch such as `feat/twicpics-phase2a-retire-parser`; never use a `codex/` prefix and never move the worktree directory.

## Immutable baseline gate

Run before Task 1 and at every checkpoint:

```shell
git diff --exit-code origin/main -- \
  test/support/image_pipe/test/twicpics_differential/constellations.ex \
  test/support/image_pipe/test/twicpics_differential/fixtures \
  test/support/image_pipe/test/twicpics_differential/sources \
  test/support/image_pipe/test/twicpics_differential/manifest.exs \
  test/support/image_pipe/test/twicpics_differential/REPORT.md
git diff --exit-code origin/main -- fiddle/mix.lock
```

## Part 1 — prove and activate fixed neutral execution

### Task 1: Add the fixed neutral driver and low-level cross-run net

**Files:**

- Modify: `lib/image_pipe/transform/executor.ex`
- Create: `test/image_pipe/transform/neutral_driver_cross_run_test.exs`

- [ ] **Step 1: Write the RED cross-run harness.** Add tests that call a not-yet-implemented `Executor.run_neutral/4` beside the existing `Executor.run/5` with `{NeutralResolver, NeutralResolver.init()}`. Use a recording `:chain` callback and deterministic `:measure_dims` callback. The corpus must cover: an identity/effect op, a pure shape advance, relative resize, staged cover resize plus crop, guided crop, trim or arbitrary rotation measurement, a pending-orientation flush, identity-pending streaming, and a chain error. Compare emitted operation batches and stage boundaries, measurement calls, final `State` fields, final image dimensions, materialization state, and error tags.
- [ ] **Step 2: Run RED.** The new file must fail to compile because `run_neutral/4` is absent:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/neutral_driver_cross_run_test.exs`
- [ ] **Step 3: Implement the fixed loop beside `run/5`.** `run_neutral/4` must call `NeutralResolver.resolve(shape, nil, operation)` and `NeutralResolver.continue(tag, measured_dims, resolve_shape, neutral_state)` directly. It must not call the `ImagePipe.Resolver` facade and must not synthesize `{NeutralResolver, state}`. Share the overlay, stage execution, measurement, error propagation, and boundary-flush helpers so the two drivers cannot drift through copied chain logic. Keep `run/5` and all injected-strategy types unchanged.
- [ ] **Step 4: Prove the comparison is load-bearing.** Temporarily skip a measured tail, skip overlay, or change one fixed-driver error tag. The cross-run file must fail in the corresponding operation/stage/state/error assertion. Revert.
- [ ] **Step 5: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/neutral_driver_cross_run_test.exs test/image_pipe/transform/executor_test.exs test/image_pipe/transform/resolved_plan_golden_test.exs`
- [ ] **Step 6: Commit:** `transform: add a cross-checked fixed neutral driver`.

### Task 2: Cross-run IIIF pixels and activate `resolver: nil`

**Files:**

- Modify: `lib/image_pipe/transform/executor.ex`
- Modify: `test/image_pipe/transform/neutral_driver_cross_run_test.exs`
- Modify: `test/image_pipe/transform/executor_test.exs`
- Modify: `test/parser/iiif_wire_test.exs` or create `test/parser/iiif_fixed_driver_test.exs`

- [ ] **Step 1: Add IIIF and real-pixel parity before changing routing.** Build representative Plans through `ImagePipe.Parser.IIIF.PlanBuilder.image_plan/3`: no geometry, pixel region, percent region, max, width-only, height-only, confined, percent scale, mirror/right-angle rotate, arbitrary rotate, gray, and bitonal. Add a doc-hidden `Executor.execute_neutral/3` entry that shares the production preamble and calls `run_neutral/4` for each pipeline, but is not yet selected by `execute/3`. Execute each Plan through `Executor.execute/3` with `resolver: NeutralResolver` for the injected dynamic arm and through `execute_neutral/3` with `resolver: nil` for the fixed arm. Keep that explicit plan split after activation so the test never becomes fixed-versus-fixed. Compare emitted stages for a recording run, final dimensions/state, output pixels, and tagged transform/decode errors. Keep the corpus product-neutral; do not add TwicPics operations or `:deferred` markers.
- [ ] **Step 1b: Cross-run the shared preamble.** Add a `seed_orientation: true` case over a committed non-identity EXIF source and an embedded-profile import case. Assert each arm seeds and consumes the preamble once, and compare pending orientation, color carry/stamp, final state, pixels, and dimensions. Exercise the existing input-color-management failure fixture if available and require the same `{:decode, _}` mapping on both arms.
- [ ] **Step 2: Add routing tests.** A `%Plan{resolver: nil}` must enter the fixed seam. A Plan with an explicit probe resolver must still enter `run/5`; use the existing injected `Probe` strategy so Phase 2C behavior remains covered. Add an IIIF wire assertion that a normal IIIF request reaches the fixed seam without changing status, headers, dimensions, or pixels. In `request_runner_test.exs`, use `no-cache explicit output returns a prepared stream delivery` as the named nil-resolver caller. Keep `cache miss executes semantic plan after fetch and stores under original key` unchanged with its explicit `resolver: NeutralResolver`.
- [ ] **Step 3: Mutation RED.** Temporarily make the fixed entry return `{:error, {:transform, :fixed_driver_probe}}`. The nil-resolver executor case, IIIF case, and named no-cache runner case must fail. The explicit-probe executor case and explicit-NeutralResolver cache-miss runner case must stay green through injected `run/5`. Revert. Don't remove the runner's explicit resolver; its later removal is a Phase 2C inventory row.
- [ ] **Step 4: Activate routing.** Refactor the shared execution preamble once, then have `execute/3` select `execute_neutral/3` when `plan.resolver == nil` and the existing injected path otherwise. Do not change the `Plan` struct, cache material, or strategy initialization.
- [ ] **Step 5: Run focused GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/neutral_driver_cross_run_test.exs test/image_pipe/transform/executor_test.exs test/image_pipe/transform/resolved_plan_golden_test.exs test/parser/iiif/plan_builder_test.exs test/parser/iiif_wire_test.exs test/image_pipe/request_runner_test.exs`
- [ ] **Step 6: Run the required pre-retirement nets while `Parser.TwicPics` is still live:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/parser/iiif_wire_test.exs test/image_pipe/plug_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twicpics_cross_arm_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs`
- [ ] **Step 7: Commit:** `transform: route neutral Plans through the fixed driver`.

Keep `execute_neutral/3` and `run_neutral/4` internal to `ImagePipe.Transform.Executor`. Do not add a second plan-execution facade or export to `ImagePipe.Transform`; production callers continue through `Transform.execute_plan/3`.

**CHECKPOINT A:** Run `mise run precommit`. Do not start coverage migration unless it passes and the immutable baseline gate is clean.

## Part 2 — move framework-generic coverage off TwicPics

### Task 3: Repoint the 22 generic Plug cases

**Files:**

- Create: `test/support/image_pipe/test/automatic_iiif_parser.ex`
- Modify: `test/image_pipe/plug_test.exs` — exactly the 22 cases and 23 parser references listed in the Phase 1 inventory

IIIF does not emit `%Plan.Output{mode: :automatic}`. Preserve the automatic-output Plug contract with a test-only host parser: it implements `ImagePipe.Parser`, delegates option validation, parsing, and error handling to `ImagePipe.Parser.IIIF`, and changes only a successful image Plan's output mode to `:automatic`. It must leave source, pipelines, response, render, `auto_rotate`, and `resolver: nil` untouched. Use plain IIIF for cases that do not require automatic output. This is test infrastructure, not a production parser or dialect.

- [ ] **Step 1: Add focused tests for the test-only parser.** Prove it delegates invalid IIIF input unchanged and changes only output mode for a valid image Plan. A temporary `Parser.IIIF.parse/2` failure must fail both.
- [ ] **Step 2: Repoint all 22 cases.** Preserve each assertion body and source/cache/error probe. Translate the TwicPics URL to the corresponding IIIF URL. Use `AutomaticIIIFParser` only for the automatic-source-format, `Vary`, negotiation, automatic-cache-key, modern-format, materialization, and cache-write cases. The matching-`Accept` test moves both mounts together.
- [ ] **Step 3: R-IIIF mutation.** Temporarily return a tagged parse failure from `Parser.IIIF.parse/2`. Every repointed case selected for this batch must fail before origin/cache work. Revert.
- [ ] **Step 4: Run GREEN and census:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/plug_test.exs`
  `rg -n 'ImagePipe\.Parser\.TwicPics' test/image_pipe/plug_test.exs`
  The grep must return no matches.
- [ ] **Step 5: Commit:** `test: move generic Plug coverage onto IIIF Plans`.

### Task 4: Repoint CDN cache and request-safety coverage

**Files:**

- Modify: `test/image_pipe/cdn_http_cache_wire_test.exs`
- Modify: `test/image_pipe/request_safety_test.exs`
- Reuse: `test/support/image_pipe/test/automatic_iiif_parser.ex` if an automatic-output case requires it
- Create: `test/support/image_pipe/test/guided_iiif_parser.ex`

- [ ] **Step 1: Repoint the first 19 CDN cases to IIIF.** Preserve public cache headers, conditional GET/HEAD, `Vary`, cookie, freshness, CORS, disposition, detector identity, cache-sink fail-open, and focal-gravity assertions. Use direct IIIF where possible and the automatic-IIIF test parser only where `Vary: Accept` is the asserted contract. IIIF has no focal or face-assist URL term, so add a second test-only host parser that delegates to IIIF and replaces one real guided-crop operation's guide with a product-neutral focal or `{:smart, :face_assist}` guide selected by the test request. Use it only for the focal ETag and detector-identity cases. It must keep `resolver: nil`; focused helper tests must prove delegation, the exact guide rewrite, and failure when IIIF parsing fails. Do not call dialect internals.
- [ ] **Step 2: Delete only** `TwicPics carried-focus cover emits an etag on the strong-identity path`. Cite the surviving dialect wire lifecycle, strong ETag, detector-identity, focus/carry cases, and `test/image_pipe/dialect/twic_pics_contract_test.exs`. Unique behavior: none.
- [ ] **Step 3: Repoint** `invalid composition parser failures return before source identity, cache lookup, and origin` to malformed IIIF input without changing its side-effect probes.
- [ ] **Step 4: R-IIIF mutation and GREEN.** For the already-invalid request-safety paths, mutate IIIF's error to `:not_found` and assert the repointed case changes from its expected 400/`bad request` to 404 while all source/cache probes remain untouched. A generic 400 parse failure is not sufficient RED evidence.
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/request_safety_test.exs`
- [ ] **Step 5: Confirm no TwicPics parser remains in either file and commit:** `test: move framework cache and safety coverage onto IIIF`.

## Part 3 — remove legacy oracles from surviving dialect tests

### Task 5: Make Pipeline and PointFlow tests dialect-local

**Files:**

- Modify: `test/image_pipe/dialect/twic_pics/pipeline_test.exs`
- Modify: `test/image_pipe/dialect/twic_pics/point_flow_test.exs`

- [ ] **Step 1: Repoint Pipeline cases.** Remove `Parser.TwicPics.PlanBuilder` and `Transform.execute_plan/3` from the focus/multiple-consumer pixels, auto-focus plus region crop, pending EXIF flush, and detector-mode cases. Keep their frozen expected pixels and event sequences. Construct only dialect `Request`/step inputs that `RequestBuilder` really emits.
- [ ] **Step 1b: Add a green local #464 behavior pin without touching the quarantine.** Drive the literal `resize=50p/resize=340` dialect steps over the committed 400×400 source and assert the current local result remains 200×200. This test protects Phase 2A from accidentally implementing TwicPics' documented shadow rewrite, while the hosted 340×340 fixture stays excluded under the unchanged `:twicpics_triage` record. Cite the official [TwicPics transformation documentation](https://www.twicpics.com/docs/reference/transformations).
- [ ] **Step 1c: Port the 16-cell pending-orientation pixel matrix before deleting its framework fixture.** Move the EXIF 2/4/6/7 × four odd/even crop-extent center-bias regression from `transform/focus_test.exs` into `dialect/twic_pics/pipeline_test.exs`, expressed through real dialect steps and `Pipeline.run/4`. Keep the exact pixel expectations. Mutation-test the center-bias or flush-placement branch so this is `R-PIPELINE` evidence, not a copied green test.
- [ ] **Step 2: R-PIPELINE mutation.** Temporarily return a transform error from `Dialect.TwicPics.Pipeline.run/4`; every repointed Pipeline case must fail. Revert.
- [ ] **Step 3: Repoint PointFlow cases.** Compare an ordinary operation directly with `Transform.NeutralResolver`. For staged cover and pending-orientation cover, assert explicit operation batches, continuation/measurement shape, and carried point; remove every `LegacyResolver` call.
- [ ] **Step 4: R-POINT mutation.** Break the relevant `PointFlow` advance/bind clause; all three repointed cases must fail. Revert.
- [ ] **Step 5: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/twic_pics/pipeline_test.exs test/image_pipe/dialect/twic_pics/point_flow_test.exs`
- [ ] **Step 6: Commit:** `test: remove legacy TwicPics oracles from dialect execution tests`.

### Task 6: Remove transition-only fixtures and framework focus tests

**Files:**

- Modify: `test/image_pipe/dialect/twic_pics/request_builder_test.exs`
- Modify: `test/image_pipe/dialect/twic_pics/request_test.exs`
- Modify: `test/image_pipe/transform/focus_test.exs`

- [ ] **Step 1: Delete synthetic anti-tautology inputs** containing `Parser.TwicPics.Resolver`, a fake `resolver` map field, or `Operation.Directive` traversal. Keep the positive recursive forbidden-vocabulary scan over every real dialect request. Cite that real producer scan; the synthetic values are not dialect outputs.
- [ ] **Step 2: Delete the seven `plan_cell/1` cases, their parser-resolver fixture, and the now-ported 16-cell pending-orientation matrix** from `focus_test.exs`. Cite dialect PointFlow, Pipeline, wire focus/carry, EXIF cases, and Task 5's exact matrix port. Keep all product-neutral rational focus helpers and tests. Unique behavior after the port: none.
- [ ] **Step 3: Run GREEN and a parser-reference census:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/twic_pics/request_builder_test.exs test/image_pipe/dialect/twic_pics/request_test.exs test/image_pipe/transform/focus_test.exs`
- [ ] **Step 4: Commit:** `test: remove TwicPics transition-only strategy fixtures`.

## Part 4 — move every live TwicPics consumer

### Task 7: Move differential tools and parse gates to the dialect

**Files:**

- Modify: `test/support/image_pipe/test/twicpics_differential/harness.ex`
- Modify: `test/support/mix/tasks/twicpics.gen_fixtures.ex`
- Modify: `test/image_pipe/twicpics_differential/constellations_test.exs`
- Verify: `test/support/mix/tasks/twicpics.diagnose.ex`
- Verify: `test/support/mix/tasks/twicpics.gen_report.ex`

- [ ] **Step 1: Make `Harness.plug_opts/0` initialize the dialect by default.** Keep the temporary `plug_opts(:framework)` and `plug_opts(:dialect)` selectors only while dual-arm callers remain. `diagnose` and `gen_report` must now render the dialect through their existing zero-arity call.
- [ ] **Step 2: Replace the generator parse gate.** Validate config once with `ImagePipe.Dialect.TwicPics.init/1`, then call `ImagePipe.Dialect.TwicPics.parse/2` for every non-triaged constellation before `resolve_sources/1`, network access, directory writes, or oracle calls. Do not invoke the task against the network.
- [ ] **Step 3: Move the constellation parse test** to the same dialect init/parse seam and rename it accordingly. Keep the 39-case verdict census and #464 triage assertion unchanged.
- [ ] **Step 4: R-PARSE mutation.** Temporarily return `{:error, :phase2a_parse_probe}` from `Dialect.TwicPics.parse/2`. The constellation parse test and the generator's existing `run_with/2` pre-side-effect test must fail before any fake network/write probe. Revert.
- [ ] **Step 5: R-HARNESS mutation.** Temporarily make zero-arity `Harness.plug_opts/0` invalid. Focused diagnose/report tests or smoke commands must fail; revert.
- [ ] **Step 6: Run GREEN without network:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential/constellations_test.exs test/image_pipe/twicpics_differential/gen_fixtures_test.exs`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_gen_report_test.exs --include twicpics_report`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix twicpics.diagnose --failing`
- [ ] **Step 7: Prove the remaining data-only tool rows.** Run `test/image_pipe/twicpics_differential/source_hosting_test.exs`, `manifest_test.exs`, and `test/image_pipe/twicpics_source_inventory_test.exs`. Temporarily fail `GenFixtures.run_with/2`, `SourceHosting.resolve!/3`, and `Manifest.load!/1`, and make `SourceInventory.all/0` empty; each named focused test must fail, then return GREEN after revert.
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential/gen_fixtures_test.exs test/image_pipe/twicpics_differential/source_hosting_test.exs test/image_pipe/twicpics_differential/manifest_test.exs test/image_pipe/twicpics_source_inventory_test.exs`
- [ ] **Step 8: Disposition `Twicpics.Reauthor` without executing it.** It already depends only on `Constellations` and `Manifest` and has no parser or harness caller to migrate. Verify that with `rg -n 'Parser|Harness|Dialect' test/support/mix/tasks/twicpics.reauthor.ex`, which must return no matches. Its `Manifest.load!/1` behavior is covered by the manifest mutation above. Do not run the task because Phase 2A forbids any manifest write.
- [ ] **Step 9: Run the immutable baseline gate and commit:** `test: move TwicPics differential tooling onto the dialect`.

### Task 8: Move the fiddle mount and request call

**Files:**

- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`
- Modify: `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex`
- Modify: `fiddle/assets/twicpics-path.ts` only to replace the stale parser-path comment
- Modify: `fiddle/test/image_pipe_fiddle_web/wire_test.exs`

- [ ] **Step 1: Add RED cases to `wire_test.exs`** for a representative `/twic/images/dog.jpg?twic=v1/cover=200x200/output=jpeg` request and the same request with `/debug=1`. Assert status, JPEG content type, 200×200 decoded dimensions, and the existing debug-header opt-in behavior.
- [ ] **Step 2: Replace `ImagePipe.Plug.init(parser: Parser.TwicPics, …)`** with `ImagePipe.Dialect.TwicPics.init/1`; retain the source adapter, debug-header opt-in, and cache option. Change the web module to call `ImagePipe.Dialect.TwicPics.call/2`.
- [ ] **Step 3: R-DIALECT mutation.** Temporarily fail `Dialect.TwicPics.call/2`; the focused fiddle endpoint test must fail. Revert.
- [ ] **Step 4: Run the full fiddle gate:** `mise run precommit:fiddle`.
- [ ] **Step 5: Verify and commit:**
  `git diff --exit-code origin/main -- fiddle/mix.lock`
  `git status --short fiddle/mix.lock`
  The lockfile commands must show no change. Commit `fiddle: mount TwicPics through the dialect` without staging `fiddle/mix.lock`.

**CHECKPOINT B:** Run `mise run precommit`, the immutable baseline gate, and the focused TwicPics differential file before removing either comparison arm.

## Part 5 — collapse comparison coverage, then retire the parser

### Task 9: Collapse wire and telemetry coverage to one dialect arm

**Files:**

- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs`
- Modify: `test/image_pipe/twic_pics_telemetry_contract_test.exs`

- [ ] **Step 1: Keep the 49 original wire cases and 10 lifecycle cases once.** Replace the generated framework/dialect module loop with one dialect module and flat dialect options. Delete the nine `CrossArm` comparisons, citing the surviving 59 dialect cases plus `TwicPicsContractTest`, error, lifecycle, and request-builder suites. Unique behavior: none after a single serving arm.
- [ ] **Step 2: Repoint six telemetry scenarios**—cache miss, cache hit, 304, parse error, streamed failure, and owner cancellation—to one dialect run and explicit semantic expectations. Keep their private telemetry prefixes, cleanup, event ordering, result/error metadata, and the three pure normalizer tests. Delete only framework option builders and arm-comparison helpers.
- [ ] **Step 3: R-DIALECT mutation.** Fail `Dialect.TwicPics.call/2`; all 59 wire cases selected by the test helper and the six telemetry cases must fail. Revert.
- [ ] **Step 4: Run GREEN and census:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs test/image_pipe/dialect/twic_pics_contract_test.exs`
  `rg -n 'CrossArm|:framework|ImagePipe\.Parser\.TwicPics' test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs`
- [ ] **Step 5: Commit:** `test: collapse TwicPics wire and telemetry nets to the dialect`.

### Task 10: Collapse the SaaS net and delete exact local comparison

**Files:**

- Modify: `test/image_pipe/twicpics_differential_conformance_test.exs`
- Modify: `test/support/image_pipe/test/twicpics_differential/harness.ex`
- Delete: `test/image_pipe/twicpics_cross_arm_conformance_test.exs`

- [ ] **Step 1: Collapse the conformance file to one render per authored constellation.** Use `Harness.plug_opts/0`. Keep all 39 authored entries, all five monitored divergence bands, the default render census, manifest-authorship assertions, tolerance logic, libvips drift hints, and the excluded #464 triage case unchanged. Only arm multiplication and arm labels disappear.
- [ ] **Step 2: Delete the exact local comparator and order self-check.** Cite the surviving dialect SaaS lane, wire order cases, `request_builder_test.exs` literal-order assertions, and `pipeline_test.exs` event ordering. Unique behavior: none; the Phase 1 exact equality gate is the durable transition record.
- [ ] **Step 3: Remove `Harness.plug_opts/1`** only after the conformance and exact-cross-arm callers are gone. Keep one zero-arity dialect initializer and existing render helpers.
- [ ] **Step 4: R-HARNESS mutation.** Break the zero-arity dialect harness. The conformance census and representative equal/diverges cases must fail. Revert.
- [ ] **Step 5: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twicpics_differential/constellations_test.exs`
  Expected census: one local render for each of 38 default cases plus one excluded #464 case; the authored 34 equal/5 diverges split remains unchanged.
- [ ] **Step 6: Run the immutable baseline gate and commit:** `test: collapse TwicPics SaaS coverage to the dialect`.

### Task 11: Delete parser-owned tests with surviving-coverage citations

**Files:**

- Delete: `test/parser/twic_pics_test.exs`
- Delete: `test/parser/twic_pics/{manipulation,output,path,plan_builder,units}_test.exs`
- Delete: `test/image_pipe/parser/twic_pics/{resolver,point_flow}_test.exs`
- Delete: `test/image_pipe/dialect/twic_pics/leaf_grammar_parity_test.exs`
- Modify: `test/image_pipe/cache/key_test.exs`
- Create: `test/support/image_pipe/test/resolver_version_probe.ex` only if the resolver-material test needs a replacement module fixture

Deletion ledger—repeat these citations in the commit body:

| Deleted coverage | Surviving coverage | Unique behavior |
| --- | --- | --- |
| 25 PlanBuilder cases | matching `legacy:` cases in `dialect/twic_pics/request_builder_test.exs`, including the quarantine chain | none; Phase 1 recorded 0/25 RED then 25/25 GREEN |
| 8 Resolver + 4 PointFlow cases | `dialect/twic_pics/point_flow_test.exs`, now independent of `LegacyResolver` | none; Phase 1 recorded missing-module RED then 12-case GREEN |
| 45 leaf grammar cases | matching `dialect/twic_pics/{manipulation,output,path,units}_test.exs` cases | none; Phase 1 recorded 0/48 RED then dialect GREEN |
| 2 leaf parity cases | direct dialect leaf suites | none; completed copy-fidelity transition |
| 7 parser wrapper cases | dialect parse, errors, and config suites | none |
| Parser autoquality case | `dialect/twic_pics/config_test.exs` mount-time size-autoquality rejection | already ported with production mutation RED in Phase 1 |
| 3 carried-focus cache-key cases | `Dialect.TwicPics.Identity`, dialect cache-key contract, wire storage identity and focus/carry cases | none |
| arithmetic/ratio cache-key cases built only through legacy PlanBuilder | `dialect/twic_pics/identity_test.exs` normalized arithmetic/ratio identity cases | none; product canonicalization now belongs to dialect identity |

- [ ] **Step 1: Delete the parser-owned test trees and leaf parity file** only after Tasks 5–10 are green.
- [ ] **Step 2: Remove legacy PlanBuilder fixtures from cache-key tests.** Delete the carried-focus and parser-canonicalization cases with the ledger citations. Don't change the three resolver-material/version assertions or `R-CACHE` semantics. Replace the TwicPics resolver fixture with a small top-level module in `resolver_version_probe.ex` that implements the same `behavior_version/0` contract. Only the expected strategy module atom changes; keep the `[strategy: module, version: integer]` shape and version behavior pinned. Phase 2C owns their absence rewrite.
- [ ] **Step 3: Run surviving coverage and cache tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/twic_pics test/image_pipe/cache/key_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs`
- [ ] **Step 4: Commit:** `test: retire parser-owned TwicPics coverage` with the deletion ledger in the commit body.

### Task 12: Delete `ImagePipe.Parser.TwicPics`

**Files:**

- Delete: `lib/image_pipe/parser/twic_pics.ex`
- Delete: `lib/image_pipe/parser/twic_pics/{manipulation,output,path,plan_builder,point_flow,resolver,source,units}.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Modify: product comments in `lib/image_pipe/transform/focus.ex`, `lib/image_pipe/transform/neutral_resolver.ex`, `lib/image_pipe/resolver.ex`, and `lib/image_pipe/dialect/imgproxy/config.ex` only where they name the retired TwicPics parser

- [ ] **Step 1: Delete the parser production tree.** Do not edit `ImagePipe.Parser`, the Resolver Boundary, Plan resolver validation, Directive, deferred guides, cache resolver material, or the injected executor path.
- [ ] **Step 2: Remove the exact Parser.TwicPics Boundary entry/assertion.** Keep `Parser.IIIF` and the dialect's exact dependency/no-export/no-framework-reference gates. Do not relax parser semantic-operation scans or host-parser boundaries to make deletion compile.
- [ ] **Step 3: De-productize stale SDK comments only.** Keep the SDK contract intact, but stop naming a deleted in-tree TwicPics implementation as a live example. Do not perform the Phase 2C documentation rewrite.
- [ ] **Step 4: Compile and run architecture plus sole-stack tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/architecture_boundary_test.exs test/parser/iiif_wire_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs`
- [ ] **Step 5: Run the code/test parser-retirement negative gate:**
  `rg -n 'ImagePipe\.Parser\.TwicPics|Parser\.TwicPics|TwicPicsResolver|LegacyResolver' lib test fiddle`
  It must return no matches. Task 13 clears the enumerated live documentation references separately.
- [ ] **Step 6: Prove Phase 2C stayed out of scope:**
  `rg -n 'defmodule ImagePipe\.Resolver|@behaviour ImagePipe\.Resolver|resolver:|:deferred|Operation\.Directive' lib/image_pipe lib/image_pipe/plan.ex test/image_pipe/cache/key_test.exs`
  Expected: the strategy SDK, cache material, marker, Directive, and Plan field remain.
- [ ] **Step 7: Commit:** `refactor: retire the TwicPics framework parser`.

## Part 6 — document the sole TwicPics stack

### Task 13: Update support, operation, and tooling documentation

**Files:**

- Modify: `docs/twicpics_support_matrix.md`
- Modify: `docs/cdn-http-cache.md`
- Modify: `docs/debug_headers.md`
- Modify: `docs/custom_parser_guide.md`
- Modify: `docs/execution_flow.md`
- Modify: `test/support/image_pipe/test/twicpics_differential/README.md`
- Modify: `AGENTS.md` only to remove stale claims that the retired TwicPics parser is a live marker/strategy example; retain the general marker-accretion rule and `:deferred` guidance for Phase 2C

- [ ] **Step 1: Make the support matrix dialect-only.** Remove Phase 1 comparison-arm prose and change differential descriptions from two local arms to one dialect render. Preserve the #464 quarantine text, 200×200 local answer, hosted 340×340 fixture, all five divergence bands, and the `output=auto` gap. Do not claim closer compatibility.
- [ ] **Step 2: Fix live mount examples.** `cdn-http-cache.md` and `debug_headers.md` must initialize/call `ImagePipe.Dialect.TwicPics` directly with flat config. Preserve the observable cache/debug behavior in each example.
- [ ] **Step 3: Update execution and host-parser docs narrowly.** `execution_flow.md` must show nil-resolver Plans using the fixed neutral driver, explicit resolver Plans retaining the injected path until Phase 2C, IIIF staying on `ImagePipe.Plug`, and TwicPics bypassing parser dispatch through its local Pipeline/PointFlow. `custom_parser_guide.md` must keep host parsers ending in product-neutral Plans and must not advertise private dialect modules. Keep its still-live strategy SDK sections for Phase 2C, but replace all retired `Parser.TwicPics` examples with honest host-parser or IIIF examples.
- [ ] **Step 4: Update the differential README.** Describe a single local dialect render and change the stale “ImagePipe's TwicPics parser” wording. Replace “current parser,” “both local arms,” and deleted “parser unit/wire tests” references with the surviving dialect coverage and Phase 2B ownership. Keep bake, reauthor, tolerance, quarantine, source-hosting, and fixture procedures unchanged.
- [ ] **Step 5: Clean the AGENTS example without retiring the rule.** Remove the claim that TwicPics currently carries `:deferred` in a root Plan. Do not delete the marker-accretion test, `:deferred` vocabulary, or the Phase 2C work item.
- [ ] **Step 6: Run Vale:**
  `vale docs/twicpics_support_matrix.md docs/cdn-http-cache.md docs/debug_headers.md docs/custom_parser_guide.md docs/execution_flow.md test/support/image_pipe/test/twicpics_differential/README.md AGENTS.md`
- [ ] **Step 7: Run documentation/live-reference gates:**
  `rg -n 'ImagePipe\.Parser\.TwicPics|Parser\.TwicPics|temporary framework|both temporary local|each local arm' lib test fiddle docs AGENTS.md --glob '!docs/superpowers/**'`
  `rg -n 'both local arms|current parser|parser unit/wire tests' test/support/image_pipe/test/twicpics_differential/README.md`
  Both negative greps must return no matches.
  `rg -n 'resize_shadow_relative_then_absolute|#464|output=auto|five accepted divergences|five monitored' docs/twicpics_support_matrix.md test/support/image_pipe/test/twicpics_differential/README.md test/support/image_pipe/test/twicpics_differential/constellations.ex`
- [ ] **Step 8: Run the immutable baseline gate and commit:** `docs: describe the sole TwicPics dialect stack`.

## Part 7 — Phase 2A exit proof

### Task 14: Run the full exit gate and review the final diff

- [ ] **Step 1: Run focused fixed-driver/framework tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/neutral_driver_cross_run_test.exs test/image_pipe/transform/executor_test.exs test/image_pipe/transform/resolved_plan_golden_test.exs test/parser/iiif test/parser/iiif_wire_test.exs test/image_pipe/plug_test.exs test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/request_safety_test.exs`
  Confirm the cross-run file still compares `resolver: NeutralResolver` through injected `run/5` with `resolver: nil` through the fixed path after activation.
- [ ] **Step 2: Run sole-stack TwicPics tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/twic_pics test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twicpics_differential test/image_pipe/twicpics_source_inventory_test.exs`
- [ ] **Step 2b: Re-run the tagged no-network report consumer:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_gen_report_test.exs --include twicpics_report`
- [ ] **Step 3: Run full repository gates:**
  `mise run precommit`
  `mise run precommit:fiddle`
- [ ] **Step 4: Run final invariants:** immutable baseline gate; `fiddle/mix.lock` clean; parser-retirement negative grep empty; strategy-SDK positive grep non-empty; no cross-arm selectors in the TwicPics harness/wire/differential files.
- [ ] **Step 5: Inspect the diff:**
  `git diff --check origin/main...HEAD`
  `git diff --stat origin/main...HEAD`
  `git status --short`
  Confirm no fixture/source/manifest/report bytes, constellation authorship, or lockfile entered any commit.
- [ ] **Step 6: Run a final parallel review** over the complete implementation diff with the same four lenses used for this plan: fixed-driver architecture, coverage/deletion/host-parser boundary, real TwicPics observable compatibility plus committed SaaS net, and operational/fiddle feasibility. Apply accepted findings in separate focused commits and repeat the affected gates.

## Execution recommendation

Execute Tasks 1–14 inline in order, then use parallel agents only for the final complete-diff review. The fixed-driver activation, framework repoints, consumer migration, harness collapse, and parser deletion form a dependency chain across shared test helpers; incremental TDD and green commit boundaries give clearer failure attribution than subagent-per-task handoffs. The compatibility and operational reviews are independent once the full diff exists.

<!-- vale on -->
