# Resolve Stage 3: The Carried-Point Move — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the TwicPics carried point out of `ImagePipe.Transform.State` into the TwicPics resolver's `strategy_state`, resolving `:carried` gravity to a concrete point *before* emission, and delete the executables' point mechanics — via the staged continuation (spec §4.4/§9 item 3).

**Architecture:** Per `docs/superpowers/specs/2026-07-01-resolve-stage-virtual-buffer-design.md` §4.4 (staged continuation), §4.5 (acquire seam), §9 item 3 (scope). The `Resolver` continuation contract gains one form: an `:acquire` `then_fn` may return a further `{ops, continuation}` stage, so a multi-executable expansion splits at the realized-dims seam (`[resize]` → read `W′` → `[crop, …]`). The neutral resolver stages its resize emissions (a `%Resize{}` is always the terminal op of its stage); the TwicPics strategy carries the point as `strategy_state` and advances it through each stage with the executables' own new pure geometry helpers (`Crop.resolved_rect/3`, `ExtendCanvas.resolved_embed_offset/5`), substituting `:carried` gravity with a concrete `{:fp, x, y}` (or the centre anchor when nil) *after* orientation compensation. The execute-time point mechanics (`Focus.scale`/`translate`/`reflect_rotate` call sites, `State.carried_point`, the `StateUpdate` op) are then deleted.

**Tech Stack:** Elixir, Vix/libvips, Boundary, ExUnit + StreamData (+ existing golden/differential/wire suites).

## Global Constraints

