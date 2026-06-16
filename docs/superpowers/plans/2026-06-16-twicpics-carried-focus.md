# TwicPics Carried Focus (pixel-coordinate focus via carried state) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement issue #321 — TwicPics focus carried as image state (`State.focus`), transformed by each geometry op's realized affine, so bare-pixel/relative/anchor focus steers later consumers faithfully through resize/cover/contain/inside/turn/flip and multiple consumers, matching live TwicPics (probe `tools/twicpics_focus_probe.exs`).

**Architecture:** A carried focus point lives on `ImagePipe.Transform.State` as `nil | {x_ratio, y_ratio}` — an **exact-rational** continuous coordinate in the *current running (live-image) frame*. A new positional `ImagePipe.Plan.Operation.SetFocus` op resolves the parsed operand (px / relative ratio / anchor) against the live frame at its chain position, clamps positive OOB to the far edge, and stores the point. Every geometry **transformer** (`Resize`, `Crop`, `ExtendCanvas`, the orientation flush) feeds its *realized* scale/origin/orientation into one shared affine helper, `ImagePipe.Transform.Focus`, that updates the carried point; the helper is a no-op when `State.focus` is `nil`, so **imgproxy is untouched**. TwicPics **consumers** (`cover`, `crop`) carry a new `:carried` gravity that reads `State.focus` and normalizes it to a `{:fp, …}` fraction at the libvips boundary (the only rounding point). The switch is data (`:carried`), not a mode — there is no `dialect_mode` flag.

**Tech Stack:** Elixir, Vix/libvips (`Image.*`), ExUnit + StreamData, the existing deferred-orientation pipeline (`PendingOrientation`/`OrientationFlush`/`Orientation`).

---

## Settled design (do NOT redesign — pressure-test only)

This section is the gating design. Task 1 proves it end-to-end before the dependent tasks. The reviewers (plan-review cycle) stress-test it, above all the compatibility lens against the probe + porting reference.

### D1. The carried point and its frame
- `State.focus :: nil | {Measure-ratio, Measure-ratio}` where each axis is `{:ratio, n, d}` (**`n :: integer()`** — may go transiently negative when a crop translate moves the point left/above the window; `d :: pos_integer()`), an **exact rational continuous coordinate** in the **live-image frame** (the frame `Image.width/height(state.image)` reports right now). `nil` = "use the center default" at a TwicPics consumer. The numerator is `integer()` (matching `Measure.t`), NOT `non_neg_integer()` — do **not** clamp negatives in `translate`; a later canvas `+x` embed can legitimately bring the point back in range. The only clamp is `to_fp/1` (`clamp01`). [exec-review F2, arch-review F4]
- "Continuous coordinate, cell-midpoint convention": the boundary fraction is `x / dim` (NOT `x / (dim-1)`). The probe's 0-based guarantee (`focus=399` on a 400-wide → last pixel; `focus=500` clamps to it) is verified by a dedicated round-trip test (Task 6), because the boundary is the single rounding point.

### D2. `SetFocus` is a positional Plan operation (resolves units once)
- New `%ImagePipe.Plan.Operation.SetFocus{point: operand}` where `operand` is one of:
  - `{:coord, x_measure, y_measure}` with each measure `{:px, n}` | `{:ratio, n, d}` (straight from `Units.coordinates/1`, no `focal_ratio` gate),
  - `{:anchor, h, v}` with `h ∈ {:left,:center,:right}`, `v ∈ {:top,:center,:bottom}`.
