# Design: an explicit Resolve stage over a `SourceShape` virtual buffer

**Status:** Design / spec — reviewed (three-lens parallel review applied; §4/§9 revised 2026-07-02 from the Stage-1 plan's four-lens review; §4.2/§4.3/§4.4/§5.1/§7/§9 revised 2026-07-02 by the Stage-2 design pass, validating against the post-[#439](https://github.com/hlindset/image_pipe/pull/439) code — Stage 1 has landed), approved for planning. *Not* an implementation plan.
**Date:** 2026-07-01
**Input:** [`2026-07-01-resolve-stage-virtual-buffer-exploration.md`](2026-07-01-resolve-stage-virtual-buffer-exploration.md)
(the banked exploration; this document is the real spec derived from it).

**Realizes [#434](https://github.com/hlindset/image_pipe/issues/434)** ("isolate
imgproxy-specific resize/orientation resolution behind a target strategy"). This
design *is* #434's "target resolution strategy" seam, plus the `SourceShape` /
driver / measure substrate. Note the rationale differs deliberately: #434 is
YAGNI-gated on "a second target ever needing different math," which is **not** met
(TwicPics/IIIF still reduce to the same resize math). We proceed instead on the
neutrality un-bleed + `#182`/`#237` bug-quarantine + legibility warrant — costs
that exist *today*, independent of a second target — consciously superseding
#434's "don't add speculatively" gate. Its precondition,
[#433](https://github.com/hlindset/image_pipe/issues/433) (the `PlanExecutor`
split), has landed. The implementation PR should close #434.

**Orthogonal to [#262](https://github.com/hlindset/image_pipe/issues/262) /
[#377](https://github.com/hlindset/image_pipe/issues/377)** (terminal-output
unification and blurhash/lqip terminals). Those tap the pipeline pre-transform
(`:source_header`) or post-transform (`:transformed_pixels`) — never mid-resolve —
so they impose no constraint on this design, and this design's shrink-on-load
handling is exactly what a transform-tapping terminal needs. The one touch-point
(the delivery-boundary materialize) is aligned forward in §4.6.

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
  live. Shape acquisition (compute vs read vs materialize+read) is the
  **driver's** separate job, behind one seam.
- Frame invariants become first-class (an explicit `frame:` on the threaded
  shape) instead of reconstructed at each call site — attacking the recurring
  quarter-turn/shrink bug class.
- Testability-as-data: assert resolved integer boxes as pure data. Achieved by
  making the driver's dim-acquisition seam injectable — a test feeds the realized
  dims for `resize`/`trim`, and resolution becomes a pure function with **no
  decode** (§4.5, §8). This holds under the shipped design; it does **not**
  depend on the `planned == realized` equality.
- Consolidation: ad-hoc `State` geometry fields collapse into one `SourceShape`;
  the shrink-carry special case is subsumed by the shape's acquire step.

**Non-goals**

- **No operation reordering.** The fixed neutral order is a contract; ops do not
  commute. Off the table.
- No change to the cache key or ETag *contract* (§7). One additive requirement:
  strategy behavioral version tags must enter `plan_material` (§7).
- No new public request surface. This is an internal architecture change; the
  observable behavior is byte-identical (the primary safety net).
- Not a perf project. libvips dimension reads are already lazy; the prize is
  decoupling and determinism, not avoiding compute.
- **Retiring the focus read-back is not in scope for the shipped design.** It is
  deferred to the optional Stage 3 — via the B-promotion's computed dims or,
  independently of that property, the staged continuation (§4.4, §9).

## 3. Current state, validated

Anchor reads confirming the exploration's structural claims:

- **`Renderer` is the precedent for a carried-module behaviour.**
  [`renderer.ex`](../../../lib/image_pipe/renderer.ex) is
  `use Boundary, deps: [ImagePipe.Plan]`, carries the module in the plan
  (`{:custom, module, params}`), and dispatches without the core enumerating
  dialects. The Resolver reuses this mechanism — with one caveat about the
  *dispatching boundary* clarified in §5.1.
- **`:auto` is already a versioned rule.**
  [`key_data.ex`](../../../lib/image_pipe/plan/key_data.ex) tags
  `%Resize{mode: :auto}` with `rule: :auto_orientation_match_v1`.
- **The ETag is symbolic-only.**
  [`http_cache.ex`](../../../lib/image_pipe/request/http_cache.ex) derives
  `etag_material` from `Key.plan_material(plan)` + source seed + `Accept`.
- **The neutral core is genuinely neutral.**
  [`Resize.resolve_dimensions`](../../../lib/image_pipe/transform/operation/resize.ex)
  is the shared column; [`ResizePlanning`](../../../lib/image_pipe/transform/resize_planning.ex)
  is the imgproxy-thick wrapper around it.

Three things the exploration under-models, discovered on the anchor reads and
confirmed by the review. They do not break the direction — **they are the
design**:

1. **The `OrientationScheduler` layer** is a full deferral engine, not a passive
   shape field. `pending_orientation` drives per-op *flush decisions* and *frame
   compensation*. Dissolving it is the bulk of the work (§4.6).
2. **Cross-op context flow.** `PlanExecutor.update_execution_context` computes
   `effective_padding_scale` + `canvas_preserving_padding_scale` at the resize
   and a later Padding/Canvas op reads them. Imgproxy-only (§4.4).
3. **Focus is already a realized read-back.**
   [`resize.ex`](../../../lib/image_pipe/transform/operation/resize.ex) scales the
   carried focus by realized post-resize dims read off the live image (§4.5).

## 4. Architecture

### 4.1 Overview

```
Parse ──▶ Plan (symbolic, carries strategy module) ──▶ Drive:
    shape         = seed(header dims, realized decode_shrink, EXIF)
    strategy_state = strategy.init()
    for each op in fixed neutral order:
        {ops, cont, strategy_state} = Resolver.resolve(shape, strategy_state, op)
        apply ops (Chain — pixels + per-op materialization)
        {shape, strategy_state} =
          case cont do
            {:advance, shape', state'} -> {shape', state'}          # pure (exact ops)
            {:acquire, then_fn}        -> then_fn.(acquire_dims())   # read realized dims, then interpret
          end
    # driver-owned end-of-pipeline backstop:
    if pending_orientation non-identity → driver emits a Flush (the resolver did
       not, e.g. a rotate + streaming-effect pipeline with no resize/crop/padding
       to flush at); identity pending is cleared without materializing
```

Resolution rules live **once**, in the resolver. Shape acquisition is the
**driver's** job, funnelled through a single seam (`acquire_dims/…`, §4.5), as is
the end-of-pipeline flush backstop (§4.6). Separating rules from acquisition is
the whole idea; today's code fuses them.

### 4.2 The `Resolver` behaviour (Seam 1)

A neutral **behaviour + dispatch facade**, mirroring `ImagePipe.Renderer`. The
Plan carries the chosen strategy module — Stage 2 adds
`Plan.resolver :: module() | nil` (parser-set; `nil` = the neutral resolver),
mirroring `render:` — and the driver calls the neutral facade
`Resolver.resolve(spec, shape, op)`, which performs the dynamic
`spec_module.resolve(...)`; the dispatch is quarantined in the facade, never in
`transform` code (the dependency inversion is detailed in §5.1). The Stage-1
transitional signature carried an `env` per-op channel (the lowering context)
and returned `strategy_state` both inside the continuation and as a trailing
tuple element; Stage 2 deletes both. Every `env.state` read is shape-derivable
once `Lowering`/`ResizePlanning` are re-signatured to shape-based inputs
(`live_dims/1` reconstructs the decoded frame *exactly* from the shape's
realized shrink factors — original ÷ decoded round-trips), the cross-op `ctx`
retires into the imgproxy strategy carry (§4.4), and the trailing
`strategy_state` was redundant — the continuation is its only live channel (the
Stage-1 driver already discards the trailing element).

```elixir
@type continuation ::
        {:advance, SourceShape.t(), strategy_state :: term()}
        | {:acquire, (realized :: {pos_integer(), pos_integer()} ->
                        {SourceShape.t(), strategy_state :: term()})}

@callback init() :: strategy_state :: term()
@callback behavior_version() :: pos_integer()
@callback resolve(SourceShape.t(), strategy_state :: term(), Plan.Operation.t()) ::
            {[executable_op :: struct()], continuation()}
```

Two continuation variants, no more:

- `{:advance, shape', state'}` — the resolver computed the post-op shape purely
  (exact ops: crop, canvas/padding, right-angle rotate, dimension-neutral
  effects). No image read.
- `{:acquire, then_fn}` — the post-op dims must come from the realized image; the
  driver reads them (§4.5) and hands them to `then_fn`, which returns the next
  `{shape, strategy_state}`. `then_fn` is the "interpreter" that **declares the
  frame and pending-orientation state** of those dims (Seam 3, §4.7).

`then_fn` is **constructed and returned by `resolve/3` itself** — a closure that
captures the pre-op `{shape, strategy_state}` plus the resolver's own decisions
(whether it emitted a `Flush`, hence the result frame; whether pending survives;
whether `decode_shrink` resets; how the strategy carry advances), parameterized
on the dims the driver will read. The resolver builds it because the resolver is the only thing that knows how
to interpret the raw ints; the driver only supplies them. Because tests assert
`then_fn`'s *output* shape (data), not its internals, injection stays pure (§4.5,
§8). A declarative descriptor struct is a possible alternative if the continuation
ever needs to be serializable/inspectable; the closure is the simpler default and
is not adopted over it here.

**`strategy_state` advances at post-op time alongside the shape.** For an
`:acquire` op the `then_fn` returns *both* shape and state, so a strategy whose
carry depends on realized dims (the deferred Stage-3 focus carry, §4.4) updates
at the same moment the shape does. An `:acquire` `then_fn` that doesn't
transform the carry threads `strategy_state` through unchanged — so a `trim`
between an imgproxy resize and padding cannot lose the stashed DprScale
(covered by a golden case, §8).

Roles — **inventory corrected by the Stage-2 validation pass** (the original
role list pre-dated the Stage-1 landing; post-#439, several rows it assigned to
the imgproxy strategy are demonstrably *shared* paths that TwicPics/IIIF plans
traverse today, pinned by their differentials — moving them would change bytes
or force duplication):

- **Neutral default resolver** owns the shared column: fit/cover/stretch
  expansion including the `#236` crop-back-to-literal-box (TwicPics `cover`
  exercises it), region/gravity crop, canvas, padding *mechanics*, CropGuided
  aspect-ratio, orientation compensation + the neutral `Flush` emission (landed
  neutral in Stage 1 — TwicPics EXIF + `cover` exercises the quarter-turn
  compensation), the decode-shrink coordinate rescale (`#151`; shared by
  TwicPics crops), the neutral point-transform primitives, and the min/dpr/zoom
  *arithmetic* in the executable's `resolve_dimensions` (§3 already classifies
  it as the shared column). IIIF and TwicPics use this plus their own overrides.
- **imgproxy strategy** owns the imgproxy *decision* column, living under
  `parser/imgproxy/`: the `:auto` fill-vs-fit bucketing (tagged by its `..._v1`
  version; the strategy rewrites the op to the concrete branch before
  delegating), the no-enlarge DPR/padding-scale cap (`#237`) plus its cross-op
  carry (§4.4), and the `fill_down` mapping. Neutral code encountering
  `mode: :auto` or `pixel_ratio: {:effective, …}` becomes impossible internal
  misuse — it crashes, per the no-guard rule.

A strategy handles the ops it specializes and **directly delegates** the rest to
the exported `NeutralResolver` (wrap-and-delegate; no facade change). Right-angle
rotate/flip fold into `pending_orientation` and emit **no** executable op — the
return is `{[], {:advance, shape', state}}`; this is the common streaming path
and the empty op-list case is normal.

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

Deliberate divergences from the exploration's §3.2 field list:

- **Drop `has_alpha?` / `interpretation`.** Nothing in resolution reads them; they
  are encode/color-management metadata and stay on the live image / `State`.
  (`trim`'s *pixel execution* reads interpretation/alpha off the live image — that
  stays; the point is only that resolution/shape-advance never needs them.)
- **`focus` is NOT on `SourceShape`.** It is strategy-supplied point state, not
  source geometry. The original plan — move it into the TwicPics
  `strategy_state` — is **deferred to Stage 3 by scope**, with the staged
  continuation banked (§4.4). In the shipped Stage-2 design it remains on
  `State` as the *neutral* carried point (renamed `carried_point`), advanced by
  the executables' nil-safe point mechanics exactly as today.

`SourceShape` subsumes today's `State.source_dimensions`, `State.decode_shrink`,
and `State.pending_orientation`. `State.focus` stays on `State` (neutralized,
§4.4) until Stage 3.

### 4.4 Cross-op carry: the strategy accumulator (Seam 2)

The driver threads a pair `{shape, strategy_state}`. `strategy_state` is an
opaque term **owned by the chosen strategy**; the neutral/IIIF/TwicPics
resolvers leave it `nil` in Stage 2 (the TwicPics carry is deferred, below). It
is seeded per pipeline — `init/0` at each `ResolveDriver.run`, matching the
Stage-1 per-run `ctx` reset, so the carry scope is results-identical by
construction.

- **imgproxy** stashes the DprScale computed **once** at the resize
  (`resize_padding_scale`, both `:resize` and `:canvas_preserving`) and reads it
  at a later padding/canvas op. Faithful to imgproxy's compute-once-reuse
  (`prepare.go` `calcScale` → `crop.go`/`padding.go`/`extend.go`). *Footnote:*
  imgproxy revises DprScale once more in `limitScale` (`prepare.go:246-264`) when
  the padded result exceeds `MaxResultDimension`; ImagePipe applies that cap in
  the **Output boundary** (`Output.Encoder`/producer clamp), so the resolver's
  stashed DprScale is final for padding/extend. The accumulator carries the
  pre-clamp value — matching current behavior, pinned by results-identical.
- **TwicPics** — the carried focus. **Stage-2 validation finding (2026-07-02):
  the full carry move is gated and deferred to Stage 3.** The original design
  (advance the focus in the strategy carry via `then_fn`'s realized dims)
  under-modeled multi-op emissions: `focus=…/cover=WxH` lowers *one* plan op
  into `[resize, crop(:carried)]`, and the acquire seam supplies only the dims
  after the whole op list ran — but the crop-origin translate
  (`left = round_ties_to_even(fp·W′ − cw/2)`, whose result feeds the focus a
  *later* crop consumes) needs the realized **intermediate** post-resize dims,
  which are never acquired. (The fp itself needs no realized dims —
  scale-by-realized then normalize-by-realized cancels to the pre-resize
  fraction — but the translate does.) Today this is exact only because the
  executables update the focus at *executable* granularity — inside `execute`,
  with the live image in hand (`resize.ex` `Focus.scale`, `crop.ex`
  `carry_focus_through_crop`, `extend_canvas.ex` translate,
  `orientation_flush.ex` `reflect_rotate`) — while the carry advances at
  *plan-op* granularity, observing only each emitted list's endpoints.
  **Designed mechanism (2026-07-02, third pass): the staged continuation —
  split the emission at the realized-dims seam.** The driver already splits
  execution at every *plan-op* seam (each unsafe op's realized dims are read
  and fed forward before the next op resolves); Stage 3 extends that same seam
  *into* a multi-executable expansion. An `:acquire` `then_fn` may return a
  further `{ops, continuation}` stage instead of a final
  `{shape, strategy_state}`: for the cover, `resolve` returns
  `{[resize], {:acquire, stage}}`, the driver executes the resize, reads the
  realized `W′` (header metadata — no pixel force), and `stage.(W′)` returns
  `{[crop], {:advance, …}}` with the crop parameterized — and the carry
  translated, via a pure origin helper (the `resolved_box_dims` twin) —
  against the *measured* intermediate: the same integers `Crop.execute`
  produces today. No new op class, no side channel: shape acquisition stays
  the driver's one seam (§4.5), just allowed to fire more than once per plan
  op; flush positioning still reads off the concatenated stages' op order; the
  injection golden injects per stage. *Rejected lighter alternative:* an
  interleaved neutral `Measure` op (`[resize, Measure, crop]`) recording dims
  into a driver-owned channel for the final `then_fn` — workable for the cover
  only because its crop happens to be fully emittable up front (the fp needs
  no `W′` — the cancellation), but it adds an op class plus a measurement
  channel and can never *parameterize* a later executable on the measurement;
  staging subsumes it. Either way the move is **independent of the
  `planned == realized` property** — it is deferred to Stage 3 by *scope*, not
  by a hard gate (§9). In Stage 2 the focus
  stays on `State`, re-documented (and renamed `carried_point`) as the neutral
  strategy-supplied carried point — the same neutrality move Stage 2b makes for
  `:carried` gravity — and the executables keep their nil-safe point mechanics.
  The TwicPics strategy still exists: it owns the **Directive** row (below),
  resolving the operand against neutral shape fields alone (the Stage-1
  `display_live_dims` env read dies with `env` — `live_dims/1` reconstructs the
  decoded frame exactly from the shape, superseding this section's earlier
  "cannot reconstruct exactly" claim) and committing via the neutral
  **`StateUpdate`** op: a pixel-untouched executable op carrying a field map
  that the chain merges into execution state — the generic channel for any
  resolver decision that is a `State` write rather than geometry.

**Plan-surface de-dialecting (Stage 2b).** `Plan.Operation.SetFocus` is the one
dialect-branded entry in the neutral Plan vocabulary — positional TwicPics
semantics, sole producer `parser/twic_pics/plan_builder.ex` — the same bleed
this design treats in the transform layer, one level up. Once the Plan carries
the strategy, it dissolves into a generic
`%Plan.Operation.Directive{name: atom(), payload: term()}`: a pipeline entry
addressed to the plan's **carried strategy**, mirroring the Renderer's
`{:custom, module, params}` precedent. The TwicPics parser emits
`%Directive{name: :set_focus, payload: operand}`; the TwicPics strategy
resolves it (same reads as the TwicPics row above) and commits the result
through the `StateUpdate` op (through its carry once Stage 3 moves the point
there). Key data hashes directives generically
(`[op: :directive, name: …, payload: …]`; payloads are parser-produced plain
canonical terms — a parser contract, asserted in parser tests, not validated
downstream). The neutral resolver has **no** `Directive` clause: a directive
reaching it means a plan whose strategy doesn't own it, which no real producer
constructs — so it crashes, per the impossible-internal-misuse rule (no guard,
no tidy error, no test). `:carried` gravity is **retained and redefined
neutrally**: with the Resolver seam, "gravity supplied by the plan's strategy"
is a product-neutral concept (any strategy may supply a point, exactly as
`:smart` is neutral although only some dialects use it). The
resolve-to-a-concrete-`{:fp, x, y}`-before-emission step (so executable ops
never see `:carried`) is **deferred to Stage 3** with the focus carry — it
rides the same staged-continuation mechanism (above); in Stage 2 the executable
`:carried` gravity remains, redefined as reading the neutral carried point. Wire behavior is
byte-identical; the cache key data reshapes in place (greenfield rule, no
version bump).

The neutral driver never inspects `strategy_state` (boundary holds). It does
**not** enter the ResolvedPlan golden artifact (that is the concrete ops +
shapes); it is private resolver memory tested via the ops it influences.

Rejected alternatives (unchanged from review): a generic `carry: map()` on
`SourceShape` (pollutes the neutral shape's type) and pipeline-aware recompute
(fragile once an `:acquire` sits between resize and padding; breaks the
one-op-at-a-time signature).

### 4.5 Shape advancement: three modes over one injectable seam

This is the resolution of the central design fork. There are **not** two
architectures (read vs compute); there is **one architecture with a per-op
dim-acquisition policy**. Every op advances the shape in one of three modes:

| Mode | Ops | Materialize? | Output dims | Continuation |
|---|---|:---:|---|---|
| **pure advance** | crop, canvas/padding, right-angle rotate, effects | no | exact (computable) | `{:advance, …}` |
| **read** | resize | no | libvips-rounds | `{:acquire, …}` (lazy read) |
| **materialize + read** | trim, arbitrary/mirrored rotate | yes | content/rotation-determined | `{:acquire, …}` (op is `requires_materialization?`; Chain materializes without orienting; read after) |

The distinction that matters: only `resize` and `trim`/arbitrary-rotate cannot
have their post-op dims computed purely — `resize` because libvips'
shrink+reduce decomposition may round ±1 off the naive target, `trim` because the
bbox is content-dependent, arbitrary rotate because libvips rounds the rotated
bounding box. Everything else is exact (`extract_area`/`embed`/`vips_rot`
right-angle) and advances purely with **zero read and zero proof**. (A *mirrored*
rotate — any angle, including right angles — does not fold into
`pending_orientation` and executes as a materializing op; its right-angle output
dims are exact, but it is classified with the arbitrary-angle read path anyway —
read-what-you-did costs nothing, and a later `:advance` promotion is trivial.)

**Materialization is orthogonal to the continuation.** Pixels reach RAM either
because the resolver emitted a `Flush` (which materializes as it orients, §4.6) or
because the op itself is `requires_materialization?` (trim, arbitrary rotate),
which `Chain` handles. Crucially, **`Chain`'s materialization never orients** —
orientation is applied only by an explicit `Flush` — so a trim under a pending
orientation materializes to the storage frame automatically, with pending intact,
and no separate "materialize without orient" op is needed. So `read` and
`materialize+read` share the `{:acquire, then_fn}` continuation; they differ only
in whether the op forced pixels to RAM first.

**The one seam.** The shape advance NEVER reads the live image itself. The driver
owns a single `acquire_dims()` step that supplies the realized dims to an
`:acquire` continuation. In production it reads the live image's lazy
`width`/`height`. **In tests it is injectable** — a test hands it the realized
dims for each `:acquire` op, so the full resolution runs as a pure function with
no decode (§8). This is the same seam that enables the A→B promotion below, and
the same seam that makes the ResolvedPlan golden pure. One seam, three payoffs.

**Why read (not compute) for resize, in the shipped design.** Reading the
realized dim is what the code does today (`effective_source_dims` →
`Image.width/height`), so it is **results-identical by construction with no
proof**. The read is lazy metadata, not a pixel computation, so it is nearly
free. Ratios/percentages *reinforce* this: every relative dim resolves against a
reference dim (`length * n / d`, half-away), so a ±1 reference error under a
compute-and-trust model would propagate into every dependent ratio downstream;
reading the reference keeps the whole fleet of ratio consumers correct without
proving anything.

**The A→B promotion (optional, later).** "B" = advancing `resize` purely
(`{:advance, …}`) instead of reading. It is a **one-op, one-line policy flip** at
the `acquire_dims` seam, gated on a StreamData property test proving
`Image.resize(img, target/source)` output equals `target` across shapes, scales,
and the alpha premultiply path (§8). It may be applied **selectively** (pure where
proven, read fallback elsewhere). It touches nothing else — not the resolver
rules, `SourceShape`, the accumulator, the boundary move, or orientation. If
promoted, retiring the focus read-back rides the same seam (focus scales by
whatever factor the seam hands it). **The A-era golden is itself the migration
net:** if `planned == realized`, the read and computed integers are identical, so
re-running the golden after the flip proves B equivalent to A for every covered
case.

### 4.6 Orientation folded into the resolver (Seam 3, part 1)

`OrientationScheduler` dissolves into a **single** resolver pixel output plus pure
shape advances:

- **`Flush`** (neutral, materializing): applies the pending `vips_rot`, advances
  the shape to `frame: :display, pending_orientation: nil`. Emitted by the
  resolver into the op list at the correct position. This is the **only** op that
  orients.
- **pure advance / identity-clear** (no op): identity pending is cleared on the
  shape without emitting anything — the streaming fast path.

**`Chain`'s materialization is orientation-agnostic.** Because orientation is
applied only by an explicit `Flush`, `Chain`'s pre-op `Materializer` (for any
`requires_materialization?` op) is a plain `copy_memory` that never orients. That
is what lets trim (and arbitrary rotate) materialize under a pending orientation
and operate on the **storage** frame with pending intact — so no separate
"materialize without orient" op is needed (this fully resolves the reviewer's
"Chain can't express materialize-without-orient" concern: non-orienting is now the
only kind of materialize). The corollary: the smart/detect case that must run on
*oriented* pixels emits an explicit `Flush` before the crop (below) rather than
relying on materialization to orient.

**Flush *position* is encoded by where the resolver places the op in the `ops`
list** — there is no separate flush-timing concept. Enumerated from the current
scheduler clauses:

- region crop → `[Flush, Crop]` (flush **before**).
- resize → `[…resize…, crop?, Flush]` (flush **after**).
- padding / pixelate / gradient → `[Flush, op]` (flush **before**, so the op
  decides in the display frame).
- trim → `[Trim]` (Chain materializes it via `requires_materialization?` without
  orienting, so it trims the **storage** frame; pending is **kept** by `then_fn`).
- **arbitrary-angle / mirrored rotate → `[Flush, Rotate]`** (flush **before**).
  Today this op relies on `Chain`'s *implicit* orienting materialize; the
  resolver makes it explicit, same as smart/detect below. One pinned definition:
  a pipeline containing both a trim and an arbitrary rotate would today rotate
  un-oriented pixels (the trim's materialize suppresses the rotate's); no parser
  can produce that pipeline, and flush-before-rotate is the defined behavior.
- canvas / background / streaming effects → **no flush.** They have no scheduler
  clause today — absence *is* the behavior: they run in the **storage** frame
  with pending intact. The display-frame rationale above does not extend to them.
- **smart/detect gravity crop → `[Flush, Crop(uncompensated)]`.** These
  materialize and today rely on the auto-flush firing first so they see
  display-frame pixels and are emitted *literal*. The resolver must make that
  explicit: emit the `Flush` itself and the crop uncompensated, rather than
  leaning on `Chain`'s implicit materialize-flush. This keeps "the resolver owns
  all pure geometry" true for this branch.

**The pipeline-boundary flush is a driver backstop.** EXIF is seeded once for the
plan and each pipeline must end in the display frame, so at each pipeline boundary
the driver emits a `Flush` if `pending_orientation` is still non-identity (the
resolver did not — e.g. `rotate` + a streaming effect like blur/colorize, with no
resize/crop/padding to flush at). Identity pending is cleared without
materializing. This is distinct from, and in addition to, the delivery backstop
below.

**The delivery-boundary materialize is re-homed.** Today
`OrientationFlush.flush` on a `nil`/identity pending still calls `materialize`,
and the delivery path relies on *something* forcing pixels to RAM before the
terminal consumes them, for the "a mid-chain op needed RAM but the last op didn't"
case. This backstop is orthogonal to orientation and is **not** a `Flush`. When
the scheduler dissolves it must be explicitly re-homed to the **terminal/delivery
satisfier that consumes transformed pixels** — i.e. the `:transformed_pixels` tap
in the [#262](https://github.com/hlindset/image_pipe/issues/262) `Renderable`
model, shared by the image-encode terminal *and* transform-tapping non-image
terminals like blurhash/lqip ([#377](https://github.com/hlindset/image_pipe/issues/377)),
not the encode path alone (blurhash/lqip need realized pixels but never encode).
The §4.1 pipeline-boundary rule (which only concerns pending orientation) does not
cover it.

### 4.7 The acquire/interpret contract (Seam 3, part 2 — the sharpest edge)

- **`acquire_dims()` is dumb:** `{Image.width(image), Image.height(image)}` — two
  integers *in whatever frame the live image currently holds*. It does not judge
  the frame.
- **The `then_fn` (interpreter) declares the frame.** It is a resolver-supplied
  pure function `(w, h) -> {SourceShape.t(), strategy_state}` that states *which
  frame the ints are in and whether orientation is still pending*, because the
  resolver knows whether it emitted a `Flush`. A naive `width/height` read cannot
  reintroduce the `#182` frame bug — the resolver is forced to declare the frame.
- **Trim's interpreter** returns `frame: :storage`, **orientation still pending**,
  `decode_shrink: nil` (trim disables shrink-on-load; the `nil` is a
  reaffirmation, see §4.8). This is the trim-first + pending-quarter-turn + cover
  walk: trim measures the storage frame with orientation pending, and the
  following cover resize then resolves in the display frame (imgproxy
  `ExtractGeometry`), exactly as `cover_resize_and_crop_display_frame` does today.

**Scope of "content-dependent output dims."** Within the **transform resolver**,
only `trim` (content bbox) and arbitrary/mirrored rotate (rounded rotated bbox;
mirrored right-angle joins by classification, §4.5) need
`:acquire`-with-materialize; `resize` needs `:acquire`-read; everything else is
`:advance`. imgproxy's other content-dependent output-sizing stage, **`fixSize`**
(format max-dimension rescale, `fix_size.go`), lives in ImagePipe's **Output
boundary** (`Output.Encoder` caps + producer clamp reading realized dims),
**downstream of the resolver and out of scope** for this refactor. The spec's
"only trim/arbitrary-rotate materialize" invariant is *resolver-scoped*, not
pipeline-wide. Smart/detect crop output dims are "known" only *relative to the
live input dims at the crop position* (their aspect-ratio clamp bounds against
live dims via `correct_aspect_ratio`/`clamp_to_bounds`) — which the `read` mode
supplies for free; they still `:advance` (no materialize for shape), needing
pixels only for gravity.

### 4.8 `decode_shrink`: three distinct resets, plus the `#185` crop swap

The spec does **not** collapse the `decode_shrink` resets. There are three,
firing on different ops:

1. **trim** → `nil` (never-shrank reaffirmation; the planner returned `1.0` for a
   trim chain, so it was never non-nil).
2. **crop-before-resize** → clears an *actually non-nil* factor the crop consumed
   (`#180`; today `clear_source_frame`). Load-bearing.
3. **resize completion** → `nil` (today `resize.ex:119`).

A region/gravity crop is a `pure advance`, but its advance is **advance-with-
effect**: it must (a) apply the quarter-turn per-axis `decode_shrink` swap
(`orient_decode_shrink`, `#185`) **before** the crop resolves — because the crop's
axes swap *after* rescale — and (b) clear `source_dimensions`/`decode_shrink`
*after* (the `#180` reset). Both effects are computed by the resolver when
producing the next shape and the emitted crop ops; enumerate them explicitly so
an implementer does not reconstruct `#185`/`#180` from scratch.

### 4.9 What stays put

- **`Chain`** keeps per-op materialization (`requires_materialization?` +
  `Materializer`). The resolver decides *shape*; the Chain decides *pixel access*.
  `Flush` is a materializing op to it; trim/arbitrary-rotate materialize via their
  own `requires_materialization?`. Its `Materializer` never orients (§4.6).
- **`Geometry`** rounding/placement primitives and the neutral point-transform
  math remain neutral utilities the resolver calls.
- **`DecodePlanner`** stays the pure pre-decode load-option planner; its output
  feeds the seed shape's realized `decode_shrink` (via a post-decode dim read).

## 5. Namespace & boundary placement

- `ImagePipe.Resolver` — neutral behaviour + dispatch facade,
  `use Boundary, deps: [ImagePipe.Plan]` (sibling to `ImagePipe.Renderer`).
- `ImagePipe.Transform.SourceShape` — the threaded neutral geometry value, under
  `transform` (its **final home** — settled by the Stage-2 pass, §5.1); joins the
  `transform` export list. Transform-domain data, never emitted in telemetry.
- Neutral default resolver + driver loop — under `transform`; `NeutralResolver`
  and the re-signatured shape-based lowering entry points join the export list
  (strategies delegate to them, §4.2).
- imgproxy strategy — under `parser/imgproxy/`, implementing `ImagePipe.Resolver`.
- TwicPics strategy — under `parser/twic_pics/`, implementing
  `ImagePipe.Resolver` (owns the Directive row, §4.4).
- `parser` boundary gains `→ resolver` (already blessed: `parser → renderer`)
  **and `→ transform`** (§5.1 amendment).

### 5.1 The dispatcher edge is real and declared: `transform → resolver`

There *is* a dependency edge here, and it must be an honest, declared one — not a
runtime call hidden in `Boundary`'s blind spot to dynamic dispatch (that would be
the same implicit-neutrality violation this refactor exists to remove). The
defensible edge is **`transform → resolver`**, achieved by dependency inversion,
exactly as `request → renderer` already is:

- `ImagePipe.Resolver` is the **neutral behaviour + dispatch facade**,
  `deps: [Plan]`.
- The imgproxy strategy under `parser/imgproxy/` **implements** `ImagePipe.Resolver`
  → `parser → resolver`.
- The driver in `transform` calls the **neutral facade**
  `Resolver.resolve(spec, shape, op)`, where `spec` is the strategy
  carried in the Plan (dependency injection) → `transform → resolver`. The dynamic
  `spec_module.resolve(...)` call is **quarantined inside the facade**, mirroring
  `Renderer.run/3`'s `module.render(...)`.

All three arrows point at the neutral abstraction; `transform` never depends on
`parser` (the reverse edge is real and declared — see the Stage-2 amendment
below). The critical discipline: the dynamic dispatch lives **in the facade**,
never in `transform`'s own code — `transform` must not call a carried module
directly, since *that* would be a genuine (if statically-invisible)
`transform → parser` dependency. Getting the inversion right is why `Boundary`
then reports no violation; the clean static result is a consequence, not the
justification. Declared edge: add `transform → resolver` to the boundary config,
covered by the existing architecture tests.

**Stage-2 amendment (2026-07-02): the static `parser → transform` edge is real
and declared too.** Strategies pattern-match `%SourceShape{}`, **emit executable
`%Transform.Operation.*{}` structs**, and call the shared shape-based lowering
entry points — an irreducible static dependency no placement trick avoids:
moving `SourceShape` into the `resolver` boundary doesn't help (the executable
ops and `Lowering` are irreducibly `transform`), and moving those into
`resolver` would need `resolver → transform`, cycling against the declared
`transform → resolver`. So `parser` declares `deps: […, ImagePipe.Transform]`.
The edge is acyclic and uses only exported entry points (`transform` already
exports every operation struct; `SourceShape`, `NeutralResolver`, and the
lowering facades join the list). The load-bearing inversion is untouched:
`transform` never names a dialect, and the dynamic dispatch stays quarantined
in the facade. A focused architecture test scopes what strategy modules may
reach (operation structs, `SourceShape`, the designated lowering/`NeutralResolver`
entry points — not `Chain`/`State` internals), and the AGENTS.md boundary table
gains the edge with that rationale.

## 6. Compatibility-doc impact

[`docs/imgproxy_support_matrix.md`](../../imgproxy_support_matrix.md) must be
updated in the same change. The axis is **stage/order** (the processing-pipeline
section): resolution moves into an imgproxy resolver strategy, and orientation
flush becomes an explicit neutral op (`Flush`). No **surface**
change and, by results-identical, no intended **behavioral/pixel** change — the
"Diverges" notes and wire conformance must stay green. Note the `fixSize` (Output
boundary) and `limitScale` (Output-boundary cap) relationships from §4.4/§4.7 so
the matrix reflects where each imgproxy stage lives in ImagePipe. Stage 2 also
touches [`docs/twicpics_support_matrix.md`](../../twicpics_support_matrix.md) on
the same **stage/order** axis (the focus/directive plumbing moves; no surface or
pixel change).

## 7. Cache / ETag

Mostly untouched by construction:

- **ResolvedPlan is a pure function of (symbolic Plan, source bytes)**, both
  already captured by identity. Resolved boxes add nothing to the key/ETag.
- **The 304-before-any-work fast path cannot regress**: identity is
  `(symbolic plan + rule version + source seed + Accept)`, and resolution *and*
  `acquire_dims()` are downstream of all four.

One **additive requirement** the review surfaced: the per-strategy **behavioral
version tag must live in `Key.plan_material`** (hence the ETag material), not just
`:auto`'s `auto_orientation_match_v1`. When the boundary moves (§9), any imgproxy
resolution rule whose algorithm could change (DPR cap, `min_*` coupling,
ties-to-even) and that has no version tag today must gain one — otherwise a future
algorithm change keeps the ETag stable and the 304 path serves stale-but-
differently-resolved bytes. This is a *behavioral* version, orthogonal to the key
*schema* version (so it does not collide with the greenfield "don't bump key data
versions" rule).

**Settled (Stage-2 design, 2026-07-02): one behavioral version per strategy.**
The `ImagePipe.Resolver` behaviour gains `behavior_version/0` (§4.2), and
`Key.plan_material` gains a single entry — `resolver: [strategy: Module,
version: n]` — for **every** plan (nil-strategy plans tag the neutral resolver
the same way), so any resolution-algorithm change bumps one number. Coarse (a
bump invalidates all of that strategy's cached variants) but simple and
impossible to forget per rule. The per-op `auto_orientation_match_v1` tag is
kept — it names the rule a specific op invoked, orthogonal to the strategy
version. Finer per-rule tags are tracked in
[#440](https://github.com/hlindset/image_pipe/issues/440) in case cache
retention on algorithm changes ever warrants them.

## 8. Testing strategy

**Results-identical is the contract.** Reproduce the exact integers before moving
where resolution runs.

- **New: ResolvedPlan golden, pure via injection.** The driver's `acquire_dims`
  seam (§4.5) is injectable, so the golden feeds realized dims for each
  `:acquire` op (`resize`, `trim`, arbitrary rotate) and asserts every resolved
  integer box **with no decode**. Deliberately inject a **±1 divergence** on a
  resize to prove downstream ratio/percent consumers still resolve sanely — an
  edge you cannot force against real libvips. Include a **resize → trim →
  padding** plan to prove `strategy_state` (DprScale) threads untouched across an
  `:acquire`.
- **Existing: imgproxy differential bake** — the ground-truth net that libvips
  actually *produces* the dims the injection tests assume, and the pixel-parity
  net. Must stay green; a compatibility reviewer (imgproxy) is mandatory.
- **Existing: wire conformance** — status/headers/content-type/decoded
  dims/cache/source/`Vary`. Must stay green.
- **Sequential-safety gate for `Flush`** (and any newly-classified op), per the
  transform guidelines: per-op sequential-vs-random
  pixel-equivalence + property test over shapes, with the known-random self-check.
  **Also assert the identity fast path:** identity `pending_orientation` emits no
  `Flush` and triggers **no** materialization (streaming-path guard) — otherwise a
  regression that always flushes would pass the materialization test while killing
  streaming.
- **Stage-1 exit criterion:** confirm the §4.7 narrowing with an explicit test that
  enumerates every `Plan.Operation.*` variant and asserts the continuation is
  `:acquire` iff the op is `trim` / arbitrary-angle or mirrored rotate / `resize`, else
  `:advance` — defining the predicate is not proving it; the golden asserts integers,
  not which variant fired. The continuation variants are the driver's core contract.
- **A→B property spike:** a StreamData test over `(source, target)` asserting
  `Image.resize` output `== target` across shapes/scales/alpha. Cheap; its result
  *decides* whether/where B is adopted. Not required to ship A.
- **Telemetry:** if any span is renamed/added (a resolution stage, `Flush`),
  update the default Logger *and* the OTel `Capture` lists in the same change, and
  keep `docs/telemetry.md` aligned. Prefer no new events without a real need.

## 9. Implementation sequencing (for the plan)

The design describes the end-state; the plan stages it **results-identical first,
boundary-moving second**, with A as the shipped dim-acquisition policy.

> **Staging correction (2026-07-01, from the plan review).** An earlier draft split
> this into "substrate/integers-identical" then "fold in orientation." That boundary
> is unsound: the injectable acquire seam and the pure injection golden require
> resolving ops *without running pixels*, which requires separating resolution from
> execution — which cannot be done while `OrientationScheduler` fuses them and
> `Chain`'s materialize orients as a side effect ([`materializer.ex`](../../../lib/image_pipe/transform/materializer.ex)
> `do_materialize` → `OrientationFlush.flush`). Making `Chain`'s materialize
> orientation-agnostic *is* the orientation dissolution. So the substrate and the
> orientation dissolution are **one stage**, merged below.

> **Plan-review corrections (2026-07-02, four-lens review of the Stage-1 plan).**
> Design-level mechanisms the plan review surfaced, now part of this spec:
> (a) **the driver State overlay** — while `Lowering`/`ResizePlanning`/op
> `execute` still read `State`, the driver syncs the shape into it at one site
> per op (`pending_orientation`, `decode_shrink`, `source_dimensions` from the
> shape); this is the Stage-1 realization of "the shape is the source of truth",
> and what makes the injection golden's dims actually flow into downstream
> lowering; (b) **the `env` channel** on `resolve/4` (§4.2); (c) **the
> `StateUpdate` op** (§4.4) as the channel for zero-op `State` writes;
> (d) **arbitrary/mirrored rotate gets an explicit `[Flush, Rotate]`** (§4.6) —
> the formerly implicit orient-at-materialize made explicit; (e) flush failures
> keep the `{:materialize_error, _}` tag and the `[:transform, :materialize]`
> span — the 415 mapping and the span tests are contract, not incidental.
> (Of these, (a) the overlay survives Stage 2 in reduced form — executables'
> execute-time reads only — and (b) the `env` channel is retired by the Stage-2
> re-signature; §4.2, §9 Stage 2.)

1. **Substrate + orientation dissolution (results-identical).** One coherent stage:
   - Introduce `SourceShape`, the two-variant continuation
     (`{:advance, …}` | `{:acquire, then_fn}`), and the single injectable
     `acquire_dims` seam.
   - Sync the shape into `State` via the single driver overlay, and commit
     zero-op resolver decisions (`SetFocus` → focus) through the neutral
     `StateUpdate` op (plan-review corrections (a)/(c) above).
   - Land the `Resolver` behaviour + facade and the `transform → resolver` edge
     (§5.1) now — the Stage-1 driver needs the seam; the parser-owned strategy
     still waits for Stage 2.
   - **Make `Chain`'s materialization orientation-agnostic** (`Materializer.materialize`
     becomes copy-only; the `materialize_without_orientation` special case
     disappears), and re-home orientation into an explicit neutral **`Flush`** op the
     resolver emits. Every site that today relies on the orienting auto-flush gets an
     explicit `Flush` at the right op-list position: before region crop / padding /
     pixelate / gradient / smart+detect crop / arbitrary-angle rotate, after resize,
     and the driver's pipeline-boundary + delivery backstop. `trim` emits **no**
     `Flush` (pre-orientation, storage frame). Re-prove sequential-safety + the
     identity fast path for `Flush`.
   - Thread the imgproxy DprScale cross-op carry (today's
     `PlanExecutor.update_execution_context`) through the driver so padding/canvas
     after a resize still resolve correctly (imgproxy logic still physically in
     `ResizePlanning`; only the *carry* is re-plumbed).
   - Decide `SourceShape`'s boundary home so the neutral `Resolver` facade does not
     runtime-reference it (facade passes the shape opaquely to the carried module;
     `SourceShape` appears in `Resolver` only in typespecs, which Boundary ignores) —
     keeping `Resolver` at `deps: [ImagePipe.Plan]`.
   - Wire `PlanExecutor` through the driver. Land the injection-based ResolvedPlan
     golden.
   - **Exit gates:** the §4.7 continuation-variant narrowing holds (a test enumerates
     ops and asserts `:acquire` iff trim/arbitrary-rotate/resize); the golden (incl.
     trim-under-pending-orientation, `fill_down`, and a concrete ±1-divergence case)
     + differential + wire are green.

2. **Move the boundary (closes #434).** Design settled 2026-07-02 (the Stage-2
   design pass, validated against the post-#439 code):
   - **Scope decision record.** The executable `Resize`/`Crop` mode/unit math
     stays put, and the TwicPics focus stays on `State` as the neutral carried
     point — both deferred to Stage 3 **by scope**: the focus-carry move needs
     realized *intermediate* dims inside multi-executable emissions that the
     per-plan-op acquire never observes (mechanism designed and banked: the
     staged continuation, §4.4 — no `planned == realized` dependency), and
     thinning the executables needs a Resolver **error channel** that doesn't
     exist yet (below). Stage 2 stays results-identical by construction.
   - **Strategy carry in the Plan.** `Plan` gains `resolver: module() | nil`
     (parser-set: imgproxy and TwicPics set their strategies, IIIF/native `nil`
     = neutral), mirroring `render:`. `PlanExecutor` seeds
     `{module, module.init()}` **per pipeline** (§4.4 — matches the Stage-1
     per-run `ctx` reset).
   - **Callback re-signature.** `resolve(shape, strategy_state, op) ::
     {ops, continuation}` — `env` deleted, trailing `strategy_state` collapsed
     into the continuation (§4.2); `behavior_version/0` added. The driver's
     `update_execution_context`/`@initial_ctx` are deleted (the DprScale pair
     becomes imgproxy strategy state).
   - **imgproxy strategy** under `parser/imgproxy/` per the corrected §4.2
     inventory: `:auto` bucketing (rewrite-to-concrete-branch, keeps
     `auto_orientation_match_v1`), the no-enlarge DPR/padding-scale computation
     + carry, `fill_down` mapping; wrap-and-delegate everything else to the
     exported `NeutralResolver`. Neutral seeing `mode: :auto` or
     `pixel_ratio: {:effective, …}` crashes (impossible internal misuse).
   - **Re-signature `Lowering`/`ResizePlanning`** to `%SourceShape{}` inputs
     (+ an explicit scale argument for the padding/canvas rows);
     `NeutralResolver`'s `lowering_state` rebuilds become shape rebuilds;
     `display_source_dims`/`display_live_dims` become shape functions. The
     driver **overlay stays**, now solely to feed the executables' execute-time
     `State` reads (`Resize.execute`, `Flush`) until Stage 3 thins them.
   - **Boundary.** Declare `parser → transform` and `parser → resolver`;
     `SourceShape`'s final home is `transform`, exported (§5.1 amendment);
     focused architecture test + AGENTS.md boundary-table update.
   - **Keys.** `plan_material` gains the per-strategy behavioral version entry
     (§7).
   - **Docs.** imgproxy support matrix, **stage/order** axis: the resolution
     column now lives in the imgproxy strategy; note `fixSize`/`limitScale`
     remain Output-boundary (§4.4/§4.7). TwicPics matrix: same axis for the
     focus/directive plumbing — no surface or pixel change on either target.
   - **Tests.** Golden proving the DprScale carry threads across an `:acquire`
     as strategy state (the §8 resize → trim → padding case); `plan_material`
     strategy-tag test; the architecture test above; golden + differential +
     wire green; imgproxy compatibility reviewer mandatory.

   **Stage 2b (same PR, separately-green commit sequence; closes #438):**
   de-dialect the Plan surface — replace `Plan.Operation.SetFocus` with the
   generic strategy `%Directive{name, payload}`, resolved by the plan's carried
   strategy (the TwicPics strategy's Directive row commits through
   `StateUpdate`; the neutral resolver has no Directive clause). Key data
   reshapes in place; parser payload-canonicality tests; byte-identical on the
   wire. `:carried` is redefined neutrally and `State.focus` renames to the
   neutral `carried_point` (§4.4); the executables-never-see-`:carried` clause
   rides Stage 3. Lands after the boundary move (it needs the carried
   strategy).

3. **(Optional) B-promotion + the banked Stage-2 deferrals.** If the §8 property
   spike is green and the version-pinning is acceptable, flip `resize` from
   `read` to `advance` at the seam (selectively if needed) and retire the focus
   read-back. The prior stages' goldens are the equivalence net. Banked from
   the Stage-2 scope decision (§4.4):
   - **Thin the executables** to apply-exact primitives (resolver emits
     force-to-exact resizes / exact-box crops). Prerequisite: an **error
     channel on the Resolver contract** — `reject_enlargement` /
     `upscale_required` must surface at resolve time, before pixels; today they
     surface from `Resize.execute` through `Chain`.
   - **Move the carried point into the TwicPics strategy carry** via the
     **staged continuation** (§4.4): an `:acquire` `then_fn` may return a
     further `{ops, continuation}` stage, so a multi-executable expansion
     splits at the realized-dims seam (`[resize]` → read `W′` → `[crop]`),
     plus pure origin helpers on `Crop`/`ExtendCanvas` (mirroring
     `resolved_box_dims`). Resolve `:carried` to a concrete `{:fp, x, y}`
     before emission and delete the executables' point mechanics
     (`Focus.scale`/`translate`/`reflect_rotate` call sites). **Independent of
     the property spike** — the fold is exact by measurement, so this lands
     whether or not B is adopted (and if B lands, the extra stage for resize
     can collapse in favor of the computed dims).

Each stage is independently green on golden + differential + wire.

## 10. Risks

- Most parity-critical, differential-pinned code in the repo. The
  results-identical gate + compatibility reviewer are non-negotiable.
- The frame-aware `acquire`/interpreter (§4.7) is the highest-risk detail: an
  interpreter that declares the wrong frame reintroduces the `#182` class.
- Orientation dissolution has subtle pieces the spec now enumerates but that are
  easy to get wrong: making `Chain`'s materialization orientation-agnostic (so trim
  materializes to the storage frame), flush position by op-list order, and the
  smart/detect explicit-`Flush` coupling.
- `decode_shrink` has three reset paths and the `#185` crop swap ordering; do not
  collapse them.
- `Flush` must clear the sequential-safety gate; the
  silent-buffering perf failure mode is not covered by correctness tests (perf
  benchmark deferred, as today).
- B-promotion (if pursued) pins results-identical to undocumented libvips output
  rounding across source-built version upgrades — hence gated on the property
  spike and kept optional.

## 11. Anchors (as of 2026-07-01)

- [`lib/image_pipe/transform/resize_planning.ex`](../../../lib/image_pipe/transform/resize_planning.ex) — conflated neutral-core + imgproxy resolver
- [`lib/image_pipe/transform/orientation_scheduler.ex`](../../../lib/image_pipe/transform/orientation_scheduler.ex) — the deferral engine that dissolves into an explicit Flush op + pure advances
- [`lib/image_pipe/transform/plan_executor.ex`](../../../lib/image_pipe/transform/plan_executor.ex) — today's driver + the cross-op `context`
- [`lib/image_pipe/transform/operation/resize.ex`](../../../lib/image_pipe/transform/operation/resize.ex) — the neutral `resolve_dimensions` core + the focus read-back (`~:111`)
- [`lib/image_pipe/transform/focus.ex`](../../../lib/image_pipe/transform/focus.ex) — neutral point-transform math (its *carry* stays on `State` as the neutral `carried_point` until Stage 3; §4.4)
- [`lib/image_pipe/transform/state.ex`](../../../lib/image_pipe/transform/state.ex) — the fields `SourceShape` subsumes
- [`lib/image_pipe/transform/chain.ex`](../../../lib/image_pipe/transform/chain.ex) — per-op driver + lazy materialization (stays)
- [`lib/image_pipe/transform/decode_planner.ex`](../../../lib/image_pipe/transform/decode_planner.ex) — pure load-option planner feeding the seed shape
- [`lib/image_pipe/transform/geometry.ex`](../../../lib/image_pipe/transform/geometry.ex) — neutral rounding/placement primitives (stays)
- [`lib/image_pipe/renderer.ex`](../../../lib/image_pipe/renderer.ex) + [`request/render_runner.ex`](../../../lib/image_pipe/request/render_runner.ex) — the carried-module precedent and its `request`-rooted dispatch (§5.1)
- [`lib/image_pipe/output/encoder.ex`](../../../lib/image_pipe/output/encoder.ex) + [`request/source_session/producer.ex`](../../../lib/image_pipe/request/source_session/producer.ex) — `fixSize`/`MaxResultDimension` caps (Output boundary, out of resolver scope)
- [`lib/image_pipe/plan/key_data.ex`](../../../lib/image_pipe/plan/key_data.ex) — `:auto` → `auto_orientation_match_v1`; where strategy version tags must land
- [`lib/image_pipe/request/http_cache.ex`](../../../lib/image_pipe/request/http_cache.ex) — ETag from symbolic plan + source seed + Accept
