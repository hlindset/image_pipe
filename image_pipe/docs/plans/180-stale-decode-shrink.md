# Plan: #180 stale `decode_shrink` across the residual resize (+ #186 comments, #185 quarter-turn axis cross)

## Scope (user-confirmed)

1. **#180** — residual resize leaks `decode_shrink` into later pipelines, mis-scaling absolute crops. **Core fix.**
2. **#186** — two stale comments in files #180 touches: `processor.ex:96-97`, `state.ex:23-25`.
3. **#185** — `decode_shrink` axis assignment crosses under a pending quarter turn for a gravity crop.

Out of scope (user declined): #182 orientation seams, #181 detector ETag, the rest of #186/#185.

This touches **imgproxy parity** (shrink-on-load = `scale_on_load.go`), so: compatibility reviewer required, and `docs/imgproxy_support_matrix.md` updated (behavioral/pixel axis).

## Background (verified against code)

- `decode_shrink` (`%{w: float, h: float}`, storage-frame, original ÷ decoded) is set on decode iff shrink-on-load fired (`processor.ex:118`), gated by `source_dimensions`.
- Absolute crops consume it via `rescale_crop_for_decode_shrink/2` (`plan_executor.ex:422`, `:436`) — divide absolute pixel dims/coords/offsets by the factor so the crop selects the same region on the shrunk frame. Mirrors imgproxy `scale_on_load.go` `CropWidth = max(1, Shrink(CropWidth, wpreshrink))`.
- The crop paths clear **both** `source_dimensions` and `decode_shrink` via `clear_source_frame/1` (`:232`).
- `Resize.execute` clears **only** `source_dimensions` (`resize.ex:75`). ← the bug.
- imgproxy has **no multi-pipeline concept** — `/-/` chaining is an ImagePipe extension; imgproxy runs one `mainPipeline` per frame and the preshrink factor (`wpreshrink`/`hpreshrink`) is a `Context`-local mutation (`scale_on_load.go`) discarded after that single pipeline. So the factor is intrinsically pipeline-local; it must not survive into ImagePipe's *next* pipeline.

> **Correction (post-implementation).** This bullet (and the matching lines under "Change 1" and "Conformance doc" below) is **wrong**: `/-/` chained pipelines are an **imgproxy Pro** feature (`IMGPROXY_MAX_CHAINED_PIPELINES`), not an ImagePipe extension. The compat reviewer only had the OSS imgproxy checkout, which omits Pro's chained-pipeline implementation. The correct framing: each chained pipeline is a full processing pass over the previous pipeline's in-memory output, so `scaleOnLoad`'s preshrink factor exists only for the initial decode and never carries forward — clearing `decode_shrink` at the residual resize is imgproxy Pro **parity**, not an extension's boundary. The fix is unchanged; only the rationale was corrected (see the shipped `scaleOnLoad` matrix row and `Resize.execute` comment).

## Review cycle

Reviewed by three disjoint subagents (imgproxy-compat against a local `~/src/imgproxy` checkout, correctness/reachability, test-coverage). Accepted corrections are folded in below: the upstream framing (display-frame rescale, single-pipeline), the `c:200:200` → `CropGuided` correction, the CropRegion scoping decision, and the #185 test shape.

## Change 1 — #180 core fix

`lib/image_pipe/transform/operation/resize.ex:71-75`:

```elixir
case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
  {:ok, image} ->
    # The residual resize has finished the downscale: the image is now at its final
    # resolution, so neither the stored original extent (source_dimensions) nor the
    # realized shrink-on-load factor (decode_shrink) applies any longer. Clearing
    # decode_shrink confines the preshrink coordinate rescale to the pipeline whose
    # decode produced it: imgproxy has a single pipeline and discards its Context
    # preshrink factor each frame (scale_on_load.go), so a later ImagePipe pipeline's
    # absolute crop must not be divided by it.
    {:ok, %State{set_image(state, image) | source_dimensions: nil, decode_shrink: nil}}
```

