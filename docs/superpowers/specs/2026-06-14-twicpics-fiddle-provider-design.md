# TwicPics fiddle provider — design spec

**Issue:** [#306](https://github.com/hlindset/image_plug/issues/306) — fiddle: add TwicPics as a third provider (reorderable transform-chain builder)
**Date:** 2026-06-14
**Status:** Proposed

## 1. Summary

Add **TwicPics** as a third provider in the demo fiddle (`fiddle/`), alongside
imgproxy and IIIF. The library parser (`ImagePipe.Parser.TwicPics`) already exists
and is wire-conformance tested (`test/image_pipe/twic_pics_wire_conformance_test.exs`).
This work is **demo UI + fiddle wiring only** — the parser is not touched.

TwicPics differs structurally from the other two providers. imgproxy and IIIF
expose a **fixed option set whose order does not change the result**, so their
controls are flat panels. TwicPics is an **ordered chain** —
`?twic=v1/resize=340/cover=100x100/focus=top` — where order changes the output and
relative units resolve against the *running* image (`resize=340/resize=50p` →
170px). The fiddle therefore needs a **reorderable chain builder**, not a fixed
control panel.

The supported surface is exactly the parser's documented v1 surface
(`docs/twicpics_support_matrix.md`): everything the builder offers must render,
and nothing the parser rejects appears in the UI.

## 2. Scope

### Chain transforms (reorderable)

| Transform | Params exposed in the UI |
| --- | --- |
| `resize`  | W and H, each with a unit selector `px` / `%` (`p`) / `scale` (`s`); either may be `auto` (`-`) |
| `cover`   | `size` ↔ `ratio` toggle → `WxH` (px) or `W:H` |
| `contain` | `WxH` (px) |
| `inside`  | `WxH` (px) — transparent letterbox only in v1 |
| `crop`    | `WxH` (px) + optional `@ XxY` origin |
| `focus`   | 8-anchor picker (`top`, `bottom`, `left`, `right`, `top-left`, `top-right`, `bottom-left`, `bottom-right`) — no `center` |

### Output settings (fixed footer, not part of the reorderable chain)

- `output` — `auto` / `avif` / `webp` / `jpeg` / `png`
- `quality` — `1..100`

Output position does not change the result, so it lives in a fixed footer below
the chain, not as a reorderable card.

### Out of scope (v1)

Everything the parser rejects — the builder simply does not offer it: `flip`,
`turn`, `zoom`, `background` / `border` / color ops, `resize-max` / `resize-min`,
ratio `resize=W:H`, ratio `inside=W:H`, coordinate / `auto` focus, URL signatures,
multi-origin path configuration. As parser support grows, the builder's transform
menu can grow with it.

## 3. Request contract

The parser reads the **source from `conn.path_info`** and the **chain from the
`twic` query param** (`ImagePipe.Parser.TwicPics.Path`):

- **Image request (fetch):** `/twic/<source>?twic=v1/<chain>/output=…/quality=…`
- **Browser address bar:** `/twicpics/<source>?twic=v1/<chain>/output=…/quality=…`

`<source>` is the raw sample path, e.g. `images/dog.jpg`. After the `/twic`
forward strips its prefix, `conn.path_info = ["images", "dog.jpg"]`, which
`Source.from_segments/1` URI-decodes into a `Plan.Source.Path`. Sample filenames
are URL-safe by existing convention (the IIIF provider relies on the same), so no
percent-encoding is needed.

This mirrors the IIIF split of `iiifFetchPath` (`/iiif-image/…`) vs.
`iiifBrowserPath` (`/iiif/…`): one prefix the backend forwards, one prefix the
demo router serves the SPA from.

### 3.1 The query-string wrinkle (the one genuinely new integration concern)

imgproxy and IIIF encode **everything in the path**, so the SPA only ever needs
`window.location.pathname`. TwicPics puts the chain in the **`?twic=` query
param**, so the URL ↔ state plumbing must also carry `window.location.search`.
Three shared call sites change (see §6):

1. `parseAppPath` gains a second parameter, `search`.
2. `initialAppState()` and `restoreStateFromLocation()` pass
   `window.location.search`.
3. `updateFiddleLocation`'s "did the URL actually change?" guard compares against
   `pathname + search`, not `pathname` alone (otherwise it always fires for
   TwicPics, since the query is never in `pathname`).

The query value is built **raw** (no `encodeURIComponent`): the value is only
`[a-z0-9/=:@x.-]`, all valid unencoded in a query string, and building it raw
keeps the URL readable and byte-identical to what the parser's wire tests exercise.
On read-back, `URLSearchParams` transparently decodes anything the browser chose
to percent-encode in the address bar, so the round-trip is safe. The fetch path is
always rebuilt from state (never read back from the address bar), so it is always
raw.

## 4. Frontend state model (`fiddle/assets/twicpics-path.ts`)

New module, sibling of `iiif-path.ts`, owning the TwicPics state shape and the
URL ↔ state functions.

```ts
export type TwicAnchor =
  | "top" | "bottom" | "left" | "right"
  | "top-left" | "top-right" | "bottom-left" | "bottom-right";

// A resize dimension. `unit: "auto"` emits "-" and ignores `value`; the other
// units carry a numeric `value`. Flat (not a discriminated union) so the Svelte
// controls can `bind:value` directly without per-branch type narrowing — a
// union would make `step.w.value` a type error inside a generic axis renderer.
// `auto` dims are normalized to `value: 0`, so the URL round-trip is exact.
export type TwicResizeUnit = "px" | "p" | "s" | "auto";
export type TwicDim = { unit: TwicResizeUnit; value: number };

// Discriminated union keyed by `type`, each with a stable `id` for sortable keying.
export type TransformStep =
  | { type: "resize"; id: string; w: TwicDim; h: TwicDim }
  | { type: "cover"; id: string; mode: "size" | "ratio"; w: number; h: number }
  | { type: "contain"; id: string; w: number; h: number }
  | { type: "inside"; id: string; w: number; h: number }
  | { type: "crop"; id: string; w: number; h: number; origin: { x: number; y: number } | null }
  | { type: "focus"; id: string; anchor: TwicAnchor };

export type TwicOutput = "auto" | "avif" | "webp" | "jpeg" | "png";

export type TwicPicsState = {
  source: SourceImage;
  chain: TransformStep[];
  output: TwicOutput;
  quality: number;
};
```

### Functions (symmetric with `iiif-path.ts`)

- `stepToken(step): string` — one chain segment, e.g. `resize=340`, `cover=16:9`,
  `crop=200x150@10x20`, `focus=top-left`.
- `twicParam(state): string` — the full `twic` value:
  `"v1/" + [...chainTokens, "output=" + output, "quality=" + quality].join("/")`.
  An empty chain yields `v1/output=auto/quality=80`.
- `twicFetchPath(state): string` → `/twic/<source>?twic=<twicParam>`.
- `twicBrowserPath(state): string` → `/twicpics/<source>?twic=<twicParam>`.
- `parseTwicTail(sourceTail, search): TwicPicsState | null` — inverse. `sourceTail`
  is the path after `/twicpics/` (e.g. `images/dog.jpg`); `search` is
  `window.location.search`. Returns `null` only when the source is unknown or the
  `twic` value is malformed/unsupported.
- `defaultTwicPicsState: TwicPicsState` — `{ source: "images/dog.jpg", chain: [],
  output: "auto", quality: 80 }`.
- `defaultStep(type, id): TransformStep` — a sensibly-defaulted card for the
  "+ Add transform" menu (e.g. resize `300 × auto`, cover `100×100` size, focus
  `top`).
- `nextStepId(): string` — monotonic session-local id generator (see §5, decision 4).
- Display helpers for the controls component (`stepSummary(step)`, anchor/output
  option lists). These produce the collapsed-card readouts (`focus · top`,
  `resize · 340px × 50%`) and are not part of the wire contract.

### Encoding rules

- `TwicDim` → `auto`→`-`, `px`→`N`, `p`→`Np`, `s`→`Ns`.
- `resize` token: when H is `auto`, emit the single token `encodeDim(w)`
  (`resize=340`); otherwise `encodeDim(w) + "x" + encodeDim(h)` (`resize=340x200`,
  `resize=-x200`). Both forms parse back identically through the parser's
  `Units.size`. A both-`auto` resize is never produced by the UI (it would be a
  degenerate no-op; the parser would actually *accept* `resize=-x-` as a no-op, so
  this is a UI non-emission, not a parser rejection).
- `cover` size → `WxH`; `cover` ratio → `W:H`.
- `contain` / `inside` → `WxH`.
- `crop` → `WxH`, plus `@XxY` when an origin is set. (Note: the issue's scope table
  writes the origin as `@X,Y`, but the parser splits coordinates on `x`
  (`Units.coordinates`), so the wire form is `@XxY` — used consistently here and in
  the tests.)
- `focus` → the anchor literal.

The fiddle parser is **not** a general TwicPics parser — it only needs to
round-trip URLs the fiddle itself generates. So `contain` / `inside` / `cover`
size / `crop` dimensions are parsed as pixels only (matching the UI surface),
even though the library parser accepts relative units on some of them.

## 5. Design decisions (resolved)

These are the choices the issue left to implementation; recorded here so the spec
can be reviewed as a whole.

1. **Chain lives in `?twic=`, not the path.** Forced by the parser contract. The
   SPA URL plumbing is extended to carry `search` (§3.1, §6). *Alternative
   considered:* fold the chain into the path segment like IIIF — rejected, it
   would diverge from the real parser contract the demo is meant to exercise.

2. **Always emit `output` and `quality`.** The footer always contributes
   `output=…/quality=…`, defaulting to `output=auto` / `quality=80`. *Rationale:*
   a deterministic, fully-specified URL is simplest to round-trip and matches the
   wire-test style. *Alternative:* omit when default — rejected as added branching
   for no demo benefit.

3. **Default chain is empty.** Consistent with imgproxy/IIIF, whose defaults are
   effectively no-ops; the preview shows the source until the user adds a
   transform.

4. **Step ids are a session-local monotonic counter** (`t0`, `t1`, …) from
   `nextStepId()`, used both by the "+ Add" menu and by `parseTwicTail`. Ids are
   **never serialized** into the URL — they exist only to key the sortable list
   across reorders. Round-trip tests therefore compare chains with ids stripped.
   *Alternative:* `crypto.randomUUID()` — avoided to keep ids short and tests
   deterministic.

5. **Pixel-only parse for the fixed-size transforms** (§4) — the fiddle parser
   matches the UI surface, not the full library grammar.

6. **Drag + remove wiring.** Reorder uses the sortable list's `ondragend` event
   (which fires for both pointer and keyboard drags) with
   `sortItems(chain, draggedItemIndex, targetItemIndex)`, applied only when the
   drag was not canceled (`!isCanceled`) **and** `targetItemIndex !== null` — an
   explicit null check, because `0` is a valid target index (a falsy check would
   drop a reorder to the first position). The library does not mutate `chain`; the
   reassignment `chain = sortItems(…)` is the consumer's responsibility. Remove
   uses `SortableList.ItemRemove`'s `onclick` → `removeStep(id)` (in v2.1.18
   `ItemRemove` only manages focus and forwards `onclick`; it does not splice the
   array, despite its doc comment). Each `SortableList.Item` is given **both**
   `id={step.id}` and `index={i}` (both are required props), and the `{#each}` is
   keyed on `step.id`. Keyboard reordering (Space/arrows/Home/End/Esc) is provided
   by the library out of the box.