- **Results-identical is the contract**: every task must leave the full suite green — the ResolvedPlan golden (`test/image_pipe/transform/resolved_plan_golden_test.exs`), the TwicPics differential (`test/image_pipe/twicpics_differential_conformance_test.exs`, incl. the canvas-under-shrink focus pins from #441), the imgproxy differential, and both wire conformance suites. No pixel or byte change anywhere — with **one deliberate, documented exception**: the detector-gated smart/detect point-translate edge (Pinned behavior 1's decision record; unreachable on every existing gate, which runs detector-less).
- **Toolchain**: prepend the mise Elixir before every mix invocation — `export PATH="$(mise where elixir)/bin:$PATH"` — then run through `mise exec -- mix …` (the bare `mise exec` resolves to a Homebrew Elixir that crashes rustler_precompiled). Gate broader changes with `mise run precommit`.
- **No behavioral-version bumps**: Stage 3 is results-identical, so `behavior_version/0` stays `1` on every strategy and `Key.plan_material` is untouched.
- **No telemetry event changes** — no event is added, renamed, or removed, so the Logger and OTel `Capture` subscription lists are untouched. Two *representation* shifts are accepted and documented in Task 6: (a) the per-op span's `:index` restarts per executed batch once a plan op's executables run in more than one stage; (b) `:state_update` op spans disappear from TwicPics focus requests (the op is deleted). Nothing in the repo asserts either.
- **No materialization-classification changes**: no op's `requires_materialization?/1` result changes (the deleted `gravity: :carried` clause returned the default `false`), so no new sequential-safety gate is required. If a task finds itself changing a classification, stop — that is out of scope and would trigger the per-op sequential-vs-random gate.
- **Point math stays exact rationals**: the carried point remains `{ratio, ratio}` with an integer numerator (transiently negative mid-chain is legal); the only float conversion is `Focus.to_fp` at the libvips boundary. Do not introduce float intermediate steps.
- Impossible internal misuse crashes: no guards, no tidy errors, no tests for states no real producer constructs (AGENTS.md). Deleting a code path beats guarding it.
- No fiddle changes (no parser option surface changes in this plan).
- Comment style: constraints only; no removal narration, no "was previously X" notes (AGENTS.md).
- Subagent git safety: worktrees share one stash stack — implementer/reviewer subagents must not run state-mutating git beyond `git add`/`git commit` of their own work (no stash, no reset, no checkout).

## Pinned behaviors (preserve exactly — the results-identical inventory)

1. **Smart/detect crops and the point — a decision record, not a clean pin.** Today's behavior is *internally inconsistent*: a pure attention crop (`smart_crop/3`) and every detector-*fallback* path never touch the point, but a detection **success** re-executes as `{:fp, …}` gravity through the generic clause → `crop_image` → `carry_focus_through_crop`, so it *does* translate the point by the realized (pixel-dependent) crop origin. And `crop_region` resets `guide: :carried` **without** a new `set_focus` directive (`plan_builder.ex`), so the chain `focus=X×Y/focus=auto/<consumer>/crop=W×H@X×Y/<consumer>` consumes that point with a detector configured. `PointFlow` cannot reproduce the success-path translate — the detection outcome does not exist at resolve time. **Decision: after Stage 3, smart/detect crops never advance the point** (it passes through unchanged — not nil'ed). This is the plan's **one deliberate, detector-gated divergence** from byte-identity: reachable only with a host-configured detector, a successful detection, *and* a later `crop=W×H@X×Y`-reset `:carried` consumer with no intervening focus. The accidental success-path translate is treated as a bug-shaped inconsistency, not a contract. Pinned at the `PointFlow` unit level (Task 4), recorded in the TwicPics matrix "Diverges" notes and in the spec's §9 wording (Task 6). No wire pin: there is no assertable baseline for "the trailing window uses the un-translated point" that doesn't just restate the unit test — the matrix note plus the unit pin carry it. *Banked extension (not built here):* if a pixel-time fact ever needs to reach resolve-time state, the acquire seam generalizes — the acquired payload widens from `{w, h}` to an op-published realized report (e.g. a pixel-chosen crop's origin) and the smart/detect rows stage like the resize rows; the staged continuation is the substrate, so this is additive, never a redesign.
2. **Region (coordinate) crops and gravity crops translate the point** by the realized clamped crop origin (`carry_focus_through_crop`, live-TwicPics-verified in #331: `crop=WxH@XxY` carries, it does not reset to the crop centre).
3. **Canvas embeds translate the point** by the realized embed offset (`ExtendCanvas.execute`); an inert extend (canvas == image) is a zero translate either way (the offset clamps to `[0, canvas − image] = [0, 0]`).
4. **A nil carried point at a `:carried` consumer falls back to the centred crop** — byte-identical to a plain centred crop, *including* the `center_bias` that `compensate_crop`'s `:carried` clause sets for the deferred-orientation odd-pixel discard (#146 Bug 2). This path is **hot**: the TwicPics parser's initial guide is `:carried` (`plan_builder.ex` `@initial`), so every plain `cover=`/`crop=` without a focus takes it. After Stage 3 the fallback lives in exactly **one** place: `PointFlow`'s centre-anchor substitution — the fallback is *strategy policy* (live-verified TwicPics semantics), not neutral-executable behavior. The native Plan constructors still accept `:carried` (the TwicPics parser calls them), but a nil-strategy plan resolving `:carried` through the `NeutralResolver` is an **unsupported surface** (spec §4.4: `:carried` means "gravity supplied by the plan's strategy" — with no point-carrying strategy the request is meaningless): no substitution happens and `Crop.execute` structurally yields `{:error, {:invalid_crop_gravity, :carried}}` — no clause, no guard. `focus_test.exs`'s #146 orientation matrix, whose plans are hand-built nil-strategy `:carried` plans, is **re-homed to the real producer path** in Task 5.
5. **A storage-frame point is never gravity-remapped.** `compensate_crop`'s `:carried` clause swaps only the crop box (and sets `center_bias`); the point itself is already storage-frame and rides the pixels. Stage 3's substitution therefore happens **after** orientation compensation — the substituted `{:fp, x, y}` must never pass through `Orientation.compensate_gravity_for/2`.
6. **The point scales by the realized per-axis resize factor** (`Resize.execute` reads the actual result dims), **rotates/reflects with the pixels at the flush** (`Focus.reflect_rotate` on the pre-flush dims, EXIF ∘ user-rotate ∘ user-flip order), and **`to_fp` clamps to `[0, 1]`** only at the libvips boundary.
7. **The directive resolves against the running frame at its chain position**: display-frame operand, bare px rescaled by the (quarter-turn-swapped) shrink factors, positive out-of-bounds clamped to `dim − 1`, then inverse-mapped into the storage frame when an orientation is pending (`Focus.resolve/3`). A later directive overwrites the point.
8. **TwicPics plans are single-pipeline** (`plan_builder.ex` builds exactly one `%Pipeline{}`), so moving the point from plan-lived `State` to per-pipeline `strategy_state` is scope-equivalent. Task 4 verifies this with a grep, not a runtime guard.
9. **The driver's pipeline-boundary backstop flush no longer touches the point** after Stage 3 (today `OrientationFlush.flush` reflect-rotates it). This is unobservable for every parser-reachable pipeline: the pipeline is over, nothing consumes the point after the boundary, and TwicPics plans are single-pipeline. Task 6 documents the invariant.
10. **Padding and trim never touched the point** (no `Focus.*` call in their execute paths) and are TwicPics-unreachable; the point flow's catch-all treats them as point-neutral, same as today.

## File Structure

| File | Role in this plan |
|---|---|
| `lib/image_pipe/resolver.ex` | Continuation type gains the staged `acquire_result` form (Task 1) |
| `lib/image_pipe/transform/resolve_driver.ex` | Recursive stage loop (Task 1); boundary-flush comment (Task 6) |
| `lib/image_pipe/transform/neutral_resolver.ex` | Resize rows stage at the realized-dims seam (Task 1) |
| `lib/image_pipe/parser/imgproxy/resolver.ex` | `rewrap/2` recurses through stages (Task 1) |
| `lib/image_pipe/transform/operation/crop.ex` | **New pure `resolved_rect/3`** shared with `execute` (Task 2); `:carried` execute clause deleted — the fallback is strategy policy, and strategy-less `:carried` is unsupported (Task 5) |
| `lib/image_pipe/transform/operation/extend_canvas.ex` | **New pure `resolved_embed_offset/5`** shared with `execute` (Task 2); `Focus.translate` call deleted (Task 5) |
| `lib/image_pipe/transform/focus.ex` | Bare-point API re-signature + display-dims derivation folded into `resolve/3` (Task 3) |
| `lib/image_pipe/transform/pending_orientation.ex` | **New `display_dims/2`** (Task 3) |
| `lib/image_pipe/parser/twic_pics/resolver.ex` | Carries the point as `strategy_state`; directive row → carry (Task 4) |
| `lib/image_pipe/parser/twic_pics/point_flow.ex` | **Create** (Task 4): the pure point walk over emitted stages |
| `lib/image_pipe/transform/operation/resize.ex` | `Focus.scale` call-site deleted (Task 5) |
| `lib/image_pipe/transform/orientation_flush.ex` | `Focus.reflect_rotate` call-site deleted (Task 5) |
| `lib/image_pipe/transform/state.ex` | `carried_point` field deleted (Task 5) |
| `lib/image_pipe/transform/operation/state_update.ex` | **Deleted** (Task 5 — no producer remains; its `transform.ex` Boundary export goes with it) |
| `test/image_pipe/transform/focus_test.exs` | Task-3 re-signature; Task-5 disposition inventory (native #146 matrix kept; mechanics describes deleted) |
| `test/image_pipe/twic_pics_wire_conformance_test.exs` | Task-0 pins; Task 4/5 gates |
| `test/image_pipe/transform/resolved_plan_golden_test.exs` | Staged driver-seam tests (Task 1) |
| `test/image_pipe/transform/neutral_resolver_test.exs` | Stage-invariant extension of the §4.7 classification gate (Task 1) |
| `test/image_pipe/parser/twic_pics/resolver_test.exs` | Carry semantics + point-flow integration tests (Task 4) |
| `test/image_pipe/architecture_boundary_test.exs` | Strategy-reach scan covers `point_flow.ex` (Task 4) |
| `docs/twicpics_support_matrix.md`, `docs/telemetry.md` | Doc sync (Task 6) |

## Execution notes (for whoever runs this plan)

- **Mode: subagent-driven development** (`superpowers:subagent-driven-development`), fresh implementer subagent per task, with the full two-stage review per task (spec-compliance reviewer + code-quality reviewer — do not shortcut to inline diff-reading). Tasks form a dependency chain in a few shared files, but each task is a distinct risk surface and the per-task review gates have caught real bugs in Stages 1–2.
- **Model pinning**: pin the top tier on Task 1 (the continuation-contract/staging core), Task 4 (the `:carried` → `{:fp}` orientation resolution core), and the final whole-diff review. Cheaper tiers are fine for Tasks 0, 2, 3, 5, 6 implementers and for reviewers of the mechanical tasks.
- **Subagent prompts must state**: "You are the implementer — do NOT delegate or spawn sub-agents", the toolchain line (`export PATH="$(mise where elixir)/bin:$PATH"` before every `mise exec -- mix …`), and the git-safety line (no stash/reset/checkout).
- **Environmental step**: Task 0's optional differential bake (`mise run twic:bake`) needs network access to live TwicPics and the catbox-hosted sources — run it inline (main session), never in a subagent. Everything else in Task 0 is deterministic and default-lane.
- **Per-task review lenses** (disjoint; at least one compatibility lens per AGENTS.md):
  - *TwicPics compatibility*: point math faithfulness vs live-TwicPics semantics — #331 region-crop carry, #321 display-frame focus, the nil-point centred fallback, clamp-to-edge; ground truth is the TwicPics differential suite + `docs/twicpics_support_matrix.md`; for the shared crop-placement math (`calc_position.go` ports) cross-check `/Users/hlindset/src/imgproxy`.
  - *Orientation/frame invariants*: the substitution-after-compensation ordering, `reflect_rotate` position and pre-dims, staged dims' frames (storage vs display at each walk step), `decode_shrink` coherence — the Stage-2 frame-incoherence class.
  - *Process/quality*: TDD structure, test-guidelines compliance (no impossible-misuse tests, no parity pins left behind), clean deletions, boundary/architecture coverage.

---

### Task 0: Pin the point-carry chains (investigation gate)

**Why this task exists:** the carried point's trajectory is currently enforced at *execute* granularity (live image in hand); Stage 3 recomputes it at *resolve* granularity. The existing nets cover focus → cover → crop and region-crop carry **without EXIF** (differential: `focus_multi_consumer`, `focus_carry_*`, `crop_region_carry_*` — the TwicPics differential has **no EXIF-oriented source**), and EXIF focus **without a later consumer** (wire #321). The gap is exactly the highest-risk surface: an EXIF-pending chain where the point must scale at the resize, substitute pre-flush in the storage frame, reflect at the flush, and feed a **post-flush** consumer. Pin it before anything moves.

**Files:**
- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs`
- Optionally modify (environmental, inline only): `test/support/image_pipe/test/twicpics_differential/constellations.ex`

- [ ] **Step 1: Derive the EXIF chain expectations from the fixture.** Read `test/support/image_pipe/twic_pics_wire_conformance_test/exif_oriented_origin.ex`: storage 40×80 portrait, red square filling storage rows 0–39 (full width), EXIF orientation 6 → displays 80×40 with red on the **right** half (display x ∈ [40, 80)). Derivation template for a `focus=X×Y/cover=20x20/crop=10x10` chain against current code: (display point) → `Focus.inverse_fraction` under EXIF 6 (`rotate_fraction/270`: `{u,v} → {v, 1−u}`) → storage point; cover 20x20 under the quarter turn resolves display-frame (80×40 → intermediate display 40×20) and executes a forcing resize to storage 20×40, scaling the point by (20/40, 40/80); the result crop is the display 20×20 box swapped to storage 20×20, `fp = point / (20, 40)`, origin `round_ties_to_even(fp·dim − 10)` clamped to `[0, 20]`; the flush forward-maps (`rotate_fraction/90`: `{u,v} → {1−v, u}`) onto the swapped 20×20 frame; the trailing `crop=10x10` reads the carried point again.
- [ ] **Step 2: Write the pins.** Add to `test/image_pipe/twic_pics_wire_conformance_test.exs` (house style: `call/2`, `dimensions/1`, `average/1`, relational channel assertions):

```elixir
  describe "point carry through multi-consumer chains" do
    # oriented.jpg: storage 40x80, red rows 0-39, EXIF 6 -> displays 80x40 with
    # red on the RIGHT half. focus=44x20 (display, just inside the red edge)
    # inverse-maps to storage (20, 36); the cover scales it to (10, 18), crops
    # storage rows 8..27 (mixed red/white), and the flush rotates point and
    # pixels together. focus=20x20 (white left half) maps to storage (20, 60)
    # and crops rows 20..39 (all white). The trailing crop=10x10 reads the
    # carried point AFTER the flush. This pins the seam scale and the crop-top
    # derivation end to end (a dropped scale crops all-white in both chains and
    # flips the relation); the reflect/translate failure modes are pinned by
    # the region-crop test below ([Flush, crop] order) at the wire and by the
    # resolver unit tests ([crop, Flush] order) at exact-integer precision —
    # an unclamped fp crop always centres the carry, so no wire chain on this
    # half/half fixture can isolate the [crop, Flush] reflect by itself.
    test "EXIF-oriented focus carries through cover to a post-flush consumer" do
      red_chain =
        call(
          "/images/oriented.jpg?twic=v1/focus=44x20/cover=20x20/crop=10x10/output=png",
          exif_opts()
        )

      white_chain =
        call(
          "/images/oriented.jpg?twic=v1/focus=20x20/cover=20x20/crop=10x10/output=png",
          exif_opts()
        )

      assert dimensions(red_chain) == {10, 10}
      assert dimensions(white_chain) == {10, 10}

      [_r1, g_red, _b1 | _] = average(red_chain)
      [_r2, g_white, _b2 | _] = average(white_chain)
      assert g_red < g_white
    end

    # Region-crop carry under EXIF: the region crop flushes FIRST ([Flush, Crop]),
    # so the point must reflect at the flush and then translate by the region
    # origin before the trailing consumer reads it (#331 carry semantics). The
    # region @20x0 spans display x in [20, 60) — white in [20, 40), red in
    # [40, 60) — so the two focus variants land the trailing 10x10 window on
    # opposite colors: focus=72x20 translates to (52, 20), past the region's
    # right edge, and to_fp clamps it to the red edge; focus=28x20 translates
    # to (8, 20), deep in the white part.
    test "EXIF-oriented focus carries through a region crop to a later consumer" do
      red_side =
        call(
          "/images/oriented.jpg?twic=v1/focus=72x20/crop=40x40@20x0/crop=10x10/output=png",
          exif_opts()
        )

      white_side =
        call(
          "/images/oriented.jpg?twic=v1/focus=28x20/crop=40x40@20x0/crop=10x10/output=png",
          exif_opts()
        )

      assert dimensions(red_side) == {10, 10}
      assert dimensions(white_side) == {10, 10}

      [_r1, g_red, _b1 | _] = average(red_side)
      [_r2, g_white, _b2 | _] = average(white_side)
      assert g_red < g_white
    end

    # Double-resize seam: two staged covers in a row, each scaling the point by
    # its realized factor before the next consumer reads it. Differential
    # coverage stops at focus -> cover -> crop; this pins the second seam.
    test "focus carries through two chained covers" do
      focal = call("/images/beach.jpg?twic=v1/focus=top-left/cover=300x100/cover=100x50/output=jpeg")
      other = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=300x100/cover=100x50/output=jpeg")

      assert dimensions(focal) == {100, 50}
      assert dimensions(other) == {100, 50}
      refute average(focal) == average(other)
    end

    # The nil-point centred fallback under EXIF with an odd extent difference:
    # compensate_crop's :carried clause sets center_bias so the discarded pixel
    # lands on the intended display side (#146 Bug 2). Pin the current BYTES
    # relation between the no-focus fallback and an explicit centre focus (the
    # fp path ignores center_bias, so these may legitimately differ by one
    # pixel row/column — record whichever relation currently holds and pin it;
    # body equality is the strongest same-cost pin and PNG output makes it
    # deterministic).
    test "nil-point centred fallback under EXIF quarter turn (odd cover box)" do
      fallback = call("/images/oriented.jpg?twic=v1/cover=15x15/output=png", exif_opts())
      explicit = call("/images/oriented.jpg?twic=v1/focus=center/cover=15x15/output=png", exif_opts())

      assert dimensions(fallback) == {15, 15}
      assert dimensions(explicit) == {15, 15}
      # Record the current relation by running once, then pin it (see Step 3).
      assert fallback.resp_body == explicit.resp_body
    end

    # Canvas-embed translate: the focus is set BEFORE an inside letterbox, so
    # the point must translate by the realized embed offset before the trailing
    # cover consumes it. Nothing else gates PointFlow's ExtendCanvas step
    # deterministically (the #441 inside_ratio_focus_* fixtures place the focus
    # AFTER the inside). Opposite-corner focuses land the trailing window on
    # opposite letterbox bands, so the outputs must differ.
    test "focus set before an inside letterbox carries through the canvas embed" do
      top_left =
        call("/images/beach.jpg?twic=v1/focus=0x0/inside=200x200/cover=50x25/output=png")

      bottom_right =
        call("/images/beach.jpg?twic=v1/focus=3999x2666/inside=200x200/cover=50x25/output=png")

      assert dimensions(top_left) == {50, 25}
      assert dimensions(bottom_right) == {50, 25}
      refute average(top_left) == average(bottom_right)
    end
  end
```

- [ ] **Step 3: Run and calibrate — STOP conditions.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`

  - The channel-relation tests must pass against **current** code. If a derived relation fails, first re-derive (Step 1 template) — a wrong hand-derivation is the likely cause; adjust coordinates so the relation is discriminating and correct. If the *observed current behavior* contradicts the derivation in a way that suggests the carry itself is wrong today (e.g. the point demonstrably does not reflect at the flush): **STOP, file a bug, and consult** before any Stage-3 task executes — the pins would otherwise bake a bug in as the contract.
  - For the nil-point test: if the two bodies differ (a legitimate 1px `center_bias` outcome — the fp path ignores `center_bias`), flip the assertion to `refute fallback.resp_body == explicit.resp_body` **plus** a comment recording why, and keep it. Either relation is a valid pin; the point is that Stage 3 must not change it.
- [ ] **Step 4 (optional, environmental — inline only): differential constellations.** If live-bake access is available, add to `constellations.ex` under the `:focus` group: `c("focus_double_cover", "focus=top-left/cover=300x100/cover=100x50", :focus)` and `c("focus_inside_canvas_carry", "focus=100x100/inside=300x300/cover=120x60", :focus)` (the focus must precede the `inside` so the point actually passes through the canvas embed), then `mise run twic:bake`, review `REPORT.md`, and commit fixtures + manifest per the suite README. If ImagePipe diverges from live TwicPics on a new fixture: **STOP and consult** (same rule as Stage 2 Task 0). If bake access is unavailable, skip — the Step-2 pins plus the existing `focus_multi_consumer`/`crop_region_carry_*` fixtures are the gate.
- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: pin TwicPics point-carry chains ahead of the resolve Stage-3 move"
```

---

### Task 1: Staged continuation — contract, driver stage loop, neutral staging

The one contract change everything else rides on. After this task: an `:acquire` `then_fn` may return `{ops, continuation}` (a further stage) instead of the final `{shape, strategy_state}`; the driver executes stage ops and recurses; the neutral resolver's resize rows stage whenever the emission has a post-resize tail; the imgproxy strategy's carry threads through stages. **Results-identical**: the staged advance computes the tail's dims with `Crop.resolved_box_dims` (already the trusted pure mirror of `Crop.execute`'s box) and the exact flush axis-swap, so every integer matches today's realized read — the record-based golden cases (`cover_result_crop`, `quarter_turn_cover`, `auto_landscape_cover`, `fill_down_target_gt_source`, …) are the proof.

**Files:**
- Modify: `lib/image_pipe/resolver.ex`
- Modify: `lib/image_pipe/transform/resolve_driver.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `lib/image_pipe/parser/imgproxy/resolver.ex`
- Test: `test/image_pipe/transform/resolved_plan_golden_test.exs`, `test/image_pipe/transform/neutral_resolver_test.exs`

**Interfaces:**
- Produces (the Stage-3 continuation contract):

```elixir
@type acquire_result ::
        {SourceShape.t(), strategy_state()}
        | {[struct()], continuation()}
@type continuation ::
        {:advance, SourceShape.t(), strategy_state()}
        | {:acquire, ({pos_integer(), pos_integer()} -> acquire_result())}
```

- Invariant later tasks rely on: **a `%Transform.Operation.Resize{}` is always the terminal op of its stage** — any ops after a resize in an emission are delivered by the stage the `then_fn` returns, so the acquired dims at every seam that follows a resize are that resize's realized post-resize dims.
- Consumed by: Task 4 (`PointFlow` scales the point at seams and walks stage op lists).

- [ ] **Step 1: Failing driver-seam test — staged plain cover.** Add to `resolved_plan_golden_test.exs` (follows the file's capturing-chain/injection harness; alias `ImagePipe.Plan.Operation.Blur, as: PlanBlur` and `ImagePipe.Transform.Operation.Flush, as: ExecFlush` at the top):

```elixir
  describe "staged continuation (spec §4.4 Stage 3)" do
    # A cover expands to [resize, crop]. Staged, the driver executes [resize],
    # acquires the realized post-resize dims, and only then receives [crop] —
    # parameterized against the MEASURED intermediate. The trailing blur
    # observes the advanced shape via the driver overlay.
    test "a plain cover splits at the realized-dims seam; the crop box follows acquired dims" do
      plan = [
        %PlanResize{
          mode: :cover,
          width: {:px, 100},
          height: {:px, 100},
          dpr: {:ratio, 1, 1},
          enlargement: :deny,
          guide: :center
        },
        %PlanBlur{sigma: 1.0}
      ]

      {:ok, image} = Image.new(800, 600, color: :white)

      shape =
        SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})

      state = %State{image: image}
      batches_agent = start_supervised!({Agent, fn -> [] end})

      capturing_chain = fn %State{} = st, ops, _opts ->
        Agent.update(batches_agent, &[{ops, st.source_dimensions} | &1])
        {:ok, st}
      end

      # Realized cover intermediate for 800x600 -> 100x100 is {133, 100}; inject
      # a -1 divergence on the height ({133, 99}) to prove the crop box resolves
      # against the MEASURED seam dims, not the planned ones (the 100px box
      # bounds to the 99px acquired frame).
      inject = fn _image -> {133, 99} end

      assert {:ok, %State{}} =
               ResolveDriver.run(
                 plan,
                 shape,
                 {NeutralResolver, NeutralResolver.init()},
                 state,
                 chain: capturing_chain,
                 acquire_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      # Three batches: [resize] / [crop] (the stage) / [blur].
      assert [
               {[%ExecResize{}], _},
               {[%Crop{} = crop], _},
               {[_blur], blur_source_dims}
             ] = batches

      # The result-crop box is bounded to the acquired frame; the advanced shape
      # the blur sees is the crop box, computed purely from the injected dims —
      # {100, 99}, not the planned {100, 100}.
      assert Crop.resolved_box_dims(crop, 133, 99) == {100, 99}
      assert blur_source_dims == {100, 99}
    end

    # Under a pending quarter turn the emission is [resize, crop, Flush]; staged
    # it becomes [resize] / [crop, Flush], with the final shape computed purely:
    # the compensated crop's storage-frame box, axis-swapped by the flush.
    test "a pending-orientation cover stages; the final shape is the flushed crop box" do
      po = %ImagePipe.Transform.PendingOrientation{auto_rotate?: true, exif_angle: 90}

      plan = [
        %PlanResize{
          mode: :cover,
          width: {:px, 20},
          height: {:px, 20},
          dpr: {:ratio, 1, 1},
          enlargement: :deny,
          guide: :center
        },
        %PlanBlur{sigma: 1.0}
      ]

      {:ok, image} = Image.new(40, 80, color: :white)
      shape = SourceShape.seed(%{width: 40, height: 80, pending_orientation: po, decode_shrink: nil})
      state = %State{image: image}
      batches_agent = start_supervised!({Agent, fn -> [] end})

      capturing_chain = fn %State{} = st, ops, _opts ->
        Agent.update(batches_agent, &[{ops, st.source_dimensions} | &1])
        {:ok, st}
      end

      # The display-frame cover of the 80x40 display source into 20x20 is a
      # 40x20 display intermediate == a 20x40 storage forcing resize.
      inject = fn _image -> {20, 40} end

      assert {:ok, %State{}} =
               ResolveDriver.run(
                 plan,
                 shape,
                 {NeutralResolver, NeutralResolver.init()},
                 state,
                 chain: capturing_chain,
                 acquire_dims: inject
               )

      batches = Agent.get(batches_agent, &Enum.reverse/1)

      assert [
               {[%ExecResize{mode: :force}], _},
               {[%Crop{}, %ExecFlush{}], _},
               {[_blur], blur_source_dims}
             ] = batches

      # Storage-frame 20x20 crop box, quarter-turn-swapped by the flush -> 20x20.
      assert blur_source_dims == {20, 20}
    end
  end
```

(Alias `ImagePipe.Transform.Operation.Resize, as: ExecResize` — the file already aliases `Crop` and `Padding`.)

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/transform/resolved_plan_golden_test.exs`
Expected: FAIL — batches arrive as `[[resize, crop], [blur]]` (no stage split).

- [ ] **Step 3: Widen the continuation type.** In `resolver.ex`:

```elixir
  @type strategy_state :: term()
  @type spec :: {module(), strategy_state()}

  @typedoc """
  What an `:acquire` `then_fn` returns: the final post-op `{shape,
  strategy_state}`, or a further `{ops, continuation}` stage — a
  multi-executable expansion split at the realized-dims seam (spec §4.4). The
  driver executes the stage's ops and continues; shape acquisition stays the
  driver's one seam, just allowed to fire more than once per plan op.
  """
  @type acquire_result ::
          {SourceShape.t(), strategy_state()}
          | {[struct()], continuation()}

  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> acquire_result())}
```

(Update the `@moduledoc`: mention staging in the continuation-channel sentence, and fix the stale `ImagePipe.Transform.ResolveDriver.advance/4` reference — Step 4 replaces that function with `execute_stages`/`continue`.)

- [ ] **Step 4: Driver stage loop.** In `resolve_driver.ex`, replace the per-op body and `advance/4` with a recursive execute-and-continue:

```elixir
    pipeline
    |> Enum.reduce_while({:ok, shape, spec, state}, fn operation, acc ->
      {:ok, shape, spec, state} = acc
      state = overlay(state, shape)

      {ops, continuation} = Resolver.resolve(spec, shape, operation)

      case execute_stages(ops, continuation, spec, state, chain, acquire_dims, opts) do
        {:ok, shape, spec, state} -> {:cont, {:ok, shape, spec, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
```

```elixir
  # One resolve may execute in several stages: run this stage's ops, then either
  # finish (final {shape, strategy_state}) or acquire the realized dims and run
  # the next stage the then_fn returns. Recursion depth is the emission's stage
  # count (2 for a cover) — never unbounded.
  defp execute_stages(ops, continuation, spec, state, chain, acquire_dims, opts) do
    case chain.(state, ops, opts) do
      {:ok, %State{} = state} ->
        continue(continuation, spec, state, chain, acquire_dims, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue({:advance, %SourceShape{} = shape, strategy_state}, {module, _}, state, _chain, _acquire_dims, _opts),
    do: {:ok, shape, {module, strategy_state}, state}

  defp continue({:acquire, then_fn}, {module, _} = spec, state, chain, acquire_dims, opts) do
    case then_fn.(acquire_dims.(state.image)) do
      {%SourceShape{} = shape, strategy_state} ->
        {:ok, shape, {module, strategy_state}, state}

      {ops, continuation} when is_list(ops) ->
        execute_stages(ops, continuation, spec, state, chain, acquire_dims, opts)
    end
  end
```

Update the module comment's continuation paragraph to describe staging (an `:acquire` may return a further stage; the overlay still runs once per *plan op*, before the first stage — the shape only advances at the continuation's end, so mid-emission executables read the same overlaid frame they do today).

- [ ] **Step 5: Stage the neutral resize rows.** In `neutral_resolver.ex`, replace the `%PlanResize{}` `do_resolve` clause:

```elixir
  # ── resize ────────────────────────────────────────────────────────────────
  # Non-identity pending: compensate for the pending orientation, run, then
  # flush so the cover result-crop and tail are post-flush/literal (see
  # pending_resize_ops). Plain path: no compensation, no flush.
  #
  # A resize's realized dims can round ±1 off the naive target, so any op after
  # it must be parameterized against the MEASURED post-resize dims: the
  # emission stages at the realized-dims seam (spec §4.4). The resize is always
  # the terminal op of its stage; the stage the then_fn returns carries the
  # tail (result crop and/or flush), with the shape advanced purely from the
  # acquired dims — the crop box via Crop.resolved_box_dims (the exact integers
  # Crop.execute produces on an image of that size) and the flush's exact axis
  # swap. A bare [resize] emission needs no stage and keeps the final form.
  defp do_resolve(%PlanResize{} = operation, %SourceShape{} = shape) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        [resize | tail] = pending_resize_ops(operation, po, shape)

        stage = fn {w, h} ->
          {box_w, box_h} = staged_tail_dims(tail, {w, h})
          {display_w, display_h} = swap_if_quarter_turn({box_w, box_h}, po)

          {tail ++ [%Flush{}],
           advance(%{
             shape
             | width: display_w,
               height: display_h,
               frame: :display,
               pending_orientation: nil,
               decode_shrink: nil
           })}
        end

        {[resize], {:acquire, stage}}

      _none_or_identity ->
        # An identity pending is kept (this row is not a flush site); the
        # pipeline boundary clears it without pixels.
        case Lowering.executable_operations(operation, shape) do
          [resize] ->
            then_fn = fn {w, h} ->
              {%{shape | width: w, height: h, decode_shrink: nil}, nil}
            end

            {[resize], {:acquire, then_fn}}

          [resize | tail] ->
            stage = fn {w, h} ->
              {box_w, box_h} = staged_tail_dims(tail, {w, h})
              {tail, advance(%{shape | width: box_w, height: box_h, decode_shrink: nil})}
            end

            {[resize], {:acquire, stage}}
        end
    end
  end
```

and add the helper next to `plain_ops_advance/2`:

```elixir
  # Realized dims of a resize's post-resize tail, computed purely against the
  # acquired post-resize dims. The tail is at most one result crop; its box is
  # bounded to the acquired frame exactly as Crop.execute bounds it.
  defp staged_tail_dims([], {w, h}), do: {w, h}
  defp staged_tail_dims([%Crop{} = crop], {w, h}), do: Crop.resolved_box_dims(crop, w, h)
```

- [ ] **Step 6: Recurse the imgproxy rewrap.** In `parser/imgproxy/resolver.ex`:

```elixir
  defp rewrap({:advance, %SourceShape{} = shape, nil}, carry), do: {:advance, shape, carry}

  defp rewrap({:acquire, then_fn}, carry) do
    {:acquire,
     fn dims ->
       case then_fn.(dims) do
         {%SourceShape{} = shape, nil} -> {shape, carry}
         {ops, continuation} when is_list(ops) -> {ops, rewrap(continuation, carry)}
       end
     end}
  end
```

(Update the delegation comment: the carry now also survives every *stage* of a staged emission.)

- [ ] **Step 7: Extend the §4.7 classification gate with the stage invariant.** In `test/image_pipe/transform/neutral_resolver_test.exs`, add to the narrowing `describe` (the `%PlanResize{}` fixture is the `@acquire_ops` "Resize" entry):

```elixir
    # Stage invariant (spec §4.4 Stage 3): a %Transform.Operation.Resize{} is
    # always the TERMINAL op of its stage — the emitted list ends at the
    # resize, and any tail arrives via the stage the then_fn returns, already
    # resize-free. PointFlow's seam scaling relies on this.
    test "a resize is the terminal op of its stage", %{shape: s} do
      op = %PlanResize{
        mode: :cover,
        width: {:px, 50},
        height: {:px, 40},
        dpr: {:ratio, 1, 1},
        enlargement: :forbid,
        guide: :center
      }

      {ops, {:acquire, then_fn}} = NeutralResolver.resolve(s, nil, op)
      assert [%ExecResize{}] = ops

      case then_fn.({50, 40}) do
        {%SourceShape{}, nil} ->
          :ok

        {stage_ops, _continuation} when is_list(stage_ops) ->
          refute Enum.any?(stage_ops, &match?(%ExecResize{}, &1))
      end
    end
```

(Alias `ImagePipe.Transform.Operation.Resize, as: ExecResize` in the test file if not present.)

- [ ] **Step 8: Full verification**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS. Watch specifically: the record-based golden cases (`cover_result_crop`, `quarter_turn_cover`, `auto_landscape_cover`, `min_width_coupling`, `fill_down_target_gt_source`) — the canonical token streams are per-op and batch-independent, so they prove the staged integers equal the realized ones; the existing `±1 divergence` and `carry survives an :acquire` seam tests (both `[resize]`-only plans) must pass unchanged; both differentials; both wire suites; the Task-0 pins.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: staged resolver continuation — resize emissions split at the realized-dims seam"
```

---

### Task 2: Pure realized-geometry helpers on `Crop` and `ExtendCanvas`

The point flow (Task 4) needs the realized crop origin and embed offset without a live image. Extract them as pure functions **used by `execute` itself** so they cannot drift (the `resolved_box_dims`/`resolved_canvas_dims` precedent).

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex`
- Modify: `lib/image_pipe/transform/operation/extend_canvas.ex`
- Test: `test/image_pipe/transform/crop_operation_test.exs` (the existing crop-operation test file — there is no `operation/crop_test.exs`; do not create one), `test/image_pipe/transform/operation/extend_canvas_test.exs` (follow each file's existing conventions; add the describe blocks below)

**Interfaces:**
- Produces:

```elixir
Crop.resolved_rect(Crop.t(), pos_integer(), pos_integer()) ::
  {:ok, %{left: integer(), top: integer(), width: pos_integer(), height: pos_integer()}}
  | {:error, term()}

ExtendCanvas.resolved_embed_offset(ExtendCanvas.t(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
  {non_neg_integer(), non_neg_integer()}
```

- `resolved_rect/3` is defined for concrete-gravity (anchor/fp) and coordinate crops; `:smart`/`{:smart, _}`/`{:detect, _}`/`:carried` gravities have no pure rectangle (pixels or a substituted point decide it) and must never be passed — trusted internal contract, no guard.
- Consumed by: Task 4 (`PointFlow`).

- [ ] **Step 1: Failing tests.** `Vix.Vips.Operation.xyz/2` makes coordinate-valued images (pixel `(x, y)` holds `[x, y]`), so the realized origin is directly observable: after any crop, pixel `(0, 0)` of the result equals `[left, top]`. Add to `test/image_pipe/transform/crop_operation_test.exs`:

```elixir
  describe "resolved_rect/3 mirrors execute/2 exactly" do
    defp xyz_state(w, h) do
      {:ok, image} = Vix.Vips.Operation.xyz(w, h)
      %ImagePipe.Transform.State{image: image}
    end

    defp origin_pixel(%ImagePipe.Transform.State{image: image}) do
      # Positional API — Image.get_pixel!(image, x, y); see the existing usage
      # in test/transform_chain_test.exs.
      Image.get_pixel!(image, 0, 0)
    end

    property "gravity and coordinate crops: execute's realized rect equals resolved_rect" do
      check all image_w <- StreamData.integer(8..64),
                image_h <- StreamData.integer(8..64),
                crop_w <- StreamData.integer(1..64),
                crop_h <- StreamData.integer(1..64),
                gravity <-
                  StreamData.one_of([
                    StreamData.tuple(
                      {StreamData.constant(:anchor),
                       StreamData.member_of([:left, :center, :right]),
                       StreamData.member_of([:top, :center, :bottom])}
                    ),
                    StreamData.tuple(
                      {StreamData.constant(:fp), StreamData.float(min: 0.0, max: 1.0),
                       StreamData.float(min: 0.0, max: 1.0)}
                    )
                  ]),
                max_runs: 60 do
        crop = %Crop{
          width: {:pixels, crop_w},
          height: {:pixels, crop_h},
          crop_from: :gravity,
          gravity: gravity
        }

        assert {:ok, %{left: left, top: top, width: w, height: h}} =
                 Crop.resolved_rect(crop, image_w, image_h)

        {:ok, state} = Crop.execute(crop, xyz_state(image_w, image_h))
        assert origin_pixel(state) == [left, top]
        assert {Image.width(state.image), Image.height(state.image)} == {w, h}
      end
    end

    test "coordinate crop resolves the clamped origin" do
      crop = %Crop{
        width: {:pixels, 20},
        height: {:pixels, 20},
        crop_from: %{left: {:pixels, 50}, top: {:pixels, 10}}
      }

      assert {:ok, %{left: left, top: top, width: 20, height: 20}} =
               Crop.resolved_rect(crop, 60, 60)

      {:ok, state} = Crop.execute(crop, xyz_state(60, 60))
      assert origin_pixel(state) == [left, top]
    end

    test "offsets and offset_scale flow into the origin" do
      crop = %Crop{
        width: {:pixels, 10},
        height: {:pixels, 10},
        crop_from: :gravity,
        gravity: {:anchor, :left, :top},
        x_offset: {:pixels, 3},
        y_offset: {:pixels, 5},
        offset_scale: 2.0
      }

      assert {:ok, %{left: 6, top: 10}} = Crop.resolved_rect(crop, 40, 40)

      {:ok, state} = Crop.execute(crop, xyz_state(40, 40))
      assert origin_pixel(state) == [6, 10]
    end
  end
```

And to `test/image_pipe/transform/operation/extend_canvas_test.exs`:

```elixir
  describe "resolved_embed_offset/5 mirrors execute/2's embed placement" do
    test "each anchor places the content at the resolved offset" do
      # centre = Geometry.center_origin/2 = round_ties_to_even((outer − inner + 1) / 2):
      # x = rte(21/2) = 10, y = rte(11/2) = 6.
      for {gravity, expected} <- [
            {{:anchor, :left, :top}, {0, 0}},
            {{:anchor, :center, :center}, {10, 6}},
            {{:anchor, :right, :bottom}, {20, 10}}
          ] do
        op = %ExtendCanvas{rule: {:dimensions, {:pixels, 40}, {:pixels, 30}}, gravity: gravity}

        assert ExtendCanvas.resolved_embed_offset(op, 20, 20, 40, 30) == expected
      end
    end

    test "a far-edge anchor subtracts its offset; the origin clamps into the canvas" do
      op = %ExtendCanvas{
        rule: {:dimensions, {:pixels, 40}, {:pixels, 30}},
        gravity: {:anchor, :right, :bottom},
        x_offset: 5.0,
        y_offset: 100.0
      }

      assert ExtendCanvas.resolved_embed_offset(op, 20, 20, 40, 30) == {15, 0}
    end
  end
```

(Re-derive the centre expectation from `ImagePipe.Transform.Geometry.center_origin/2` before running; if it rounds differently than the comment claims, fix the expectation to the real value, not the code.)

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs test/image_pipe/transform/operation/extend_canvas_test.exs`
Expected: FAIL — `resolved_rect/3` and `resolved_embed_offset/5` undefined.

- [ ] **Step 3: Extract `Crop.resolved_rect/3`.** In `crop.ex`, rename the two private `crop_coordinates/4` clauses into a public `resolved_rect/3` (bodies unchanged — the `%State{}` parameter was already unused):

```elixir
  @doc false
  # The realized crop rectangle resolved purely against the given live image
  # dims — the exact {left, top, width, height} `execute/2` crops on an image
  # of that size. Defined for concrete-gravity (anchor/fp) and coordinate
  # crops; a :smart/:detect/:carried gravity has no pure rectangle (pixels or
  # a substituted point decide it). Lets a resolver strategy translate a
  # carried point by the realized crop origin without reading the live image.
  @spec resolved_rect(t(), pos_integer(), pos_integer()) ::
          {:ok, %{left: integer(), top: integer(), width: pos_integer(), height: pos_integer()}}
          | {:error, term()}
  def resolved_rect(%__MODULE__{crop_from: :gravity} = params, image_width, image_height) do
    # body of the current crop_coordinates/4 :gravity clause, verbatim
  end

  def resolved_rect(%__MODULE__{} = params, image_width, image_height) do
    # body of the current crop_coordinates/4 coordinate clause, verbatim
  end
```

and point `execute/2` at it:

```elixir
    case resolved_rect(params, image_width, image_height) do
```

Delete the old `crop_coordinates/4` heads.

- [ ] **Step 4: Extract `ExtendCanvas.resolved_embed_offset/5`.** In `extend_canvas.ex`:

```elixir
  @doc false
  # The realized embed origin of the image content inside the resolved canvas —
  # the exact {x, y} `execute/2` passes to Image.embed (gravity placement,
  # signed offset, clamped into the canvas). Pure; the resolver-strategy twin
  # of resolved_canvas_dims/3.
  @spec resolved_embed_offset(t(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def resolved_embed_offset(%__MODULE__{} = operation, image_width, image_height, canvas_width, canvas_height) do
    {offset(:x, operation.gravity, operation.x_offset, image_width, canvas_width),
     offset(:y, operation.gravity, operation.y_offset, image_height, canvas_height)}
  end
```

and rewire `embed_image/4`:

```elixir
  defp embed_image(%State{} = state, %__MODULE__{} = operation, width, height) do
    {x, y} = resolved_embed_offset(operation, image_width(state), image_height(state), width, height)

    with {:ok, image} <- alpha_ready_image(state.image, operation.background),
         ...
```

- [ ] **Step 5: Run tests, then the operation suites**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs test/image_pipe/transform/operation/ && mise exec -- mix test`
Expected: PASS (pure extraction; `execute` routes through the helpers).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: pure resolved_rect/resolved_embed_offset shared with execute"
```

---

### Task 3: Neutralize the `Focus` API; consolidate the display-dims decision

Two coupled mechanical moves in `focus.ex`: (a) re-signature the point transforms to the bare point (`point() | nil`) so the strategy can call them without a `State` (the four executable call sites adapt in place — deleted wholesale in Task 5); (b) fold the quarter-turn display-dims derivation *into* `Focus.resolve/3` via a new `PendingOrientation.display_dims/2`, killing the duplication between `parser/twic_pics/resolver.ex` and `focus.ex` (the PR-#441 review deferral).

**Files:**
- Modify: `lib/image_pipe/transform/focus.ex`
- Modify: `lib/image_pipe/transform/pending_orientation.ex`
- Modify: `lib/image_pipe/transform/operation/resize.ex`, `lib/image_pipe/transform/operation/crop.ex`, `lib/image_pipe/transform/operation/extend_canvas.ex`, `lib/image_pipe/transform/orientation_flush.ex` (call-site adaptation)
- Modify: `lib/image_pipe/parser/twic_pics/resolver.ex` (focus row loses its display computation)
- Test: `test/image_pipe/transform/focus_test.exs`, `test/image_pipe/transform/focus_property_test.exs`, `test/image_pipe/transform/pending_orientation_test.exs` (create the describe if the file lacks one)

**Interfaces:**
- Produces:

```elixir
PendingOrientation.display_dims({pos_integer(), pos_integer()}, PendingOrientation.t() | nil) ::
  {pos_integer(), pos_integer()}

Focus.scale(Focus.point() | nil, Focus.ratio(), Focus.ratio()) :: Focus.point() | nil
Focus.translate(Focus.point() | nil, integer(), integer()) :: Focus.point() | nil
Focus.to_fp(Focus.point() | nil, pos_integer(), pos_integer()) :: nil | {:fp, float(), float()}
Focus.reflect_rotate(Focus.point() | nil, PendingOrientation.t(), {pos_integer(), pos_integer()}) :: Focus.point() | nil
Focus.resolve(Focus.operand(), %{storage: {pos_integer(), pos_integer()}, decode_shrink: map() | nil}, PendingOrientation.t() | nil) :: Focus.point()
```

- Consumed by: Task 4 (`PointFlow`, the TwicPics directive row), Task 5 (call-site deletion).

- [ ] **Step 1: Failing tests.** Add to `pending_orientation_test.exs`:

```elixir
  describe "display_dims/2" do
    test "nil pending and non-quarter turns keep the axes" do
      assert PendingOrientation.display_dims({80, 40}, nil) == {80, 40}

      half_turn = %PendingOrientation{auto_rotate?: true, exif_angle: 180}
      assert PendingOrientation.display_dims({80, 40}, half_turn) == {80, 40}
    end

    test "a pending quarter turn swaps the axes" do
      quarter = %PendingOrientation{auto_rotate?: true, exif_angle: 90}
      assert PendingOrientation.display_dims({40, 80}, quarter) == {80, 40}
    end
  end
```

Update `focus_test.exs`/`focus_property_test.exs` signatures mechanically: every `Focus.scale(%State{carried_point: p}, …)` becomes `Focus.scale(p, …)` asserting on the returned point; `Focus.resolve` calls drop the `:display` key from the ctx map (the function now derives it). Keep every assertion value unchanged — this task moves signatures, not math.

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/transform/pending_orientation_test.exs test/image_pipe/transform/focus_test.exs`
Expected: FAIL — `display_dims/2` undefined; `Focus.*` arity mismatches.

- [ ] **Step 3: Implement.** `pending_orientation.ex`:

```elixir
  @doc """
  The display-frame dims for storage-frame dims under a (possibly nil) pending
  orientation: the axes swap iff a quarter turn is pending. The shared home
  for the nil-tolerant form of this decision (the Focus/strategy dedup);
  resolver-internal sites with a proven non-nil pending may still swap via
  quarter_turn?/1 directly.
  """
  @spec display_dims({pos_integer(), pos_integer()}, t() | nil) ::
          {pos_integer(), pos_integer()}
  def display_dims(dims, nil), do: dims

  def display_dims({w, h} = dims, %__MODULE__{} = po),
    do: if(quarter_turn?(po), do: {h, w}, else: dims)
```

`focus.ex` — bare-point signatures (drop the `State` alias entirely):

```elixir
  @spec scale(point() | nil, ratio(), ratio()) :: point() | nil
  def scale(nil, _sx, _sy), do: nil
  def scale({x, y}, sx, sy), do: {ratio_mul(x, sx), ratio_mul(y, sy)}

  @spec translate(point() | nil, integer(), integer()) :: point() | nil
  def translate(nil, _dx, _dy), do: nil
  def translate({x, y}, dx, dy), do: {ratio_add_int(x, dx), ratio_add_int(y, dy)}

  @spec to_fp(point() | nil, pos_integer(), pos_integer()) :: nil | {:fp, float(), float()}
  def to_fp(nil, _width, _height), do: nil

  def to_fp({x, y}, width, height),
    do: {:fp, clamp01(ratio_to_float(x) / width), clamp01(ratio_to_float(y) / height)}

  @spec reflect_rotate(point() | nil, PendingOrientation.t(), {pos_integer(), pos_integer()}) ::
          point() | nil
  def reflect_rotate(nil, _po, _pre), do: nil

  def reflect_rotate({x, y}, %PendingOrientation{} = po, {pre_w, pre_h}) do
    {fx2, fy2} = forward_fraction({ratio_div(x, pre_w), ratio_div(y, pre_h)}, po)
    {post_w, post_h} = PendingOrientation.display_dims({pre_w, pre_h}, po)
    {ratio_mul(fx2, {:ratio, post_w, 1}), ratio_mul(fy2, {:ratio, post_h, 1})}
  end
```

`Focus.resolve/3` — ctx loses `:display`, derived internally:

```elixir
  @typedoc """
  Resolution context for `resolve/3`: the live storage-frame dims the carried
  point is stored in, and the realized shrink-on-load factor (or `nil`). The
  display-frame dims the operand resolves against are derived internally
  (PendingOrientation.display_dims/2).
  """
  @type resolve_ctx :: %{
          storage: {pos_integer(), pos_integer()},
          decode_shrink: %{w: float(), h: float()} | nil
        }

  @spec resolve(operand(), resolve_ctx(), PendingOrientation.t() | nil) :: point()
  def resolve(operand, %{storage: {sw, sh}, decode_shrink: shrink}, po) do
    {dw, dh} = PendingOrientation.display_dims({sw, sh}, po)
    {sx, sy} = orient_shrink(shrink, po)
    x = resolve_axis(operand_x(operand), dw, sx)
    y = resolve_axis(operand_y(operand), dh, sy)

    if is_nil(po) or PendingOrientation.identity?(po) do
      {x, y}
    else
      {fx, fy} = inverse_fraction({ratio_div(x, dw), ratio_div(y, dh)}, po)
      {ratio_mul(fx, {:ratio, sw, 1}), ratio_mul(fy, {:ratio, sh, 1})}
    end
  end
```

Call-site adaptation (behavior-identical wrappers; deleted in Task 5):
- `resize.ex` execute:

```elixir
          state = %State{
            state
            | carried_point:
                Focus.scale(
                  state.carried_point,
                  {:ratio, Image.width(image), before_w},
                  {:ratio, Image.height(image), before_h}
                )
          }

          state = set_image(state, image)
```

- `crop.ex` `:carried` clause: `case Focus.to_fp(state.carried_point, image_width(state), image_height(state)) do`; `carry_focus_through_crop`: `%State{state | carried_point: Focus.translate(state.carried_point, -left, -top)}`.
- `extend_canvas.ex`: `{:ok, set_image(%State{state | carried_point: Focus.translate(state.carried_point, x, y)}, image)}`.
- `orientation_flush.ex`: `state = %State{state | carried_point: Focus.reflect_rotate(state.carried_point, po, pre)}`.
- `parser/twic_pics/resolver.ex` focus row:

```elixir
    focus_ctx = %{storage: SourceShape.live_dims(shape), decode_shrink: shape.decode_shrink}
    resolved = Focus.resolve(operand, focus_ctx, shape.pending_orientation)
```

(drop the `display` computation and, if now unused, the `PendingOrientation` alias).

- [ ] **Step 4: Full verification**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS — signature move only; the TwicPics differential + wire suites and Task-0 pins prove no math changed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: bare-point Focus API; display-dims decision owned by PendingOrientation"
```

---

### Task 4: The TwicPics point carry (CORE)

The move itself. The TwicPics strategy carries the point as `strategy_state` (`Focus.point() | nil`, `init/0` → `nil`); the `set_focus` directive resolves into the carry (**zero ops** — no more `StateUpdate`); every delegated emission is post-processed by a pure point walk (`PointFlow`) that advances the point exactly as the execute-time mechanics do, substitutes `:carried` gravity **after** the neutral resolver's orientation compensation, and threads the carry through staged continuations. After this task the executables' `State`-based mechanics still exist but are dead: `State.carried_point` is never set (nil at every `Focus.*` call site → all no-ops), and no crop handed to the chain carries `:carried` gravity.

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/point_flow.ex`
- Modify: `lib/image_pipe/parser/twic_pics/resolver.ex`
- Modify: `test/image_pipe/parser/twic_pics/resolver_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs` (strategy-reach scan covers the new file)

**Interfaces:**
- Consumes: Task 1's staged continuation + resize-terminal invariant; Task 2's `Crop.resolved_rect/3`, `ExtendCanvas.resolved_embed_offset/5`, `Crop.resolved_box_dims/3`, `ExtendCanvas.resolved_canvas_dims/3`; Task 3's bare-point `Focus` API + `PendingOrientation.display_dims/2`.
- Produces: `ImagePipe.Parser.TwicPics.PointFlow.advance([struct()], continuation, Focus.point() | nil, SourceShape.t()) :: {[struct()], continuation}` — ops with `:carried` substituted, continuation rewrapped to carry the advanced point.

- [ ] **Step 1: Failing strategy tests.** Rewrite `test/image_pipe/parser/twic_pics/resolver_test.exs`'s focus test (it currently asserts a `StateUpdate` emission) and add the flow tests:

```elixir
defmodule ImagePipe.Parser.TwicPics.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Resolver, as: TwicPicsResolver
  alias ImagePipe.Plan.Operation.Directive
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize, as: ExecResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h, po \\ nil) do
    SourceShape.seed(%{width: w, height: h, pending_orientation: po, decode_shrink: nil})
  end

  test "set_focus resolves the operand into the carry with zero ops" do
    op = %Directive{name: :set_focus, payload: {:coord, {:px, 200}, {:px, 150}}}

    assert {[], {:advance, returned_shape, {x, y}}} =
             TwicPicsResolver.resolve(shape(800, 600), nil, op)

    assert returned_shape == shape(800, 600)
    assert x == {:ratio, 200, 1}
    assert y == {:ratio, 150, 1}
  end

  test "a later set_focus overwrites the carried point" do
    op = %Directive{name: :set_focus, payload: {:coord, {:px, 10}, {:px, 20}}}

    assert {[], {:advance, _shape, {x, y}}} =
             TwicPicsResolver.resolve(shape(800, 600), {{:ratio, 5, 1}, {:ratio, 5, 1}}, op)

    assert {x, y} == {{:ratio, 10, 1}, {:ratio, 20, 1}}
  end

  test "delegated ops still match the neutral resolution for a nil point" do
    {:ok, op} = ImagePipe.Plan.Operation.blur(2.0)
    {neutral_ops, {:advance, neutral_shape, nil}} = NeutralResolver.resolve(shape(800, 600), nil, op)

    assert {^neutral_ops, {:advance, ^neutral_shape, nil}} =
             TwicPicsResolver.resolve(shape(800, 600), nil, op)
  end

  # focus (100,100) on a 400x400 source, cover=200x100 (staged [resize] ->
  # seam -> [crop]): the cover intermediate is 200x200 (injected at the seam),
  # so the point scales to (50,50) and the crop's :carried gravity substitutes
  # to fp (0.25, 0.25) against the 200x200 intermediate. The 200x100 box crops
  # at origin (0, 0) — round_ties_to_even(0.25*200 - 100) = -50 clamps to 0,
  # round_ties_to_even(0.25*200 - 50) = 0 — so the carry stays (50, 50).
  test "a staged cover substitutes :carried to a concrete fp and translates the carry" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 200},
      height: {:px, 100},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{}], {:acquire, stage}} = TwicPicsResolver.resolve(shape(400, 400), point, resize)

    {[%Crop{gravity: gravity}], {:advance, _shape, carried}} = stage.({200, 200})

    assert gravity == {:fp, 0.25, 0.25}
    assert carried == {{:ratio, 50, 1}, {:ratio, 50, 1}}
  end

  test "a nil point substitutes the centred anchor (the hot fallback path)" do
    resize = %PlanResize{
      mode: :cover,
      width: {:px, 200},
      height: {:px, 100},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{}], {:acquire, stage}} = TwicPicsResolver.resolve(shape(400, 400), nil, resize)
    {[%Crop{gravity: gravity}], {:advance, _shape, nil}} = stage.({200, 200})

    assert gravity == {:anchor, :center, :center}
  end

  # Under a pending quarter turn the stage is [crop, Flush]: the fp substitutes
  # against the storage-frame point BEFORE the flush (never gravity-remapped —
  # compensate_crop's :carried clause), and the carry reflect-rotates with the
  # flush. Storage 40x80 EXIF-6 source, point (20, 36) storage-frame,
  # cover=20x20 -> forcing resize to storage 20x40 (injected), point scales to
  # (10, 18), fp (0.5, 0.45); the 20x20 box (display->storage swap is identity
  # for a square) crops at top = round_ties_to_even(0.45*40 - 10) = 8 ->
  # carry (10, 10); the flush maps fraction (0.5, 0.5) by rotate-90 to
  # (0.5, 0.5) on the swapped 20x20 frame -> carry (10, 10).
  test "a pending-orientation cover substitutes storage-frame fp and folds reflect_rotate" do
    po = %PendingOrientation{auto_rotate?: true, exif_angle: 90}
    point = {{:ratio, 20, 1}, {:ratio, 36, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 20},
      height: {:px, 20},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{mode: :force}], {:acquire, stage}} =
      TwicPicsResolver.resolve(shape(40, 80, po), point, resize)

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, advanced, carried}} = stage.({20, 40})

    assert gravity == {:fp, 0.5, 0.45}
    assert carried == {{:ratio, 10, 1}, {:ratio, 10, 1}}
    assert {advanced.width, advanced.height} == {20, 20}
    assert advanced.pending_orientation == nil
  end

  # The reflect fold, discriminated: an UNCLAMPED fp crop always centres the
  # carry, and the centre is a fixed point of reflect_rotate — so this case
  # uses a point whose crop origin CLAMPS (top round_ties_to_even(0.05*40 - 10)
  # = -8 -> 0), leaving the off-centre carry (10, 2) that the flush must
  # actually move: fractions (0.5, 0.1) rotate-90 to (0.9, 0.5) on the swapped
  # 20x20 frame -> (18, 10). A dropped/mis-framed %Flush{} step yields (10, 2).
  test "the flush fold moves an off-centre carry" do
    po = %PendingOrientation{auto_rotate?: true, exif_angle: 90}
    point = {{:ratio, 20, 1}, {:ratio, 4, 1}}

    resize = %PlanResize{
      mode: :cover,
      width: {:px, 20},
      height: {:px, 20},
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :carried
    }

    {[%ExecResize{mode: :force}], {:acquire, stage}} =
      TwicPicsResolver.resolve(shape(40, 80, po), point, resize)

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, _advanced, carried}} = stage.({20, 40})

    assert gravity == {:fp, 0.5, 0.05}
    assert carried == {{:ratio, 18, 1}, {:ratio, 10, 1}}
  end

  # The Pinned-behavior-1 decision record: a smart/detect-gravity crop never
  # advances the point (it passes through unchanged, not nil'ed). This is the
  # plan's one deliberate, detector-gated divergence — at resolve time the
  # detection outcome does not exist, so the old success-path translate cannot
  # be reproduced. Documented in docs/twicpics_support_matrix.md.
  test "a smart-gravity crop passes the point through unchanged" do
    point = {{:ratio, 100, 1}, {:ratio, 100, 1}}
    {:ok, op} = ImagePipe.Plan.Operation.crop_guided({:px, 50}, {:px, 50}, {:smart, :face_assist})

    {[%Crop{gravity: {:smart, :face_assist}}], {:advance, _shape, carried}} =
      TwicPicsResolver.resolve(shape(400, 400), point, op)

    assert carried == point
  end
