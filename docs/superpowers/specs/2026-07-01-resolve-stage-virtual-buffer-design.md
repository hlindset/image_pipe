# Design: an explicit Resolve stage over a `SourceShape` virtual buffer

**Status:** Design / spec — approved for planning. *Not* an implementation plan.
**Date:** 2026-07-01
**Input:** [`2026-07-01-resolve-stage-virtual-buffer-exploration.md`](2026-07-01-resolve-stage-virtual-buffer-exploration.md)
(the banked exploration; this document is the real spec derived from it).

---

## 1. Problem

Per-dialect (imgproxy) geometry-resolution logic has bled out of the parser seam
into the neutral *transform* layer. Parsers do the right thing — each dialect's
`plan_builder.ex` emits semantic `ImagePipe.Plan.Operation.*` structs and defers
resolution — but downstream, [`ImagePipe.Transform.ResizePlanning`](../../../lib/image_pipe/transform/resize_planning.ex)
and [`ImagePipe.Transform.OrientationScheduler`](../../../lib/image_pipe/transform/orientation_scheduler.ex)
are soaked in imgproxy semantics (auto fill-vs-fit bucketing, `min_*` coupling,
no-enlarge DPR cap, display-frame quarter-turn swaps, shrink-on-load rescale,
ties-to-even offsets). None of it `alias`es a parser module, so `Boundary` is
satisfied — but the *Transform-neutrality* guideline is quietly violated.
`ResizePlanning` is a de-facto imgproxy adapter wearing a neutral name.

The resolution bled into execution because it is **source-shape-dependent**:
fill-vs-fit compares `srcW−srcH` to `dstW−dstH`; the no-enlarge cap is
`min(srcW/w, srcH/h)`; shrink-rescale needs the realized decode factor. Parsers
run *before* fetch, so they cannot do this math. Execution was simply the first
place the source shape was known.

The exploration's key finding — validated against the code (§3) — is that the
imgproxy-only machinery is exactly the bug-dense frame cluster (`#182`/`#237`
quarter-turn × `min_*` coupling × DPR cap). Moving it into an isolated,
dialect-owned resolver both ends the neutrality bleed *and* quarantines the
bug-dense code to the one dialect that needs it, where it can be tested as data
against imgproxy's own source.

## 2. Goals / non-goals

**Goals**

- Un-bleed: imgproxy resolution leaves the neutral transform layer for an
  isolated, dialect-owned strategy.
- A single pure resolver, driven op-by-op, is the *only* place resolution rules
  live. Shape acquisition (header vs measurement) is the driver's separate job.
- Frame invariants become first-class (an explicit `frame:` on the threaded
  shape) instead of reconstructed at each call site — attacking the recurring
  quarter-turn/shrink bug class.
- Testability-as-data: assert resolved integer boxes without decoding output
  (a new "ResolvedPlan golden" test), full for opaque-free plans.
- Consolidation: ad-hoc `State` geometry fields collapse into one `SourceShape`;
  the shrink-carry special case is subsumed by `measure()`.

**Non-goals**

- **No operation reordering.** The fixed neutral order is a contract; ops do not
  commute. Off the table.
- No change to the cache key or ETag contract (§7 shows the model does not touch
  it).
- No new public request surface. This is an internal architecture change; the
  observable behavior is byte-identical (that is the primary safety net).
- Not a perf project. libvips dimension reads are already lazy; the prize is
  decoupling and determinism, not avoiding compute.

## 3. Current state, validated

Anchor reads confirming the exploration's structural claims:

- **`Renderer` is the exact precedent for a carried-module behaviour.**
  [`renderer.ex`](../../../lib/image_pipe/renderer.ex) is
  `use Boundary, deps: [ImagePipe.Plan]`, carries the module in the plan
  (`{:custom, module, params}`), and dispatches without the core enumerating
  dialects. A `Resolver` behaviour mirrors it 1:1.
- **`:auto` is already a versioned rule.**
  [`key_data.ex`](../../../lib/image_pipe/plan/key_data.ex) tags
  `%Resize{mode: :auto}` with `rule: :auto_orientation_match_v1`. Marker-in-Plan /
  rule-in-strategy is a clean, already-blessed split.
- **The ETag is symbolic-only.**
  [`http_cache.ex`](../../../lib/image_pipe/request/http_cache.ex) derives
  `etag_material` from `Key.plan_material(plan)` + source seed + `Accept` — never
  resolved geometry, never output bytes.
