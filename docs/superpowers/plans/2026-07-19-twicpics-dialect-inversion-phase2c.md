# TwicPics dialect inversion Phase 2C: Retire the geometry-strategy SDK

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to execute this plan task by task. Use superpowers:test-driven-development for every behavior or coverage migration. Steps use checkbox (`- [ ]`) syntax for tracking.

<!-- vale off -->

**Goal:** Delete the framework geometry-strategy SDK — `ImagePipe.Resolver` behaviour/facade, the `Plan.resolver` field and its validation, `Plan.Operation.Directive`, the shared `:deferred` guide marker, cache-key resolver material, and every injected-strategy dispatch path — leaving `ImagePipe.Transform.NeutralResolver` and the fixed neutral driver as the sole runtime-geometry lowering, host `ImagePipe.Parser` returning only product-neutral declarative Plans, and every TwicPics/IIIF observable unchanged.

**Architecture:** The Phase 2A fixed neutral driver (`resolver: nil` Plans → `Executor.run_neutral/4` → `NeutralResolver` directly) is already the only live runtime path. No parser produces a non-`nil` `resolver`; both dialects (`imgproxy`, `native`) and the TwicPics dialect Pipeline call `NeutralResolver.resolve/3`/`continue/4` directly and never touch the `ImagePipe.Resolver` facade. Phase 2C therefore removes dead injected-strategy scaffolding, the marker vocabulary it existed to carry, and the cache/Boundary/doc surface that advertised it — replacing the removed resolver-version cache pin and the removed non-module-resolver rejection with explicit *absence* assertions, not silence.

**Tech Stack:** Elixir/ExUnit/StreamData, Plug, Vix/libvips, Boundary, ExDNA, mise, Vale, Svelte/Phoenix fiddle.

**Design records:**

- `docs/superpowers/specs/2026-07-17-twicpics-dialect-inversion-design.md`, especially **Phase 2C** (lines 961–1043), decisions T4/T12/T13, and the retirement-inventory cross-references.
- `.superpowers/sdd/twicpics-phase1-test-inventory.md`, especially **"Strategy and marker SDK surface"** (the per-file PORT/REPOINT/DELETE ledger) and **"Cache key and strategy-version pins"**.
- `docs/superpowers/plans/2026-07-18-twicpics-dialect-inversion-phase2a.md` (fixed-driver landing; the coverage-migration discipline this wave continues).
- `docs/superpowers/plans/2026-07-16-imgproxy-dialect-phase2-wave2.md` (precedent: one-way deletion, deletion-evidence discipline, single-arm collapse).
- `docs/custom_parser_guide.md`, `docs/execution_flow.md`, `AGENTS.md` (the live documentation rewritten here).

## Global constraints

Every task's requirements implicitly include this section.

- **Toolchain:** every direct Mix command must start with `export PATH="$(mise where elixir)/bin:$PATH" && mix …`. Plain `mise exec -- mix` resolves to the Homebrew 1.19.3 shadow and false-fails. `mise run precommit` and `mise run precommit:fiddle` already select the repository toolchain.
- **Vix/JXL rebuild trap:** if dependency compilation rebuilds Vix without JXL support, repair both environments before interpreting a JXL failure (from the design's *Verification discipline*):

  ```shell
  export PATH="$(mise where elixir)/bin:$PATH" && \
    mix deps.get && \
    VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix
  export PATH="$(mise where elixir)/bin:$PATH" && \
    MIX_ENV=test mix deps.get && \
    MIX_ENV=test VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix
  ```
- **Phase boundary:** this is Phase 2C only. Do **not** change any TwicPics compatibility behavior, fixtures, verdicts, tolerances, or SaaS oracle bytes; do **not** extend Phase 2B behavior; do **not** move IIIF into a dialect; do **not** add a compatibility wrapper that reconstructs the deleted strategy vocabulary; do **not** expose a private dialect-pipeline or transform-lowering module as a replacement public SDK.
- **Preserve:** `ImagePipe.Transform.NeutralResolver` (and its pure lowering/late-bound-guide functions); the fixed neutral execution driver; measured-stage continuation and runtime-geometry resolution; IIIF on `ImagePipe.Plug`; the sole `ImagePipe.Dialect.TwicPics` stack and every Phase-2B observable; host-implementable `ImagePipe.Parser` returning product-neutral declarative Plans; the boundary that product-specific ordered runtime carry lives in a self-contained Plug; cache-key and ETag correctness after strategy material disappears.
- **Drift protection is replaced, never dropped:** removing the resolver-version cache-key pin is paired with a canonical-material assertion that no `:resolver` field survives (Task 4). Removing the non-module-resolver Plan-validation rejection is paired with a syntax-aware architecture gate rejecting a `:resolver` root-Plan field (Task 4).
- **Immutable TwicPics artifacts:** the TwicPics differential fixtures, sources, `constellations.ex`, `manifest.exs`, and `REPORT.md` stay byte-identical the whole wave (gate below). A failure there is a code bug, never a re-bake.
- **Fiddle lock:** never stage or commit `fiddle/mix.lock`.
- **Deletion evidence:** each `DELETE` step cites surviving coverage (file + test name) or an explicit unreachable-surface analysis, and repeats that citation in the commit body. Each `PORT`/`REPOINT` and each new assertion gets RED or a temporary production mutation (shown red, reverted, then green), with the failing command/test names recorded in the commit body. **An unexpected GREEN is a stop signal** — investigate the gap analysis before continuing.
- **Commits stay green:** use the commit boundaries below; each commit compiles `--warnings-as-errors` and passes its focused tests. Do not combine dispatch deletion, marker removal, and documentation into one commit.
- **Branch:** execute on `refactor/twicpics-phase2c-retire-strategy-sdk` (already renamed); never a `codex/` prefix; never move the worktree directory.
- **Review agents perform no git mutations** in the shared checkout (worktrees share one stash stack).
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Immutable-artifact gate

Run before Task 1 and at every checkpoint; it must print nothing and exit 0:

```shell
git diff --exit-code origin/main -- \
  test/support/image_pipe/test/twicpics_differential/constellations.ex \
  test/support/image_pipe/test/twicpics_differential/fixtures \
  test/support/image_pipe/test/twicpics_differential/sources \
  test/support/image_pipe/test/twicpics_differential/manifest.exs \
  test/support/image_pipe/test/twicpics_differential/REPORT.md
git diff --exit-code origin/main -- fiddle/mix.lock
```

## Phase-2C negative live-surface gate

This is the wave's north star (the design's one-time manual exit check, run per checkpoint as it converges). It must return **no matches** at Task 8, excluding historical design records:

```shell
rg -n \
  'ImagePipe\.Resolver|ImagePipe\.Parser\.TwicPics|TwicPics\.Resolver|LegacyResolver|behavior_version|resolver_data|Operation\.(Directive|directive)|:strategy_required|:deferred|strategy SDK|carried resolver strategy' \
  lib test fiddle docs AGENTS.md \
  --glob '!docs/superpowers/**'
```

`Parser\.TwicPics` (0 matches since Phase 2A) is included by the design's own gate; it must stay 0.

---

## Part 1 — Retire the runtime strategy dispatch

### Task 1: Rewrite the resolve-driver golden and executor tests onto the fixed neutral seam

Move the last two callers off the injected `Executor.run/5` + `{Strategy, state}` tuple so Task 2 can delete that surface. Promote the fixed driver's `run_neutral/4` to a documented-internal test seam.

**Files:**

- Modify: `lib/image_pipe/transform/executor.ex` (promote `run_neutral/4` from `defp` to `@doc false def`, ~line 166)
- Modify: `test/image_pipe/transform/resolved_plan_golden_test.exs` (all three describe blocks; remove the `{NeutralResolver, NeutralResolver.init()}` tuple)
- Modify: `test/image_pipe/transform/executor_test.exs` (delete the injected `Probe` module and the `run/5`/explicit-resolver cases)

**Interfaces:**

- Produces: `ImagePipe.Transform.Executor.run_neutral(operations :: [struct()], shape :: SourceShape.t(), state :: State.t(), opts :: keyword()) :: {:ok, State.t()} | {:error, term()}` — the fixed neutral driver, now `@doc false` public. It already threads `chain:` and `measure_dims:` opts through `run_driver/5`, so it is the injection seam the golden needs. Consumed by the golden test in this task and by production `execute/3` (unchanged).

- [ ] **Step 1: Promote `run_neutral/4` to a documented-internal seam.** In `lib/image_pipe/transform/executor.ex`, change the private definition (currently `defp run_neutral(pipeline, shape, state, opts), do: run_driver(pipeline, shape, {:neutral, nil}, state, opts)`, ~line 166) to:

  ```elixir
  @doc false
  # Fixed neutral execution driver: lowers each plan op through NeutralResolver
  # directly and keeps neutral staged measurement/continuation. Public only as an
  # internal test seam for resolved_plan_golden_test.exs.
  def run_neutral(pipeline, shape, %State{} = state, opts),
    do: run_driver(pipeline, shape, {:neutral, nil}, state, opts)
  ```

- [ ] **Step 2: Rewrite the golden onto `run_neutral/4`.** In `test/image_pipe/transform/resolved_plan_golden_test.exs`, replace every `Executor.run(<plan_ops>, <shape>, {NeutralResolver, NeutralResolver.init()}, <state>, <opts>)` call (the identity-streaming guard ~L61, the ±1 divergence case ~L164, and both staged-continuation cases ~L240, ~L300) with `Executor.run_neutral(<plan_ops>, <shape>, <state>, <opts>)`. Keep the `alias ImagePipe.Transform.NeutralResolver` only if a surviving line still names it for building plan-op structs; otherwise drop it. Update the moduledoc line (~L6) that says "drives `Executor.run/5`" to name `run_neutral/4`. Keep every assertion (no-flush/`materialized? == false`, measured-recorded-1 crop dims, staged crop-box-follows-measured, pending-orientation flushed crop box) byte-for-byte.

- [ ] **Step 3: Prove the golden still fails on a driver regression (mutation evidence).** Temporarily force a boundary flush in `Executor.flush_boundary/…` (e.g. make the identity-pending branch materialize) and run:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/resolved_plan_golden_test.exs`
  Expect the identity-streaming guard RED. Revert.

- [ ] **Step 4: Delete the injected `Probe` executor tests.** In `test/image_pipe/transform/executor_test.exs`, delete the `Probe` module (the `@behaviour ImagePipe.Resolver` fixture, ~L16–39), the `describe "run/5 (pipeline loop)"` block (~L41–68), and the explicit-resolver half of `describe "plan driver routing"` — the `test "an explicit resolver Plan keeps the injected strategy path"` (~L80–96). **Keep** `test "a nil-resolver Plan executes through the neutral driver"` (~L71–78). Citation (record in commit body): measured-continuation coverage survives in `resolved_plan_golden_test.exs` (`±1 divergence` + `staged continuation`); the injected `Probe` path has no live producer and is deleted in Task 2.

- [ ] **Step 5: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/resolved_plan_golden_test.exs test/image_pipe/transform/executor_test.exs`
  and `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`.

- [ ] **Step 6: Commit:** `test: drive the resolve-driver golden through the fixed neutral seam`.

### Task 2: Delete the injected-strategy dispatch, the `ImagePipe.Resolver` facade, and its Boundary edges

With no live caller, remove the injected path end to end. This is the wave's first one-way deletion.

**Files:**

- Modify: `lib/image_pipe/transform/executor.ex` (delete `run/5`, the `{:strategy, _}` clauses, the second `execute/3` clause, `alias ImagePipe.Resolver`, and injected-path moduledoc narration)
- Modify: `lib/image_pipe/transform/neutral_resolver.ex` (drop `@behaviour ImagePipe.Resolver`, `@impl`, `behavior_version/0`, `ImagePipe.Resolver.continuation()` specs, and carried-strategy moduledoc framing)
- Modify: `lib/image_pipe/transform.ex` (drop `ImagePipe.Resolver` from `deps:`; reword the "Strategy SDK" export framing)
- Modify: `lib/image_pipe/parser.ex` (drop `ImagePipe.Resolver` from `deps:`)
- Delete: `lib/image_pipe/resolver.ex`
- Delete: `test/image_pipe/resolver_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs` (drop `ImagePipe.Resolver` from Parser/Transform `assert_boundary_deps`/`assert_allowed_deps` and from every dialect/decode/delivery `refute_boundary_deps`; drop the TwicPics forbidden-`ImagePipe.Resolver` reference row + its self-test)

**Interfaces:**