end
```

Derive every asserted integer by hand from the Task-2 helper math before running (the comments show the method); if a hand-derived value disagrees with the test run, re-derive first — the current wire/differential behavior is the arbiter, never adjust production code to fit a mis-derived expectation. Check the `Operation.crop_guided/blur` constructor signatures against `lib/image_pipe/plan/operation.ex` before first run and adapt the fixture calls, keeping the assertions.

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/parser/twic_pics/resolver_test.exs`
Expected: FAIL — the focus row still emits `StateUpdate`; no `PointFlow`.

- [ ] **Step 3: Create `PointFlow`.** `lib/image_pipe/parser/twic_pics/point_flow.ex`:

```elixir
defmodule ImagePipe.Parser.TwicPics.PointFlow do
  @moduledoc false
  # Advances the TwicPics carried point through a neutral emission at resolve
  # time, using the executables' own pure geometry helpers so the trajectory
  # matches execution exactly:
  #
  #   * %Resize{} — the point scales by the realized per-axis factor. A resize
  #     is always the TERMINAL op of its stage (the neutral staging invariant),
  #     so the factor is acquired-stage-dims / dims-entering-the-resize,
  #     applied at the stage seam.
  #   * %Crop{} — a `:carried` gravity substitutes first: a set point becomes
  #     the concrete {:fp, x, y} (Focus.to_fp against the live dims at the
  #     crop), a nil point becomes the centred anchor (byte-identical to the
  #     old Crop.execute fallback; compensate_crop has already set center_bias,
  #     which the fp path ignores). Substitution happens AFTER the neutral
  #     resolver's orientation compensation, so a storage-frame point is never
  #     gravity-remapped. The point then translates by the realized crop origin
  #     (Crop.resolved_rect/3). Smart/detect crops choose their window from
  #     pixels and do not carry the point — it passes through unchanged, and is
  #     only ever consumed again after a new set_focus directive overwrites it.
  #   * %ExtendCanvas{} — the point translates by the realized embed offset.
  #   * %Flush{} — the point rotates/reflects with the pixels
  #     (Focus.reflect_rotate on the pre-flush dims); the dims swap on a
  #     quarter turn.
  #   * anything else — point- and dims-neutral, matching the execute-time
  #     mechanics (streaming effects; no other dims-changing op is
  #     TwicPics-reachable).

  alias ImagePipe.Resolver
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  @spec advance([struct()], Resolver.continuation(), Focus.point() | nil, SourceShape.t()) ::
          {[struct()], Resolver.continuation()}
  def advance(ops, continuation, point, %SourceShape{} = shape) do
    walk_stage(ops, continuation, point, SourceShape.live_dims(shape), shape.pending_orientation)
  end

  defp walk_stage(ops, continuation, point, entry_dims, po) do
    {ops, {point, dims}} = Enum.map_reduce(ops, {point, entry_dims}, &step(&1, &2, po))
    {ops, rewrap(continuation, point, dims, po)}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, point, _dims, _po),
    do: {:advance, shape, point}

  defp rewrap({:acquire, then_fn}, point, pre_dims, po) do
    {:acquire,
     fn acquired ->
       point = scale_at_seam(point, pre_dims, acquired)

       case then_fn.(acquired) do
         {%SourceShape{} = shape, nil} -> {shape, point}
         {ops, continuation} when is_list(ops) -> walk_stage(ops, continuation, point, acquired, po)
       end
     end}
  end

  # Every TwicPics-reachable :acquire seam follows a %Resize{} (the terminal-op
  # invariant), so the realized per-axis factor is acquired/pre — the same
  # integers Resize.execute used to read off the live image.
  defp scale_at_seam(point, {pre_w, pre_h}, {w, h}),
    do: Focus.scale(point, {:ratio, w, pre_w}, {:ratio, h, pre_h})

  defp step(%Crop{gravity: :carried} = crop, {point, {w, h}}, po),
    do: step(%Crop{crop | gravity: substituted_gravity(point, w, h)}, {point, {w, h}}, po)

  defp step(%Crop{gravity: gravity} = crop, {point, {w, h}}, _po)
       when gravity == :smart
       when is_tuple(gravity) and elem(gravity, 0) in [:smart, :detect] do
    {crop, {point, Crop.resolved_box_dims(crop, w, h)}}
  end

  defp step(%Crop{} = crop, {point, {w, h}}, _po) do
    {:ok, %{left: left, top: top, width: box_w, height: box_h}} = Crop.resolved_rect(crop, w, h)
    {crop, {Focus.translate(point, -left, -top), {box_w, box_h}}}
  end

  defp step(%ExtendCanvas{rule: rule} = op, {point, {w, h}}, _po) do
    {:ok, {canvas_w, canvas_h}} = ExtendCanvas.resolved_canvas_dims(rule, w, h)
    {x, y} = ExtendCanvas.resolved_embed_offset(op, w, h, canvas_w, canvas_h)
    {op, {Focus.translate(point, x, y), {canvas_w, canvas_h}}}
  end

  defp step(%Flush{} = op, {point, dims}, %PendingOrientation{} = po) do
    {op, {Focus.reflect_rotate(point, po, dims), PendingOrientation.display_dims(dims, po)}}
  end

  defp step(%Resize{} = op, acc, _po), do: {op, acc}

  defp step(op, acc, _po), do: {op, acc}

  defp substituted_gravity(nil, _w, _h), do: {:anchor, :center, :center}
  defp substituted_gravity(point, w, h), do: Focus.to_fp(point, w, h)
end
```