- **The neutral core is genuinely neutral.**
  [`Resize.resolve_dimensions`](../../../lib/image_pipe/transform/operation/resize.ex)
  is the shared column (fit/cover/stretch/region/canvas + cropToResult, min-dim
  expansion, bounds). [`ResizePlanning`](../../../lib/image_pipe/transform/resize_planning.ex)
  is the imgproxy-thick wrapper around it.

Three things the exploration under-models, discovered on the anchor reads. They
do not break the direction — **they are the design**:

1. **The `OrientationScheduler` layer.** The exploration's driver loop is
   `resolve → apply → advance/measure`. Reality:
   [`plan_executor.ex`](../../../lib/image_pipe/transform/plan_executor.ex) →
   [`orientation_scheduler.ex`](../../../lib/image_pipe/transform/orientation_scheduler.ex)
   is a full deferral engine. `pending_orientation` is not just a shape field; it
   drives per-op *flush decisions* and *frame compensation* (display-frame
   resolve + storage-frame execution + `compensate_crop`/`swap_resize`/
   `center_bias`). This is where Seam 3 actually lives, and folding it into the
   resolver is the bulk of the work.

2. **Cross-op context flow.** `PlanExecutor.update_execution_context` computes
   `effective_padding_scale` + `canvas_preserving_padding_scale` from the resize
   op and stashes them in a `context` map a *later* Padding/Canvas op reads. A
   resize's DPR cap reaches forward. This is imgproxy-only (IIIF/TwicPics are
   dpr=1).

3. **Focus is already a partial measurement.**
   [`resize.ex`](../../../lib/image_pipe/transform/operation/resize.ex) scales the
   carried focus by the *realized* post-resize dims read back off the live image,
   because `State` never carried a trustworthy planned shape. With exact planned
   dims on the shape, planned == realized for a forcing resize, so the read-back
   can be retired.

## 4. Architecture

### 4.1 Overview

```
Parse ──▶ Plan (symbolic, carries strategy module) ──▶ Drive:
    seed shape (header + realized shrink + EXIF)
    for each op in fixed neutral order:
        {ops, cont, strategy_state} = Resolver.resolve(shape, strategy_state, op)
        apply ops (pixels; Chain owns per-op materialization)
        shape = advance purely  |  interpret(measure(image))
    boundary backstop: flush any still-pending orientation
```

Resolution rules live **once**, in the resolver. Shape acquisition (header facts
vs a pixel measurement) is the **driver's** job. Separating these two is the
whole idea; today's code fuses them.

### 4.2 The `Resolver` behaviour (Seam 1)

A neutral behaviour, `use Boundary, deps: [ImagePipe.Plan]`, mirroring
`ImagePipe.Renderer`. The Plan carries the chosen strategy module (selected by
the parser); the driver dispatches dynamically. **No `transform → parser`
edge** — the mechanism already blessed for renderers.

```elixir
@type continuation ::
        {:advance, SourceShape.t()}
        | {:measure, (measured :: {pos_integer(), pos_integer()} -> SourceShape.t())}

@callback init() :: strategy_state :: term()
@callback resolve(SourceShape.t(), strategy_state :: term(), Plan.Operation.t()) ::
            {[executable_op :: struct()], continuation(), strategy_state :: term()}
```

- The **neutral default resolver** owns the shared column: fit/cover/stretch,
  region/gravity crop, canvas, padding, `cropToResult`, CropGuided aspect-ratio,
  and the neutral point-transform primitives. IIIF and TwicPics use only this
  plus their own strategy overrides.
- The **imgproxy strategy** additionally owns the imgproxy-only column (auto
  fill-vs-fit bucketing tagged by its `..._v1` version, `min_*` coupling,
  no-enlarge DPR cap, display-frame quarter-turn swaps, shrink rescale,
  `fill_down`, ties-to-even). It lives under `parser/imgproxy/` — dialect quirks
  stay in the adapter.

Delegation model: a strategy handles the ops/gravities it specializes and falls
through to the neutral resolver for the shared cases (e.g. TwicPics resolves only
`:carried` gravity itself; anchors/static-`fp`/smart/detect go to neutral).

### 4.3 `SourceShape` — the virtual buffer

A pure value threaded by the driver, carrying **only neutral geometry**:

```elixir
%SourceShape{
  width:               pos_integer(),
  height:              pos_integer(),
  frame:               :storage | :display,
  pending_orientation: PendingOrientation.t() | nil,
  decode_shrink:       %{w: float(), h: float()} | nil
}
```

Two deliberate divergences from the exploration's §3.2 field list:

- **Drop `has_alpha?` / `interpretation`.** Nothing in resolution reads them;
  they are encode/color-management metadata and stay on the live image / `State`.
  Putting them on `SourceShape` bloats "the resolution shape" with things the
  resolver never touches.
- **`focus` is NOT on `SourceShape`.** It is dialect-carried state (only TwicPics
  populates/advances/consumes it), so it lives in the TwicPics `strategy_state`
  (§4.5), not on the neutral shape. This is the same rule that keeps imgproxy's
  DprScale off the neutral shape.

`SourceShape` subsumes today's `State.source_dimensions`, `State.decode_shrink`,
and `State.pending_orientation`. `State.focus` moves to strategy state.

### 4.4 Cross-op carry: the strategy accumulator (Seam 2 / finding 2)

The driver threads a pair `{shape, strategy_state}`. `strategy_state` is an
opaque term **owned by the chosen strategy**; the neutral/IIIF resolvers leave it
`nil`. This is where imgproxy stashes the DprScale it computes **once** at the
resize and reuses at a later padding/canvas op — faithful to imgproxy's own
compute-once-reuse model, and invisible to the neutral core and to the other
dialects.

Rejected alternatives:

- **Generic `carry: map()` on `SourceShape`** — puts dialect data on the neutral
  shape, makes its type dishonest, and forces a neutral golden test to carry or
  filter imgproxy junk. Bad trade for the one refactor whose entire purpose is
  the boundary.
- **Pipeline-aware recompute (no carry)** — reconstructing the pre-resize shape
  replays resolution, is fragile once a `measure()` sits between resize and
  padding, and breaks the one-op-at-a-time signature the measure model depends on.

`strategy_state` does **not** enter the ResolvedPlan golden artifact (that is the
concrete ops + shapes). It is private resolver memory; we test the ops it
influences, not the blob.

### 4.5 Orientation folded into the resolver; `Flush` is a neutral op (Seam 3)

Today orientation splits into pure geometry (frame choice, `swap_resize`,
`compensate_crop`, `center_bias`, display-frame cover coupling) and the pixel
flush (`vips_rot` via `Materializer`/`OrientationFlush`) plus a scattered
policy of *when* to flush.

Target:

- **The resolver owns all the pure geometry.** Given a shape carrying
  `pending_orientation`, it emits the compensated concrete ops. The imgproxy-only
  parts (display-frame min-dim coupling, `swap_resize`) live in the imgproxy
  strategy; plain right-angle rotate/flip folding into `pending_orientation`
  stays neutral.
- **The flush becomes a neutral, materializing executable op** the resolver emits
  into its op list at the flush boundary; it advances the shape to
  `frame: :display, pending_orientation: nil`. An identity pending emits no
  `Flush` and clears the shape — the streaming fast path is preserved.
- **`OrientationScheduler` dissolves.** Its per-op flush decisions + compensation
  become resolver outputs + shape advances.
- **The driver keeps one backstop only:** at a pipeline boundary, if
  `pending_orientation` is non-identity, emit `Flush` and advance to display
  (EXIF is seeded once for the plan; each pipeline must end in the display frame).

### 4.6 The `measure()` contract (Seam 3, the sharpest edge)

- **`measure(image)` is dumb:** `{Image.width(image), Image.height(image)}` — two
  storage-frame integers, nothing else.
- **The `{:measure, interpret}` continuation carries the frame knowledge.**
  `interpret` is a resolver-supplied pure function `(w, h) -> SourceShape.t()`
  that declares *which frame the ints are in and whether orientation is still
  pending*. A naive `width/height` read cannot reintroduce the `#182` frame bug,
  because the resolver is forced to state the frame explicitly.
- **Trim is the canonical case and, we claim, the only `:measure` op.** Trim is
  imgproxy's pre-orientation op (stage 2 < rotateAndFlip stage 7): it trims the
  storage frame and does **not** consume `pending_orientation`. Its interpreter
  returns `%{shape | width: w, height: h, decode_shrink: nil, frame: :storage}`
  with **orientation still pending**. This also authoritatively subsumes the
  "crop-before-resize clears `decode_shrink`" reset.
