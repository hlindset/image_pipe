# imgproxy dialect inversion — phase 2, wave 2: retire `Parser.Imgproxy` (§A) + C1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the framework imgproxy parser (`ImagePipe.Parser.Imgproxy`, 19 files) so `ImagePipe.Dialect.Imgproxy` becomes the sole imgproxy implementation, migrate every test/doc/fiddle surface that referenced it, retire the `{:effective, …}` marker, then land C1 (collapse the unobservable two-fallback padding/canvas distinction).

**Architecture:** All new dialect-side coverage (ports) and all re-points land **while the framework parser still exists**, each commit green. The `lib/` deletion is then a small, atomic, grep-gated commit. Cleanup (marker, ExDNA, docs, fiddle) and C1 follow. This is the one-way step: after Task 22, recovering the framework arm means reverting the branch.

**Tech Stack:** Elixir/ExUnit/StreamData, mise toolchain, libvips via Vix.

**Spec:** `docs/superpowers/specs/2026-07-16-imgproxy-dialect-phase2-design.md` §"Wave 2" + §"Wave 3 — C1" (decisions P1–P10). Backlog: `docs/imgproxy_dialect_phase2_backlog.md` §A, §C1.

## Global Constraints

- **Toolchain:** every mix command runs as `export PATH="$(mise where elixir)/bin:$PATH" && mix …`. Plain `mise exec -- mix` resolves to the Homebrew 1.19.3 shadow and false-fails. `mise run precommit` already embeds the correct PATH.
- **No differential re-bake** (P10): `git status test/support/image_pipe/test/imgproxy_differential/` stays clean for the whole wave. A differential failure is a dialect bug, never a fixture problem.
- **Never commit `fiddle/mix.lock`** (it is already dirty in the worktree; leave it).
- **No state-mutating git in subagents** (no stash/checkout/reset — worktrees share one stash stack).
- **Deletion evidence discipline:** before deleting or re-pointing a test, cite the surviving test that asserts the same behavior (file + test name), or state that it pins impossible misuse / a completed transition. Every **ported** test needs proof it can fail: a RED run before the port target existed, or a temporary mutation of the code under test shown red then reverted.
- **Full gate per batch:** run `mise run precommit` (dialyzer + ExDNA included) at the checkpoints marked below, not only at the end.
- **Un-expected greens are stop signals:** a test expected RED that passes immediately means the gap analysis was wrong — investigate, don't celebrate.
- **Branch rename before first push:** `git branch -m feat/imgproxy-retire-framework-parser` (rename only the branch, never move the worktree).
- **Commit message trailer:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Flagged decisions (defaults chosen; user may override at the go-ahead checkpoint)

1. **Fiddle `allow_debug_headers`** — the dialect has no debug-header support (`lib/image_pipe/dialect/imgproxy.ex` `@debug_info nil`; its `Config.validate!/1` rejects the key). The dialect grammar *parses* `debug:1` (option_grammar.ex:81), so fiddle previews keep rendering; only the `X-ImagePipe-*` headers disappear on the imgproxy mount. **Default (Task 25): drop the key from the imgproxy mount; the fiddle's DebugInfoPanel shows its empty state for that mount; note it in the mount comment and `docs/debug_headers.md`.** Implementing dialect debug support is out of scope (not in the settled spec).
2. **Resolve-driver golden retirement** — the spec says "re-point `resolved_plan_cases.ex` at the dialect", but the golden runs `ImagePipe.Transform.execute_plan/3` (the framework transform path the dialect never uses) over `Imgproxy.parse`-built `%Plan{}`s, several carrying the `{:effective, …}` marker + `ImgproxyResolver`. A literal re-point is impossible (the dialect produces no `%Plan{}`). **Default (Task 8): retire the recording-driven golden + `ResolvedPlanCases` + `resolved_plan_expected.exs` as a completed-transition pin (the resolve-driver cutover landed; op-shapes like trim/padding have no surviving `%Plan{}` producer), keep/rewrite the hand-built describes that pin still-live core Executor behavior.** The compatibility reviewer must confirm this loses no imgproxy-observable coverage (the dialect arms of wire/differential own that contract).

---

## Part 1 — new dialect coverage (framework still alive; Tasks 1–8)

### Task 1: Re-anchor `/info` wire oracle to a committed golden

**Files:**
- Modify: `test/image_pipe/dialect/imgproxy/info_wire_test.exs` — **three** `framework_get/2` call sites (:135 main body parity, :177 EXIF swapped-dims parity, :425 non-image 415 parity) plus the `framework_get/2` helper and `framework_opts` (~:124). Checkpoint B's grep does not exclude this file, so no `Parser.Imgproxy` reference may survive.

The tests currently use the framework arm as a body-equality oracle. Re-anchor while the framework arm is still alive to print goldens.

- [ ] **Step 1: Capture the framework body for the main parity test (:135).** Temporarily add `IO.inspect(Jason.decode!(framework_body), label: :info_golden)`, run, copy the decoded map:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/imgproxy/info_wire_test.exs`
- [ ] **Step 2: Rewrite the main test** to assert `Jason.decode!(dialect_body) == @info_golden` with the captured map as a module attribute literal (fields are source-derived only — format, mime_type, width, height, orientation; `size` is already refuted — so the golden is environment-stable). Keep the test name honest (e.g. `"the /info body matches the committed golden (baked from the framework arm pre-retirement)"`).
- [ ] **Step 3: De-oracle the other two sites.** The EXIF-swap test (:177) already carries independent assertions (:182–184 `orientation == 6`, `width == 80`, `height == 40`) and the non-image test (:425) asserts `status == 415` — drop their `framework_get` calls and body-equality lines, keep the standalone assertions. Then delete the `framework_get/2` helper and `framework_opts` entirely.
- [ ] **Step 4: Prove the golden can fail.** Temporarily flip one golden field (e.g. width +1), run, expect FAIL; revert.
- [ ] **Step 5: Run the file green; verify** `grep -c 'Parser.Imgproxy' test/image_pipe/dialect/imgproxy/info_wire_test.exs` → 0.
- [ ] **Step 6: Commit** `test: anchor dialect /info body to a committed golden (was framework-arm oracle)`.

### Task 2: Port neutral-Plan structural invariants onto `Assembly.operations/1`

**Files:**
- Create: `test/image_pipe/dialect/imgproxy/assembly_invariants_test.exs`
- Source of ported behavior: `test/parser/imgproxy/plan_builder_test.exs` (no-dialect-leak :944; objw canonicalization props :1372/:1386 + mappings :1323–1359; smart/`:face_assist`/detect guide mapping :844–1069; fixed op order :575, :623, :1414–1437)

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Imgproxy.Assembly.operations/1` (`%Request{} → [%ImagePipe.Plan.Operation.…{}]`); build `%Request{}`s the way `pipeline_assembly_test.exs` and `pipeline_carry_test.exs` already do (via the dialect grammar: `OptionGrammar`/`Options` — copy their request-builder helpers, do not hand-build structs no producer makes).
- Produces: the sole post-§A home for these invariants (currently last-covered by `pipeline_assembly_test.exs`, which Task 21 deletes).

Port only what nothing else covers. Wire/differential already pin the *pixel* behavior; these pin the *structural* invariants:

- [ ] **Step 1: Write the failing/mutation-proofed tests.** One test or property per invariant, asserting on `Assembly.operations(request)` output:
  1. `"operations emit only product-neutral guide terms"` — parse a `g:obj:face`/`g:sm`/`g:objw:…` request, assert every operation's guide is a neutral term (`{:detect, {_, _}}`, `{:smart, :face_assist}`, `:center`, …) and no dialect-private struct/atom leaks (mirror plan_builder_test:944's assertion body).
  2. objw canonicalization: the weights map is canonical (sorted, merged), plus the two StreamData properties ported verbatim in shape: `"objw canonicalization is order-independent"`, `"objw canonicalization is idempotent"`.
  3. smart / face-assist / detect guide mapping: `g:sm` → `{:smart, :face_assist}` only when `smart_crop_face_detection` is set; `g:obj:CLASSES` → `{:detect, {spec, nil}}`; `g:objw:…` → `{:detect, {spec, weights}}` (port the mapping table from plan_builder_test:844–1069, keeping only rows the wire suite's object-detection block doesn't already assert user-visibly).
  4. `"operation order is fixed regardless of URL option order"` — two permutations of the same option set produce the same operation-module sequence — **plus one canonical stage-sequence assertion** (a request exercising effects+geometry+canvas+padding+background produces the specific module order plan_builder_test pins at :288/:361/:376/:636; permutation-insensitivity alone doesn't pin *which* order).
  5. `mw:0`/`mh:0` mean "no minimum on that axis", distinct from unset (from pipeline_assembly_test:382) — first grep the wire/differential suites for an `mw:0` case; port only if none pins the distinction (the min-dim *math* survives in `transform/resize_dimension_test.exs:188` + `decode_preflight_test.exs:233`, but the zero-vs-unset assembly distinction may not).
- [ ] **Step 2: Prove each group can fail.** Temporarily mutate `Assembly` (e.g. swap two stages in its emission order; drop the weights sort) → relevant tests RED; revert.
- [ ] **Step 3: Run green.** `mix test test/image_pipe/dialect/imgproxy/assembly_invariants_test.exs`
- [ ] **Step 4: Commit** `test: port neutral-Plan structural invariants onto Dialect.Imgproxy.Assembly`.

### Task 3: Port preset-expansion internals onto the dialect

**Files:**
- Modify: `test/image_pipe/dialect/imgproxy/config_test.exs` or create `test/image_pipe/dialect/imgproxy/presets_test.exs`
- Source: `test/parser/imgproxy_test.exs` :1652–1907

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Imgproxy.Presets` + `Options` (the seam `options_test.exs`'s dialect arm already drives).

- [ ] **Step 1: Write the ported tests** (~7–10): recursive re-entry skip, indirect recursion, preset-references-preset expansion, default-preset-applies-before-URL-options precedence, same-offset cross-preset group merging, **missing/empty/unknown preset references → parse error** (from imgproxy_test.exs:1742 — the native twin `dialect/native/presets_test.exs:90` does not cover `Dialect.Imgproxy.Presets`), and **preset pipeline-group merging into trailing/default pipelines** (from :1781/:1821/:1839). Assert on the expanded `%Request{}`/pipelines. Only `pr:` == expansion *equivalence* is already covered (`test/image_pipe/dialect/imgproxy_contract_test.exs`) — do not duplicate it.
- [ ] **Step 2: Mutation evidence.** Temporarily break the recursion guard in `Dialect.Imgproxy.Presets` → recursion tests RED; revert.
- [ ] **Step 3: Run green; commit** `test: port preset-expansion internals onto Dialect.Imgproxy.Presets`.

### Task 4: Port generative order-insensitivity properties

**Files:**
- Create: `test/image_pipe/dialect/imgproxy/canonical_property_test.exs` (mirror `test/image_pipe/dialect/native/canonical_property_test.exs`'s structure)
- Source: `test/parser/imgproxy_property_test.exs` (6 properties)

- [ ] **Step 1: Write the properties** against the dialect grammar (`OptionGrammar`/`Options` → `%Request{}`):
  1. permutations of a mutually-compatible distinct-option segment list yield an equal `%Request{}`;
  2. last-wins for repeated options (later `w:` overwrites earlier; `rs:` meta-option overwrites by position);
  3. alias/order-equivalent dimension spellings (`rs:fit:W:H` vs `w:W/h:H/rt:fit`) yield equal requests.
  The two remaining framework properties are **deleted with citation**: "tagged results for arbitrary segments" (robustness/total-function property, subsumed by the relocated grammar tests, Task 20) and "segments after plain preserved as source path" (implicit in every wire `/plain/…` case + the relocated `path_test.exs`).
- [ ] **Step 2: Mutation evidence** (e.g. temporarily make `Options` keep first-wins) → RED; revert.
- [ ] **Step 3: Run green; commit** `test: generative canonicalization properties for the imgproxy dialect grammar`.

### Task 5: Singleton ports

**Files:**
- Modify: `test/image_pipe/dialect/imgproxy/config_test.exs` (signature explicit-nil)
- Modify: dialect InfoRenderer coverage (extend `test/image_pipe/dialect/imgproxy/info_wire_test.exs` or a focused InfoRenderer unit test)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (debug-tamper case, add to the signatures describe — it dual-runs until Task 18, which is fine)

- [ ] **Step 1:** Port `"rejects explicit nil signature config"` (from `test/parser/imgproxy/signature_test.exs:34`) onto `Dialect.Imgproxy.Config.validate!/1`. RED first if the dialect lacks the rejection; if it passes immediately, verify the config module really rejects it (read the code) before accepting the green.
- [ ] **Step 2:** Port `"reports imgproxy spellings for HEIC and JXL sources"` (from `test/image_pipe/parser/imgproxy/info_renderer_test.exs:29`) onto `ImagePipe.Dialect.Imgproxy.InfoRenderer` — only if no HEIC/JXL `/info` case exists in the dialect suites (grep first; cite if found and skip).
- [ ] **Step 3:** Port the debug-tamper signature case (from `test/image_pipe/debug_headers_wire_test.exs` "signature coverage" :326–350): injecting `debug:1` into a correctly signed imgproxy URL → 403. Signed-material tampering per se is covered (`dialect/imgproxy/mount_test.exs:190`, `info_wire_test.exs:191`); add this case only because `debug:1` sits in the signed processing-options segment — a distinct tamper vector.
- [ ] **Step 4:** Mutation/RED evidence per port as above; run the touched files; commit `test: port signature-nil, /info format-spelling, and debug-tamper singletons to the dialect`.

### Task 6: Re-anchor `color_carry_parity_test.exs`

**Files:**
- Modify: `test/image_pipe/dialect/color_carry_parity_test.exs`

- [ ] **Step 1:** Delete the `describe "imgproxy dialect vs framework arm, same URL"` (:126–147) — a parity pin whose transition completes with §A; dialect-imgproxy color-carry behavior is separately pinned by `test/image_pipe/dialect/imgproxy/pipeline_color_preamble_test.exs`.
- [ ] **Step 2:** Re-pair the `describe "native dialect"` (:149–162) oracle: replace the framework arm with the **dialect imgproxy** arm (both dialects share Decode/Transform/Output, so dialect-native vs dialect-imgproxy is a valid cross-implementation pairing for ICC-carry pixels). Remove the `ImagePipe.Parser.Imgproxy` reference.
- [ ] **Step 3:** Prove the re-paired test can fail (temporarily skew one arm's URL, e.g. drop the ICC option) → RED; revert. Run green; commit `test: re-pair color-carry parity onto the two dialects`.

### Task 7: Rewrite `imgproxy_resize_auto_test.exs` off `Request.Runner`

**Files:**
- Create: `test/image_pipe/dialect/imgproxy/resize_auto_wire_test.exs`
- Delete (same commit): `test/image_pipe/imgproxy_resize_auto_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Imgproxy.init/1` + `call/2` (flat config), the existing `GeneratedSourceAdapter` pattern (copy it from the old file — it is parser-agnostic).

The 7 dimension tests pin the **neutral** `resize:auto` fill-vs-fit bucketing (#233, promoted to `NeutralResolver` in #448) end-to-end on the imgproxy surface. Rewrite them as dialect wire tests:

- [ ] **Step 1: Write the new wire test.** Keep `GeneratedSourceAdapter` verbatim; drive full requests:
  ```elixir
  defp call_auto({sw, sh}, {tw, th}) do
    opts =
      ImagePipe.Dialect.Imgproxy.init(
        sources: [path: {GeneratedSourceAdapter, []}],
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000
      )

    conn(:get, "/unsafe/rt:auto/w:#{tw}/h:#{th}/f:jpeg/plain/generated/#{sw}x#{sh}.png")
    |> ImagePipe.Dialect.Imgproxy.call(opts)
  end
  ```
  The adapter's `resolve/3` must now work (the old test hand-built `%Resolved{}`; wire calls resolve for real) — note `resolve/3`'s first argument is a `%ImagePipe.Plan.Source{}` (not a conn/path): derive `{w, h}` from the source's path segments' basename and return a real `%ImagePipe.Source.Resolved{}` (reuse the old file's `resolved_source/1` body — `adapter: :path` + keyword identity satisfy `Source.validate_resolved/2`, which the wire path applies where the old `Runner.run` bypass did not). Assert `conn.status == 200` and decoded body dimensions equal the expected `{w, h}` for all 7 cases (same expectations as the old tests 1–7).
- [ ] **Step 2:** Delete the old file's `"host jxl_options lands on Plan.Output.encoder_options"` test with citation: neutral encoder-options derivation is covered by `test/image_pipe/config_test.exs` and `:jxl_options` key acceptance by `test/image_pipe/dialect/imgproxy/config_test.exs` — do not port.
- [ ] **Step 3:** RED evidence: the new file must fail if bucketing breaks — temporarily flip the neutral fill/fit rule (or assert a wrong dimension first, watch it fail, then correct). Run green.
- [ ] **Step 4:** `git rm test/image_pipe/imgproxy_resize_auto_test.exs`; commit `test: rework resize:auto coverage as dialect wire tests`.

### Task 8: Retire the resolve-driver golden's imgproxy corpus

**Files:**
- Modify: `test/image_pipe/transform/resolved_plan_golden_test.exs`
- Delete: `test/support/image_pipe/test/resolved_plan_cases.ex`, `test/support/image_pipe/test/resolved_plan_expected.exs`

Per flagged decision 2. What stays, what goes:

- [ ] **Step 1: Keep (untouched):** `describe "±1 divergence (synthetic, driver-seam injection)"` and `describe "staged continuation (spec §4.4 Stage 3)"` — hand-built plans, `NeutralResolver`, still-live Executor behavior serving IIIF/TwicPics.
- [ ] **Step 2: Rewrite `describe "identity-streaming guard"` hand-built:** replace `ResolvedPlanCases.record!/1` with a direct `Executor.run/5` (or `Transform.execute_plan/3` over a hand-built single-pipeline `%Plan{}` if `execute_plan` is the honest seam) using plan `[%PlanBlur{sigma: 2.0}]` over a decoded streamed source, asserting no flush token and `materialized? == false`. Mutation evidence: temporarily force a boundary flush in the scheduler → RED; revert.
- [ ] **Step 3: Delete** the recording-driven `describe "ResolvedPlan golden (old-path-baked, two-rule canonicalizer)"` and the now-unused `canonicalize/1` machinery (keep whatever the rewritten identity guard still uses), citing: completed-transition pin (moduledoc says "cross-implementation net" for the landed cutover); its imgproxy-only op streams (trim/padding `%Plan{}`s) have no surviving producer post-§A.
- [ ] **Step 4: Delete** `describe "imgproxy strategy carry survives a :measure (spec §8)"` citing: the surviving strategy carrier's carry-through-measure behavior is pinned by `test/image_pipe/parser/twic_pics/resolver_test.exs` (staged cover `:deferred` substitution across `{:measure, …}` seams, flush-fold carry tests) — the deleted test's subject was `ImgproxyResolver.rewrap/2` specifically, which dies with the parser.
- [ ] **Step 5: Delete** `resolved_plan_cases.ex` + `resolved_plan_expected.exs` (`git rm`), **and in the same commit** remove the golden test's module-level dependencies: `@expected ResolvedPlanCases.expected()` (:37), `alias ImagePipe.Test.ResolvedPlanCases` (:26), and `alias ImagePipe.Parser.Imgproxy.Resolver, as: ImgproxyResolver` (:20) — line :37 is a compile-time attribute and breaks compilation the moment the support file is gone. `test/support/mix/tasks/imgproxy.gen_fixtures.ex` does not reference them (its `validate_parses!` is Task 19's job).
- [ ] **Step 6:** Run the modified file + full transform tests: `mix test test/image_pipe/transform/` → green. Commit `test: retire the resolve-driver golden's imgproxy corpus (completed-transition pin)`.

**CHECKPOINT A:** `mise run precommit` green. Commit any fallout fixes separately.

---

## Part 2 — re-points (framework still alive; Tasks 9–16)

Re-point decision rule (apply per case): **repoint** to IIIF/TwicPics if the assertion is framework-`ImagePipe.Plug` machinery expressible via a surviving parser; **delete with citation** if the case's substance is imgproxy-optioned behavior the dialect suites pin; **port to the dialect suite** only if neither (rare — Task 5 caught the known ones). Where a wire path changes, keep the assertion body identical; only the URL/opts change.

### Task 9: Bare-module repoints (no URLs)

**Files:** `test/image_pipe/request/options_test.exs` (7 refs), `test/image_pipe/request_options_test.exs` (5), `test/image_pipe/source_test.exs` (2)

- [ ] **Step 1:** Replace every `parser: ImagePipe.Parser.Imgproxy` with `parser: ImagePipe.Parser.IIIF` (the parser is a required placeholder; assertions are about `allow_debug_headers`/`allow_origin` CRLF validation, `sources:`/`root_url` exclusivity, adapter config). No other edits.
- [ ] **Step 2:** `mix test test/image_pipe/request/options_test.exs test/image_pipe/request_options_test.exs test/image_pipe/source_test.exs` → green. Commit `test: repoint parser-placeholder option/source tests at IIIF`.

### Task 10: IIIF URL repoints — cache, telemetry, trace, baselines, runner

**Files:** `test/image_pipe/cache_test.exs` (3), `test/image_pipe/telemetry_test.exs` (4), `test/image_pipe/telemetry/trace/{open_telemetry_integration,materialize_span,inbound_plug,encode_span,cross_process}_test.exs` (7 total), `test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs` (1), `test/image_pipe/request/delivery_owner_cleanup_baseline_test.exs` (1), `test/image_pipe/request_runner_test.exs` (1), `test/image_pipe/shrink_on_load_test.exs` (2)

Precedent for IIIF wiring: `test/parser/iiif_wire_test.exs` (`/img/{identifier}/{region}/{size}/{rotation}/{quality}.{format}`, `iiif: [resolver: …]` opts). The trace files and baselines alias `ImgproxyWireConformanceTest.{OriginImage, CacheProbe}` — those fixture modules are defined at the top of the wire file **outside** the dual-run loop and survive Task 18; the aliases stay valid.

- [ ] **Step 1:** Per file: swap `parser:` to IIIF, translate URLs (`/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg` → the IIIF spelling of the same geometry, e.g. `/img/<id>/full/120,90/0/default.jpg` with a static resolver mapping `<id>` to the same fixture), and swap `metadata.parser == ImagePipe.Parser.Imgproxy` assertions (telemetry_test :197/:205/:299) to the IIIF module. `request/delivery_owner_cleanup_baseline_test.exs:107`'s `/unsafe/rs:fit:64:64/plain/…` translates the same way. `shrink_on_load_test.exs` translates its single-pipeline `w:`/`c:`/`rs:` geometry to IIIF `size`/`region` spellings that preserve the shrink factors under test (`c:2000:2000/rs:fit` → region `0,0,2000,2000` + size).
- [ ] **Step 1b — port, don't delete, the two chained `/-/` shrink tests** (shrink_on_load_test.exs:393 `#180` shrink-factor must not leak past the residual resize into a later pipeline, and :410 the no-shrink complement). Multi-pipeline `/-/` is imgproxy-dialect-specific and **no dialect/wire test currently exercises `decode_shrink` across a pipeline boundary** (`pipeline_scoping_test.exs` never sets it; `pipeline_carry_test.exs:356` pins padding-scale, not shrink). Write a dialect wire test (in `test/image_pipe/dialect/imgproxy/`, reusing Task 7's generated-source pattern or a large committed fixture): drive `rs:fit:500:500/-/c:200:200` over a shrink-triggering source and assert exact `{200, 200}` output, plus the no-shrink complement. Mutation evidence: temporarily make the dialect pipeline leak the shrink factor into the second pipeline's crop → RED; revert.
- [ ] **Step 2:** Per-file green runs. The telemetry files use private `telemetry_prefix`es — keep them.
- [ ] **Step 3:** Commit `test: repoint generic Plug/telemetry/trace suites at IIIF`.