- [ ] **Step 4: Rewire the strategy.** `parser/twic_pics/resolver.ex` becomes:

```elixir
defmodule ImagePipe.Parser.TwicPics.Resolver do
  @moduledoc """
  TwicPics geometry-resolution strategy (spec §4.4/§9 Stage 3; #438): carries
  the TwicPics focus point as its strategy state, resolves the positional
  `set_focus` directive into that carry, substitutes `:carried` gravity with a
  concrete point before emission, and delegates all geometry resolution to
  `ImagePipe.Transform.NeutralResolver`, advancing the point through each
  emitted stage with the executables' pure geometry helpers
  (`ImagePipe.Parser.TwicPics.PointFlow`).
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Parser.TwicPics.PointFlow
  alias ImagePipe.Plan.Operation.Directive
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, _point, %Directive{name: :set_focus, payload: operand}) do
    resolved =
      Focus.resolve(
        operand,
        %{storage: SourceShape.live_dims(shape), decode_shrink: shape.decode_shrink},
        shape.pending_orientation
      )

    {[], {:advance, shape, resolved}}
  end

  def resolve(%SourceShape{} = shape, point, operation) do
    {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)
    PointFlow.advance(ops, continuation, point, shape)
  end
end
```

(The `StateUpdate` and `PendingOrientation` aliases die here.)