- Removes: `ImagePipe.Resolver` (behaviour, `resolve/3`, `continue/5`, `rewrap/2`, `behavior_version/0`). No replacement — the fixed driver calls `NeutralResolver` directly.
- Preserves: `NeutralResolver.resolve/3`, `NeutralResolver.continue/4`, `NeutralResolver.resolve_late_bound_guide/2`, `NeutralResolver.display_frame_advance/2`, `NeutralResolver.plain_advance/2`, `NeutralResolver.resolve_mode/2` — all still called directly by `Executor.run_neutral/4` and both dialect pipelines. The `{:advance, shape, nil}` / `{:measure, tag, nil}` continuation *tuple shapes* stay; only the `ImagePipe.Resolver` *type name* is removed.

- [ ] **Step 1: Delete the injected Executor dispatch.** In `lib/image_pipe/transform/executor.ex`:
  - Remove `alias ImagePipe.Resolver` (~L44).
  - Collapse `execute/3` to a single clause matching `%Plan{pipelines: pipelines} = plan` (drop the `resolver: nil` vs `resolver: resolver` split) that seeds state and calls `execute_pipelines(pipelines, state, opts)`. Delete the second (injected) clause.
  - Thread the neutral driver directly: `execute_pipeline` calls `run_neutral(operations, shape, state, opts)` — delete the `case driver do {:strategy, resolver} -> run(...) ; :neutral -> run_neutral(...) end` fork and the `driver` parameter it switched on.
  - Delete `run/5` (the `@doc false def run(...)` + its `@spec` naming `Resolver.strategy()`).
  - In `resolve/3`, `continue/5`, and `advance/2`, delete the `{:strategy, _}` clause and unwrap the surviving `{:neutral, _}` clause to call `NeutralResolver` directly (drop the driver tag). Because the driver tag now has a single value, also remove `driver` from `run_driver/5`'s reduce accumulator and collapse `advance/2` — which becomes a vestigial identity re-tag — rather than leaving a dead `{:neutral, state}` wrap.
  - Rewrite the moduledoc **and** the inline strategy-narrating comments: describe only the fixed neutral driver; remove "injected strategy driver / carried strategy / strategy's own per-pipeline state" narration. Include the `flush_boundary/…` inline comment (~L294–295, "never touches a strategy's carried point / Strategy state dies…") and the `execute_stages/…` comment (~L211–213) so no strategy prose survives in this file.
  Let `mix compile --warnings-as-errors` catch every now-unused var/clause; produce the minimal diff it demands.

- [ ] **Step 2: Drop the behaviour from `NeutralResolver`.** In `lib/image_pipe/transform/neutral_resolver.ex`: delete `@behaviour ImagePipe.Resolver` (~L46); delete the `@impl` attributes on `init/0`, `resolve/3`, `continue/4`, `behavior_version/0`; delete `behavior_version/0` (~L79–80); replace `ImagePipe.Resolver.continuation()` in the three `@spec`s (~L89, L534, L561) with a local `@type continuation` alias (define it once as `{:advance, SourceShape.t(), nil} | {:measure, term(), nil}`) or with the concrete tuple types; rewrite the moduledoc so it frames the module as the fixed driver's direct lowering (drop "delegation target for carried strategies / Implements `ImagePipe.Resolver`"). Keep `init/0`, `resolve/3`, `continue/4`, and every pure lowering/late-bound function as ordinary functions.

- [ ] **Step 3: Cut the Boundary edges.** In `lib/image_pipe/transform.ex`, change `deps:` from `[ImagePipe.Plan, ImagePipe.Telemetry, ImagePipe.Resolver]` to `[ImagePipe.Plan, ImagePipe.Telemetry]`, and reword the "Strategy SDK — the stable contract for carried resolver strategies (`ImagePipe.Resolver` implementations…)" export comment (~L25/L28/L58) to "Dialect-pipeline contract — structs and neutral lowering helpers the in-tree dialect Pipelines consume" (keep every export atom). In `lib/image_pipe/parser.ex`, delete `ImagePipe.Resolver,` from `deps:` (L13), leaving `[Config, Format, Plan, Renderer, Transform]`.

- [ ] **Step 4: Delete the facade module and its test.** `git rm lib/image_pipe/resolver.ex test/image_pipe/resolver_test.exs`. Citation (commit body): the four facade tests (dispatch/continuation/`rewrap`) covered only `ImagePipe.Resolver`, which no producer targets; the fixed neutral driver's behavior survives in `resolved_plan_golden_test.exs` and `neutral_resolver_test.exs`. Unique behavior: none.

- [ ] **Step 5: Update the architecture Boundary assertions.** In `test/image_pipe/architecture_boundary_test.exs`:
  - Remove `ImagePipe.Resolver` from the Parser `assert_boundary_deps` (~L147) and `assert_allowed_deps` (~L170) sets.
  - Change the Transform `assert_boundary_deps` (~L900) to `[ImagePipe.Plan, ImagePipe.Telemetry]`.
  - Remove `ImagePipe.Resolver` from every `refute_boundary_deps(...)` list that names it (native ~L208, imgproxy ~L243, twicpics ~L279, decode ~L419, delivery ~L449) — refuting a now-deleted module both breaks the negative grep and is vacuous; the dialect boundary already forbids undeclared deps.
  - Remove the `[:ImagePipe, :Resolver | _] -> "ImagePipe.Resolver"` row from `twicpics_forbidden_module/1` (~L1270) and drop the matching case from the `scan_twicpics_reference_sequence` self-test (~L384). Citation: the module no longer exists, so a reference is a compile error, not a boundary leak; the surviving `Parser`/`Plan`-root forbidden rows and the Task 4 AST gate cover reintroduction. Unique behavior: none.