- The parser emits it at the focus segment's chain position; `focus=auto` does **not** emit it (smart mode — see D6).
- `PlanExecutor.execute_operation(%SetFocus{}, state, …)` resolves the operand against the **live display frame** at its chain position into an exact-rational point, clamps, and stores it. It performs **no pixel work** and does **not** flush or alter `source_dimensions`/`decode_shrink` (so a following cover resize still sizes correctly). Resolution rules (per axis, `dim` = that axis's display extent):
  - `{:px, n}` → `{:ratio, n, 1}`.
  - `{:ratio, n, d}` → `{:ratio, n*dim, d}` (e.g. `1/2` of 400 → `200`; `3/2` of 400 → `600` before clamp).
  - anchor component: `:left`/`:top` → `{:ratio, 0, 1}`; `:right`/`:bottom` → `{:ratio, dim-1, 1}` (the far-edge pixel); `:center` → `{:ratio, dim, 2}` (fraction exactly `1/2`).
  - **Clamp positive OOB**: `x := min(x, dim-1)` (rational compare; `max(0, …)` too for safety). This makes `focus=500x500`→`399x399` on 400² and `focus=150p`/`focus=150px150p`→edge. Negative is impossible (rejected earlier by `Units` — keep it).

### D3. Display-frame resolution under pending orientation (EXIF / earlier turn-flip)
- The user authors focus in the **display frame** (TwicPics orients first). ImagePipe **defers** orientation, so when a `%SetFocus{}` runs with a non-identity `pending_orientation`, resolve against **display dims** and store the point **inverse-mapped into the live storage frame** (so it rides the storage image like every other geometry value, and the flush forward-maps it back). No early flush.
  - `display_dims` = live image dims, swapped on a pending quarter turn (mirror `PlanExecutor.display_source_dims/1` but off the **live image dims**, not `effective_source_dims`, because focus resolves against the running frame).
  - Resolve operand against `display_dims` → display fraction per axis (`x_frac = resolved_abs / display_dim`, exact rational, clamped to `[0, (dim-1)/dim]`).
  - Inverse-map the display fraction to the storage fraction with `Focus.inverse_point/2` (display→storage; the inverse of `OrientationFlush.apply_orientation`'s order). Multiply by storage (live) dims → storage absolute rational. Store.
  - Identity pending (or `nil`) → display==storage, the inverse map is identity.

### D3a. Shrink-on-load: rescale bare-pixel operands [exec-review F1 — HIGH/blocking]
- A leading `focus=20x10/cover=…` lets shrink-on-load decode the source smaller (`DecodePlanner` shrinks for the first resize; a `%SetFocus{}` is not a crop, so it neither blocks nor adjusts the shrink). The user authored `20` in the conceptual full frame, but the live image is the **shrunk** frame, so a raw `{:px, 20}` stored as `20` lands ~`shrink`× too deep. This is the exact class `rescale_crop_for_decode_shrink` (`plan_executor.ex:858-895`, `shrink_abs_coordinate`) handles for crops — `SetFocus` needs the analog.
- In `Focus.resolve/3`, **before** storing, divide each **`{:px, n}`** operand axis by `state.decode_shrink` (per-axis `%{w, h}`, `round` like `shrink_abs_coordinate`), with the same quarter-turn `orient_decode_shrink` per-axis swap the crop path applies under a pending orientation. **Relative `{:ratio,…}` and anchor operands are untouched** (proportional — they already track the shrunk frame). Pass `state.decode_shrink` (+ `pending_orientation` for the swap) into `Focus.resolve/3`.
- Test it: a transform-level test seeding `decode_shrink: %{w: 4.0, h: 4.0}` asserting a bare-pixel focus lands at the full-frame coordinate (Task 4), since the grid tests otherwise never set `decode_shrink`.

### D4. The shared affine helper `ImagePipe.Transform.Focus`
A new module `lib/image_pipe/transform/focus.ex`. Pure rational math; every function is a no-op when `state.focus == nil`. API (all take/return `State`):
- `scale(state, sx_ratio, sy_ratio)` — multiply each axis (resize). `sx = {:ratio, after_w, before_w}` from realized dims.
- `translate(state, dx_int, dy_int)` — add integer deltas (crop: `-left,-top`; canvas: `+x,+y`).
- `reflect_rotate(state, %PendingOrientation{}, {before_w, before_h})` — forward storage→display transform of the point (used by the flush). Composes EXIF autorotate ∘ user rotate ∘ user flips on the rational point, swapping dims on quarter turns.
- `to_fp(state)` — `nil | {:fp, fx_float, fy_float}` where `fx = clamp01(x / live_w)`, `fy = clamp01(y / live_h)`. The single float-conversion / clamp point. `clamp01` keeps fp in `[0.0, 1.0]` (the `Crop.crop_gravity` guard).
- `resolve(operand, display_dims, pending_orientation)` — D2/D3 resolution + clamp + inverse-map → stored rational point (called by `SetFocus`).
- Plus internal rational helpers: `ratio_mul`, `ratio_add_int`, `ratio_sub_int`, `ratio_reflect(x, dim)` = `dim - x` (continuous reflection; matches `Orientation`'s `1 - u` fraction rule), `ratio_min`/compare, all `gcd`-reduced per step.
- `Focus.inverse_point/2` and the forward in `reflect_rotate` reuse the **exact** quarter-turn/reflection rules already in `ImagePipe.Transform.Orientation` (`rotate_point`/`flip_x_point`/`flip_y_point` are `1-u`/swaps — re-express on rationals). Forward order = `rotate(exif) → flip_x(exif) → rotate(user) → flip_x(user) → flip_y(user)` (matches `Orientation.forward_point/2`). Inverse = reverse with self-inverse reflections and `360-angle` rotations.

### D5. Per-op realize-point hooks (the surfaced scale/origin)
Each executable geometry op, after computing its realized geometry and **before returning `{:ok, state}`**, updates `state.focus` via `Focus`:
- `Resize.execute/2` (`resize.ex:90-99`): capture live `{before_w, before_h}` before `resize_image`; after, `after_*` = `Image.width/height(image)`. `Focus.scale(state, {:ratio, after_w, before_w}, {:ratio, after_h, before_h})`. (Robust to shrink-on-load — uses actual live dims.)
- `Crop.execute/2` generic clause (`crop.ex:189-203`): after `crop_coordinates` yields `%{left, top, …}`, `Focus.translate(state, -left, -top)` on the result state. Applies to **every** crop (cover result-crop, guided crop) — a crop is always a transformer.
- `ExtendCanvas.execute/2` (`extend_canvas.ex:106-115,151-156`): surface the realized `{x, y}` embed offset from `embed_image`; `Focus.translate(state, +x, +y)`. Inert extend (no growth) → no-op.
- `OrientationFlush.flush/1` (`orientation_flush.ex:16-22`): before `copy_memory`, `Focus.reflect_rotate(state, po, {pre_w, pre_h})` using the pre-flush live dims. The flush is the **only** place rotate/flip touches focus (TwicPics turn/flip and EXIF all defer to here; arbitrary-angle `Rotate.execute` is never reached with a carried focus — imgproxy-only — and is left untouched).

### D6. The `:carried` gravity (consumer read) and the switch
- New gravity value `:carried` valid as a `CropGuided.guide` and `Resize.guide` (cover). Parser default for TwicPics cover/crop becomes `:carried`; `focus=auto` sets `{:smart, :face_assist}` (unchanged); a coord/anchor focus emits `%SetFocus{}` and leaves the running guide `:carried`. `crop=…@XxY` resets `State.focus` (D7) and leaves guide `:carried`.
- `PlanExecutor.tagged_executable_gravity(:carried)` → `:carried` (passthrough into the executable `%Crop{gravity: :carried}`).
- `Crop.execute(%{gravity: :carried} = params, state)` new clause: `case Focus.to_fp(state) do nil -> execute(%{params | gravity: {:anchor,:center,:center}}, state); {:fp,_,_}=g -> execute(%{params | gravity: g}, state) end`. `nil` focus ⇒ **center anchor** (byte-identical to today's no-focus cover/crop — no pixel regression).
- `Crop.requires_materialization?(%{gravity: :carried})` → `false`.
- The cover path (`cover_resize_and_crop`, `cover_resize_and_crop_display_frame`, `fit_resize_and_result_crop`) already passes `tagged_executable_gravity(operation.guide)` into the `%Crop{}` — `:carried` flows through unchanged. Order is correct: `Chain.execute` runs the resize first (scales focus), then the crop reads the scaled focus.

### D7. `crop=…@XxY` focus reset
- `%CropRegion{}` (executable: `crop_from: %{left, top}`) **resets** `State.focus` to the crop-result center: after the crop runs, set `state.focus = {{:ratio, new_w, 2}, {:ratio, new_h, 2}}` where `new_*` are the cropped live dims (fraction `1/2` ⇒ centre). Do this in `PlanExecutor.execute_operation(%CropRegion{}, …)` (it already wraps the crop + `clear_source_frame`). A region crop is NOT a focus-translate (it overrides), so the generic `Crop.execute` translate is **skipped for region crops** — gate the `Focus.translate` to gravity crops only (`crop_from: :gravity`), since region crops reset rather than carry.

### D8. Orientation interaction at carried consumers (pending turn/flip)
- A `:carried` crop or cover with a **non-identity pending orientation** must read/translate the focus in the **storage frame** (where `State.focus` lives), then the flush forward-rotates both image and focus. The carried point is already storage-frame content, so it must **not** be gravity-remapped by `compensate_crop`; but the crop **dimensions** still need the quarter-turn swap.
  - `PlanExecutor.compensate_crop/2`: add a clause for `%Crop{gravity: :carried}` — swap `width`/`height` on a quarter turn, leave gravity/offsets untouched (skip `compensate_gravity_for`). (imgproxy never produces `:carried`, so this is TwicPics-only.)
  - `do_execute_crop(%CropGuided{guide → :carried}, pending po)`: `:carried` is not `materializing_gravity?`, so it takes the `true ->` compensate branch — which now dim-swaps only. Cover under pending quarter turn uses `cover_resize_and_crop_display_frame` whose `%Crop{gravity: :carried}` is mapped by the same `compensate_crop` clause. The focus is read at `Crop.execute` time (storage frame, post-resize-scale), the crop fires, then `flush_if_pending` forward-rotates. Verified by the EXIF test (Task 8).

### D9. Exactness & neutrality invariants (must hold)
- No floats in `State.focus` end-to-end; only `Focus.to_fp/1` produces floats, at the libvips boundary, clamped to `[0,1]`.
- `imgproxy` path: `State.focus` is always `nil` → every `Focus.*` call is a no-op, `:carried` never appears. **Do not touch imgproxy parser/matrix/tests.** An architecture/compat reviewer confirms zero imgproxy behavior change.
- `zoom` stays out of scope (no `zoom` segment exists). Do not add one.

### File structure / change map
- **Create** `lib/image_pipe/transform/focus.ex` — the shared affine helper (D4).
- **Create** `lib/image_pipe/plan/operation/set_focus.ex` — the `%SetFocus{}` struct (D2).
- **Modify** `lib/image_pipe/transform/state.ex` — add `focus` field + typespec + moduledoc note.
- **Modify** `lib/image_pipe/transform/operation/resize.ex`, `crop.ex`, `extend_canvas.ex`, `orientation_flush.ex` — per-op hooks (D5) + `:carried` clause in crop (D6).
- **Modify** `lib/image_pipe/transform/plan_executor.ex` — `%SetFocus{}` dispatch (D2/D3), `tagged_executable_gravity(:carried)`, `compensate_crop` `:carried` clause (D8), `%CropRegion{}` focus reset (D7).
- **Modify** `lib/image_pipe/plan/operation.ex` — `set_focus/1` constructor, **`semantic?(%SetFocus{})` clause** (required — `Plan.validated_pipelines` rejects ops without one), `:carried` accepted by `resize_guide`/`tagged_crop_guide`, `SetFocus` in `@type semantic_operation`.
- **Modify** `lib/image_pipe/plan.ex` — add `Operation.SetFocus` to the `Plan` boundary `exports:` list.
- **Modify** `test/image_pipe/architecture_boundary_test.exs` — add `ImagePipe.Plan.Operation.SetFocus` to the exact-match `Plan` exports list and to `@concrete_plan_names`.
- **Modify** `lib/image_pipe/parser/twic_pics/plan_builder.ex` — emit `%SetFocus{}`, default guide `:carried`, remove `focal_ratio` rejection, route bare-px/anchor/relative.
- **Modify** `lib/image_pipe/parser/twic_pics/units.ex` — none expected (coordinates already parse px + relative + reject negative); confirm.
- **Modify** `fiddle/assets/twicpics-path.ts` + `fiddle/assets/TwicPicsControls.svelte` — px unit on coord focus (D-fiddle).
- **Modify** `docs/twicpics_support_matrix.md` — flip `focus=<coords>` bare-pixel + coordinate rows to Supported; update relative-focus row (clamp, not reject).
- **Tests** under `test/` (parser, transform unit/property, wire-boundary pixel) — see tasks.

Boundary check: `Focus` and `SetFocus` dispatch live in `Transform`/`Plan`. Request/source/response never name them. `ImagePipe.Plan.Operation` exports `set_focus/1`. Run `test/image_pipe/architecture_boundary_test.exs` after wiring.

---

## Task 1: Prove the realize-point + orientation design (the gating risk)

**Goal:** Land `State.focus`, the `Focus` helper, and the four per-op hooks, proven by transform-level pixel-equivalence tests on a synthetic grid — *before* any parser/`:carried` wiring. This de-risks "surfacing each op's realized scale/origin" and the flush rotation in isolation.

**Files:**
- Modify: `lib/image_pipe/transform/state.ex`
- Create: `lib/image_pipe/transform/focus.ex`
- Modify: `lib/image_pipe/transform/operation/resize.ex`, `.../crop.ex`, `.../extend_canvas.ex`, `.../orientation_flush.ex`
- Test: `test/image_pipe/transform/focus_test.exs`

- [ ] **Step 1: Failing test — `State.focus` defaults to `nil` and a scale multiplies it**

```elixir
# test/image_pipe/transform/focus_test.exs
defmodule ImagePipe.Transform.FocusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.State

  test "default focus is nil and helpers no-op on nil" do
    state = %State{focus: nil}
    assert Focus.scale(state, {:ratio, 1, 2}, {:ratio, 1, 2}).focus == nil
    assert Focus.translate(state, -10, -5).focus == nil
    assert Focus.to_fp(state) == nil
  end

  test "scale multiplies each axis exactly (rational, no float)" do
    state = %State{focus: {{:ratio, 200, 1}, {:ratio, 100, 1}}}
    scaled = Focus.scale(state, {:ratio, 1, 2}, {:ratio, 1, 2})
    assert scaled.focus == {{:ratio, 100, 1}, {:ratio, 50, 1}}
  end
end
```

- [ ] **Step 2: Run, expect failure** — `mise exec -- mix test test/image_pipe/transform/focus_test.exs` → fails (`State` has no `:focus`, `Focus` undefined).

- [ ] **Step 3: Add `State.focus`**

In `state.ex`, add to `defstruct` (after `color_imported?: false`): `focus: nil`, and to the typespec: `focus: {ImagePipe.Plan.Measure.t(), ImagePipe.Plan.Measure.t()} | nil`. Add a one-line moduledoc bullet: `- `focus`: TwicPics carried focus point `{x, y}` (exact rationals) in the live-image frame, transformed by each geometry op; `nil` defaults to center. imgproxy never sets it.`

- [ ] **Step 4: Create `Focus` with `scale`, `translate`, `to_fp`, and the rational helpers**

```elixir
# lib/image_pipe/transform/focus.ex
defmodule ImagePipe.Transform.Focus do
  @moduledoc false
  # TwicPics carried focus point, transformed by each geometry op's realized
  # affine. Exact-rational continuous coordinate in the live-image frame; the
  # only float conversion is `to_fp/1` at the libvips boundary. Every function is
  # a no-op when `state.focus == nil` (imgproxy never carries a focus).

  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  # numerator is integer() (matches Measure.t): a crop translate may transiently
  # negate it; only to_fp clamps. [exec-review F2]
  @type ratio :: {:ratio, integer(), pos_integer()}
  @type point :: {ratio(), ratio()}

  @spec scale(State.t(), ratio(), ratio()) :: State.t()
  def scale(%State{focus: nil} = s, _sx, _sy), do: s
  def scale(%State{focus: {x, y}} = s, sx, sy),
    do: %State{s | focus: {ratio_mul(x, sx), ratio_mul(y, sy)}}

  @spec translate(State.t(), integer(), integer()) :: State.t()
  def translate(%State{focus: nil} = s, _dx, _dy), do: s
  def translate(%State{focus: {x, y}} = s, dx, dy),
    do: %State{s | focus: {ratio_add_int(x, dx), ratio_add_int(y, dy)}}

  @spec to_fp(State.t()) :: nil | {:fp, float(), float()}
  def to_fp(%State{focus: nil}), do: nil
  def to_fp(%State{focus: {x, y}, image: image}) do
    {:fp, clamp01(ratio_to_float(x) / Image.width(image)),
          clamp01(ratio_to_float(y) / Image.height(image))}
  end

  # rationals -------------------------------------------------------------
  defp ratio_mul({:ratio, n, d}, {:ratio, n2, d2}), do: reduce(n * n2, d * d2)
  defp ratio_add_int({:ratio, n, d}, i), do: reduce(n + i * d, d)
  defp ratio_to_float({:ratio, n, d}), do: n / d
  defp reduce(n, d) do
    sign = if d < 0, do: -1, else: 1
    n = n * sign
    d = d * sign
    g = max(1, Integer.gcd(abs(n), d))
    {:ratio, div(n, g), div(d, g)}
  end
  defp clamp01(v), do: v |> max(0.0) |> min(1.0)
end
```

- [ ] **Step 5: Run focus_test.exs, expect PASS.** `mise exec -- mix test test/image_pipe/transform/focus_test.exs`

- [ ] **Step 6: Failing transform-level pixel test — focus carries through a resize op**

Add a grid helper + an end-to-end op test that builds a 4×4 colour-grid image (mirror the probe's `cell_color`: `{round(col*255/3), round(row*255/3), 255}`, 100px cells → 400×400), sets `State.focus`, runs an executable `%Resize{}` then a tiny `%Crop{gravity: :fp from focus}` via `Chain.execute`, decodes the centre pixel, and asserts the nearest cell equals the focused cell.

```elixir
# add to focus_test.exs
alias ImagePipe.Transform.Chain
alias ImagePipe.Transform.Operation.{Crop, Resize}

defp grid(cols \\ 4, rows \\ 4, cell \\ 100) do
  base = Image.new!(cols * cell, rows * cell, color: [0, 0, 0])
  for col <- 0..(cols - 1), row <- 0..(rows - 1), reduce: base do
    acc ->
      c = [round(col * 255 / (cols - 1)), round(row * 255 / (rows - 1)), 255]
      Image.compose!(acc, Image.new!(cell, cell, color: c), x: col * cell, y: row * cell)
  end
end

defp focus_cell(image, focus, ops) do
  state = %ImagePipe.Transform.State{image: image, focus: focus, materialized?: true}
  fp = ImagePipe.Transform.Focus.to_fp(%{state | image: state.image})
  # run the geometry ops, then a tiny centred crop reading the *carried* focus
  {:ok, st} = Chain.execute(state, ops)
  {:fp, fx, fy} = ImagePipe.Transform.Focus.to_fp(st)
  {:ok, st} = Chain.execute(st, [%Crop{width: 12, height: 12, crop_from: :gravity, gravity: {:fp, fx, fy}}])
  px = Image.get_pixel!(st.image, div(Image.width(st.image), 2), div(Image.height(st.image), 2))
       |> Enum.take(3) |> Enum.map(&round/1)
  nearest_cell(px)
end
# nearest_cell/1 mirrors the probe (min squared distance over the 16 cell colours).

test "focus carries through a 50% fit resize" do
  img = grid()
  # cell (1,1) centre = (150,150); after resize=0.5 -> (75,75) -> still cell (1,1) content
  resize = %Resize{mode: :fit, width: {:pixels, 200}, height: {:pixels, 200}, enlarge: false}
  assert focus_cell(img, {{:ratio, 150, 1}, {:ratio, 150, 1}}, [resize]) == {1, 1}
end
```

- [ ] **Step 7: Run, expect failure** (focus not yet updated by `Resize.execute`).

- [ ] **Step 8: Hook `Resize.execute/2`**

In `resize.ex`, in the `{:ok, image}` branch of `execute/2`, capture pre-resize live dims and apply scale:

```elixir
{:ok, image} ->
  before_w = image_width(state)
  before_h = image_height(state)
  after_w = Image.width(image)
  after_h = Image.height(image)

  state =
    state
    |> ImagePipe.Transform.Focus.scale({:ratio, after_w, before_w}, {:ratio, after_h, before_h})
    |> set_image(image)

  {:ok, %State{state | source_dimensions: nil, decode_shrink: nil}}
```

(`Focus.scale` first, then `set_image`, so `to_fp` later reads the new dims.)

- [ ] **Step 9: Run resize test, expect PASS.**

- [ ] **Step 10: Failing tests — crop translate + canvas translate + the flush rotation**

Add four tests modelled on the probe rows, each via `focus_cell/3`:
- `%Crop{...}` gravity crop translates focus: `cover=150x150` analogue — a `%Resize{mode: :fill,…}` + result `%Crop{gravity: {:fp from focus}}`; corner focus `(0,0)` (cell `{0,0}`) stays `{0,0}` after the cover-crop and a trailing crop. (Proves the cover-crop both reads and translates.)
- **`contain=150x150` analogue** [test-review F3]: a plain fit `%Resize{mode: :fit, width: {:pixels,150}, height: {:pixels,150}}` with NO consumer that moves focus (contain = pure scale, no crop/canvas); focus on cell `{3,0}` → `{3,0}`. Pins contain explicitly (named in the issue) rather than assuming it's covered by the resize case.
- `inside=200x100` analogue: a fit `%Resize{}` + `%ExtendCanvas{rule: {:dimensions, …}, gravity: center, background: :transparent}`; focus on cell `{2,2}` lands on `{2,2}` (not padding).
- flush rotation: seed `pending_orientation: %PendingOrientation{user_angle: 90}`, focus on cell `{1,0}`; after a flush + trailing crop the decoded cell is `{1,0}` (content tracked through the turn).

- [ ] **Step 11: Hook `Crop.execute/2` (gravity crops only) and `ExtendCanvas.execute/2`**

`crop.ex`, generic clause `def execute(%__MODULE__{} = params, %State{} = state)` — keep the existing `crop_width`/`crop_height` binding names so the edit applies cleanly [exec-review F5 nit]:
```elixir
{:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
  case Image.crop(state.image, left, top, crop_width, crop_height) do
    {:ok, cropped_image} ->
      state =
        if params.crop_from == :gravity,
          do: ImagePipe.Transform.Focus.translate(state, -left, -top),
          else: state

      {:ok, set_image(state, cropped_image)}

    {:error, error} ->
      {:error, {__MODULE__, error}}
  end
```
(Region crops `crop_from: %{…}` do NOT translate — they reset via `PlanExecutor`, Task 5.)

`extend_canvas.ex`, surface `{x,y}` from `embed_image` and translate:
```elixir
with {:ok, {width, height}} <- canvas_dimensions(state, operation.rule),
     false <- inert_extend?(state, width, height),
     {:ok, {image, x, y}} <- embed_image(state, operation, width, height) do
  {:ok, set_image(ImagePipe.Transform.Focus.translate(state, x, y), image)}
else
  true -> {:ok, state}
  {:error, reason} -> {:error, {__MODULE__, reason}}
end
```
Change `embed_image/4` to return `{:ok, {image, x, y}}` (it already computes `x`,`y`).

- [ ] **Step 12: Hook `OrientationFlush.flush/1` + add `Focus.reflect_rotate/3` and `inverse_point/2`**

`orientation_flush.ex`, in the pending clause, transform focus on the pre-flush dims:
```elixir
def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
  pre = {Image.width(state.image), Image.height(state.image)}
  with {:ok, image} <- prepare_random_access(state.image, po),
       {:ok, image} <- apply_orientation(image, po),
       {:ok, image} <- VipsImage.copy_memory(image) do
    state = ImagePipe.Transform.Focus.reflect_rotate(state, po, pre)
    {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
  end
end
```

Add to `focus.ex` the forward (`reflect_rotate/3`) and inverse (`inverse_point/2`) rational point transforms, composing the exact quarter-turn/reflection rules from `Orientation` (forward order = `rotate(exif) → flip_x(exif) → rotate(user) → flip_x(user) → flip_y(user)`), operating on a normalized rational fraction and re-scaling to the post-orientation dims. Reflection on a fraction is `1 - f`; quarter rotation maps `(u,v)→(1-v,u)` etc., with dims swapped. Implement on rationals (subtract-from-one, swap), `gcd`-reduced. `reflect_rotate` converts the stored point to a fraction (÷ pre dims), forward-transforms, and re-multiplies by the post-orientation dims (swapped on quarter turns). `inverse_point/2` is the display→storage inverse used by `SetFocus` (Task 4).

```elixir
@spec reflect_rotate(State.t(), PendingOrientation.t(), {pos_integer(), pos_integer()}) :: State.t()
def reflect_rotate(%State{focus: nil} = s, _po, _pre), do: s
def reflect_rotate(%State{focus: {x, y}} = s, po, {pw, ph}) do
  fx = ratio_div(x, pw); fy = ratio_div(y, ph)
  {fx2, fy2} = forward_fraction({fx, fy}, po)
  {nw, nh} = if PendingOrientation.quarter_turn?(po), do: {ph, pw}, else: {pw, ph}
  %State{s | focus: {ratio_mul(fx2, {:ratio, nw, 1}), ratio_mul(fy2, {:ratio, nh, 1})}}
end
```
(Define `ratio_div`, `forward_fraction`/`inverse_fraction` with `r_reflect({:ratio,n,d}) = reduce(d - n, d)` and the quarter-turn coordinate swaps mirroring `Orientation.rotate_point/2`.)

- [ ] **Step 13: Run the full focus_test.exs, expect PASS for resize/cover/inside/turn.** `mise exec -- mix test test/image_pipe/transform/focus_test.exs`

- [ ] **Step 14: Regression gate** — `mise exec -- mix compile --warnings-as-errors` then `mise exec -- mix test test/image_pipe/transform/` (the existing sequential-access + orientation tests must still pass — confirms imgproxy/no-focus paths unaffected, since `Focus.*` is a no-op on `nil`).

- [ ] **Step 15: Commit** — `git add lib/image_pipe/transform/{state,focus}.ex lib/image_pipe/transform/operation/{resize,crop,extend_canvas}.ex lib/image_pipe/transform/orientation_flush.ex test/image_pipe/transform/focus_test.exs && git commit` with a message describing the carried-focus state + per-op affine hooks.

---

## Task 2: `SetFocus` Plan operation + `:carried` guide validation

**Files:**
- Create: `lib/image_pipe/plan/operation/set_focus.ex`
- Modify: `lib/image_pipe/plan/operation.ex`
- Test: `test/parser/twic_pics/plan_builder_test.exs` (constructor-level) and `test/image_pipe/plan/operation_test.exs` if present (else add to plan_builder_test)

- [ ] **Step 1: Failing test — `Operation.set_focus/1` builds a struct; `:carried` is a valid guide**

```elixir
test "set_focus builds a positional focus operation" do
  assert {:ok, %ImagePipe.Plan.Operation.SetFocus{point: {:coord, {:px, 20}, {:px, 10}}}} =
           ImagePipe.Plan.Operation.set_focus({:coord, {:px, 20}, {:px, 10}})
  assert {:ok, %ImagePipe.Plan.Operation.SetFocus{point: {:anchor, :left, :top}}} =
           ImagePipe.Plan.Operation.set_focus({:anchor, :left, :top})
end

test "carried is a valid crop/cover guide" do
  assert {:ok, %ImagePipe.Plan.Operation.CropGuided{guide: :carried}} =
           ImagePipe.Plan.Operation.crop_guided({:px, 100}, {:px, 100}, :carried)
  assert {:ok, %ImagePipe.Plan.Operation.Resize{guide: :carried}} =
           ImagePipe.Plan.Operation.resize(:cover, {:px, 100}, {:px, 100}, guide: :carried)
end
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Create the struct**

```elixir
# lib/image_pipe/plan/operation/set_focus.ex
defmodule ImagePipe.Plan.Operation.SetFocus do
  @moduledoc """
  Positional focus directive: resolves a focus operand against the running frame
  at its chain position and stores it as `State.focus`. Emits no pixel operation.
  """
  @enforce_keys [:point]
  defstruct @enforce_keys

  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}
  @type operand ::
          {:coord, measure(), measure()}
          | {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type t :: %__MODULE__{point: operand()}
end
```

- [ ] **Step 4: Add the constructor + guide validation in `operation.ex`**

- Add `alias ImagePipe.Plan.Operation.SetFocus`.
- Add `SetFocus.t()` to `@type semantic_operation` (a new `| SetFocus.t()` arm; or a dedicated `@type focus_operation`).
- Add constructor (reuse the existing `@x_anchors`/`@y_anchors` module attrs already in `operation.ex` — do NOT define new ones):
```elixir
@spec set_focus(term()) :: {:ok, SetFocus.t()} | {:error, error()}
def set_focus({:coord, x, y}) do
  with {:ok, x} <- Measure.position(x),
       {:ok, y} <- Measure.position(y) do
    {:ok, %SetFocus{point: {:coord, x, y}}}
  else
    _ -> invalid(:set_focus, [{:coord, x, y}])
  end
end

def set_focus({:anchor, h, v}) when h in @x_anchors and v in @y_anchors,
  do: {:ok, %SetFocus{point: {:anchor, h, v}}}

def set_focus(other), do: invalid(:set_focus, [other])
```
- Extend guide validators to accept `:carried`:
  - `defp resize_guide(:carried), do: {:ok, :carried}` (above `resize_guide(guide), do: smart_guide(guide)`).
  - `defp tagged_crop_guide(:carried), do: {:ok, :carried}` (above the `smart_guide` fallback).

- [ ] **Step 5: HIGH — add a `semantic?/1` clause for `%SetFocus{}`** [arch-review F3 — blocking]

`Plan.validated_pipelines` (`plan.ex:164`) calls `Operation.semantic?(operation)` on **every** op and rejects any that returns `false` with `{:invalid_pipeline_operation, …}`. Extending `@type semantic_operation` is **not** enough — without a `semantic?` clause every focus plan 4xx's at `validate_shape`. Add (next to the other `semantic?` clauses in `operation.ex`):
```elixir
def semantic?(%SetFocus{point: point}), do: valid_set_focus_point?(point)

defp valid_set_focus_point?({:coord, x, y}) do
  match?({:ok, _}, Measure.position(x)) and match?({:ok, _}, Measure.position(y))
end
defp valid_set_focus_point?({:anchor, h, v}) when h in @x_anchors and v in @y_anchors, do: true
defp valid_set_focus_point?(_), do: false
```
Add a test:
```elixir
test "a plan containing SetFocus passes validate_shape" do
  {:ok, sf} = ImagePipe.Plan.Operation.set_focus({:coord, {:px, 20}, {:px, 10}})
  assert ImagePipe.Plan.Operation.semantic?(sf)
end
```

- [ ] **Step 6: HIGH — export `Operation.SetFocus` from the `Plan` boundary** [arch-review F1b/1c — blocking]

`%SetFocus{}` is referenced cross-boundary (the `Transform` `PlanExecutor` aliases/matches it; the parser emits it). The `Plan` boundary `exports:` list (`plan.ex:9-44`) must include it, or `mix compile` fails the Boundary check.
- Add `Operation.SetFocus,` to the `exports:` list in `lib/image_pipe/plan.ex` (keep alphabetical: after `Operation.Saturation`/before `Operation.Sharpen`, matching the existing order).
- The arch test `assert_boundary_exports(plan, [...])` (`architecture_boundary_test.exs:540`) is **exact-match** (`declaration.exports == Enum.sort(expected)`, line 681) — add `ImagePipe.Plan.Operation.SetFocus` to that expected list (near line 562, with `CropGuided`/`CropRegion`).
- Add `:SetFocus` to `@concrete_plan_names` (`architecture_boundary_test.exs:64`) so request/source/response are guarded against naming it, consistent with `CropGuided`/`CropRegion`.

- [ ] **Step 7: Run** `mise exec -- mix test test/parser/twic_pics/plan_builder_test.exs test/image_pipe/architecture_boundary_test.exs` **+ `mix compile --warnings-as-errors`, expect PASS.**

- [ ] **Step 8: Commit** — plan-layer `SetFocus` (struct + constructor + `semantic?` + boundary export) + `:carried` guide.

---

## Task 3: Parser emits `SetFocus`, default `:carried`, removes the relative-`>1` rejection

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex`
- Test: `test/parser/twic_pics/plan_builder_test.exs`

- [ ] **Step 1: Failing parser tests**

```elixir
test "coordinate focus emits a positional SetFocus and a carried consumer" do
  {:ok, plan} = parse("focus=20x10/cover=100x100")
  ops = hd(plan.pipelines).operations
  assert [%SetFocus{point: {:coord, {:px, 20}, {:px, 10}}},
          %Resize{mode: :cover, guide: :carried}] = ops
end

test "relative >1 focus is clamped (no longer rejected) — emits SetFocus" do
  assert {:ok, plan} = parse("focus=150px150p/cover=100x100")
  assert [%SetFocus{point: {:coord, {:ratio, 3, 2}, {:ratio, 3, 2}}}, %Resize{guide: :carried}] =
           hd(plan.pipelines).operations
end

test "anchor focus emits SetFocus(anchor) + carried consumer" do
  {:ok, plan} = parse("focus=top-left/cover=100x100")
  assert [%SetFocus{point: {:anchor, :left, :top}}, %Resize{guide: :carried}] =
           hd(plan.pipelines).operations
end

test "mixed-unit coords (100x50p) parse to px + relative" do
  {:ok, plan} = parse("focus=100x50p/cover=100x100")
  assert [%SetFocus{point: {:coord, {:px, 100}, {:ratio, 1, 2}}}, %Resize{guide: :carried}] =
           hd(plan.pipelines).operations
end

test "negative focus is still rejected" do
  assert {:error, _} = parse("focus=-50x-50/cover=100x100")
end

test "focus=auto stays smart (no SetFocus)" do
  {:ok, plan} = parse("focus=auto/cover=100x100")
  assert [%Resize{guide: {:smart, :face_assist}}] = hd(plan.pipelines).operations
end

test "crop@coords resets to a plain center crop region" do
  {:ok, plan} = parse("focus=20x10/crop=100x100@0x0/cover=50x50")
  assert [%SetFocus{}, %CropRegion{}, %Resize{guide: :carried}] = hd(plan.pipelines).operations
end
```
(Provide a `parse/1` helper that calls the TwicPics manipulation parser + `PlanBuilder.to_plan/2`; mirror existing `plan_builder_test.exs` setup.)

**Rewrite ALL the obsolete focal-guide/anchor-guide/reject parser tests to the new `%SetFocus{}` + `:carried` contract** [test-review F2, arch-review F5, compat-review G2] — every one of these asserts the now-gone TwicPics `{:focal,…}`/`{:anchor,…}`/`guide: :center` emission and will fail otherwise:
  - `plan_builder_test.exs:36` `"relative-unit coordinate focus -> focal ratio guide"` (`focus=25px75p` → old `{:focal, 1/4, 3/4}` guide) → now `%SetFocus{point: {:coord, {:ratio,1,4}, {:ratio,3,4}}}` + `:carried`.
  - `plan_builder_test.exs:47` `"edge focal ratio of exactly 1 (100p)"` (`focus=100px0p`) → `%SetFocus{}` + `:carried` (no longer the `{:focal,…}` edge case).
  - `plan_builder_test.exs:68-75` the `focus=150px50p`/bare-pixel/`center` rejection test → `150px50p` now emits `%SetFocus{point: {:coord, {:ratio,3,2}, {:ratio,1,2}}}` (clamp at execute); `focus=center` still rejected; bare-pixel now emits.
  - the existing `"crop with coords resets to center"` test (asserts `guide: :center`) → now `guide: :carried` (the running guide stays carried; the *point* resets at execution — Task 5).
  These are genuine **contract migrations** (#321 changes the contract), not parity pins — delete the old assertion, don't keep an old-vs-new pin.

**Do NOT delete the `{:focal, …}` guide path itself.** `resize_guide({:focal,…})`/`tagged_crop_guide({:focal,…})` and `tagged_executable_gravity({:focal,…})` (`plan_executor.ex:1088`) stay — **imgproxy** still emits `{:focal,…}` for `g:fp`. Only the *TwicPics emission* of `{:focal,…}` (via `focal_ratio/1`) goes away. [arch-review F5, correcting compat-review G3]

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Rewrite the parser focus path + default guide**

In `plan_builder.ex`:
- `@initial`: change `guide: :center` → `guide: :carried`.
- `focus("auto", acc)` → unchanged (`{:smart, :face_assist}`), but note auto must also reset to a SMART consumer not carried: keep `%{acc | guide: {:smart, :face_assist}}`.
- `focus("center", _)` → keep rejection.
- Replace `focus/2` coordinate/anchor handling:
```elixir
defp focus(args, acc) do
  case Units.anchor(args) do
    {:ok, {:anchor, h, v}} -> emit_focus({:anchor, h, v}, acc)
    {:error, _} -> focus_coordinates(args, acc)
  end
end

defp focus_coordinates(args, acc) do
  with {:ok, {x, y}} <- Units.coordinates(args),
       {:ok, op} <- Operation.set_focus({:coord, x, y}) do
    {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
  else
    _ -> {:error, {:unsupported_focus, args}}
  end
end

defp emit_focus(anchor, acc) do
  with {:ok, op} <- Operation.set_focus(anchor) do
    {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
  end
end
```
- Delete `focal_ratio/1` (the relative-`>1` rejection — the divergence #321 fixes; clamp now happens at `SetFocus` execute, Task 4). **Delete the now-stale comments with it** [arch-review F5]: the `focus_coordinates` "Bare-pixel coordinates need running-dim … deferred" comment (~`plan_builder.ex:158-159`) and the `focal_ratio` "In-range relative focus only … Bare-px deferred" comment (~`170-172`). Remove cleanly — no narration of the removal (AGENTS.md).
- `crop_region/3`: change `guide: :center` reset → `guide: :carried` (focus reset happens at execution; the running guide stays carried so the *next* consumer reads the reset point).
- `cover`/`crop_guided` already pass `acc.guide` → now `:carried` by default. No change needed there beyond the default.

- [ ] **Step 4: Run parser tests, expect PASS.** `mise exec -- mix test test/parser/twic_pics/plan_builder_test.exs`

- [ ] **Step 5: Commit** — parser emits `SetFocus`, carried default, relative-clamp divergence removed.

---

## Task 4: `SetFocus` execution — resolve units, clamp, display-frame/EXIF handling

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex`
- Modify: `lib/image_pipe/transform/focus.ex` (add `resolve/3` + `inverse_point/2`)
- Test: `test/image_pipe/transform/focus_test.exs`

- [ ] **Step 1: Failing tests — resolution + clamp + inverse (no EXIF, then quarter-turn EXIF)**

```elixir
# ctx/1 builds %{display: dims, storage: dims, decode_shrink: nil} (no orientation);
# ctx/2 adds decode_shrink. Defined as a test helper.
test "SetFocus resolves px against the live frame" do
  assert Focus.resolve({:coord, {:px, 20}, {:px, 10}}, ctx({400, 400}), nil) ==
           {{:ratio, 20, 1}, {:ratio, 10, 1}}
end

test "SetFocus clamps positive OOB to the far edge (dim-1)" do
  assert Focus.resolve({:coord, {:px, 500}, {:px, 500}}, ctx({400, 400}), nil) ==
           {{:ratio, 399, 1}, {:ratio, 399, 1}}
  assert Focus.resolve({:coord, {:ratio, 3, 2}, {:ratio, 3, 2}}, ctx({400, 400}), nil) ==
           {{:ratio, 399, 1}, {:ratio, 399, 1}}
end

test "anchors resolve to corner/edge points" do
  assert Focus.resolve({:anchor, :left, :top}, ctx({400, 400}), nil) ==
           {{:ratio, 0, 1}, {:ratio, 0, 1}}
  assert Focus.resolve({:anchor, :right, :bottom}, ctx({400, 400}), nil) ==
           {{:ratio, 399, 1}, {:ratio, 399, 1}}
end

test "bare-pixel focus rescales by decode_shrink; relative does not" do
  # 4x decode shrink: a px-100 focus authored full-frame lands at 25 in the shrunk frame
  shrunk = ctx({100, 100}, %{w: 4.0, h: 4.0})
  assert Focus.resolve({:coord, {:px, 100}, {:px, 100}}, shrunk, nil) ==
           {{:ratio, 25, 1}, {:ratio, 25, 1}}
  # a relative 1/2 is proportional -> half the shrunk frame, untouched by shrink
  assert Focus.resolve({:coord, {:ratio, 1, 2}, {:ratio, 1, 2}}, shrunk, nil) ==
           {{:ratio, 50, 1}, {:ratio, 50, 1}}
end
```
(`ctx/1`/`ctx/2` build the resolution context — display dims, storage dims, and `decode_shrink` — that `PlanExecutor` passes in; see Step 3.)

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Implement `Focus.resolve/3`** (D2/D3/D3a) in `focus.ex`. Signature: `resolve(operand, ctx, pending_orientation)` where `ctx = %{display: {dw, dh}, storage: {sw, sh}, decode_shrink: nil | %{w, h}}` (the common no-orientation, no-shrink case has `display == storage`, `decode_shrink: nil`). Per axis:
  1. Resolve operand against the **display** dim → absolute rational: `{:px, n}` → `{:ratio, n, 1}`; `{:ratio, n, d}` → `{:ratio, n*dim, d}`; anchor component per D2.
  2. **Shrink rescale (D3a):** for a `{:px, _}` operand only, divide by `decode_shrink` (per-axis, with the quarter-turn `orient_decode_shrink` swap when `pending_orientation` is a quarter turn). Relative/anchor untouched.
  3. **Clamp** to `[0, dim-1]` (rational compare; `max(0, min(x, dim-1))`).
  4. **Orientation inverse (D3):** if `pending_orientation` non-identity, convert to display fraction, `inverse_point/2` (display→storage, reverse of the forward order) → storage fraction, multiply by **storage** dims. Identity/`nil` → store the display-frame absolute directly (display == storage).
  Implement `inverse_point/2` as the exact reverse of `reflect_rotate`'s forward composition (self-inverse reflections, `360-angle` rotations).

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Failing test — `%SetFocus{}` executes end-to-end via `PlanExecutor`** (no-EXIF): a small synthetic plan `[%SetFocus{point: {:coord,{:px,150},{:px,150}}}, %CropGuided{guide: :carried, width: {:px,12}, height: {:px,12}}]` on a 400² grid decodes to cell `{1,1}`. (Use `PlanExecutor.execute/3` with a `%State{image: grid}`.)

- [ ] **Step 6: Dispatch `%SetFocus{}` in `PlanExecutor.execute_operation/4`**

Add a clause (near the rotate/flip deferral clauses):
```elixir
defp execute_operation(%SetFocus{point: operand}, %State{} = state, _ctx, _opts) do
  ctx = %{
    display: display_live_dims(state),
    storage: {Image.width(state.image), Image.height(state.image)},
    decode_shrink: state.decode_shrink
  }

  {:ok, %State{state | focus: Focus.resolve(operand, ctx, state.pending_orientation)}}
end
```
Add `display_live_dims/1` (mirrors `display_source_dims/1` but off live image dims):
```elixir
defp display_live_dims(%State{pending_orientation: po, image: image} = _state) do
  w = Image.width(image); h = Image.height(image)
  if not is_nil(po) and PendingOrientation.quarter_turn?(po), do: {h, w}, else: {w, h}
end
```
Add `alias ImagePipe.Plan.Operation.SetFocus` and `alias ImagePipe.Transform.Focus`.

- [ ] **Step 7: Run, expect PASS.** Then `mise exec -- mix compile --warnings-as-errors`.

- [ ] **Step 8: Commit** — `SetFocus` execution + display-frame/EXIF resolution.

---

## Task 5: `:carried` consumer read, `crop@coords` reset, pending-orientation compensation

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex` (the `:carried` clause)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (`tagged_executable_gravity(:carried)`, `compensate_crop` `:carried`, `%CropRegion{}` reset)
- Test: `test/image_pipe/transform/focus_test.exs`

- [ ] **Step 1: Failing tests** — (a) a `%Crop{gravity: :carried}` reads `State.focus` (nil → center anchor, byte-identical to a center crop; set → fp); (b) `%CropRegion{}` resets `State.focus` to the cropped centre; (c) **`compensate_crop(%Crop{gravity: :carried}, po)`** swaps `width`/`height` under a quarter turn and leaves them (and gravity/offsets) unchanged under a half turn — assert gravity stays `:carried` in both [exec-review F3].

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Add the `:carried` clause to `Crop.execute/2`** (D6):
```elixir
def execute(%__MODULE__{gravity: :carried} = params, %State{} = state) do
  case ImagePipe.Transform.Focus.to_fp(state) do
    nil -> execute(%{params | gravity: {:anchor, :center, :center}}, state)
    {:fp, _, _} = fp -> execute(%{params | gravity: fp}, state)
  end
end
```
Place above the generic clause. Add `requires_materialization?(%__MODULE__{gravity: :carried}), do: false`.

- [ ] **Step 4: Wire `tagged_executable_gravity(:carried)` → `:carried`** in `plan_executor.ex` (passthrough, above the `{:focal, …}` clause).

- [ ] **Step 5: `%CropRegion{}` focus reset** (D7) — in `execute_operation(%CropRegion{}, …)`, after the crop + `clear_source_frame`, set the reset point:
```elixir
defp execute_operation(%CropRegion{} = operation, %State{} = state, ctx, opts) do
  with {:ok, %State{} = state} <- do_execute_crop(operation, state, ctx, opts) do
    {:ok, reset_focus_center(clear_source_frame(state))}
  end
end

defp reset_focus_center(%State{focus: nil} = state), do: state
defp reset_focus_center(%State{image: image} = state),
  do: %State{state | focus: {{:ratio, Image.width(image), 2}, {:ratio, Image.height(image), 2}}}
```
(Only resets when a focus is carried; a plain region crop with no focus stays `nil`.)

- [ ] **Step 6: `compensate_crop` `:carried` clause** (D8) — **clause ordering is load-bearing** [exec-review F3]: place this clause **above both** the existing `%Crop{crop_from: :gravity, gravity: gravity}` clause **and** the `%Crop{}` catch-all. A carried crop *is* `crop_from: :gravity` with `gravity: :carried`; if it falls into the gravity clause it hits `Orientation.compensate_gravity_for({:carried, …}, po)`, which has no `:carried` arm and misbehaves. The new clause:
```elixir
defp compensate_crop(%Crop{gravity: :carried} = crop, %PendingOrientation{} = po) do
  if PendingOrientation.quarter_turn?(po),
    do: %Crop{crop | width: crop.height, height: crop.width},
    else: crop
end
```
(Carried focus is already storage-frame content; only the crop box needs the quarter-turn dim swap. No gravity/offset remap.) The Step 1(c) unit test pins this clause for quarter + half turns.

- [ ] **Step 7: Run focus_test.exs + `mix compile --warnings-as-errors`, expect PASS.**

- [ ] **Step 8: Commit** — carried consumer read + region reset + carried orientation compensation.

---

## Task 6: 0-based boundary round-trip + property tests (the rounding crux)

**Files:**
- Test: `test/image_pipe/transform/focus_test.exs` (+ a property module)

These tests pin the single rounding point and the rational algebra. Some may pass immediately on the Task 1–5 code (regression-style); the round-trip/property assertions are the **red phase** for any boundary/orientation drift — note in the task that a test passing on first run is acceptable here (it locks behavior), but the OOB/reset cell tests below should be written and seen to exercise the new clamp/reset paths. [test-review F7]

- [ ] **Step 1: 0-based round-trip cell tests** — assert the guarantee survives `resolve → to_fp → fp gravity` for the probe's edge rows on a 400² grid via `focus_cell/3` with a **1×1** crop (pins the exact pixel): `focus=399x399` → bottom-right cell `{3,3}`; `focus=500x500` (clamped to 399) → `{3,3}`; cell-midpoint `focus=150x150` → `{1,1}`.

- [ ] **Step 2: `crop@coords` reset cell test** [test-review F4] — seed the probe's "reset after oob" chain at the transform level so the reset's **decoded pixel** effect is proven (not only the `{:ratio, w, 2}` struct value): a 400² grid, plan `[%SetFocus{point: {:coord,{:px,500},{:px,500}}}, %CropRegion{x: {:px,100}, y: {:px,100}, width: {:px,100}, height: {:px,100}}, %CropGuided{guide: :carried, width: {:px,12}, height: {:px,12}}]` decodes to cell `{1,1}` (the region centre `(150,150)`), proving the OOB focus was reset and recovered.

- [ ] **Step 3: Property tests** [test-review F6] — using StreamData:
  - `Focus.scale` then inverse scale returns the original reduced rational.
  - Orientation round-trip on **non-square** dims (`w ≠ h`, e.g. 300×400): four 90° `reflect_rotate`s return the original point, AND the intermediate single-90° point lands in the **swapped** frame (a dim-swap bug is invisible on square frames). 
  - `inverse_point(forward(p)) == p` over `PendingOrientation`s built from the **real producers** (`PendingOrientation.from_exif/2` + `fold_rotate/2` / `fold_flip/2` folds — not hand-built structs, per AGENTS.md "use a real producer") and random rational fractions.
  - Assert reduced form (bounded denominators) on outputs.

- [ ] **Step 4: Run, expect PASS.** Commit.

---

## Task 7: Wire-boundary pixel tests — focus carries through each op (probe-seeded)

**Files:**
- Test: `test/image_pipe/twic_pics_wire_conformance_test.exs`

Use the existing `call/2` + `average/1` + `dimensions/1` helpers. Seed structural cases from the probe `@cases`. Because the wire suite fetches a fixture source (e.g. `beach.jpg`), assert focus *steering* (decoded region/average differs from a centered baseline AND from opposing anchors) rather than exact cell colours; where a synthetic grid is needed for exact-cell assertions, prefer the transform-level grid tests (Task 1/6). Representative wire tests:

- [ ] **Step 1: bare-pixel focus steers a cover** — assert against BOTH the centered baseline AND the top-left anchor [test-review F5]: a focus that silently snaps to a fixed wrong anchor would pass a centered-only refute. Use a focus that is distinct from every corner (e.g. a mid-ish point) and assert it differs from the centered baseline and the top-left anchor:
```elixir
test "bare-pixel coordinate focus steers the next cover (no longer rejected)" do
  # pick a px focus that lands between the corner anchors on the cover's crop-slack axis
  focal = call("/images/beach.jpg?twic=v1/focus=2000x10/cover=100x100/output=jpeg")
  topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=100x100/output=jpeg")
  bottomright = call("/images/beach.jpg?twic=v1/focus=bottom-right/cover=100x100/output=jpeg")
  assert focal.status == 200
  assert dimensions(focal) == {100, 100}
  refute average(focal) == average(topleft)
  refute average(focal) == average(bottomright)
end
```
Replace the existing `bare-pixel coordinate focus is rejected (deferred)` test (it asserted `status == 400`). (Choose the px coordinate against the actual `beach.jpg` source dimensions so the cover's crop-slack axis is exercised — mirror the reasoning in the existing `relative coordinate focus steers the next cover` test at ~line 102; update that test's stale `{:focal,…}`-guide comment too [compat-review G4].)

- [ ] **Step 2: order-sensitivity (non-commutativity)** — `resize=50p/focus=…/cover` vs `focus=…/resize=50p/cover` resolve to different source content (averages differ), per the probe noncommute rows.
- [ ] **Step 3: multi-consumer carry-through (isolating baseline)** [test-review F5] — prove the carry survives the **second** consumer, not just that the cover stage differs. Compare `focus=X/cover=200x200/crop=120x120` against a baseline that steers the cover identically but does NOT carry into the trailing crop — i.e. a variant where the trailing crop is forced to center (`focus=X/cover=200x200/crop=120x120@…` region-reset, or `focus=X/cover=200x200/focus=center`-style). The two must differ, isolating that the carried focus steers the *trailing* crop. (A single all-centered baseline can pass merely from the cover differing — too weak.)
- [ ] **Step 4: relative `>1` clamp** — `focus=150px150p/cover=100x100` returns `200`/`{100,100}` and **equals the bottom-right anchor average** (clamped to the far edge), NOT a 4xx. (Strong equality assertion — keep.)
- [ ] **Step 5: negative reject** — `focus=-50x-50/cover=100x100` → `status == 400` (request-safety: fails before fetch; assert source not fetched using the `OriginShouldNotFetch` pattern from the existing rejection test).
- [ ] **Step 6: Delete the obsolete reject test** [compat-review G1] — remove the existing `out-of-range relative focus is rejected before source fetch` test (~`twic_pics_wire_conformance_test.exs:119`, asserts `status == 400` for `focus=150px50p`); Step 4 replaces its contract (now clamps + fetches). Genuine migration, not a parity pin.
- [ ] **Step 7: Run** `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`. Commit.

---

## Task 8: EXIF-oriented + turn/flip pixel tests

**Files:**
- Test: `test/image_pipe/twic_pics_wire_conformance_test.exs` (or a focused transform test with an EXIF fixture)

- [ ] **Step 1: EXIF-oriented source** — using an existing EXIF fixture (find one already used by orientation tests; reuse it), assert `focus=<near a known display corner>/cover=WxH` lands on that display-frame content (average differs from the opposite-corner anchor and matches the same anchor). This exercises D3 (display-frame resolution + inverse map) and D8 (carried crop under pending quarter turn).
- [ ] **Step 2: user turn/flip after focus** — `focus=<point>/turn=90/crop=…` and `focus=<point>/flip=x/crop=…` steer to the focused content through the deferred rotation/flip (decoded average differs from the no-focus turn/flip baseline). Seed from the probe `turn=90/180/270`, `flip x/y` rows.
- [ ] **Step 3: Run, expect PASS.** Commit.

---

## Task 9: Fiddle — pixel unit on the coordinate-focus control

**Files:**
- Modify: `fiddle/assets/twicpics-path.ts`
- Modify: `fiddle/assets/TwicPicsControls.svelte`

- [ ] **Step 1: `twicpics-path.ts`** — change the coord-focus axis type from `TwicRelLen` to `TwicLen` (which already supports `px | p | s`); `stepToken`'s `coord` case already uses `encodeLen` (handles `px`). Update `parseRelLen`/the focus-coord parser to accept bare-pixel tokens (a bare non-negative integer → `{unit: "px", value}`) and to **clamp** (not reject) relative `>1` for parity with the parser? — No: the fiddle only builds URLs; leave clamping to the server. Remove the `n > 100 ? null` / `n > 1 ? null` *focus* guards so the UI can author `150p` (the server clamps). The `coord` focus step type becomes `{ x: TwicLen; y: TwicLen }`.
- [ ] **Step 2: `TwicPicsControls.svelte`** — `setFocusMode`'s `"coord"` default `{ unit: "p", value: 50 }` stays valid; add `"px"` to the focus axis unit `<select>` (mirror the crop control's px option) and extend `focusRange` to return a px range (`{ max: <large>, step: 1, suffix: "px" }`). Update the stale comments that say "the parser rejects bare-pixel and center focus" / "ratio > 1 (max 100%)".
- [ ] **Step 3: Build** — `pnpm -C fiddle/assets run build` (also needed for fiddle mix tests). Then `pnpm -C fiddle/assets run check && pnpm -C fiddle/assets run lint`.
- [ ] **Step 4: Commit.**

---

## Task 10: Docs — support matrix

**Files:**
- Modify: `docs/twicpics_support_matrix.md`

- [ ] **Step 1:** Flip the `focus=<coords>` (bare pixel) row from `🚫 Rejected` to `✅ Supported` — bare pixel coordinates resolve against the running frame at the focus's chain position, carried as `State.focus` and transformed by each geometry op; describe the carry + clamp.
- [ ] **Step 2:** Update the `focus=<coords>` (relative `p`/`s`) row: an out-of-range relative focus (ratio `> 1`, e.g. `150p`) is now **clamped to the edge** (matching live TwicPics), not rejected. Remove the "rejected at the parser" wording.
- [ ] **Step 3:** Add a short note that focus is **carried image state** (transformers update it; `cover`/`crop` consume it; `crop@coords` resets it) — the **stage/order + behavioral** axes per AGENTS.md "Native API guidelines". Note `zoom` remains Deferred and composes once its segment lands. Keep `focus=auto` and `focus=center` rows as-is. (The porting reference is already updated — do not re-edit it.)
- [ ] **Step 4: Commit.**

---

## Task 11: Full gate + finish

- [ ] **Step 1:** `mise run precommit` (format-check, compile warnings-as-errors, credo --strict, full test). Fix any fallout.
- [ ] **Step 2:** `mise run precommit:fiddle` (adds the fiddle JS test/check/lint/format/build + Elixir gate). Requires the Task 9 build to have run.
- [ ] **Step 3:** `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs` — confirm no request/source/response code names `Focus`/`SetFocus`/concrete transform modules, and the new ops sit in the right boundaries.
- [ ] **Step 4:** Rename the branch to `feat/twicpics-carried-focus` (`git branch -m feat/twicpics-carried-focus`) before the first push. Leave the worktree dir as-is.
- [ ] **Step 5:** Open the PR. Body: `Fixes #321` as its own bare line. Verify with `gh pr view <n> --json closingIssuesReferences`. Note it builds on #324 (already merged).

---

## Self-review (run before the plan-review cycle)

**Spec coverage** (issue #321 acceptance, mapped):
- bare-px steers next consumer, resolved at chain position → Tasks 3,4,7.
- carries through resize/cover/contain/inside/turn/flip + multi-consumer → Tasks 1,7,8.
- positive OOB clamps / negative rejected / relative-`>1` clamp divergence → Tasks 3,4,7.
- EXIF frame → Tasks 4,8.
- mixed-unit `100x50p` → covered by `Units.coordinates` (px + relative) + Task 3 (`150px150p` test is mixed-unit shaped; add a `100x50p` parser assertion to Task 3 Step 1).
- exact rationals, only float at boundary; no `dialect_mode`, `:carried` is the switch → Tasks 1,2,6 + D9.
- support-matrix rows flipped → Task 10.

**Placeholder scan:** new module/struct code is complete; tests give real assertions seeded from the probe. The orientation `forward_fraction`/`inverse_fraction` rational helpers in Task 1 Step 12 and Task 4 Step 3 are described with the exact rules (`d - n` reflection, quarter-turn coordinate swaps mirroring `Orientation.rotate_point/2`, forward order from `Orientation.forward_point/2`) — implement them verbatim from those primitives; do not invent new rotation math.

**Type consistency:** `State.focus :: {Measure-ratio, Measure-ratio} | nil`; `SetFocus.point` operand `{:coord, measure, measure} | {:anchor, h, v}`; guide `:carried` valid in `CropGuided`/`Resize`; executable `%Crop{gravity: :carried}`; `Focus.to_fp/1` → `{:fp, float, float}`. Consistent across tasks.

**Plan-review cycle: completed (4 reviewers, disjoint lenses — compatibility, execution/orientation, architecture, test-design). All returned ACCEPT-WITH-CHANGES; accepted feedback applied above.** Resolved items:
- (HIGH) `semantic?(%SetFocus{})` clause — without it every focus plan is rejected at `validate_shape` (arch-review F3; Task 2 Step 5).
- (HIGH) `decode_shrink` rescale of bare-pixel focus — otherwise the headline feature mislands under shrink-on-load (exec-review F1; D3a, Task 4).
- (HIGH) `Operation.SetFocus` boundary export + arch-test exact-match list (arch-review F1b/c; Task 2 Step 6).
- `{:focal,…}` guide path stays imgproxy-only — compat-review's "delete it" was wrong; arch-review caught it (Task 3).
- ratio numerator widened to `integer()` (transient negatives via crop translate); `compensate_crop(:carried)` clause ordering; weak wire assertions strengthened; all obsolete focal-guide/reject tests enumerated for rewrite; non-square property dims + real `PendingOrientation` producers.

Compatibility verdict: all 23 reachable probe `@case` rows satisfied by a cited design rule; imgproxy provably untouched (`State.focus` nil → every `Focus.*` is a no-op, `:carried` never emitted). `zoom` correctly out of scope (no segment).