- [ ] **Step 5: Extend the architecture scan.** In `test/image_pipe/architecture_boundary_test.exs`, the strategy-reach test is a **forbidden-name scan** (`@resolver_strategy_forbidden_transform_names` — `Chain`, `State`, `Materializer`, `DecodePlanner` — over `@resolver_strategy_globs`), not an allowlist; widen `@resolver_strategy_globs` to also match `lib/image_pipe/parser/**/point_flow.ex` so the new file is scanned with the same forbidden set.

- [ ] **Step 6: Verify — the carry move is byte-invisible**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix test test/image_pipe/parser/twic_pics/resolver_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — in particular every Task-0 pin, the #321 display-frame focus tests, the #441 canvas-under-shrink focus pins, and the `focus_multi_consumer`/`crop_region_carry_*` fixtures. Then the full gate: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test` — PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: TwicPics strategy carries the point; :carried resolves to a concrete gravity before emission"
```

---

### Task 5: Delete the execute-time point mechanics

Everything the Task-4 flow replaced is now dead **for point-carrying plans**: `State.carried_point` is never written (the directive emits zero ops), so every executable `Focus.*` call is a nil no-op, and no TwicPics crop reaching the chain carries `:carried` gravity. Delete the point channel — cleanly, per the AGENTS removal rule (no narration, no "no longer" notes). The `:carried` **execute clause is deleted too**: `:carried` requires a point-carrying resolver strategy (Pinned behavior 4), so a nil-strategy plan resolving it through the `NeutralResolver` is an unsupported surface — it falls through to the generic clause's structural `{:error, {:invalid_crop_gravity, :carried}}`, and the hand-built nil-strategy test matrix that pinned the old fallback is re-homed to the real producer (Step 3). What **stays**: the native constructor acceptance of `:carried` (the TwicPics parser is a real caller), `Plan.KeyData`'s `guide_data(:carried)` (TwicPics plans carry `:carried` guides into cache-key material; only execution resolves them), `Lowering.tagged_executable_gravity(:carried)`, and `compensate_crop`'s `:carried` clause (both live on the TwicPics pre-substitution path).

**Files:**
- Modify: `lib/image_pipe/transform/operation/resize.ex`, `lib/image_pipe/transform/operation/crop.ex`, `lib/image_pipe/transform/operation/extend_canvas.ex`, `lib/image_pipe/transform/orientation_flush.ex`, `lib/image_pipe/transform/state.ex`, `lib/image_pipe/transform/focus.ex`
- Modify: `lib/image_pipe/transform.ex` (remove `Operation.StateUpdate` from the Boundary `exports:` list — leaving it breaks compile)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (moduledoc names "Flush/StateUpdate ops" — drop the StateUpdate mention)
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex` (the `crop_region` comment claims the region crop "resets the carried focus to the crop-result centre at execution" — false since #331 and doubly stale now; reword to the carry-through semantics)
- Modify: `lib/image_pipe/plan/operation.ex` (doc-only: the `guide` typedoc notes `:carried` requires a point-carrying resolver strategy)
- Delete: `lib/image_pipe/transform/operation/state_update.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex` (comment touch-ups only, see Step 2)
- Test: delete `test/image_pipe/transform/operation/state_update_test.exs`; apply the `focus_test.exs` disposition inventory (Step 3); sweep any other consumers the greps surface

- [ ] **Step 1: Verify the mechanics are dead before deleting.** Run the producer greps:

```bash
grep -rn "StateUpdate" lib/ --include="*.ex"
grep -rn "carried_point" lib/ --include="*.ex"
grep -rn ":carried" lib/ --include="*.ex" | grep -v "parser/twic_pics"
```

Expected hits, exhaustively: `StateUpdate` → its own module file, the `transform.ex` export entry, and the `plan_executor.ex` moduledoc (all removed in Step 2) — **no producer** (nothing constructs `%StateUpdate{}`); `carried_point` → `state.ex`, the four executables' call sites (`resize.ex`, `crop.ex`, `extend_canvas.ex`, `orientation_flush.ex`), `focus.ex`, and `state_update.ex`'s moduledoc; `:carried` outside `parser/twic_pics` → the native constructor guards in `plan/operation.ex` and `plan/key_data.ex`'s `guide_data` (both stay — the TwicPics parser is their real caller), `lowering.ex`'s `tagged_executable_gravity(:carried)` and `neutral_resolver.ex`'s `compensate_crop` clause (both stay — live on the TwicPics pre-substitution path), and the executable `crop.ex` clauses/typespec (the `execute`/`requires_materialization?` clauses are removed in Step 2; the typespec entry stays). A hit outside this inventory: stop and resolve before deleting.

- [ ] **Step 2: Delete.**
  - `resize.ex`: remove the `Focus.scale` block from `execute/2` (keep the `#180` `decode_shrink` comment; drop the carried-focus paragraph) — the success branch becomes:

```elixir
        {:ok, image} ->
          state = set_image(state, image)
          {:ok, %State{state | source_dimensions: nil, decode_shrink: nil}}
```

  Drop the `Focus` alias.
  - `crop.ex`: **delete** the `gravity: :carried` `execute/2` clause — a point-carrying strategy substitutes a concrete gravity before emission, and a `:carried` crop from a strategy-less plan is an unsupported request that falls through to the generic clause's `crop_gravity(:carried)` → `{:error, {:invalid_crop_gravity, :carried}}` (structural; add no guard and no test for it). Delete the `requires_materialization?(%__MODULE__{gravity: :carried})` clause (the catch-all `false` covers it); delete `carry_focus_through_crop/4` and inline its call away:

```elixir
  defp crop_image(%__MODULE__{}, %State{} = state, {left, top, crop_width, crop_height}) do
    case Image.crop(state.image, left, top, crop_width, crop_height) do
      {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
```

  Drop the `Focus` alias. `:carried` stays in the `gravity` typespec union — lowered TwicPics crops legitimately hold it between `Lowering` and the strategy's substitution — with a one-line doc note that it requires a point-carrying resolver strategy and never reaches `execute` from one. Add the same requires-a-strategy note to the `guide` typedoc in `lib/image_pipe/plan/operation.ex` (doc-only; the constructors keep accepting it).
  - `extend_canvas.ex`: `{:ok, set_image(state, image)}`; drop the `Focus` alias and the embed-translate comment.
  - `orientation_flush.ex`: remove the `pre = …` read and the `Focus.reflect_rotate` line (the success branch keeps only the image/materialized/pending update); drop `Focus` from the alias list.
  - `state.ex`: remove the `carried_point` field from `defstruct`, the typespec, and its doc bullet.
  - `focus.ex`: update the `@moduledoc` — the carried point is TwicPics-strategy state advanced by `ImagePipe.Parser.TwicPics.PointFlow`; the module is the neutral point math it (and any future point-carrying strategy) uses.
  - Delete `lib/image_pipe/transform/operation/state_update.ex` and `test/image_pipe/transform/operation/state_update_test.exs`; remove `Operation.StateUpdate` from `lib/image_pipe/transform.ex`'s `exports:`; drop the StateUpdate mention from `lib/image_pipe/transform/plan_executor.ex`'s moduledoc.
  - `lib/image_pipe/parser/twic_pics/plan_builder.ex`: fix the `crop_region` comment to the #331 carry-through semantics (the region crop translates the carried point; it does not reset it).
  - `neutral_resolver.ex`: the `compensate_crop` `:carried` clause **stays** (it is live — it runs on the TwicPics pre-substitution ops); update only its comment's second paragraph to describe the nil-fallback in terms of the substitution (the TwicPics strategy substitutes a nil point to the centred anchor, which consumes the `center_bias` set here; a set point becomes `:fp`, which ignores it).

- [ ] **Step 3: `focus_test.exs` disposition inventory.** `test/image_pipe/transform/focus_test.exs` exercises the deleted mechanics; apply these dispositions (do not over-delete — the `plan_builder`-based cases go through the real producer and stay):
  - The rational-helper cases on `%State{carried_point: …}` — already re-signatured to bare points by Task 3; **keep**.
  - `"nil-focus carried crop equals a centred crop under pending orientation"` (the `guided_crop_image` native-plan #146 Bug-2 orientation matrix) — **re-home to the real producer**: the hand-built plans are nil-strategy `:carried` plans, an unsupported surface after this task (impossible-internal-misuse per AGENTS once no real producer constructs it). Rewrite `guided_crop_image` to build its plan through the TwicPics parser (a `cover=WxH` path with no focus over the same synthetic oriented images) — or, equivalently, set `resolver: ImagePipe.Parser.TwicPics.Resolver` on the built plan, mirroring exactly what the parser emits — so the matrix pins what now owns the fallback: `PointFlow`'s centre substitution consuming `compensate_crop`'s `center_bias`, across the same axis-reversing orientations and odd extents. **The asserted bytes must not change** — the matrix compares carried-nil against explicit-centre crops, and that equality is orientation-parity (#146 Bug 2), not plumbing; if any cell goes red under the re-home, stop and consult.
  - `"carry through geometry ops"` (seeds `State.carried_point`, drives raw executables through `Chain`) — **delete**: the mechanics it exercises no longer exist; its invariants are re-pinned at resolve granularity by Task 4's resolver tests (scale-at-seam, crop translate, canvas translate) and Task 0's wire pins.
  - `"the orientation flush rotates the carried point"` (direct `OrientationFlush.flush` + `State.carried_point`) — **delete**: re-pinned by Task 4's "flush fold moves an off-centre carry" unit test and Task 0's pins.

- [ ] **Step 4: Grep gate.**

```bash
grep -rn "carried_point\|StateUpdate" lib/ test/ --include="*.ex" --include="*.exs"
grep -rn "Focus\." lib/image_pipe/transform/operation/ lib/image_pipe/transform/orientation_flush.ex
```

Expected: first grep hits only `focus.ex`'s own moduledoc (if it names the concept), `point_flow.ex`, `twic_pics/resolver.ex`, their tests, and `docs/` (handled in Task 6); second grep is empty. Audit every hit.

- [ ] **Step 5: Full verification**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS — the Task-0 pins, the kept #146 native-plan matrix, both differentials, both wire suites, and the golden all green with the mechanics gone.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: delete the execute-time point mechanics — the strategy carry is the only point channel"
```

---

### Task 6: Docs, final gates, PR

**Files:**
- Modify: `docs/twicpics_support_matrix.md`
- Modify: `docs/telemetry.md`
- Modify: `docs/imgproxy_support_matrix.md` (one stage/order note)
- Modify: `lib/image_pipe/transform/resolve_driver.ex` (boundary-flush comment)
- Modify: `docs/superpowers/specs/2026-07-01-resolve-stage-virtual-buffer-design.md` (§9 item-3 tick, if the team tracks status there; **and correct its pinned-behavior line** — "smart/detect crops do not carry the point today (no `carry_focus_through_crop` on that path)" is inaccurate: the detection-*success* path re-executes as `{:fp,…}` gravity and does translate; note the Stage-3 decision record that this edge is deliberately not carried)

- [ ] **Step 1: TwicPics matrix — stage/order axis, plus one behavioral note.** In `docs/twicpics_support_matrix.md`: the "Focus state (carried)" section currently names the `carried_point` field on `ImagePipe.Transform.State` and the `StateUpdate` commit channel — rewrite it: the point is the TwicPics strategy's per-pipeline `strategy_state`, resolved from the `set_focus` directive at its chain position, advanced through each emitted stage by `ImagePipe.Parser.TwicPics.PointFlow`, and consumed by substituting `:carried` gravity with a concrete focal point (or the centred anchor when unset) before any executable runs. Sweep the surface-table rows (~86–92) for `StateUpdate`/`State`-field wording. While there, tighten the `crop=WxH@XxY` row's parenthetical — "translated + clamped into the new frame" describes clamp-at-crop, but the carry never clamps at the translate: the point may sit transiently outside the frame (a later canvas embed can bring it back) and clamps only at the consuming crop/cover's focal-point conversion. Reword to "translated into the new frame; clamped only when the next `cover`/`crop` consumes it". Behavior unchanged — this corrects the description to the mechanism the code (and Stage 3's `PointFlow`) has always used. No surface rows change. **One behavioral note (Pinned behavior 1's decision record):** add to the focus-state section that a smart/detect crop (`focus=auto`) never advances the carried point — a detector-configured host whose detection succeeds previously saw the point translated by that crop's realized origin; the point channel is resolve-time-pure and detection outcomes are pixel-time, so this edge is deliberately not carried. No other pixel change.
- [ ] **Step 2: telemetry doc — representation notes.** In `docs/telemetry.md`: the `[:transform, :operation]` section (~line 196) lists `:state_update` among the ops — remove it; reword the `:index` bullet (~line 198) to "zero-based position within its executed batch (a staged resolve may execute one plan operation's executables across more than one batch)". No event, Logger, or Capture list changes.
- [ ] **Step 3: imgproxy matrix — stage note.** In the processing-pipeline section of `docs/imgproxy_support_matrix.md`, where the scale/crop stages describe the resolver: note that a resize emission now resolves in two stages split at the realized-dims read (the result crop is parameterized against the measured post-resize dims — same integers as before, per `resolved_box_dims`). Axis: **stage/order**; no surface or pixel change.
- [ ] **Step 4: the backstop-flush invariant.** In `resolve_driver.ex`'s `flush_boundary` comment, add the pinned-behavior note: the boundary flush never touches a strategy's carried point — unobservable for every parser-reachable pipeline (nothing consumes a point after the pipeline boundary; TwicPics plans are single-pipeline).
- [ ] **Step 5: Full gate.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise run precommit`
Expected: format, compile --warnings-as-errors, credo --strict, full suite — all green.

- [ ] **Step 6: Branch + PR.**

```bash
git branch -m refactor/resolve-stage-3-carried-point
git push -u origin refactor/resolve-stage-3-carried-point
```

No open issue tracks Stage 3 (spec §9 item 3 is the tracker; #434/#438 closed with Stage 2) — the PR body references the spec section instead of a closing keyword. End the body with the standard generated-with footer; do not clobber any CodeRabbit summary block on later edits.

- [ ] **Step 7: Commit docs (if not already amended into Step 5's tree)**

```bash
git add -A
git commit -m "docs: TwicPics/imgproxy matrix + telemetry sync for the carried-point move"
```

---

## Self-Review Notes

- **Spec coverage (§9 item 3):** continuation-contract change + driver stage loop + per-stage injection golden → Task 1; pure origin helpers shared with execute → Task 2; carried point into TwicPics `strategy_state`, `:carried` → `{:fp}` substituted after orientation compensation → Task 4; `reflect_rotate` folded at strategy-emitted flushes + boundary-backstop invariant documented → Tasks 4/6; executables' point mechanics + `State.carried_point` deleted → Task 5; pinned behaviors enumerated up front → *Pinned behaviors* section; the PR-#441 display-dims dedup fold-in → Task 3.
- **Deliberate scope decisions:** (a) staging is **conditional** (`[resize | tail]` with non-empty tail) so bare-resize plans keep single-acquire behavior and the existing seam tests pass untouched; (b) `StateUpdate` is deleted rather than kept as an unused channel (shrink-unsupported-API rule — its one producer is gone); (c) `:carried` stays in `Crop.t()`'s gravity union because lowered crops legitimately hold it between `Lowering` and the strategy substitution; (d) the smart/detect walk step keeps the point *unchanged* (not nil) — matching today's execute exactly, even though the stale frame is unobservable; (e) no `behavior_version` bump — results-identical.
- **Known risks routed to gates:** the `:carried`→fp orientation ordering (Pinned behavior 5) is exercised by the Task-0 EXIF pins + the Task-4 pending-cover unit test; frame coherence of `live_dims` at walk entry rides the Stage-2 canvas-under-shrink pins (#441); staged-dims exactness rides the record-based golden (realized-vs-computed equality).
- **Type-consistency check:** `acquire_result` (Task 1) is consumed by `PointFlow.rewrap` (Task 4) with the same two shapes; `resolved_rect/3` returns `{:ok, %{left, top, width, height}}` in Tasks 2 and 4; `Focus.to_fp(point, w, h)` arity matches between Tasks 3, 4, and 5's deletions; `display_dims/2` is nil-tolerant everywhere it is called.
- **Plan-review cycle applied (2026-07-02, three parallel reviewers: TwicPics compatibility REQUEST-CHANGES; orientation/staging REQUEST-CHANGES; process/quality REQUEST-CHANGES).** All blockers and should-fixes incorporated:
  - *Smart/detect point-translate* (compat blocker): today's detection-**success** path re-executes as `{:fp,…}` and translates the point via `carry_focus_through_crop`, and `crop_region` resets `guide: :carried` without a new directive — irreproducible at resolve time. Settled as the plan's one documented detector-gated divergence (Pinned behavior 1 decision record; PointFlow unit pin in Task 4; matrix + spec notes in Task 6). Partially declined: the suggested stub-detector *wire* pin — no assertable baseline exists beyond restating the unit test; the decision record + matrix note carry it.
  - *Native `:carried` producer* (staging blocker): the native Plan constructors accept `:carried` and resolve through the NeutralResolver with no substitution, pinned by `focus_test.exs`'s #146 orientation matrix; the grep inventory/`focus_test.exs` disposition table was added (Task 5 Steps 1/3). **Amended 2026-07-03 (user review):** the first resolution (a slimmed point-free `:carried` → centre clause on `Crop.execute`) was replaced — the fallback is *strategy policy* (TwicPics semantics), and keeping it in the neutral executable is exactly the dialect-policy bleed this project removes. Final form: strategy-less `:carried` is an unsupported surface (falls through to the structural `invalid_crop_gravity` error, no clause, no guard), and the #146 matrix is re-homed to the real producer path (TwicPics-carried plans pinning `PointFlow`'s centre substitution), byte-identical cells required.
  - *Deletion inventory* (process blocker): `transform.ex`'s `Operation.StateUpdate` Boundary export, `plan_executor.ex`'s moduledoc, `plan_builder.ex`'s stale crop-region comment, and the full `focus_test.exs` disposition (keep the native matrix and re-signatured helpers; delete the Chain/flush mechanics describes, coverage re-homed to Task 4's resolver tests) all enumerated in Task 5.
  - *Reflect-fold discrimination*: an unclamped fp crop always centres the carry (a reflect fixed point), so Task 4 gained the clamped off-centre case ((20,4) → carry (18,10)); Task 0 pin 1's comment was corrected to what it actually pins (seam scale + crop-top derivation), with reflect/translate wire coverage owned by the region-crop pin.
  - *Gate gaps*: deterministic focus→inside→cover wire pin added (the canvas-embed translate was otherwise ungated — the #441 fixtures place focus after inside); the optional differential constellation's ordering fixed; the nil-point pin upgraded to `resp_body` equality.
  - *Mechanical*: crop tests live in `crop_operation_test.exs` (not `operation/crop_test.exs`); `Image.get_pixel!/3` is positional; centre-embed expectation corrected to `{10, 6}`; fixture path, `display_dims` doc scope, `resolver.ex`'s stale `advance/4` reference, and the architecture-scan description (forbidden-name scan over globs, not an allowlist) all fixed.