- [ ] **Step 6: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform test/image_pipe/architecture_boundary_test.exs test/parser/iiif_wire_test.exs test/image_pipe/dialect/twic_pics test/image_pipe/twic_pics_wire_conformance_test.exs`

- [ ] **Step 7: Partial negative-gate check.** `rg -n 'ImagePipe\.Resolver' lib test --glob '!docs/superpowers/**'` — expect only the still-pending comment/test sites scheduled for Tasks 3–7 (dialect pipeline comments, `ordered_spike/pipeline.ex`, docs). Confirm no *dependency/behaviour* reference remains.

- [ ] **Step 8: Commit:** `refactor: delete the ImagePipe.Resolver strategy facade and injected dispatch` (cite the deleted facade test's surviving coverage in the body).

**CHECKPOINT A:** `mise run precommit`, the immutable-artifact gate, and the focused TwicPics differential file (`mix test test/image_pipe/twicpics_differential_conformance_test.exs`) all pass before starting Part 2.

---

## Part 2 — Retire the marker vocabulary from the Plan model

### Task 3: Remove the `:deferred` guide marker

`:deferred` existed only so a point-carrying strategy could substitute a concrete point before emission. No producer emits it; the neutral driver resolves late-bound guides directly through `resolve_late_bound_guide/2`.

**Files:**

- Modify: `lib/image_pipe/plan/operation.ex` (drop `resize_guide(:deferred)` L792, `tagged_crop_guide(:deferred)` L846)
- Modify: `lib/image_pipe/plan/operation/resize.ex` (drop `:deferred` from `@type guide`, L34–35)
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex` (drop `:deferred` from `@type guide`, L29–30)
- Modify: `lib/image_pipe/transform/operation/crop.ex` (drop `:deferred` from `@type t`, L156; drop only `:deferred` from the `:smart/:detect/:deferred` gravity comment ~L213, keeping the `:smart/:detect` note)
- Modify: `lib/image_pipe/transform/lowering.ex` (drop `tagged_executable_gravity(:deferred)` clause + comment, L346–350)
- Modify: `lib/image_pipe/plan/key_data.ex` (drop `guide_data(:deferred)`, L224)
- Modify: `test/image_pipe/plan/operation_test.exs` (delete the `describe "carried guide (#321)"` `:deferred` block, ~L27–34)
- Modify: `test/image_pipe/transform/neutral_resolver_test.exs` (remove the `:deferred` oracle arm from the two `resolve_late_bound_guide/2` cases)

- [ ] **Step 1: Delete the constructor acceptance.** In `lib/image_pipe/plan/operation.ex`, delete `defp resize_guide(:deferred), do: {:ok, :deferred}` (L792) and `defp tagged_crop_guide(:deferred), do: {:ok, :deferred}` (L846). After this, constructing `guide: :deferred` returns `{:error, {:invalid_guide, :deferred}}` (or the existing invalid-guide tag).

- [ ] **Step 2: Delete `:deferred` from the type unions and lowering.** Remove the `| :deferred` line (and its preceding `# requires a point-carrying resolver strategy` comment) from `lib/image_pipe/plan/operation/resize.ex` (L34–35), `lib/image_pipe/plan/operation/crop_guided.ex` (L29–30), and `lib/image_pipe/transform/operation/crop.ex` (`@type t` L156). In `transform/operation/crop.ex`, also drop **only** the `:deferred` token from the gravity comment at ~L213 (`# crops; a :smart/:detect/:deferred gravity has no pure rectangle…`), keeping the `:smart/:detect` note. In `lib/image_pipe/transform/lowering.ex`, delete the `def tagged_executable_gravity(:deferred), do: :deferred` clause and its 4-line comment (L346–350). In `lib/image_pipe/plan/key_data.ex`, delete `defp guide_data(:deferred), do: :deferred` (L224).

- [ ] **Step 3: Remove the `:deferred` oracle arm from the neutral-resolver tests (REPOINT, R-NEUTRAL).** In `test/image_pipe/transform/neutral_resolver_test.exs`, in `describe "resolve_late_bound_guide/2"`, delete the oracle comparison lines that build `%CropGuided{... | guide: :deferred}` / `%PlanResize{... | guide: :deferred}` and compare to `resolve_late_bound_guide/2` (~L224–228 and ~L271–272, plus the `normalize_late_bound_tail/1` `%Crop{gravity: :deferred}` mapping ~L293–298). Keep the direct `resolve_late_bound_guide/2` assertions (emitted executable, continuation, rectangle, odd-pixel bias). The test now asserts the concrete late-bound result directly.

- [ ] **Step 4: Prove the direct late-bound assertions are load-bearing (R-NEUTRAL mutation).** Temporarily break `NeutralResolver.resolve_late_bound_guide/2` (e.g. off-by-one in `compensate_late_bound_crop/2`) and run:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/neutral_resolver_test.exs`
  Expect both `resolve_late_bound_guide/2` cases RED. Revert.

- [ ] **Step 5: Delete the `:deferred` constructor test (DELETE).** In `test/image_pipe/plan/operation_test.exs`, delete `describe "carried guide (#321)"` (~L27–34). Citation: the surviving concrete-guide constructor cases (`:center`, anchors, `{:focal,…}`, `:smart`, `{:smart,:face_assist}`, `{:detect,…}`) cover guide validation; no producer emits `:deferred`. Unique behavior: none.

- [ ] **Step 6: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/plan test/image_pipe/transform/neutral_resolver_test.exs test/image_pipe/transform/lowering_test.exs test/image_pipe/dialect/twic_pics`

- [ ] **Step 7: Commit:** `refactor: remove the :deferred guide marker from the Plan model`.

### Task 4: Remove the Plan `resolver` field, strategy validation, and cache-key resolver material

Delete the field that selected a strategy, the validation that required one, the `:strategy_required` status, and the cache-key strategy digest — replacing the two removed drift guards with explicit absence assertions.

**Files:**

- Modify: `lib/image_pipe/plan.ex` (struct field L73, type L85, error tags L101–102, `validate_shape` clauses L112–113, `validate_resolver/1` L354–360, `validate_strategy_requirements`/`find_strategy_requiring_operation`/`requires_strategy?` L362–393, comments L355/L362–363)
- Modify: `lib/image_pipe/response/error_status.ex` (drop `:strategy_required` from `@plan_validation_error_tags`, L48)
- Modify: `lib/image_pipe/cache/key.ex` (drop `resolver: resolver_data(plan.resolver)` L57; delete `resolver_data/1` L78–82)
- Modify: `test/image_pipe/plan_test.exs` (delete strategy-requirement + non-module-resolver + nil/module-resolver cases; repoint the smart/detect/`:auto` acceptance cases)
- Modify: `test/image_pipe/cache/key_test.exs` (drop the golden `resolver:` line; replace `plan_material resolver tag` describe with an absence assertion)
- Modify: `test/image_pipe/request_runner_test.exs` (drop the `resolver: NeutralResolver` line, L876)
- Delete: `test/support/image_pipe/test/resolver_version_probe.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs` (add the syntax-aware root-Plan `:resolver`-field gate)