### Task 11: Resolver-strategy swaps in transform tests

**Files:** `test/image_pipe/transform/executor_test.exs` (helper `imgproxy_plan/1` at :816 with `resolver: ImagePipe.Parser.Imgproxy.Resolver`, **8 call sites**: :154, :336, :357, :382, :661, :688, :725, :743), `test/image_pipe/transform/prefetch_validation_test.exs` (:18), `test/image_pipe/transform/deferred_orientation_frame_test.exs` (:77 resolver + :174 `{:effective, …}`)

The split is driven by the `{:effective, …}` padding marker, not cap math: a plan carrying the marker is resolvable **only** by `Imgproxy.Resolver` — it cannot be swapped to `NeutralResolver`.

- [ ] **Step 1 — executor_test.exs:** the three tests at :325–387 (call sites :336/:357/:382) hand-build `%Padding{pixel_ratio: {:effective, …}}` — **delete them** with citation (dialect-owned carry behavior, pinned by `dialect/imgproxy/pipeline_carry_test.exs`; the marker itself retires in Task 23). The remaining 5 call sites use the resolver as "a carried strategy"/plan metadata — swap those plans to `NeutralResolver` (or drop the option where it's the default). Then **delete the now-unused `imgproxy_plan/1` helper** (:816) — an orphaned private function fails `--warnings-as-errors`.
- [ ] **Step 2 — deferred_orientation_frame_test.exs:** same shape — the `{:effective, …}` case at :174 is deleted with the same citation; the plain resolver use at :77 swaps to `NeutralResolver`. `prefetch_validation_test.exs:18` is a plain swap.
- [ ] **Step 3:** Green runs per file (`mix compile --warnings-as-errors` too); commit `test: swap framework transform tests off the imgproxy resolver strategy`.

### Task 12: `plug_test.exs`

**Files:** `test/image_pipe/plug_test.exs` (82 refs; no describe blocks — regions by line)

- [ ] **Step 1 — Region A (:588–611, parser-option init):** repoint the 4 tests to `ImagePipe.Parser.IIIF` (keep the "without loading module" test's semantics).
- [ ] **Step 2 — Region B (:621–757, nested `imgproxy:` config init) — DELETE** (8 tests): the nested-sublist config path dies with the parser; flat-key equivalents live in `test/image_pipe/dialect/imgproxy/config_test.exs` (:33 signature normalize, :45 presets validate, :51 invalid presets, :27 unknown-key raise) **plus the relocated `signature_test.exs` (Task 20) for full normalization** (`signature_size`, `trusted_signatures` — config_test:33 alone asserts only mode).
- [ ] **Step 3 — Region D (:1890–1955, preset runtime) — DELETE** (3 tests): covered by dialect presets/pipeline tests + `cache/key` preset-expansion equivalence in `dialect/imgproxy_contract_test.exs`.
- [ ] **Step 4 — Region C (:757–2576, ~60 generic tests):** repoint by feature, **split across the two surviving parsers**:
  - **Auto-negotiation / `Vary: Accept` / modern-candidate / Accept-cache-key cases (:1013, :1073, :1147, :1274, :1355, :1373, :1421, :1457–1488, :1495) → TwicPics `twic=v1/output=auto`.** IIIF cannot express format negotiation — `iiif_wire_test.exs:581–592` *asserts* IIIF image responses never carry `Vary: Accept`; TwicPics `output=auto` → `%PlanOutput{mode: :automatic}` is the surviving negotiating parser (`twic_pics_wire_conformance_test.exs:406` is the precedent).
  - **Explicit-format `vary == []` cases (:1436, :1450) and geometry/streaming/cache/limit/error cases → IIIF** (streaming/chunking, cache hit/miss, sequential access, pixel/body limits, decode/encode error paths).
  - For cases whose *setup* leans on imgproxy options with no equivalent: `cb:` (:1101) — **delete with citation** (grammar→cachebuster mapping: relocated `options_test.exs:224` via Task 20; key-vs-ETag behavior: `dialect/imgproxy/identity_test.exs:116`); `fn:`/`att:` (:1219) — delete with citation (`dialect/imgproxy_wire_smoke_test.exs:241` disposition); `el:1` (:2184) — delete with citation (wire enlarge cases :2502/:3881); `rt:force`/`rs:fill`/`fl:0:1` sequential/materialization drivers (:1988–2073, :2380–2397) — repoint using IIIF spellings that force the same materialization (IIIF rotation `90` forces the quarter-turn path); `w:-1`/`f:best` validation-failure drivers (:954, :972, :1298, :1312, :1873) — repoint using IIIF-invalid inputs (bad region/size strings) since the assertion is "parse failure before fetch", not the specific message.
- [ ] **Step 5:** After the sweep: `grep -c 'Parser.Imgproxy' test/image_pipe/plug_test.exs` → 0. Run the file green. Verify no Plug feature lost its last coverage: streaming, caching, **≥1 `Vary: Accept` negotiation test through TwicPics**, limits, error paths each still have ≥1 test (the repointed ones).
- [ ] **Step 6:** Commit `test: plug_test serves the generic Plug contract through IIIF`.

### Task 13: `request_safety_test.exs`

**Files:** `test/image_pipe/request_safety_test.exs` (12 refs)

- [ ] **Step 1:** Repoint :108–197 (validation-returns-before-origin: out-of-range `pd:`/`bg:`/`br:`/`co:`/`sa:`/`exp:` strings) using surviving-parser invalid inputs (IIIF malformed region/size; TwicPics out-of-range ops) — the contract is "parser/planner failure before source identity", not the imgproxy grammar. The dialect's own pre-fetch safety is already dual-run in the wire suite.
- [ ] **Step 2:** Delete the 3 signature tests (:209–269) with citation: pre-fetch signature rejection is pinned by `dialect/imgproxy/info_wire_test.exs:191` + `dialect/imgproxy/errors_test.exs` + the wire suite's signature-safety block (dialect arm).
- [ ] **Step 3:** Repoint :276–376 (InvalidPipelinePlanParser + plain source-error ordering) to IIIF. Green run; commit `test: repoint request-safety ordering contract at surviving parsers`.

### Task 14: `cdn_http_cache_wire_test.exs` → TwicPics

**Files:** `test/image_pipe/cdn_http_cache_wire_test.exs` (13 refs; :557 already uses TwicPics — the in-file precedent)

- [ ] **Step 1:** Repoint the file to TwicPics (`/beach.jpg?twic=v1/…`). Grammar-keyed cases translate: `g:obj:face` (:494) → delete-with-citation (dialect wire covers detection identity) or TwicPics `focus`; `rs:fill…/c:…` ordering (:577–583) → TwicPics `cover`/`crop`; `el:1` (:595–616) → delete with citation (dialect wire enlarge cases); `scp:0/1` (:633–638) → delete with citation (wire `scp` normalization block) unless TwicPics exposes an equivalent toggle; `cb:v2` (:660) → TwicPics has no cachebuster — the case's substance is "cachebuster busts CDN cache", which for the surviving framework parsers doesn't exist; delete with citation to the surviving dialect cachebuster coverage (relocated `options_test.exs:224` grammar mapping + `dialect/imgproxy/identity_test.exs:116` key-busts-but-not-ETag).
- [ ] **Step 2:** Green run; confirm the parser-generic CDN contract (ETag, HEAD, cache-control, Vary) retained coverage. Commit `test: CDN/http-cache wire contract served through TwicPics`.

### Task 15: `debug_headers_wire_test.exs`

**Files:** `test/image_pipe/debug_headers_wire_test.exs` (4 refs)

- [ ] **Step 1:** Repoint the body tests (:115–311, debug-header emission + autoquality debug) to IIIF's `?debug=1` trigger (real: `lib/image_pipe/parser/iiif.ex:143–145`).
- [ ] **Step 2:** Delete `describe "signature coverage"` (:326–350) — the tamper case was ported in Task 5 Step 3; the plain signed-render-with-debug case is framework-imgproxy-only surface.
- [ ] **Step 3:** Green run; commit `test: debug-header wire coverage through IIIF ?debug=1`.

### Task 16: `deferred_orientation_property_test.exs` generator rewrite

**Files:** `test/image_pipe/deferred_orientation_property_test.exs` (1 ref + imgproxy URL generators at :45, :69)

- [ ] **Step 1:** Rewrite the property generators to emit IIIF spellings: rotation `0|90|180|270` (+ `!` mirror forms) × size/region — preserving the invariant under test (deferred EXIF orientation composes with user rotate/flip through the framework Plug). Where the generator emitted imgproxy-only ops with no IIIF spelling, drop those branches with a note in the test (dialect orientation coverage: `dialect/imgproxy/orientation_matrix_test.exs`).
- [ ] **Step 2:** Green run (multiple seeds: `mix test --seed 0` and default). Commit `test: deferred-orientation property drives IIIF spellings`.

**CHECKPOINT B:** `grep -rn 'Parser\.Imgproxy' test/ --include='*.exs' --include='*.ex' | grep -v imgproxy_wire_conformance | grep -v imgproxy_differential | grep -v imgproxy_telemetry_contract | grep -v 'test/parser/imgproxy' | grep -v architecture_boundary | grep -v cross_arm | grep -v 'parser/imgproxy/' | grep -v pipeline_assembly | grep -v leaf_structs | grep -v 'dialect/imgproxy/request_test'` → empty. `mise run precommit` green.

---

## Part 3 — framework-arm drops (Tasks 17–21)

### Task 17: `encrypt_source_url/3` public facade on the dialect

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (public function + doc)
- Test: `test/image_pipe/dialect/imgproxy/source_encryption_test.exs`-adjacent (add to the dialect's dual-run arm file or a focused test)
- Docs: `docs/imgproxy_path_api.md:112–117`, `docs/imgproxy_support_matrix.md:1087`

**Interfaces:**
- Produces: `ImagePipe.Dialect.Imgproxy.encrypt_source_url/3` — `(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, :invalid_source_url | :invalid_key | :invalid_iv | :invalid_options}`, delegating to `ImagePipe.Dialect.Imgproxy.SourceEncryption.encrypt_source_url/3` (:20). Task 18 consumes it.

- [ ] **Step 1: Failing test:**
  ```elixir
  test "encrypt_source_url/3 is public API on the dialect" do
    key = String.duplicate("a", 64)
    assert {:ok, segment} = ImagePipe.Dialect.Imgproxy.encrypt_source_url("local:///x.png", key, [])
    assert is_binary(segment)
    assert {:error, :invalid_key} = ImagePipe.Dialect.Imgproxy.encrypt_source_url("local:///x.png", "short", [])
  end
  ```
  Run → FAIL (undefined function).
- [ ] **Step 2: Implement** the facade on `Dialect.Imgproxy` (copy the framework's `@doc`/`@spec` shape from `lib/image_pipe/parser/imgproxy.ex:68–88`, adjusted). Check `SourceEncryption` is exported from the dialect boundary; if not, export it or route through the top-level module only.
- [ ] **Step 3:** Run green. Update `docs/imgproxy_path_api.md:112,117` and `docs/imgproxy_support_matrix.md:1087` to name `ImagePipe.Dialect.Imgproxy.encrypt_source_url/3`.
- [ ] **Step 4:** Commit `feat: public encrypt_source_url/3 facade on Dialect.Imgproxy`.

### Task 18: Wire conformance suite → single-arm

**Files:** `test/image_pipe/imgproxy_wire_conformance_test.exs` (4945 lines)

Current machinery (verified): dual-run comprehension :23; `@stack` :30; `FrameworkParser` alias :40 (used at :4226 as a URL builder on both arms); ~36 `parser: ImagePipe.Parser.Imgproxy` opts sites; functional `if @stack == :framework` at :1113 and :3738 (the documented `http_cache:` opt-in exception); `@parse_error_tag` case at :2108–2112; dispatch `case @stack` :4688–4722 with `translate_opts/1` :4718.

- [ ] **Step 1:** Drop the comprehension: delete `{:framework, Framework}` from :23's list — suite still compiles dual-modules→single; then unwrap entirely: remove the `for`/`Module.concat` wrapper so the file defines one plain module (name it `ImagePipe.ImgproxyWireConformanceTest`; external aliases like `ImgproxyWireConformanceTest.OriginImage` must keep resolving — the fixture modules are defined outside the loop and keep their names).
- [ ] **Step 2:** Flatten dispatch: keep only the dialect `call_imgproxy_conn/2`; **delete `translate_opts/1`** and rewrite every opts site to flat dialect config (drop `parser:`, hoist each `imgproxy: [...]` sublist's keys to top level). `Config.validate!/1` raises on unknown keys, so any mis-hoist fails loudly.
- [ ] **Step 3:** Collapse the three `@stack` constructs: :1113 and :3738 lose the framework branch (dialect ETag behavior is unconditional — delete the `http_cache:` opt-in blocks); :2108's `@parse_error_tag` becomes the dialect literal.
- [ ] **Step 4:** Replace `FrameworkParser` (:40 alias, :4226 call) with `ImagePipe.Dialect.Imgproxy.encrypt_source_url/3` (Task 17).
- [ ] **Step 5:** Reword the header TRAP comment (:1–21) and the dispatch commentary (:4682–4717) for a one-stack world (the suite pins the sole imgproxy implementation against upstream-derived expectations; no arm parameterization).
- [ ] **Step 6:** Run the whole file: `mix test test/image_pipe/imgproxy_wire_conformance_test.exs` → same case count as the dialect arm had (~156), all green, zero skips. Commit `test: wire conformance suite runs the dialect as the sole imgproxy stack`.

### Task 19: Differential suite, harness, gen_fixtures, telemetry contract → single-arm

**Files:** `test/image_pipe/imgproxy_differential_conformance_test.exs`, `test/support/image_pipe/test/imgproxy_differential/harness.ex`, `test/support/mix/tasks/imgproxy.gen_fixtures.ex`, `test/image_pipe/imgproxy_telemetry_contract_test.exs`

- [ ] **Step 1 — differential:** drop `{:framework, Framework}` from :19's comprehension and unwrap to a single module; delete the framework-only provenance `IO.puts` gate (:44–52). `ImgproxyDifferentialFixtureIntegrityTest` (:175–203) untouched.
- [ ] **Step 2 — harness:** `plug_opts/1` (:26–28) loses the `:framework` clause; collapse to `plug_opts/0` returning the dialect opts (update the doc comment :17–25 and both call sites in the differential/cross-arm files — cross-arm dies in Task 21).
- [ ] **Step 3 — gen_fixtures:** `validate_parses!` (:103–117) currently calls `Imgproxy.parse/1`. The dialect has no public parse — replace parse-validation with render-validation. **`Harness.render/2` returns `{resp_body, content_type}` and discards the status**, so it cannot express a 200 check; inline the plug call instead (gen_fixtures already imports `conn/2`):
  ```elixir
  defp validate_renders! do
    {plug, plug_opts} = Test.ImgproxyDifferential.Harness.plug_opts()

    failures =
      Constellations.all()
      |> Enum.reject(& &1[:triage])
      |> Enum.flat_map(fn c ->
        conn = plug.call(conn(:get, Constellations.imgproxy_path(c)), plug_opts)
        if conn.status == 200, do: [], else: [{c.id, conn.status}]
      end)
    # …unchanged failure-raising tail
  end
  ```
  (Match `plug_opts/0`'s actual post-Step-2 return shape — if it returns opts only, hard-code `ImagePipe.Dialect.Imgproxy` as the plug.) Drop the `alias ImagePipe.Parser.Imgproxy` (:16). This is bake-tooling only (P10: no re-bake this wave), but it must actually catch a non-200.
- [ ] **Step 4 — telemetry contract (dual-run module):** drop `{:framework, Framework}` (:27), unwrap, keep the dialect `call_conn/2` clause; unwrap the `case @stack` (:314) deleting only the `:framework` branch (:315–325) — **keep `@test_only_seam_keys` (:312)**, the surviving dialect `call_conn` uses it; verify `@stages` (:165) still covers every dialect-emitted stage after the unwrap (stage-set parity means no framework-only names remain — expect no deletions); `@shared_stages` (:188) stays as the asserted set; the `if @stack == :dialect` describe (:533) unwraps to unconditional.
- [ ] **Step 5 — stage-set module** (same file, :673–818): delete `stage_set_for(:framework)` (:759–772), `@framework_only` (:726), and the framework≡dialect stage-set assertion (:813–816); keep the dialect≡native sequence-equality test; reword the moduledoc (:674–692).
- [ ] **Step 6:** Run all three files green (`mix test test/image_pipe/imgproxy_differential_conformance_test.exs test/image_pipe/imgproxy_telemetry_contract_test.exs`; gen_fixtures compiles via the test env). Verify `git status test/support/image_pipe/test/imgproxy_differential/` clean. Commit `test: differential/telemetry suites single-arm; gen_fixtures validates by dialect render`.

### Task 20: Grammar tests — drop the framework arm, relocate

**Files:** the 6 dual-run files under `test/parser/imgproxy/` (`signature_test.exs` :42, `source_encryption_test.exs` :186, `source_test.exs` :22, `options_test.exs` :1, `path_test.exs` :1, `option_grammar_test.exs` :1); delete whole: `test/parser/imgproxy_test.exs`, `test/parser/imgproxy/plan_builder_test.exs`, `test/parser/imgproxy_property_test.exs`

- [ ] **Step 1:** For each dual-run file: remove the framework tuple from the `for` head (these parameterize on implementation modules, not `@stack` atoms — no conditional bodies to touch), unwrap the `for`/`Module.concat` to a plain module aliasing the dialect modules directly, and delete the framework-only intro describes (`signature_test.exs` :13–39 `Imgproxy.validate_options!/1` — covered by dialect `config_test.exs`; `source_encryption_test.exs`'s top `SourceEncryptionAdapterTest` — covered by wire encrypted-source cases).
- [ ] **Step 2:** `git mv` the 6 files to `test/image_pipe/dialect/imgproxy/` (the parser dir dies with the parser); fix module names to `ImagePipe.Dialect.Imgproxy.*Test` (no collisions with existing dialect test modules — verified). `source_test.exs` also defines top-level helper modules (`ImgproxySourceTestFoobarTranslator`/`…FailingTranslator` at :1/:14) — rename them into the new test module's namespace.
- [ ] **Step 3:** `git rm test/parser/imgproxy_test.exs test/parser/imgproxy/plan_builder_test.exs test/parser/imgproxy_property_test.exs` — ports landed in Tasks 2–4; everything else is delete-covered per the Part 1 citations (record the per-group citations in the commit message: config validation → `config_test.exs`; scp/cp/icc/sm/kcr → wire describes; signature → wire + `errors_test.exs`; sources → wire + `mount_test.exs`; geometry → dual-armed grammar tests + wire + differential; presets internals → Task 3; structural invariants → Task 2; properties → Task 4).
- [ ] **Step 4:** `test/parser/imgproxy/` directory now empty → remove. Run `mix test test/image_pipe/dialect/imgproxy/` green. Commit `test: imgproxy grammar tests single-arm, relocated to the dialect tree`.

### Task 21: Delete the parity pins

**Files (git rm whole):** `test/image_pipe/imgproxy_cross_arm_body_test.exs`, `test/image_pipe/dialect/imgproxy/pipeline_assembly_test.exs`, `test/image_pipe/dialect/imgproxy/leaf_structs_test.exs`, `test/image_pipe/parser/imgproxy/info_dispatch_test.exs`, `test/image_pipe/parser/imgproxy/resolver_test.exs`, `test/image_pipe/parser/imgproxy/info_renderer_test.exs`
**Files (edit):** `test/image_pipe/dialect/imgproxy/request_test.exs`

- [ ] **Step 1:** Delete the five whole files, citing per file: cross_arm — cross-arm comparison is its purpose; pipeline_assembly — self-documented "RETIRES WITH THE FRAMEWORK ARM" (:26–31), invariants rehomed by Task 2; leaf_structs — field-parity pin, same moduledoc; info_dispatch/info_renderer/resolver — covered by `info_wire_test.exs` (+ Task 5's spelling port) and `pipeline_carry_test.exs`/`decode_preflight_test.exs`/Task 7.
- [ ] **Step 2:** `request_test.exs`: delete the 6 `ParsedRequest`-comparison tests and the framework alias; keep the `"the canonical request is pure data"` test.
- [ ] **Step 3:** Verify `test/image_pipe/parser/` contains no imgproxy files; remove the empty dir. Run `mix test` (full) → green. Commit `test: delete framework↔dialect parity pins (transition complete)`.

**CHECKPOINT C:** `mise run precommit` green. `grep -rn 'Parser\.Imgproxy' test/ fiddle/test/` → only `test/image_pipe/architecture_boundary_test.exs` (map entry :88, boundary decl :136/:163, AST matchers) and `fiddle` (Task 25).

---

## Part 4 — the one-way deletion (Task 22)

### Task 22: Delete `lib/image_pipe/parser/imgproxy*`

**Files:**
- Delete: `lib/image_pipe/parser/imgproxy.ex` + `lib/image_pipe/parser/imgproxy/` (19 files, verified: crop_request, effects, format, info_renderer, option_grammar, options, orientation, parsed_request, path, percent_encoding, pipeline_request, plan_builder, presets, resolver, signature, source, source_encryption, source_scheme + the root)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (:88 module→file map entry; :136 `boundary_declaration(ImagePipe.Parser.Imgproxy)`; :163 `assert_boundary_exports(imgproxy, [ImagePipe.Parser.Imgproxy.SourceScheme])`)

- [ ] **Step 1 — gate:** `grep -rn 'Parser\.Imgproxy\|parser/imgproxy' lib/ test/ fiddle/lib fiddle/test | grep -v 'lib/image_pipe/parser/imgproxy' | grep -v architecture_boundary_test` → only **comment/doc-prose hits deferred to Task 27** — expected: `neutral_resolver.ex:18`, `resize_planning.ex:9–10`, and the dialect-tree comment/moduledoc mentions (`dialect/imgproxy.ex:316,368`, `dialect/imgproxy/errors.ex:12`, `dialect/imgproxy/config.ex:105`, `dialect/imgproxy/response_meta.ex:7`, `dialect/imgproxy/identity.ex:89,120,129`, `dialect/imgproxy/assembly.ex:8`, `dialect/imgproxy/info_renderer.ex:10`) — plus fiddle if Task 25 hasn't landed yet. Any hit that is *code* (alias, call, module reference that compiles): stop, fix first.
- [ ] **Step 2:** `git rm -r lib/image_pipe/parser/imgproxy.ex lib/image_pipe/parser/imgproxy/`
- [ ] **Step 3:** Architecture test: drop :88, :136, :163. The rip-out AST matchers (`imgproxy_parser_references/1`, :1451–1515) **stay** — post-§A they catch `Dialect.Imgproxy` leaking into core via the `[:Imgproxy | _]` matchers.
- [ ] **Step 4:** `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors && mix test` → green. Then the full gate: `mise run precommit` → green (expect ExDNA noise only if the dialect ignores now mis-target; that cleanup is Task 26 — if ExDNA fails here because an ignore's *duplication partner* died, note it and fix in Task 26 within the same PR, or pull Task 26 forward if the gate must pass per-commit — prefer pulling forward the minimal entries).
- [ ] **Step 5:** Commit `feat!: retire ImagePipe.Parser.Imgproxy — the dialect is the sole imgproxy implementation`.

---

## Part 5 — post-deletion cleanup (Tasks 23–27)

### Task 23: Retire the `{:effective, …}` marker

**Files (verified anchors):**
- `lib/image_pipe/plan.ex` :363 (comment), :392 (`requires_strategy?` Padding clause)
- `lib/image_pipe/plan/key_data.ex` :209 (`data({:effective, …})` clause)
- `lib/image_pipe/plan/operation.ex` :745–748 (`tagged_padding_pixel_ratio({:effective, …})`), :68 (type mention)
- `lib/image_pipe/plan/operation/padding.ex` :13 (type union arm)
- Comments referencing the marker: `lib/image_pipe/dialect/imgproxy/assembly.ex` :24, :124, :569; `lib/image_pipe/transform/neutral_resolver.ex` :16

- [ ] **Step 1:** Sweep tests first: `grep -rn '{:effective' test/` — delete/adjust any test asserting the marker's acceptance (they pin a shape with no producer post-§A; the sole emitter was `PlanBuilder`).
- [ ] **Step 2:** Remove the marker arm from `padding.ex:13`'s type, the `tagged_padding_pixel_ratio` clause (operation.ex:745–748) **and the `@effective_padding_modes` module attribute at operation.ex:68** (its only consumers are that clause's guard — leaving it orphaned fails `--warnings-as-errors`), the `key_data.ex:209` clause, and plan.ex:392's `requires_strategy?` Padding clause (+ the :363 comment). If `requires_strategy?/1` retains other clauses (TwicPics `:deferred` guides), it survives; `ImagePipe.Resolver` survives regardless (TwicPics).
- [ ] **Step 3:** Rewrite the marker-referencing comments (assembly.ex ×3, neutral_resolver.ex:16) so the text reads as if the marker never existed — no "no longer"/removal narration (AGENTS.md removal rule).
- [ ] **Step 4:** `mix compile --warnings-as-errors && mix test` green (dialyzer at the next checkpoint). Commit `feat: retire the {:effective, …} padding marker`.

### Task 24: Replace AGENTS.md's marker-accretion worked example

**Files:** `AGENTS.md` (:23, the **Marker accretion** bullet; `CLAUDE.md` is a symlink — edit `AGENTS.md`)

- [ ] **Step 1:** Replace the parenthetical illustration `(a field value only the emitting dialect's resolver understands, e.g. \`Padding\` \`pixel_ratio: {:effective, …}\`)` with the live marker: TwicPics `:deferred` gravity (`Plan.Operation.CropGuided`/`Resize` `guide: :deferred`, resolved by `ImagePipe.Parser.TwicPics.Resolver`'s focus carry). Keep the `mode: :auto` promotion story (it is the "worked example" of criterion (c) failing) — only the *illustration of a legitimate marker* changes. The three criteria stay verbatim.
- [ ] **Step 2:** Comment-only change: no verify gate needed. Commit `docs: marker-accretion example is TwicPics deferred focus`.

### Task 25: Fiddle migration

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex` (`build_imgproxy_opts/0` :84–102), `fiddle/lib/image_pipe_fiddle_web/imgproxy.ex` (the web wrapper), `fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs`

- [ ] **Step 1:** Rewrite `build_imgproxy_opts/0`:
  ```elixir
  defp build_imgproxy_opts do
    imgproxy = Application.fetch_env!(:image_pipe_fiddle, :imgproxy)

    [sources: imgproxy_source_mounts(), detector_required: false]
    |> Keyword.merge(imgproxy)
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Dialect.Imgproxy.init()
  end
  ```
  (`parser:` dropped; `imgproxy:` sublist hoisted — its current contents `signature:` + `smart_crop_face_detection:` are both accepted flat; `allow_debug_headers:` dropped per flagged decision 1 — rewrite the :91–97 comment to state the dialect serves no debug headers and the panel stays empty on this mount.)
- [ ] **Step 2:** Web wrapper: `ImagePipe.Plug.call(conn, …)` → `ImagePipe.Dialect.Imgproxy.call(conn, …)` (same persistent-term indirection). IIIF/TwicPics mounts untouched.
- [ ] **Step 3:** `imgproxy_source_mounts_test.exs`: `ImagePipe.Plug.init([parser: …])` → `ImagePipe.Dialect.Imgproxy.init(...)` flat; assertions about the fanned-out `sources` keyword stay.
- [ ] **Step 4:** Update `docs/debug_headers.md:17` (names `Parser.Imgproxy` as the `debug:1` carrier — reword: the imgproxy dialect parses `debug:1` but emits no debug headers; IIIF/TwicPics on `ImagePipe.Plug` remain the debug-header surface).
- [ ] **Step 5:** `pnpm -C fiddle/assets run build` (fresh-worktree prerequisite), then `mise run precommit:fiddle` → green. **Do not commit `fiddle/mix.lock`.** Commit `feat(fiddle): imgproxy mount serves through Dialect.Imgproxy`.

### Task 26: ExDNA / credo re-audit

**Files:** `.credo.exs` (ignore list :178–207, prose :39–175), `mise.toml` (:77, the `--ignore` chain)

Verified: **zero** entries point at `parser/imgproxy/**` — the list holds **28** entries (22 `dialect/imgproxy*` phase-1 copies + `dialect/imgproxy.ex`/`dialect/imgproxy/pipeline.ex` breadcrumbed to #457 + `decode.ex`, `decode/source_format.ex`, `dialect/native.ex`, `dialect/native/pipeline.ex`, `dialect/shared_config.ex`, `response/conditional.ex` with their own justifications). The re-audit, not a mechanical delete:

- [ ] **Step 1:** Read the prose block and remove from **both** files (they must stay in sync) every entry whose justification is the phase-1 copy (~20 removals); keep every entry whose justification is NOT the phase-1 copy (~8 survivors, including the #457-breadcrumbed pair).
- [ ] **Step 2:** Run ExDNA (`mise run precommit` includes it). Any removed entry that still flags means the file duplicates something *else* (e.g. mirrors native) — re-add it with a fresh, accurate justification comment, not the stale copy-ignore prose.
- [ ] **Step 3:** Rewrite the prose block (:74–135) to drop the phase-1-copy narrative; verify `.credo.exs` list == `mise.toml` chain 1:1.
- [ ] **Step 4:** `mise run precommit` green. Commit `chore: re-audit ExDNA ignores after the framework-parser deletion`.

### Task 27: Docs sweep

**Files (verified hits):** `docs/cache.md:9`, `docs/cdn-http-cache.md:11`, `docs/content-aware-gravity.md:77`, `docs/custom_parser_guide.md:27,113,181`, `docs/debug_headers.md:17` (Task 25 did it — verify), `docs/execution_flow.md:114–115`, `docs/imgproxy_dialect_phase2_backlog.md:19,155`, `docs/imgproxy_path_api.md:21,209,228` (:112/:117 done in Task 17), `docs/telemetry.md:18,541`, `docs/imgproxy_support_matrix.md:18,610,612` (:1087 done in Task 17); support matrix "Two stacks serve imgproxy URLs" §:11–46; `lib/image_pipe/transform/neutral_resolver.ex:18`, `lib/image_pipe/transform/resize_planning.ex:9–10`, `lib/image_pipe/config.ex:151–155` (`@doc` prose "used by the imgproxy parser…"), the 5 dialect "phase-1 copy of the frozen…" moduledocs (`dialect/imgproxy.ex`, `identity.ex` :89/:120/:129, `response_meta.ex:7`, `info_renderer.ex:10`, `assembly.ex:8`), `dialect/imgproxy/errors.ex:12` (names `Parser.Imgproxy.handle_error/2`), the `dialect/imgproxy.ex` inline comments at :316/:368, `dialect/imgproxy/config.ex:105`

- [ ] **Step 1:** Rewrite the support matrix's "Two stacks" section (:11–46) to one stack (`plug ImagePipe.Dialect.Imgproxy`); reduce § Dialect-stack divergences to the deliberate differences only (per the wave-1 exit note: the `[:parse, :stop]` `:result`-semantics row dies here — the framework `[:parse]` span is gone).
- [ ] **Step 2:** Reword each remaining `Parser.Imgproxy` doc/comment hit for the one-stack world; per the removal rule, no "no longer"/"was removed" narration. The 5 dialect moduledocs drop the "phase-1 copy / retired in phase 2" framing and describe what the module *is*. Historical records under `docs/superpowers/` stay as-is.
- [ ] **Step 3:** Update `docs/imgproxy_dialect_phase2_backlog.md` §A to record completion (what closed where, mirroring §B's style).
- [ ] **Step 4:** `mise run precommit` green (docs don't gate, but the lib comment edits do). Commit `docs: one imgproxy stack`.

**CHECKPOINT D:** full `mise run precommit` + `mise run precommit:fiddle` green; `git status test/support/image_pipe/test/imgproxy_differential/` clean; `git status sources/` clean.

---

## Part 6 — C1 (Task 28)

### Task 28: Collapse the two-fallback padding/canvas distinction

**Files (verified):**
- `lib/image_pipe/dialect/imgproxy/pipeline.ex` :437–446 (`padding_scale_for/2` + the misleading comment), :413 (`Lowering.canvas_executables(op, carry.canvas_preserving_padding_scale || 1.0)`)
- `lib/image_pipe/dialect/imgproxy/assembly.ex` :129–132 (`pipeline_ctx/1` `@spec` — drop `dpr_fallback: float()` too, or dialyzer flags it), :133–140 (`pipeline_ctx/1`, `dpr_fallback: request.dpr || 1.0`)
- `test/image_pipe/dialect/imgproxy/pipeline_carry_test.exs:387` — **must be reworked, see Step 2b**
- Prose: `docs/imgproxy_dialect_phase2_backlog.md` §C1; `.superpowers/sdd/phase1-exit-criteria.md` (record done); support-matrix mentions if any

Why unobservable (spec §Wave 3): `resize_rule_requested?/1` (assembly.ex:305–311) includes `not is_nil(request.dpr)`, so whenever `dpr` is non-nil a resize is emitted and `effective_padding_scale` is set — the fallback fires **only** when `dpr` is nil, where `dpr_fallback = request.dpr || 1.0 = 1.0`. Both fallbacks are therefore always 1.0. This holds **per pipeline** too (compat-review-verified): the carry is fresh per pipeline (`@empty_carry`, pipeline.ex:71/356), `pctx` and the resize emission read the same `%PipelineRequest{}`, and the scales are set whenever a `%PlanResize{}` runs (pipeline.ex:380–389) — there is no path where a pipeline has non-nil dpr but no resize op. (The :437 comment claims the two fallbacks differ — the code disproves it; the comment dies with the collapse.)

- [ ] **Step 1 — mutation evidence FIRST (refactor, no RED expected):** temporarily change `padding_scale_for`'s fallback to `s || 1.5` and run the wire + differential padding/canvas cases with nil dpr (e.g. `mix test test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs`) → RED (dimensions/pixels shift). Revert. This proves the suites police the collapsed value.
- [ ] **Step 2 — collapse:** in `pipeline_ctx/1` drop `dpr_fallback` (map **and** `@spec` :129–132); both `padding_scale_for/2` clauses become `s || 1.0`; the canvas `run_op` clause at :413 already reads `|| 1.0` — leave it. Delete the :437–446 comment block; replace with one line stating the single 1.0 fallback (fires only when no resize was emitted).
- [ ] **Step 2b — keep the carry-preservation sentinel discriminating:** `pipeline_carry_test.exs:387` ("an effect between the resize and the padding does not lose the carry") uses `dpr: 2.0` where the carried `effective_padding_scale` is **1.0** and the old fallback (request dpr = 2.0) was the poison — a dropped carry surfaced as `top: 20`. After the collapse the fallback is 1.0 too, so a dropped carry becomes indistinguishable (`top: 10` either way) and the test goes tautological. Rework its setup so the **carried scale is a distinct non-1.0 value** (e.g. a no-enlarge-capped resize where `effective_padding_scale == 2.0`) and the poison for a dropped carry is the 1.0 fallback; assert the scaled padding side. Prove it discriminates: temporarily drop the carry in the neutral-delegation clause (pipeline.ex:426) → RED; revert. (The sibling at :356 stays — its sentinel is a leaked scale from p1, not the fallback.)
- [ ] **Step 3:** Full wire + differential green, zero pixel change (`git status` on fixtures clean). `mise run precommit` green.
- [ ] **Step 4 — prose:** correct `docs/imgproxy_dialect_phase2_backlog.md` §C1 (record done + the corrected description), `.superpowers/sdd/phase1-exit-criteria.md`'s simplification-candidate entry. Commit `refactor: single 1.0 padding/canvas fallback (C1)`.

---

## Task 29: Exit gate

- [ ] **Step 1:** `mise run precommit` AND `mise run precommit:fiddle` green from a clean tree.
- [ ] **Step 2:** Cross-check the spec's phase-2 exit criteria 6–10: lib tree gone; all suites single-arm green; fiddle on the dialect; ExDNA re-audited; marker retired; `encrypt_source_url/3` re-homed; docs synced; differential fixtures byte-untouched (`git diff --stat origin/main -- test/support/image_pipe/test/imgproxy_differential/sources` empty); `fiddle/mix.lock` not in any commit (`git log --oneline -- fiddle/mix.lock` shows nothing new).
- [ ] **Step 3:** `git branch -m feat/imgproxy-retire-framework-parser` before push.
- [ ] **Step 4:** Whole-branch review (per the session workflow) before PR.

## Self-review notes (spec coverage)

- Spec §Wave 2 bullets → Tasks: delete 19 files (22); Plug/Config no-change (verified — plug.ex/config.ex have zero imgproxy code; only prose, Task 27); generic re-pointing (9–16); white-box porting (1–8, 20); framework-arm drops (18–20) + cross-arm delete (21); harness/gen_fixtures/resolved_plan_cases (8, 19); resize_auto (7); architecture tests (22); fiddle (25); encrypt facade (17); ExDNA (26); marker (23); AGENTS.md (24); docs (27). §Wave 3 C1 → 28.
- Deviations from spec prose, each grounded in verified code: (a) `resolved_plan_cases` cannot literally "re-point at the dialect" — flagged decision 2; (b) fiddle `allow_debug_headers` — flagged decision 1; (c) the stage-set test is embedded in the telemetry contract file, not standalone; (d) `.credo.exs` has zero `parser/imgproxy` entries — the cleanup is a dialect-side re-audit, exactly as the spec's "re-audit" instructs; (e) architecture test has 10 literal `Parser.Imgproxy` hits, not 8 — the extra two are AST-matcher helper lines that stay.

## Plan-review record (2026-07-17)

Three parallel reviewers, disjoint lenses, all APPROVE-WITH-EDITS; every finding applied:
- **Compatibility** (zero observable imgproxy-behavior change; wire/differential dialect arms + local imgproxy checkout as ground truth): confirmed Tasks 17/18/25/28 behavior-identical, C1's unobservability traced per-pipeline. Edits applied: Task 28 Step 2b (carry-sentinel rework) + `@spec`; Task 19 render-validation realized with real status check; cachebuster citations corrected (Tasks 12/14).
- **Coverage/deletion-evidence:** edits applied: Task 12 negotiation cases → TwicPics `output=auto` (IIIF never negotiates); Task 1 covers all three `framework_get` sites; Task 10 Step 1b ports the `/-/` shrink-leak tests (#180) instead of deleting; Task 3 gains preset-error + group-merge ports; Task 4 gains delete-citations; Task 2 gains stage-sequence + `mw:0` items.
- **Executability** (all anchors verified): edits applied: Task 11 rewritten (delete `{:effective}` executor tests, not swap; helper removal); Task 8 Step 5 removes the golden's module-level attribute/aliases; Task 22 gate expectation enumerates the deferred comment hits; Task 19 keeps `@test_only_seam_keys`; Task 23 deletes the `@effective_padding_modes` attribute; Task 26 counts corrected (28 entries / ~20 removals / ~8 survivors); Task 27 gains `errors.ex:12` + inline comments; Task 7 notes the `resolve/3` contract; Task 20 notes the helper-module renames.