Why safe in every other ordering:
- Crop-before-resize (same pipeline): crop already ran `clear_source_frame` → `decode_shrink` is `nil` at resize; the extra clear is a no-op.
- Cover resize emits `[resize, crop]` (result-crop) in one `Chain.execute` list; that result-crop is built pre-execute and does **not** consume `decode_shrink` (only `CropGuided`/`CropRegion` `executable_operations` rescale). No interaction.
- Fixed pipeline order puts crop before resize, so no in-pipeline crop legitimately needs `decode_shrink` after a resize.

## Change 2 — #185 quarter-turn axis cross

`do_execute_crop(%CropGuided{}, ...)` quarter-turn branch (`plan_executor.ex:267-275`): `executable_operations` rescales the **display-frame** crop dims by **storage-frame** `%{w:, h:}` factors, then `compensate_crop` swaps width↔height for the quarter turn — so a display width divided by `wshrink` lands on the storage **height** axis (which was shrunk by `hshrink`). Crossed factors. Latent (factors usually equal; per-axis JPEG `shrink:n` rounding → worst case ~1px), but wire-reachable (EXIF 5–8 / `rot:90/270` + gravity crop + shrink-triggering resize, all in one pipeline).

Fix: rescale with **swapped** factors when the pending orientation is a quarter turn, so the swap that follows lands them on the right axes. Localized to the quarter-turn branch — leave the non-oriented rescale untouched.

```elixir
true ->
  shrink = orient_decode_shrink(state.decode_shrink, po)
  executable =
    operation
    |> executable_operations(%State{state | decode_shrink: shrink}, ctx)
    |> Enum.map(&compensate_crop(&1, po))
  Chain.execute(state, executable, opts)
```

```elixir
# A pending quarter turn swaps the crop's axes (compensate_crop) AFTER the decode-
# shrink rescale. decode_shrink is storage-frame (compute_achieved_shrink divides
# the un-oriented header dims); the crop dims are display-frame. imgproxy rescales
# crop dims in the DISPLAY frame — its SrcWidth/preshrink are ExtractGeometry-swapped
# (prepare.go), so display dim ÷ display factor, no crossing. We reach the same
# result by pre-swapping our storage-frame factors so each display axis is divided by
# the factor of the storage axis it will become after the quarter-turn swap.
defp orient_decode_shrink(nil, _po), do: nil
defp orient_decode_shrink(%{w: w, h: h} = shrink, po) do
  if PendingOrientation.quarter_turn?(po), do: %{shrink | w: h, h: w}, else: shrink
end
```

`Chain.execute` is still called with the **original** `state`; only the built ops carry the swapped factors. `quarter_turn?` is false for a 180° half turn, which `compensate_crop` does **not** dim-swap — so the guard correctly leaves the factor unswapped there.

**CropRegion — scoped out, not fixed (review-confirmed).** The compat reviewer verified the imgproxy parser emits **only `CropGuided`** (`plan_builder.ex` `crop_guided`); imgproxy has no absolute-region crop, and no other in-repo parser produces `%CropRegion{}`. Its pending-orientation path (`:236-246`) flushes first then crops the oriented frame with `decode_shrink` still set, so it carries the *analogous* latent crossed-factor under a quarter turn — but the shape is **unreachable from any producer**. Per the project's "no impossible-internal-misuse tests / shrink unsupported API surface" rules, we do **not** add CropRegion quarter-turn handling or a test for it. Leave the path untouched; note the scoping in the commit. (`#185` itself only names `CropGuided`.)

## Change 3 — #186 stale comments

- `processor.ex:96-97`: drop the false "shrink is declined when a crop/quarter-turn rotate precedes the resize, so they cannot go stale" tail. Both are allowed through since #151; cross-pipeline staleness is real (this is #180). Rewrite to state the actual invariant: `source_dimensions`/`decode_shrink` are stored-frame and confined to the pipeline whose decode set them — the residual resize (and any preceding crop) clears them.
- `state.ex:23-25`: "Shrink-on-load is declined when a quarter-turn rotate precedes the resize" is false since #151 (`decode_planner.ex:105-111` allows it with an axis swap). Correct to reflect that a preceding quarter-turn rotate is allowed through (orientation deferred), and that the residual resize now clears **both** `source_dimensions` and `decode_shrink`.

Remove cleanly (no "this used to say…" residue, per project rules).