- [ ] **Step 1: Delete the field and its validation from `plan.ex`.** Remove the `resolver: nil` struct field (L73) and its `@type` line (L85); remove `{:invalid_resolver_plan, term()}` (L101) and `{:strategy_required, term()}` (L102) from `shape_error()`; delete the `validate_resolver(plan.resolver)` and `validate_strategy_requirements(plan)` clauses from the `validate_shape/1` `with` chain (L112–113); delete `validate_resolver/1` (L354–360) and the whole `validate_strategy_requirements`/`find_strategy_requiring_operation`/`requires_strategy?` block (L362–393) including the `%Operation.Directive{}` clause; delete the carried-strategy comments (L355, L362–363). Keep `detect_classes/1` and `face_assist?/1` (product-neutral).

- [ ] **Step 2: Drop the `:strategy_required` status tag.** In `lib/image_pipe/response/error_status.ex`, remove `:strategy_required,` from `@plan_validation_error_tags` (L48). The surviving tags still map to `422`/"invalid image transform".

- [ ] **Step 3: Remove the cache-key resolver material.** In `lib/image_pipe/cache/key.ex`, delete `resolver: resolver_data(plan.resolver),` from the `plan_material/2` keyword (L57) and delete `resolver_data/1` with its comment (L78–82). The canonical plan material no longer carries a `:resolver` key.

- [ ] **Step 4: Add the cache-key absence assertion (R-CACHE — replaces the resolver-version pin).** In `test/image_pipe/cache/key_test.exs`: remove `resolver: [strategy: :neutral, version: 1]` from the golden `key.data` expectation (~L195); delete the `describe "plan_material resolver tag"` block (~L1275–1304) and the `alias ImagePipe.Test.ResolverVersionProbe` (L17); add one test that pins the *absence*:

  ```elixir
  test "canonical plan material carries no resolver field (strategy SDK retired)" do
    {:ok, material} = Key.plan_material(plan(), [])
    refute Keyword.has_key?(material, :resolver)
  end
  ```

  `plan_material/2` returns `{:ok, keyword()}` and takes `(%Plan{}, opts)` (every in-repo caller destructures `{:ok, material} = Key.plan_material(plan(), [])`), so bind the tuple and refute on the inner keyword — do **not** pass a source-identity value as `opts`. Citation for the deleted describe: dialect identity + wire storage-identity own TwicPics cache identity; imgproxy/native/IIIF cache identity is covered by their suites; the resolver digest no longer exists.

- [ ] **Step 5: Prove the absence assertion is load-bearing (R-CACHE mutation).** Temporarily re-add `resolver: [strategy: :neutral, version: 1]` to `plan_material/2` and run:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/cache/key_test.exs`
  Expect the new absence test RED (and the golden test RED). Revert.

- [ ] **Step 6: Fix `plan_test.exs`.** Delete `describe "validate_shape strategy-requiring vocabulary"`'s three rejection cases (`:deferred` resize L163, `:deferred` crop L171, `directive` L179) and the two resolver-field cases (`rejects a non-module resolver` L207, `accepts a nil and a module resolver` L212). **Keep and repoint** the acceptance cases `accepts neutral-resolvable guides without a resolver` (L187) and `accepts an :auto resize mode without a resolver` (L199): drop the "without a resolver" phrasing and any `resolver:`-field reference; they now read as plain product-neutral Plan-validation cases (`:smart`/`{:detect,…}` guides and `:auto` mode validate).

- [ ] **Step 7: Prove the repointed acceptance cases are load-bearing.** Temporarily make `validate_shape/1` reject a `:smart` guide (or an `:auto` mode) and run:
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/plan_test.exs`
  Expect the two repointed cases RED. Revert.

- [ ] **Step 8: Drop the explicit resolver from the runner test.** In `test/image_pipe/request_runner_test.exs`, delete the `resolver: ImagePipe.Transform.NeutralResolver` line from the `plan(...)` call in `test "cache miss executes semantic plan after fetch and stores under original key"` (L876); the plan defaults to the fixed neutral path. Keep every cache-before-fetch / cache-put ordering assertion. Prove load-bearing (already-cited R-CACHE-adjacent): temporarily make `Executor.run_neutral/4` return `{:error, {:transform, :probe}}`, confirm this case RED, revert.

- [ ] **Step 9: Delete the resolver-version probe fixture.** `git rm test/support/image_pipe/test/resolver_version_probe.ex`. Citation: its only consumer was the deleted `plan_material resolver tag` describe.

- [ ] **Step 10: Add the syntax-aware root-Plan `:resolver`-field gate (replaces the non-module-resolver rejection).** In `test/image_pipe/architecture_boundary_test.exs`, extend the existing Plan-construction AST checker: the current clause matches `{:%, meta, [{:__aliases__, _, parts}, fields]}` where `fields` is the raw map node (**not** pre-destructured). When `resolve_plan_alias(parts, aliases)` resolves to `[:ImagePipe, :Plan]`, reach into the map node — `{:%{}, _, kwlist}` — and also flag a violation if `Keyword.has_key?(kwlist, :resolver)` (a `:resolver` key in a root-`%Plan{…}` construction/update). Reuse `bind_plan_aliases/2`/`resolve_plan_alias/2` unchanged. Add a production test scanning all `lib/**/*.ex` for a root-Plan `:resolver` field and a self-test proving the checker resolves aliases lexically and does **not** flag the IIIF source resolver, HTTP `address_resolver`, or telemetry resolver option groups. Prove load-bearing: temporarily add `%ImagePipe.Plan{resolver: nil}` to a scanned lib file (or a self-test fixture string), confirm RED, revert.