- **`:measure` fires for trim alone.** Only trim has pixel-dependent *output
  dimensions* (a content bbox). Smart/detect crops have known output dims — the
  resolved crop box — and need pixels only for *gravity* (saliency), which is
  Chain's existing `requires_materialization?`, not a shape measure. So
  smart/detect advance the shape purely and merely happen to materialize.
  **This narrowing is a claim the ResolvedPlan golden + differential bake must
  confirm** (§8) before it is relied on.

### 4.7 What stays put

- **`Chain`** keeps ownership of per-op materialization
  (`requires_materialization?` + `Materializer`). The resolver decides *shape*;
  the Chain decides *pixel access*. `Flush` is just another materializing op to
  it.
- **`Geometry`** rounding primitives (half-away, ties-to-even, `center_origin`)
  and the neutral point-transform math remain neutral utilities the resolver
  calls.
- **`DecodePlanner`** stays the pure pre-decode load-option planner; its output
  feeds the seed shape's realized `decode_shrink` (via a post-decode dim read).

## 5. Namespace & boundary placement

- `ImagePipe.Resolver` — neutral behaviour + dispatch facade,
  `use Boundary, deps: [ImagePipe.Plan]` (sibling to `ImagePipe.Renderer`).
- `ImagePipe.Transform.SourceShape` — the threaded neutral geometry value, under
  `transform` (it is transform-domain data; must never be emitted in telemetry).
- Neutral default resolver — under `transform` (owns the shared column and the
  driver loop, or the driver sits in a thin `transform` orchestrator that calls
  `Resolver`).
- imgproxy strategy — under `parser/imgproxy/`, implementing `ImagePipe.Resolver`
  (dialect quirks in the adapter; the core never names it — the Plan carries the
  module).
- `parser` boundary gains `→ resolver` (already blessed: `parser → renderer`
  exists for exactly this dialect-implements-a-neutral-behaviour pattern).

Architecture tests must confirm: request/source/response code does not name
concrete resolver strategies; the core never enumerates strategies; the imgproxy
strategy is reachable only via the carried module.

## 6. Compatibility-doc impact

Per the conformance-doc discipline, [`docs/imgproxy_support_matrix.md`](../../imgproxy_support_matrix.md)
must be updated in the same change. The axis is **stage/order** (the
processing-pipeline section): resolution moves from the neutral transform layer
into an imgproxy resolver strategy, and orientation flush becomes an explicit
neutral op. No **surface** change (no option/config table row changes) and,
because of results-identical-first, no intended **behavioral/pixel** change — the
"Diverges" notes and wire conformance results must stay green.

## 7. Cache / ETag — untouched by construction

The model does not touch the cache/ETag contract:

- **ResolvedPlan is a pure function of (symbolic Plan, source bytes)**, both
  already captured by identity. Resolved boxes add nothing to the key/ETag.
- **Behavioral version tags, not schema bumps.** Each strategy carries a version
  tag (auto already does: `auto_orientation_match_v1`). Changing a resolution
  algorithm bumps that *behavioral* tag for correct invalidation — orthogonal to
  the key *schema* version, so it does not collide with the greenfield
  "don't bump key data versions" rule.
- **The 304-before-any-work fast path cannot regress**, even for trim-first
  plans: identity is `(symbolic plan + rule version + source seed + Accept)`, and
  resolution *and* `measure()` are downstream of all four.

## 8. Testing strategy

**Results-identical is the contract.** The refactor must reproduce the exact same
integers before it is allowed to change where resolution runs.

- **New: ResolvedPlan golden test.** Assert the concrete resolved op boxes as
  data (integers), without decoding output. Full coverage for opaque-free plans;
  for a trim-first plan the artifact degrades to "resolved prefix + opaque marker
  + resolved suffix" (physics, not a defect). This is both the safety net and the
  payoff.
- **Existing: imgproxy differential bake** (`test/support/.../imgproxy_differential/`)
  — the pixel-parity net. Must stay green throughout; a compatibility reviewer
  (imgproxy focus) is mandatory per the review-cycle rule.
- **Existing: wire conformance** (`imgproxy_wire_conformance_test.exs`) — status,
  headers, content type, decoded dims, cache/source access, `Vary`. Must stay
  green.
- **Sequential-safety gate for `Flush` and any newly-classified op.** Per the
  transform guidelines, any op's `requires_materialization?` classification must
  be proven by the per-op sequential-vs-random pixel-equivalence test plus the
  property test over input shapes; the harness self-check (a known-random op
  raises under the streamed open) must hold.
