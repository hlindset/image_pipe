# Exploration: a "virtual libvips buffer" and an explicit Resolve stage

**Status:** Exploration / design sketch — *not* an approved spec, *not* an implementation plan.
**Date:** 2026-07-01
**Origin:** A "dreaming" conversation about whether coordinate resolution could happen
without a live libvips image, and what that would unlock.

This document banks the findings so a later real brainstorming → spec cycle can pick
them up without re-deriving. Nothing here is committed to; the "Direction" is a
hypothesis that survived a pressure test, not a decision.

---

## 1. The question that started it

> Is it possible to have a "virtual libvips buffer" to work against in the transform
> pipeline planning stage — so calculations aren't dependent on running things through
> libvips until execution, and at that point we already have the coordinates we need?
> What could we gain?

Two corrections reframed the question during exploration:

1. **libvips dimension reads are already lazy.** `Image.width/1` doesn't force pixels —
   it reads pipeline metadata. So the win is *not* "avoid paying compute during
   planning" (we aren't paying it). The prize is **decoupling and determinism**.
2. **The real motivation is un-bleeding, not the buffer itself.** The driver is that
   per-parser (imgproxy/IIIF/TwicPics) resolution logic has bled into the *execution*
   stage. A virtual buffer is the *substrate* that makes pulling it back possible; it's
   the means, not the end.

## 2. Current state — the bleed, mapped

Parsers do the right thing at their seam: each dialect's `plan_builder.ex` emits
semantic `ImagePipe.Plan.Operation.*` structs via the `ImagePipe.Plan.Operation`
factory and defers resolution. The bleed is downstream, in the *transform* layer.

`ImagePipe.Transform.ResizePlanning` and `ImagePipe.Transform.Lowering` are soaked in
imgproxy semantics (`prepare.go`, `calc_position.go`, `scale_on_load.go`,
`ExtractGeometry`, `cropToResult`, `ResizeAuto`, ties-to-even vs half-away rounding,
issue tags `#236`/`#182`/`#237`). None of it `alias`es a parser module, so **Boundary is
satisfied** — but the *Transform-neutrality* guideline is quietly violated.
`Transform.ResizePlanning` is a **de-facto imgproxy adapter wearing a neutral name.**

**Why it bled into execution:** the resolution is *source-shape-dependent*. Fill-vs-fit
compares `srcW−srcH` to `dstW−dstH`; the no-enlarge cap is `min(srcW/w, srcH/h)`;
shrink-rescale needs the realized decode factor. Parsers run *before* fetch, so they
can't do this math. Execution was simply the first place the source shape was known.

### 2.1 Stratification (the key finding)

The three dialects light up very different slices of the `Plan.Operation.Resize`
surface. Resolution machinery stratifies accordingly:

| Resolution machinery | IIIF | TwicPics | imgproxy | Verdict |
|---|:---:|:---:|:---:|---|
| `resolve_dimension` px/ratio/scale/auto, half-away rounding | ✅ | ✅ | ✅ | **neutral core** |
| gravity anchors, center placement, region crop | ✅ | ✅ | ✅ | **neutral core** |
| `:cover`/`:fit` + cropToResult (crop back to box) | — | ✅ | ✅ | **neutral core** |
| CropGuided aspect-ratio | ✅ | ✅ | ✅ | **neutral core** |
| `mode: :auto` fill-vs-fit (`ResizeAuto` diff-bucketing) | — | — | ✅ | **imgproxy-only** |
| `min_*` dimension coupling | — | — | ✅ | **imgproxy-only** |
| no-enlarge DPR cap (`resize_padding_scale`) | — (dpr=1) | — (dpr=1) | ✅ | **imgproxy-only** |
| `down`/`fill_down` | — | — | ✅ | **imgproxy-only** |
| quarter-turn **display-frame** swap (`display_source_dims`) | — | — | ✅ | **imgproxy-only** |
| shrink-on-load coord rescale (`rescale_crop_for_decode_shrink`) | — | — | ✅ | **imgproxy-only** |
| ties-to-even offset rounding | — | — | ✅ | **imgproxy-only** |

`Transform.ResizePlanning` is therefore a **thin neutral geometry core wrapped in a
thick imgproxy resolver**, conflated in the same functions and gated by `mode`.

**Punchline:** the entire bug-dense frame cluster — the `#182`/`#237` quarter-turn ×
min-coupling × DPR-cap interactions — is *purely imgproxy*. IIIF and TwicPics cannot
even reach it (dpr=1, no `min_*`, no `:auto`). Moving it into an imgproxy resolution
strategy both fixes the neutrality bleed *and* quarantines the bug-dense code to the one
dialect that needs it, where it can be tested as data against imgproxy's actual source.

### 2.2 The codebase is already ~60% here

`ImagePipe.Transform.State` accretes symbolic scalar facts *precisely because the live
Vix image is an unreliable narrator about geometry*:

- `source_dimensions` — exact stored `{w,h}`, carried because the live image gives the
  wrong frame under shrink-on-load.