- [ ] **Step 11: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/plan_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/request_runner_test.exs test/image_pipe/architecture_boundary_test.exs test/image_pipe/response/error_status_test.exs`

- [ ] **Step 12: Commit:** `refactor: remove the Plan resolver field, strategy validation, and cache-key resolver material` (cite the replaced drift guards in the body).

### Task 5: Delete `Operation.Directive`

The last marker: a no-pixel positional message addressed to a strategy that no longer exists.

**Files:**

- Delete: `lib/image_pipe/plan/operation/directive.ex`
- Modify: `lib/image_pipe/plan/operation.ex` (drop `directive/2` L310–314, the `Directive` alias L17, `@type focus_operation` L85, the `semantic_operation` member L109, the `semantic?(%Directive{})` clause L543)
- Modify: `lib/image_pipe/plan.ex` (drop `Operation.Directive` from Boundary `exports:`, L44)
- Modify: `lib/image_pipe/plan/key_data.ex` (drop the `Directive` alias L19 and the `data(%Directive{})` clause + comment L145–150)
- Modify: `test/image_pipe/plan/operation_test.exs` (delete `describe "directive/2 constructor (#438)"` ~L20–24 and the `Directive` alias L10)
- Modify: `test/image_pipe/plan/key_data_test.exs` (delete `test "directive key data hashes name and payload generically"` L41–45)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (drop `ImagePipe.Plan.Operation.Directive` from the Plan `assert_boundary_exports`, L977)

- [ ] **Step 1: Remove Directive from `operation.ex`.** Delete `directive/2` (L310–314), `alias ImagePipe.Plan.Operation.Directive` (L17), `@type focus_operation :: Directive.t()` (L85) and its member in `semantic_operation` (L109), and `def semantic?(%Directive{name: name}) when is_atom(name), do: true` (L543). The other `semantic?`/constructor clauses stay.

- [ ] **Step 2: Remove Directive from key data and the Plan export.** In `lib/image_pipe/plan/key_data.ex`, delete `alias ImagePipe.Plan.Operation.Directive` (L19) and the `data(%Directive{…})` clause + its comment (L145–150). In `lib/image_pipe/plan.ex`, delete `Operation.Directive,` from `exports:` (L44).

- [ ] **Step 3: Delete the module.** `git rm lib/image_pipe/plan/operation/directive.ex`.

- [ ] **Step 4: Delete the Directive tests and the export assertion.** In `test/image_pipe/plan/operation_test.exs`, delete `describe "directive/2 constructor (#438)"` (~L20–24) and `alias ImagePipe.Plan.Operation.Directive` (L10). In `test/image_pipe/plan/key_data_test.exs`, delete `test "directive key data hashes name and payload generically"` (L41–45). In `test/image_pipe/architecture_boundary_test.exs`, remove `ImagePipe.Plan.Operation.Directive` from the Plan `assert_boundary_exports` list (L977). Citation (commit body): no producer constructs a `Directive`; the concrete-operation constructor/key-data/export suites survive; unique behavior: none.

- [ ] **Step 5: Run GREEN:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix compile --warnings-as-errors`
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/plan test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 6: Commit:** `refactor: delete Plan.Operation.Directive`.

**CHECKPOINT B:** `mise run precommit`, the immutable-artifact gate, and `mix test test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs` all pass before Part 3.

---

## Part 3 — Architecture guards, fixtures, and stale comments

### Task 6: Retire the parser resolver-strategy scan exception, the carried-strategy isolation test, and remaining strategy references

Clean up the architecture test's strategy-file machinery (now referencing paths that no longer exist) and every remaining source comment/fixture that names the retired vocabulary, driving the negative gate to zero in `lib`/`test`.

**Files:**

- Modify: `test/image_pipe/architecture_boundary_test.exs` (drop `@resolver_strategy_globs`, `resolver_strategy_files/0`, the parser-scan exception filter, and the carried-strategy isolation test)
- Modify: `test/image_pipe/plan/vendor_mapping_fixture_test.exs` (repoint the two `:strategy_guide` fixtures)
- Modify: `test/support/image_pipe/ordered_spike/pipeline.ex` (moduledoc)
- Modify: `lib/image_pipe/transform/resize_planning.ex` (L16 comment), `lib/image_pipe/transform/lowering.ex` (L12 comment), `lib/image_pipe/transform/focus.ex` (moduledoc strategy framing)
- Modify: `lib/image_pipe/dialect/imgproxy/pipeline.ex` (L372 comment), `lib/image_pipe/dialect/native/pipeline.ex` (L15, L227 comments)
- Modify: `test/image_pipe/dialect/twic_pics/request_test.exs` and `test/image_pipe/dialect/twic_pics/request_builder_test.exs` (drop retired atoms from the forbidden-vocabulary scan data)

- [ ] **Step 1: Remove the parser executable-op scan exception (REPOINT).** In `test/image_pipe/architecture_boundary_test.exs`, delete `@resolver_strategy_globs` (L67–70), `resolver_strategy_files/0` (L1281–1286), and the `not MapSet.member?(resolver_strategy_files, file)` filter in `test "parser code does not depend on executable transform operation modules"` (L1026/L1030) so the scan covers **all** parser files with no exception. Also rewrite the test's rationale comment (~L1019–1025), which currently names an `ImagePipe.Resolver` strategy and the `parser -> Resolver, Transform` Boundary edge — reduce it to the surviving rule ("parser output — PlanBuilder/Path/Options — stays semantic-only"), dropping the resolver-exception justification so no `ImagePipe.Resolver` reference survives the negative gate. Prove load-bearing: temporarily add a concrete `ImagePipe.Transform.Operation.Crop` reference to `lib/image_pipe/parser/iiif.ex`, confirm the scan RED, revert.

- [ ] **Step 2: Delete the carried-strategy isolation test (DELETE).** Remove `test "a carried resolver strategy never touches execution state or pixel access"` (L1038) and its `resolver_strategy_forbidden_transform_references/1` helper if now unused. Citation: no carried-strategy file exists (Parser.TwicPics deleted in 2A; the facade in Task 2); the fixed-driver and dialect boundary assertions survive. Unique behavior: none.

- [ ] **Step 3: Repoint the vendor-mapping fixtures (REPOINT).** In `test/image_pipe/plan/vendor_mapping_fixture_test.exs`, rewrite the two `:strategy_guide` fixtures to concrete product-neutral guide vocabulary while keeping the vendor identities and the classification census: the twicpics `focus=auto/crop=300x200` fixture's `semantic_shape` becomes `[:crop_guided, {:smart, :face_assist}]`; the cloudinary `c_fill,g_auto,w_300,h_200` fixture becomes `[{:resize, :cover}, {:smart, :face_assist}]`; update the `notes` to drop "future-facing / once strategy guides exist" language. If `:strategy_guide` was a distinct classification bucket, fold these into the existing executable/representable bucket that the concrete guides warrant. Prove load-bearing: deliberately corrupt one rewritten fixture (e.g. a non-existent guide atom), confirm the shallow-fixture structural test RED, revert.