- **Confirm the §4.6 narrowing** (only trim triggers `:measure`; smart/detect
  have known output dims) against the golden + differential before relying on it.
- **Telemetry:** if any span is renamed/added (e.g. resolution stage, `Flush`),
  update the default Logger *and* the OTel `Capture` lists in the same change, and
  keep `docs/telemetry.md` aligned. Prefer no new events unless there is a real
  observability need.

## 9. Implementation sequencing (for the plan)

The design describes the end-state; the implementation plan must stage it
**results-identical first, boundary-moving second**:

1. **Substrate, integers-identical.** Introduce `SourceShape` and the driven
   resolver loop reproducing today's exact integers, with imgproxy logic still
   physically where it is (or moved verbatim). Land the ResolvedPlan golden test.
   Net: golden + differential + wire all green, no boundary change yet.
2. **Fold in orientation; `Flush` as a neutral op.** Dissolve
   `OrientationScheduler` into resolver outputs + shape advances + the driver
   backstop. Re-prove sequential-safety for `Flush`. Golden/differential/wire
   green.
3. **Move the boundary.** Extract the imgproxy-only column into an
   `ImagePipe.Resolver` strategy under `parser/imgproxy/`, carried in the Plan;
   neutral default resolver owns the shared column. Update the support matrix and
   architecture tests.
4. **Retire the focus read-back** (finding 3) and move `focus` into TwicPics
   `strategy_state`, once exact planned dims are proven to match realized.

Each stage is independently green on the golden + differential + wire nets, so a
regression is caught at the stage that introduced it.

## 10. Risks

- This is the most parity-critical, differential-pinned code in the repo. The
  results-identical gate + compatibility reviewer are non-negotiable.
- A complete static ResolvedPlan exists only for opaque-free plans; trim-first
  degrades to a partial artifact. Accepted (physics).
- The frame-aware `measure()` / opaque-op continuation (§4.6) is the highest-risk
  detail: a lazy interpreter that reads the wrong frame reintroduces the `#182`
  bug class this refactor exists to make impossible.
- The `Flush`-as-op re-classification must clear the sequential-safety gate; a
  silent line/tile cache (correct pixels, no memory win) is not covered by
  correctness tests (perf benchmark deferred, as today).

## 11. Anchors (as of 2026-07-01)

- [`lib/image_pipe/transform/resize_planning.ex`](../../../lib/image_pipe/transform/resize_planning.ex) — conflated neutral-core + imgproxy resolver
- [`lib/image_pipe/transform/orientation_scheduler.ex`](../../../lib/image_pipe/transform/orientation_scheduler.ex) — the deferral engine that dissolves into the resolver
- [`lib/image_pipe/transform/plan_executor.ex`](../../../lib/image_pipe/transform/plan_executor.ex) — today's driver + the cross-op `context`
- [`lib/image_pipe/transform/operation/resize.ex`](../../../lib/image_pipe/transform/operation/resize.ex) — the neutral `resolve_dimensions` core + the focus read-back
- [`lib/image_pipe/transform/state.ex`](../../../lib/image_pipe/transform/state.ex) — the fields `SourceShape` subsumes
- [`lib/image_pipe/transform/chain.ex`](../../../lib/image_pipe/transform/chain.ex) — per-op driver + lazy materialization (stays)
- [`lib/image_pipe/transform/decode_planner.ex`](../../../lib/image_pipe/transform/decode_planner.ex) — pure load-option planner feeding the seed shape
- [`lib/image_pipe/transform/focus.ex`](../../../lib/image_pipe/transform/focus.ex) — neutral point-transform math (moves its *carry* to TwicPics strategy state)
- [`lib/image_pipe/transform/geometry.ex`](../../../lib/image_pipe/transform/geometry.ex) — neutral rounding/placement primitives (stays)
- [`lib/image_pipe/renderer.ex`](../../../lib/image_pipe/renderer.ex) — the carried-module behaviour precedent for `Resolver`
- [`lib/image_pipe/plan/key_data.ex`](../../../lib/image_pipe/plan/key_data.ex) — `:auto` → `auto_orientation_match_v1` (versioned-rule seam)
- [`lib/image_pipe/request/http_cache.ex`](../../../lib/image_pipe/request/http_cache.ex) — ETag from symbolic plan + source seed + Accept