- `decode_shrink` — the realized per-axis factor.
- `pending_orientation` — deferred rotation, symbolic (only the EXIF header is read once).
- `focus` — carried point, transformed by pure math per op.

Every one exists so the code can reach *past* `Image.width(image)` toward a carried
scalar fact. The virtual buffer is the honest completion of that trend.

## 3. Direction (hypothesis)

### 3.1 A single pure resolver, driven — *not* two stages with a firewall

The naive framing is a 3-stage pipeline (Parse → Resolve → Execute) with a symbolic
Resolve pass. The trim-first case (below) shows that a fully-static, ahead-of-pixels
Resolve pass is impossible in general. The escape is to collapse Resolve+Execute into
**one driver loop over a single pure resolver**:

```
Resolver.resolve(shape, plan_op, strategy) -> {[concrete_op], continuation}
   continuation = {:shape, next_shape}   # pure ops: new shape computed, no pixels
                | :measure               # opaque ops: shape unknown, read it back
```

The resolver is **never called against an unknown shape.** The driver supplies a
*concrete* `SourceShape` at every step — from header facts when derivable, from a pixel
measurement when an opaque op intervened:

```
shape = seed_from_header + decode_planner        # concrete: w/h/orientation/shrink
for op in plan:                                   # fixed neutral order, no reorder
    {ops, cont} = Resolver.resolve(shape, op, strategy)   # the ONLY resolution logic
    image = apply(ops, image)                             # pixels
    shape = case cont do
              {:shape, s} -> s                            # advanced purely
              :measure    -> measure(image)               # opaque: dims read back
            end
```

**Resolution rules live once** (in the resolver). **Shape acquisition** (header vs
measurement) is the driver's job. These are the two things today's code fuses, and
separating them is the whole idea.

### 3.2 The virtual buffer = `SourceShape`

A pure value threaded by the driver: `{w, h, frame: :storage|:display,
pending_orientation, has_alpha?, interpretation, decode_shrink}`. It **subsumes four
ad-hoc `State` fields** (`source_dimensions`, `decode_shrink`, `pending_orientation`,
`focus`) into one coherent propagated shape. The live image is touched only to *apply*
pixels and to `measure` after opaque ops.

### 3.3 Neutral core + dialect strategy

- **Neutral default resolver** owns the shared column (fit/cover/stretch/region/canvas/
  padding + cropToResult). IIIF and TwicPics use only this.
- **imgproxy strategy** additionally owns the imgproxy-only column (auto classification,
  `min_*` coupling, no-enlarge DPR cap, display-frame swaps, shrink rescale, fill_down,
  ties-to-even), living under `parser/imgproxy/` (dialect quirks stay in the adapter).

## 4. Trim-first: the pressure test that shaped the design

> How can we escape having all rules in both plan and execution if we start the pipeline
> with a trim?

A trim's output shape is unknown until pixels run, so a symbolic pass can resolve
nothing downstream. The *trap* is implementing resolution twice (symbolic + execution).
The *escape* (§3.1): one resumable pure resolver, driven with concrete shapes.

Trim-first walks the driver loop with **zero downstream rules in execution**:

1. Op 0 = trim. `resolve` returns `{[%Trim{…}], :measure}` — resolves trim's own params
   (shape-independent) and signals "measure after." No downstream rule ran.
2. Driver runs trim (materializes, as `requires_materialization?` already dictates),
   then `measure(image)` → concrete post-trim shape. Free: trim had to run anyway.
3. Op 1 = `resize(:auto, …)`. `resolve` is called with the *measured* shape — the
   **identical** fill-vs-fit code runs, fed a shape from a ruler instead of a header.

You don't split the *rules*; you split the *timeline*. Trim-first just means the first
shape handoff is a measurement instead of a header read.

**What you lose (honest):** a *complete, static, ahead-of-pixels* `ResolvedPlan` exists
only for opaque-free plans. A trim-first plan's downstream boxes are unknowable before
pixels — physics, not architecture. Testability-as-data is **full for the opaque-free
majority**, degrading to "resolved prefix + opaque marker + resolved suffix" otherwise.
You lose the *artifact's completeness*, never the *single resolver*.

## 5. Pressure-test verdicts

### Seam 1 — Resolver boundary: `Renderer` is the exact precedent
`ImagePipe.Renderer` (a neutral `Boundary, deps: [ImagePipe.Plan]` behaviour) already
solves this: the Plan carries the dialect module itself (`render: {:custom, module,
params}`) "so the core never enumerates renderers," and `request` dispatches
`module.render(...)` without naming a dialect. A `Resolver` behaviour mirrors it 1:1 —
the Plan carries an opaque strategy module chosen by the parser; the driver dispatches
dynamically; **no `transform → parser` edge**, by exactly the mechanism already blessed
for renderers.