- [ ] **Step 4: Reword the ordered-spike and production comments.** In `test/support/image_pipe/ordered_spike/pipeline.ex` moduledoc (L7–17), reword the "no `ImagePipe.Resolver` strategy … replace the strategy framework" claim to "no injected callback seam / no framework strategy dispatch" (do not name the deleted module). In `lib/image_pipe/transform/resize_planning.ex` (L16) and `lib/image_pipe/transform/lowering.ex` (L12), reword "not part of the strategy SDK" to "an internal lowering seam, exported only for the in-tree dialect Pipelines". In `lib/image_pipe/transform/focus.ex` moduledoc, reword "the neutral point math any point-carrying strategy uses" to "the neutral point math the dialect Pipelines' PointFlow uses". In `lib/image_pipe/dialect/imgproxy/pipeline.ex` (L372) and `lib/image_pipe/dialect/native/pipeline.ex` (L15, L227), reword the "no `ImagePipe.Resolver` strategy" comments to "runs its own ordered pipeline; no injected strategy dispatch".

- [ ] **Step 5: Drop retired atoms from the TwicPics forbidden-vocabulary scan.** In `test/image_pipe/dialect/twic_pics/request_test.exs` (~L64, L91) and `request_builder_test.exs` (~L355, L412), remove `:deferred` (and any `Operation.Directive` / `ImagePipe.Resolver` term) from the forbidden-term list the scan asserts a produced request never contains. Keep the positive recursive scan over every produced request. Citation: those atoms no longer exist as constructable values, so a leak is a compile error; the Boundary tests and the Task 4 AST gate cover reintroduction.

- [ ] **Step 6: Run GREEN and the partial negative gate:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/architecture_boundary_test.exs test/image_pipe/plan/vendor_mapping_fixture_test.exs test/image_pipe/dialect/twic_pics`
  `rg -n 'ImagePipe\.Resolver|behavior_version|resolver_data|Operation\.(Directive|directive)|:strategy_required|:deferred|strategy SDK|carried resolver strategy' lib test fiddle --glob '!docs/superpowers/**'`
  The grep must return **no matches** across `lib`, `test`, `fiddle`.

- [ ] **Step 7: Commit:** `test: retire strategy-file architecture guards and stale strategy references`.

---

## Part 4 — Documentation

### Task 7: Rewrite `custom_parser_guide.md`, `execution_flow.md`, and `AGENTS.md`

Make the live documentation describe a world where host parsers end at product-neutral Plans, the fixed neutral driver is the only runtime-geometry path, and product-specific ordered runtime carry belongs to a self-contained Plug.

**Files:**

- Modify: `docs/custom_parser_guide.md`
- Modify: `docs/execution_flow.md`
- Modify: `docs/twicpics_support_matrix.md` (one architectural sentence only, ~L12)
- Modify: `AGENTS.md`

- [ ] **Step 1: Rewrite `custom_parser_guide.md`.** Remove the entire `## Geometry resolution: custom resolver strategies` section and its subsections (`### Why resolvers exist`, `### The execution model`, `### Carried state, two patterns`, `### Dialect vocabulary: deferred markers and directives`, `### The strategy SDK`, `### behavior_version/0 and caching` — ~L371–561). Remove `resolver: nil` from the Plan skeleton (~L152) and its bullet. Remove the module-overview bullet advertising "a geometry-resolution strategy via `ImagePipe.Resolver`, including custom carried state (optional)" (~L14–15). Reword the "big picture" sentence "the transform layer owns operation semantics and **a resolver strategy owns geometry decisions**" (~L52–53) to "the transform layer owns operation semantics and neutral runtime-geometry lowering" (drop the bare "resolver strategy" phrase). Remove the "special operation … `Operation.directive/2`" paragraph (~L228–234) and the `:deferred` guide bullet (~L217) from the guides list, leaving the closed neutral guide vocabulary. Remove the `:strategy_required` plan-validation paragraph (~L522–528). In the Boundary checklist (~L619–620), drop `ImagePipe.Resolver` from the parser's allowed deps. Add a short subsection stating the boundary: **a host `ImagePipe.Parser` produces only product-neutral declarative `ImagePipe.Plan` values; a dialect needing ordered, product-specific runtime carry (positional focus, running-dimension units) owns a self-contained Plug and its own Pipeline, and must not depend on `ImagePipe.Transform.Lowering`, `ResizePlanning`, or other in-tree implementation helpers.** Keep the IIIF worked example, parser behaviour, option validation, source structs, custom renderers, and testing sections; use IIIF only for features it actually demonstrates (no resolver/strategy testing tier).

- [ ] **Step 2: Rewrite `execution_flow.md`.** In "The call spine", collapse the `select by plan.resolver` fork (L23–33): the framework path is `Executor.execute → run_neutral → NeutralResolver directly`; delete the `module → Executor.run → ImagePipe.Resolver facade ②` branch. In "The two operation vocabularies", reword the section-intro sentence "the **resolver strategy is the translator** between them" (~L53) so the neutral driver's lowering is the translator, and drop `:deferred` from "possibly deferred (`:auto` dims, `:deferred` guides)" (L57–59) — leave `:auto` dims. Rewrite "The resolve loop and continuations": one driver (the fixed neutral driver), delete the injected-resolver `run/5`/`init/0` narration and the `Delegation re-wraps` / `rewrap/2` paragraph (L108–113). In "Where 'go to definition' stops working", delete row ② (the `Resolver.resolve` dispatch) and reword row ④ so `continue(tag, …)` lands on `NeutralResolver.continue/4` only. Update the suggested-reading list to drop injected-driver references (L142–149).

- [ ] **Step 3: Clean the AGENTS.md marker-accretion guidance.** In the *Native API guidelines* marker-accretion paragraph, remove the sentence claiming `:deferred` guide values "remain available for host-supplied resolver strategies" (a live SDK that no longer exists). Keep the general (a)/(b)/(c) rule and the resize `mode: :auto` promotion example (it documents the rule by describing a promotion *away from* a marker). In the *Boundary library guidelines* `deps:` list, remove the `parser → … resolver …` edge and the parenthetical describing "a dialect's carried resolver strategy under `parser/*` implements `ImagePipe.Resolver`"; state instead that a host parser depends on `plan`, `renderer`, `transform` and produces product-neutral Plans, and product-specific ordered orchestration lives in a self-contained dialect Plug.