## 6. Shared-code changes

### `fiddle/assets/fiddle-url-state.ts`

- `Provider` gains `"twicpics"`.
- `providers` gains `{ id: "twicpics", label: "TwicPics" }`.
- `AppState` gains `twicpics: TwicPicsState`.
- `defaultAppState()` includes `twicpics: { ...defaultTwicPicsState }`.
- `appPathForState(state)` adds a `twicpics` branch returning
  `twicBrowserPath(state.twicpics)`.
- `parseAppPath(pathname, search = "")`:
  - dispatch `first === "twicpics"` → `parseTwicTail(rest.join("/"), search)`,
    falling back to `defaultTwicPicsState` on `null` (mirrors the IIIF
    malformed-tail behavior: stay on the provider, default the slice).
  - the `imgproxy` / `iiif` / default branches gain a `twicpics:
    { ...defaultTwicPicsState }` field; they ignore `search`.

### `fiddle/assets/App.svelte`

> **Critical structural note.** Several of the sites below are written today as a
> **binary** `provider === "imgproxy" ? … : <iiif>` — the `else` branch *is* IIIF,
> unconditionally. Adding TwicPics is **not** "append an arm"; each must be
> **rewritten to an explicit three-way** (nested ternary or a `switch` on
> `provider`/`parsed.provider`) so that the fall-through no longer silently means
> IIIF. A literal "add a branch" reading would leave TwicPics reading
> `appState.iiif.*` — a real correctness trap. The affected sites are: the provider
> `$effect`, `restoreStateFromLocation`, and the four `$derived`
> (`previewParameters` / `outputLabel` / `requestSummary` / `currentSource`).