### Seam 2 — Is `:auto` neutral? The code already treats it as a *versioned rule*
`Plan.KeyData.data(%Resize{mode: :auto})` contributes `rule: :auto_orientation_match_v1`
to the cache key — an admission that `:auto`'s classification is a named, versioned
policy, not a pure semantic. Clean seam: `mode: :auto` stays in the neutral Plan as a
**deferral marker** ("choose fill-or-fit at resolve time"); the **bucketing rule** moves
to the imgproxy strategy, tagged by that `..._v1` version. Don't banish `:auto`; the
code's own versioning shows the marker-in-Plan / rule-in-strategy split.

### Seam 3 — `measure()`: free on cost, simplifies shrink, but must be frame-aware
- **Cost zero:** only opaque ops (trim/smart/detect) trigger `measure`, and they already
  return `requires_materialization?: true`. Non-opaque ops advance the shape purely and
  never measure — streaming fast paths never materialize for shape reasons.
- **Consolidates shrink-on-load:** a frame-changing opaque op's `measure()` *is* the
  "crop before resize clears `decode_shrink`" reset, authoritatively.
- **The sharpest correctness edge:** `measure()` reads storage-frame dims, but an opaque
  op that self-materializes can also flush `pending_orientation` (storage→display). So
  the continuation must report **which frame the dims are in and whether an orientation
  flush co-occurred**. A naive `width/height` read reintroduces an `#182`-class frame
  bug. This is the highest-risk detail in the whole scheme.

### Cache / ETag — the model touches the contract *not at all*
`Request.HttpCache.etag_material/4` derives the ETag from `Key.plan_material(plan)` +
`source_seed` + `accept` — the **symbolic Plan**, never resolved geometry, never output
bytes — and `plan_material` for `:auto` already folds in the rule version tag.

- **ResolvedPlan is a pure function of (Plan, source bytes)**, both already captured by
  identity. Resolved boxes add nothing to the key/ETag.
- **Invariant:** each strategy must carry a **version tag** (auto already does). Change
  the resolution algorithm → bump the tag → correct invalidation. This is a *behavioral*
  version, orthogonal to the key *schema* version (so it doesn't collide with the
  greenfield "don't bump key data versions" rule).
- **Trim-first still gets the 304-before-any-work fast path**, because identity is
  `(symbolic plan + rule version + source seed + Accept)` and resolution *and* `measure()`
  are downstream of all four. The virtual-buffer/measure model *cannot* regress the
  pre-fetch conditional path, no matter how opaque the plan is.

## 6. What we'd gain / what it costs

**Gain**
- Un-bleed: imgproxy resolution leaves the neutral transform layer for an isolated,
  dialect-owned strategy — the primary motivation.
- Testability-as-data: assert resolved integer boxes without libvips/decoding output
  (full for opaque-free plans; the safety net *and* the payoff at once).
- Frame invariants become first-class (explicit `frame:` on `SourceShape`) instead of
  reconstructed at each call site — attacks the recurring quarter-turn/shrink bug class.
- Consolidation: 4 ad-hoc `State` fields → 1 `SourceShape`; shrink-carry special-case
  subsumed by `measure()`.
- Safe optimizations: drop-elision (provable identity ops) and explicit materialization
  scheduling. **Not** reorder (fixed-order contract; ops don't commute) — off the table.
- Introspection: a resolved plan is a great debug/fiddle artifact.

**Cost / risk**
- This is the most parity-critical, differential-pinned code in the repo.
- Complete static ResolvedPlan only exists for opaque-free plans.
- The frame-aware `measure()` edge (Seam 3) is genuinely fiddly.

## 7. If this is ever pursued

Not now — this is exploration. If picked up:

1. Run the normal brainstorming → spec → plan-review cycle (this doc is input, not the
   spec). A compatibility reviewer (imgproxy focus) is mandatory: the change touches the
   imgproxy resolution implementation.
2. **Results-identical first, boundary-moving second.** The resolver must reproduce the
   exact same integers before it's allowed to change *where* it runs. Net = a new
   "ResolvedPlan golden" test (assert concrete boxes as data) + the existing differential
   bake.
3. Treat the frame-aware `measure()` / opaque-op continuation as the highest-risk detail
   to nail in the spec — it's where a lazy implementation reintroduces the `#182` bug
   class this refactor exists to make impossible.

## 8. Anchors (as of 2026-07-01)

- `lib/image_pipe/transform/resize_planning.ex` — the conflated neutral-core + imgproxy resolver
- `lib/image_pipe/transform/lowering.ex` — Plan→executable lowering + shrink rescale
- `lib/image_pipe/transform/geometry.ex` — the genuinely neutral resolution primitives
- `lib/image_pipe/transform/state.ex` — the four fields `SourceShape` would subsume
- `lib/image_pipe/transform/chain.ex` — today's op-by-op driver + lazy materialization
- `lib/image_pipe/plan/operation/resize.ex` — the imgproxy-complete Resize surface
- `lib/image_pipe/plan/key_data.ex:250` — `mode: :auto` → `rule: :auto_orientation_match_v1`
- `lib/image_pipe/request/http_cache.ex:59` — ETag from symbolic plan + source seed + Accept
- `lib/image_pipe/renderer.ex` — the neutral-behaviour-carried-in-Plan precedent for `Resolver`