## Tests (TDD — write first, watch fail, then implement)

**#180 — wire-level, in `test/image_pipe/shrink_on_load_test.exs`** (real `ImagePipe.call/2`, imgproxy parser; `/-/` separates pipelines). `c:200:200` parses to a **center `CropGuided`** with absolute pixel dims — these go through `shrink_abs_dimension` (the width/height divide), which is the staleness the test exercises (not `shrink_crop_from`, which is region-only and unproduced).

1. **Multi-pipeline absolute crop regression.** `/_/rs:fit:500:500/-/c:200:200/f:jpeg/plain/images/beach.jpg`. beach.jpg 4000×2667 → pipeline 1 `fit:500:500` shrinks ~8 (decode 500×333, residual resize lands 500×333), `decode_shrink ≈ {w: 8, h: 8}`. Pipeline 2 center-crops 200×200 from the 500×333 live image. Assert decoded output **200×200**. Pre-fix the leaked factor divides → ~25×25. (Math reviewer-verified.)
2. **No false positive without shrink.** A multi-pipeline request whose pipeline 1 provably does **not** shrink (pin a PNG source or a large-enough pipeline-1 target so no power-of-2 shrink fires), same pipeline-2 `c:200:200`, asserts identical **200×200** — guards the fix isn't shrink-dependent.

**#185 — `execute_plan`-level, in `test/image_pipe/transform/plan_executor_test.exs`.** Not wire-observable: real shrink-on-load is uniform (`shrink:n`/`scale`), so `decode_shrink.w ≈ .h` and the crossed factor is sub-pixel at the wire. The crossing is only visible with **asymmetric** per-axis factors. Mirror the established pattern at `plan_executor_test.exs:291` (which builds a `%State{}` with `source_dimensions` set, composes ops via `Operation.*` constructors, runs `Transform.execute_plan/3`, and asserts on **output image dims**):

3. Build a `%State{}` with an asymmetric `decode_shrink` (e.g. `%{w: 2.0, h: 4.0}`) + a pending quarter-turn orientation, run a `CropGuided` (via `Operation.crop_guided`, absolute pixel w/h) through `execute_plan`, and assert the **output crop dims** land on the orientation-correct axes. Pre-fix the crossed factors put the wrong extent on each axis; post-fix they match. This pins the orientation × per-axis-shrink contract the `rescale_crop_for_decode_shrink` per-axis generality exists for. (Setting `decode_shrink` on State is consistent with the accepted `:291` precedent setting `source_dimensions` on State — both are executor-owned fields, asserted via executed output, not a hand-built `%Crop{}`.)

No CropRegion test (unproduced — see Change 2). Confirm during the failing-test step that test 3 actually fails before the fix (non-tautological); if `execute_plan` output also can't resolve it, escalate the test shape rather than weaken the assertion.

## Conformance doc

`docs/imgproxy_support_matrix.md`:
- **Stage 3 `scaleOnLoad` row:** the realized preshrink coordinate rescale is **confined to the pipeline whose decode produced it** — the residual resize clears the factor, so an absolute crop in a later (ImagePipe `/-/`) pipeline is not rescaled. Frame it correctly: imgproxy has a single pipeline and discards its `Context` preshrink factor per frame, so there is no upstream cross-pipeline behavior to match — ImagePipe's clear keeps the extension's pipeline boundary parity-faithful. Behavioral/pixel axis.
- **Stage 7 `rotateAndFlip` row:** add that the `decode_shrink` per-axis factors are swapped for a quarter-turn crop (same storage↔display compensation family already documented there for gravity/dims). State imgproxy rescales crop dims in the **display** frame (ExtractGeometry-swapped `SrcWidth`/preshrink); ImagePipe reaches the same result by swapping its storage-frame `decode_shrink` before the quarter-turn crop compensation. Behavioral/pixel axis.

## Gate

`mise run precommit` (format, compile --warnings-as-errors, credo --strict, test). Focused first: `mise exec -- mix test test/image_pipe/shrink_on_load_test.exs test/image_pipe/transform/plan_executor_test.exs`.

## Commit

One reviewed-plan commit (this file) before implementation, per project process. Then the implementation commit(s).