- Import `TwicPicsControls`, and `defaultTwicPicsState` / `twicFetchPath` from
  `twicpics-path`.
- `path` initial value and the provider `$effect` become three-way; the `twicpics`
  arm sets `path = twicFetchPath(appState.twicpics)` with `pathRequestId += 1` to
  invalidate in-flight imgproxy signing, exactly like the IIIF arm.
- `initialAppState()` / `restoreStateFromLocation()` pass `window.location.search`
  to `parseAppPath`. `restoreStateFromLocation` is rewritten to switch on
  `parsed.provider`: take `parsed.<that-slice>` and **preserve the other two**
  in-memory slices from `appState` (the current two-way hard-codes
  `provider: "imgproxy"` in its else, which would mis-handle a parsed TwicPics URL).
- `updateFiddleLocation`'s change-guard compares `window.location.pathname +
  window.location.search === nextPath`. `nextPath` comes from `appPathForState`,
  which for TwicPics returns a path-*with-query*; the imgproxy/IIIF branches have
  empty `search`, so they still compare equal. Without this fix the guard never
  matches for TwicPics and `replaceState` fires on every edit.
- The four `$derived` get explicit `twicpics` arms:
  - `previewParameters`: `path.replace(/^\/twic\//, "")` → `<source>?twic=v1/…`.
    This intentionally keeps the `?twic=` chain in the readout (that *is* the
    TwicPics request); it is not stripped to a bare option tail like the other
    providers.
  - `outputLabel`: `appState.twicpics.output`.
  - `requestSummary`: `appState.twicpics.source.replace(/^images\//, "")`.
  - `currentSource`: `appState.twicpics.source`.
- `updateSource` also sets `appState.twicpics = { ...appState.twicpics, source }`
  (no source-dimension-bound fields to reset — crop pixels are independent and the
  backend clips out-of-bounds).
- `resetSettings` gets a `twicpics` arm: `appState.twicpics =
  { ...defaultTwicPicsState, source: appState.twicpics.source }`.
- The controls block renders `<TwicPicsControls bind:twicpicsState … />` in the
  `twicpics` branch.

### `fiddle/assets/fiddle-url-state.test.ts`

`baseAppState()` constructs an `AppState` literal; it must gain a
`twicpics: { ...defaultTwicPicsState }` field once `AppState` requires it
(otherwise the file fails type-check). No behavioral test changes required for the
existing imgproxy/IIIF cases.

## 7. The chain-builder UI (`fiddle/assets/TwicPicsControls.svelte`)

- **Library:** `@rodrigodagostino/svelte-sortable-list` `2.1.18` (added to
  `package.json`; `esm-env` peer resolves transitively via pnpm). Chosen per the
  issue: Svelte-5 runes-native, built-in keyboard reordering, compound API
  (`SortableList.Root` / `Item` / `ItemHandle` / `ItemRemove`) matching the
  existing `bits-ui` compositional style. Its `styles.css` is imported in the
  component.
- **Props:** `{ twicpicsState = $bindable(), source }` — mirrors
  `IiifControls.svelte`.
- **Layout:**
  - An ordered list of **collapsible cards**, drag-to-reorder via
    `SortableList.Root`. Each `SortableList.Item` (keyed by `step.id`) holds a
    drag handle (`ItemHandle`), a collapse toggle showing `type + stepSummary`
    when collapsed and the editable params when expanded, and a remove button
    (`ItemRemove`).
  - **"+ Add transform ▾"** menu appends `defaultStep(type, nextStepId())`.
  - A fixed **Output** footer (output `<select>` + quality control) below the
    chain.
- **Editing controls** reuse the existing fiddle primitives where they fit
  (`RangeNumber`, `<select>`, the shared `.tool-section` / `.field` /
  `.accordion-heading` classes) so the panel matches imgproxy/IIIF styling.
- Per the existing fiddle reactivity model, edits mutate `twicpicsState` in place
  (runes `$bindable`), which flows through the App `$effect` into the live preview
  and URL.

## 8. Backend wiring

### `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex` (new)

Mirror `imgproxy.ex` exactly — a thin `Plug` that delegates to `ImagePipe.Plug`
with boot-built opts. No CORS (unlike IIIF), no resolver.

```elixir
defmodule ImagePipeFiddleWeb.TwicPics do
  @moduledoc "Forwards /twic requests to ImagePipe.Plug with opts built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(conn, :persistent_term.get({ImagePipeFiddle.Application, :twicpics_opts}))
  end
end
```

### `fiddle/lib/image_pipe_fiddle_web/router.ex`

Add `forward "/twic", ImagePipeFiddleWeb.TwicPics` alongside the imgproxy/IIIF
forwards (before the catch-all SPA scope).

### `fiddle/lib/image_pipe_fiddle/application.ex`

- `:persistent_term.put({__MODULE__, :twicpics_opts}, build_twicpics_opts())` in
  `start/2`.
- `build_twicpics_opts/0`:

```elixir
defp build_twicpics_opts do
  static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

  [
    parser: ImagePipe.Parser.TwicPics,
    sources: [
      path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
    ]
  ]
  |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
  |> ImagePipe.Plug.init()
end
```

Same static root as the other providers; reuses `maybe_put_cache/2`.

## 9. Testing

### `fiddle/assets/twicpics-path.test.ts` (TDD, authored before the module)

Follows `iiif-path.test.ts`. Covers:

- **Step token encoding** for every transform and unit (the `resize` px/`p`/`s`/
  `auto` forms, cover size vs ratio, crop with/without origin, focus anchors).
- **`twicParam`** order preservation and explicit output/quality emission.
- **`twicFetchPath` / `twicBrowserPath`** prefixes and the source-in-path shape.
- **Round-trips** (`browser path → state`) for a representative set, including the
  relative-unit showcase `resize=340/resize=50p` and a long mixed chain, asserting
  **chain order is preserved** (ids stripped before comparison).
- **Rejections:** unknown source, missing `v1/` prefix, unsupported transform
  (`zoom`), unsupported focus (`center`), malformed segment, out-of-range quality,
  unsupported output (`heif`); and the empty-`twic` case (valid source, empty
  chain).
- **`defaultStep`** produces a parser-acceptable token for every type.

### Not unit-tested

`TwicPicsControls.svelte` and the App/backend wiring — this repo has no Svelte
component test harness (all JS tests are pure `.test.ts`). These are covered by
`svelte-check` / `tsgo` / `vite build` and by manually verifying the issue's
acceptance criteria against a running fiddle. Library/wire behavior is already
covered by `test/image_pipe/twic_pics_wire_conformance_test.exs`; **no new Elixir
wire tests are needed**.

### Gate

`mise run precommit:fiddle` (Elixir gate + fiddle JS test/check/lint/format/build)
must pass before finishing.

### Process notes

- **TDD ordering, auditable in history.** Commit the (reviewed) spec first, then the
  red `twicpics-path.test.ts`, then the `twicpics-path.ts` module that turns it
  green. A draft test already exists uncommitted from an earlier false start; it is
  re-driven test-first under the implementation plan, not "implemented against."
- **Landing-time (AGENTS.md).** Before the first push, rename the branch to a
  descriptive name (e.g. `feat/fiddle-twicpics-provider`). The PR body carries a
  bare `Fixes #306` line so the issue auto-closes.

## 10. Conformance-doc impact

`docs/twicpics_support_matrix.md` describes the **parser**, which is unchanged.
This work adds no parser surface, output behavior, processing stage, or deliberate
divergence — it only exposes existing parser surface through the demo UI.
**No support-matrix change is required.** (Per AGENTS.md, the demo UI tracks
transform/parser changes; here the dependency runs the other way — the UI follows
the already-shipped parser.)

## 11. Files

**New**
- `fiddle/assets/twicpics-path.ts`
- `fiddle/assets/twicpics-path.test.ts`
- `fiddle/assets/TwicPicsControls.svelte`
- `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex`

**Modified**
- `fiddle/assets/fiddle-url-state.ts`
- `fiddle/assets/fiddle-url-state.test.ts`
- `fiddle/assets/App.svelte`
- `fiddle/assets/package.json` (dependency — already added)
- `fiddle/lib/image_pipe_fiddle_web/router.ex`
- `fiddle/lib/image_pipe_fiddle/application.ex`

## 12. Acceptance criteria (from the issue)

- A "TwicPics" entry appears in the provider selector and renders the chain builder.
- Transforms can be added, removed, and reordered by drag **and** by keyboard, with
  changes reflected live in the preview and URL.
- `resize` exposes `px` / `%` / `scale`; stacking two `%` resizes visibly compounds
  against the running dimensions.
- The generated request matches the parser's `?twic=v1/…` contract and renders a
  real processed image through `/twic`.
- Browser URL ↔ state round-trips with chain order preserved (reload / back-forward
  restores the exact chain).
- `mise run precommit:fiddle` passes.