- [ ] **Step 4: Correct the stale support-matrix architectural sentence.** In `docs/twicpics_support_matrix.md` (~L12), drop the clause "or use the framework's resolver strategy" from "The dialect doesn't construct a root `ImagePipe.Plan` **or use the framework's resolver strategy**." (there is no framework resolver strategy after Phase 2C). This is an architectural sentence, not a behavior/verdict/tolerance row — change **nothing** else in the matrix, and the compatibility reviewer confirms no behavior row moved.

- [ ] **Step 5: Verify no stray strategy vocabulary remains in docs.** Run the spec negative-gate terms **and** a supplementary bare-phrase grep (the spec gate does not match bare "resolver strategy"):
  `rg -n 'ImagePipe\.Resolver|behavior_version|resolver_data|Operation\.(Directive|directive)|:strategy_required|:deferred|strategy SDK|carried resolver strategy|resolver strategy|Parser\.TwicPics' docs AGENTS.md --glob '!docs/superpowers/**'`
  Must return **no matches**. Also grep `docs/transform_operations.md` for `Directive`/`:deferred` and remove any surviving reference.

- [ ] **Step 6: Run Vale on every changed doc:**
  `vale docs/custom_parser_guide.md docs/execution_flow.md docs/twicpics_support_matrix.md AGENTS.md`
  (add `docs/transform_operations.md` if Step 5 edited it). Fix any new findings.

- [ ] **Step 7: Commit:** `docs: describe host parsers ending in neutral Plans and the fixed neutral driver`.

---

## Part 5 — Phase-2C exit proof

### Task 8: Run the full exit gate and the complete-diff review

- [ ] **Step 1: Negative live-surface gate (the design's exit check).**
  ```shell
  rg -n \
    'ImagePipe\.Resolver|ImagePipe\.Parser\.TwicPics|TwicPics\.Resolver|LegacyResolver|behavior_version|resolver_data|Operation\.(Directive|directive)|:strategy_required|:deferred|strategy SDK|carried resolver strategy' \
    lib test fiddle docs AGENTS.md \
    --glob '!docs/superpowers/**'
  ```
  Must return **no matches**.

- [ ] **Step 2: Focused fixed-driver and IIIF framework tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/transform/executor_test.exs test/image_pipe/transform/resolved_plan_golden_test.exs test/image_pipe/transform/neutral_resolver_test.exs test/parser/iiif test/parser/iiif_wire_test.exs test/image_pipe/plug_test.exs`

- [ ] **Step 3: TwicPics dialect wire, telemetry, and differential suites:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/dialect/twic_pics test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twicpics_differential test/image_pipe/twicpics_source_inventory_test.exs`

- [ ] **Step 4: Cache identity and ETag tests:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/cache/key_test.exs test/image_pipe/cache test/image_pipe/request_runner_test.exs test/image_pipe/response/error_status_test.exs`
  Locate and run the ETag/conditional-request wire test (`rg -l 'etag|304|conditional' test/image_pipe`). Removing the (always-`nil`) `:resolver` key legitimately changes the ETag *digest* once, deterministically; this is correct for a greenfield library (no data-version bump, no stale-serve). Do **not** add an ETag-value-stability pin — that would wrongly freeze the changed digest. The 304/conditional fast path is validated by the existing wire test, which must stay green.

- [ ] **Step 5: Architecture Boundary + ExDNA gates:**
  `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/architecture_boundary_test.exs`
  `mise run precommit` (runs `mix credo --strict`, compile `--warnings-as-errors`, format check, full `mix test`, and ExDNA/dialyzer per its definition).

- [ ] **Step 6: Vale on every changed documentation file:**
  `vale docs/custom_parser_guide.md docs/execution_flow.md docs/twicpics_support_matrix.md AGENTS.md` (plus any other doc touched).

- [ ] **Step 7: Fiddle gate:** `mise run precommit:fiddle`. Phase 2C touches no fiddle source, so this is belt-and-suspenders required by the design's exit gate. If the fiddle `mix test` false-fails on a missing Vite manifest (fresh-worktree trap), run `pnpm -C fiddle/assets run build` first, then re-run. Then `git diff --exit-code origin/main -- fiddle/mix.lock` and `git status --short fiddle/mix.lock` — the lockfile must show no change and never be staged.

- [ ] **Step 8: Immutable-artifact gate + whitespace/diff check:**
  the immutable-artifact gate (above), then `git diff --check origin/main...HEAD` and `git diff --stat origin/main...HEAD`. Confirm no fixture/source/manifest/report bytes, constellation authorship, or lockfile entered any commit.

- [ ] **Step 9: Complete-diff parallel review.** Run a parallel review over the full `origin/main...HEAD` diff with four disjoint lenses (no git mutations in review agents): (1) fixed-driver architecture and preservation of neutral measured stages; (2) SDK deletion inventory completeness, coverage migration, and cache-identity/ETag correctness; (3) host-parser contract, Boundary direction, and public/private API surface; (4) TwicPics/IIIF/operational/documentation/fiddle regression risk (at least one lens confirms TwicPics observables and the support matrix are unchanged against the hosted oracle). Apply accepted findings in focused commits and re-run the affected gates.

- [ ] **Step 10: Push and open a draft PR** summarizing the one-way SDK retirement and the full inversion++ exit evidence (negative gate empty; fixed-driver/IIIF/TwicPics/cache suites green; Boundary + ExDNA + Vale green; `precommit` + `precommit:fiddle` green; immutable artifacts and `fiddle/mix.lock` clean; `git diff --check` clean). Do not add issue-closing keywords unless a specific issue is fully resolved.

## Execution recommendation

Execute Tasks 1–8 **inline** in order (superpowers:executing-plans), with the final complete-diff review (Task 8 Step 9) fanned out to parallel agents. The tasks form a strict dependency chain in a few shared files (`executor.ex`, `plan.ex`, `operation.ex`, `key.ex`, `architecture_boundary_test.exs`): the injected dispatch must go before the facade, the facade before its Boundary edges, the `:strategy_required`/validation before the `Directive` struct, and every code reference before the negative gate. Incremental TDD with green commit boundaries gives clearer failure attribution than subagent-per-task handoffs, and the compiler (`--warnings-as-errors`) is the load-bearing driver for the dead-code deletions. Only the complete-diff review is genuinely parallelizable.

<!-- vale on -->
