# TwicPics fiddle provider — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add TwicPics as a third provider in the demo fiddle, exposing the
existing `ImagePipe.Parser.TwicPics` v1 surface through a reorderable
transform-chain builder.

**Architecture:** A pure TS module (`twicpics-path.ts`) owns the state shape and
the URL ↔ state functions (mirroring `iiif-path.ts`). A new Svelte 5 component
(`TwicPicsControls.svelte`) renders a drag/keyboard-reorderable list of
collapsible transform cards using `@rodrigodagostino/svelte-sortable-list`. The
shared SPA plumbing (`fiddle-url-state.ts`, `App.svelte`) gains a third provider
branch — each existing **binary** `imgproxy ? … : iiif` site is rewritten to a
**three-way** switch. A thin backend plug (`twic_pics.ex`) forwards `/twic`
requests to `ImagePipe.Plug`, with the source from `conn.path_info` and the chain
from the `twic` query param.

**Tech Stack:** Svelte 5 (runes), TypeScript, Vitest, Vite, pnpm; Elixir/Plug
(Phoenix fiddle app); `@rodrigodagostino/svelte-sortable-list@2.1.18`.

**Reference:** Design spec at
`docs/superpowers/specs/2026-06-14-twicpics-fiddle-provider-design.md`.

**Conventions:**
- Run repo tooling through mise: `mise exec -- <cmd>`.
- Single JS test file: `mise exec -- pnpm -C fiddle/assets exec vitest run <file>`.
- All JS checks: `mise exec -- pnpm -C fiddle/assets run check` (tsgo + svelte-check).
- Elixir compile (fiddle): `cd fiddle && mise exec -- mix compile --warnings-as-errors`.
- The working tree already carries the `@rodrigodagostino/svelte-sortable-list`
  dependency in `fiddle/assets/package.json` + `fiddle/pnpm-lock.yaml` (installed),
  and an **uncommitted draft** `fiddle/assets/twicpics-path.test.ts` from an earlier
  false start. Task 3 overwrites that draft; do not rely on its contents.

---

## File Structure

**New**
- `fiddle/assets/twicpics-path.ts` — state types, encoding (`stepToken`,
  `twicParam`, `twicFetchPath`, `twicBrowserPath`), parsing (`parseTwicTail`),
  defaults, `nextStepId`, `defaultStep`, display helpers.
- `fiddle/assets/twicpics-path.test.ts` — Vitest coverage (TDD).
- `fiddle/assets/TwicPicsControls.svelte` — the chain-builder UI.
- `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex` — `/twic` forward plug.

**Modified**
- `fiddle/assets/package.json` + `fiddle/pnpm-lock.yaml` — dependency (Task 1).
- `fiddle/assets/fiddle-url-state.ts` — Provider/AppState/dispatch (Task 6).
- `fiddle/assets/fiddle-url-state.test.ts` — `baseAppState` + dispatch tests (Task 6).
- `fiddle/assets/App.svelte` — three-way provider wiring (Task 6).
- `fiddle/lib/image_pipe_fiddle_web/router.ex` — `forward "/twic"` (Task 2).
- `fiddle/lib/image_pipe_fiddle/application.ex` — `:twicpics_opts` (Task 2).

**Task order & green-check invariant:** Tasks are ordered so `pnpm -C
fiddle/assets run check` stays green at every commit. The `AppState` shape change
(Task 6) ripples into `App.svelte`'s object literals, so url-state + its test +
`App.svelte` land together in Task 6. `TwicPicsControls.svelte` is built first
(Task 5) so Task 6's controls branch resolves its import.

---

## Task 1: Commit the sortable-list dependency

**Files:**
- Modify: `fiddle/assets/package.json` (already edited in the working tree)
- Modify: `fiddle/pnpm-lock.yaml` (already updated in the working tree)

- [ ] **Step 1: Confirm the dependency is present and installed**

Run:
```bash
grep rodrigodagostino fiddle/assets/package.json
ls fiddle/assets/node_modules/@rodrigodagostino/svelte-sortable-list/dist/styles.css
```
Expected: the `package.json` line `"@rodrigodagostino/svelte-sortable-list": "2.1.18",`
and the `styles.css` path both present. If missing, run
`cd fiddle && mise exec -- pnpm install`.

- [ ] **Step 2: Commit only the dependency files**

```bash
git add fiddle/assets/package.json fiddle/pnpm-lock.yaml
git commit -m "build(fiddle): add @rodrigodagostino/svelte-sortable-list (#306)

Svelte-5 runes-native sortable list with built-in keyboard reordering, for
the TwicPics chain builder. esm-env peer resolves transitively via pnpm.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Do NOT `git add` the untracked draft `twicpics-path.test.ts` here.

---

## Task 2: Backend wiring (`/twic` forward)

Mirror `imgproxy.ex` exactly — a thin Plug delegating to `ImagePipe.Plug` with
boot-built opts. No CORS, no resolver. No new Elixir tests (the parser's wire
behavior is already covered by `test/image_pipe/twic_pics_wire_conformance_test.exs`).

**Files:**
- Create: `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex`
- Modify: `fiddle/lib/image_pipe_fiddle_web/router.ex:18`
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex:11` and `:67`

- [ ] **Step 1: Create the forward plug**

`fiddle/lib/image_pipe_fiddle_web/twic_pics.ex`:
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

- [ ] **Step 2: Add the route**

In `fiddle/lib/image_pipe_fiddle_web/router.ex`, add the forward directly after
the IIIF forward (line 18 `forward "/iiif-image", ImagePipeFiddleWeb.IIIF`):
```elixir
  forward "/twic", ImagePipeFiddleWeb.TwicPics
```
Result (the forward block):
```elixir
  forward "/img", ImagePipeFiddleWeb.Imgproxy
  forward "/iiif-image", ImagePipeFiddleWeb.IIIF
  forward "/twic", ImagePipeFiddleWeb.TwicPics
```
(`forward` matches the segment `twic` only; `/twicpics/...` falls through to the
SPA catch-all `get "/*path"`. No collision.)

- [ ] **Step 3: Register the boot-built opts**

In `fiddle/lib/image_pipe_fiddle/application.ex`, add the persistent-term put in
`start/2` after the `:iiif_opts` line (line 11):
```elixir
    :persistent_term.put({__MODULE__, :twicpics_opts}, build_twicpics_opts())
```

Then add `build_twicpics_opts/0` next to `build_iiif_opts/0` (after line 83):
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

- [ ] **Step 4: Compile (warnings as errors)**

Run: `cd fiddle && mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean, no warnings.

- [ ] **Step 5: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle_web/twic_pics.ex \
        fiddle/lib/image_pipe_fiddle_web/router.ex \
        fiddle/lib/image_pipe_fiddle/application.ex
git commit -m "feat(fiddle): wire /twic to ImagePipe.Plug with TwicPics parser (#306)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `twicpics-path.ts` — types + encoding (TDD)

Build the state model and the state → URL direction first. This task **overwrites**
the uncommitted draft test with an encoding-only test, then implements just enough
of the module to pass. (Parsing arrives in Task 4.)

**Files:**
- Create: `fiddle/assets/twicpics-path.ts`
- Create (overwrite draft): `fiddle/assets/twicpics-path.test.ts`

- [ ] **Step 1: Write the failing encoding test**

Overwrite `fiddle/assets/twicpics-path.test.ts` with:
```ts
import { describe, expect, it } from "vitest";
import {
  defaultStep,
  defaultTwicPicsState,
  stepToken,
  twicBrowserPath,
  twicFetchPath,
  twicParam,
  type TransformStep,
  type TwicPicsState,
} from "./twicpics-path";

describe("twicpics step token encoding", () => {
  it("encodes resize dimensions and units", () => {
    expect(
      stepToken({ type: "resize", id: "x", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } }),
    ).toBe("resize=340");
    expect(
      stepToken({ type: "resize", id: "x", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } }),
    ).toBe("resize=50p");
    expect(
      stepToken({ type: "resize", id: "x", w: { unit: "s", value: 0.5 }, h: { unit: "auto", value: 0 } }),
    ).toBe("resize=0.5s");
    expect(
      stepToken({ type: "resize", id: "x", w: { unit: "px", value: 340 }, h: { unit: "px", value: 200 } }),
    ).toBe("resize=340x200");
    expect(
      stepToken({ type: "resize", id: "x", w: { unit: "auto", value: 0 }, h: { unit: "px", value: 200 } }),
    ).toBe("resize=-x200");
  });

  it("encodes cover size and ratio", () => {
    expect(stepToken({ type: "cover", id: "x", mode: "size", w: 100, h: 100 })).toBe("cover=100x100");
    expect(stepToken({ type: "cover", id: "x", mode: "ratio", w: 16, h: 9 })).toBe("cover=16:9");
  });

  it("encodes contain and inside", () => {
    expect(stepToken({ type: "contain", id: "x", w: 200, h: 200 })).toBe("contain=200x200");
    expect(stepToken({ type: "inside", id: "x", w: 200, h: 200 })).toBe("inside=200x200");
  });

  it("encodes crop with and without an origin", () => {
    expect(stepToken({ type: "crop", id: "x", w: 200, h: 150, origin: null })).toBe("crop=200x150");
    expect(stepToken({ type: "crop", id: "x", w: 200, h: 150, origin: { x: 10, y: 20 } })).toBe(
      "crop=200x150@10x20",
    );
  });

  it("encodes focus anchors", () => {
    expect(stepToken({ type: "focus", id: "x", anchor: "top" })).toBe("focus=top");
    expect(stepToken({ type: "focus", id: "x", anchor: "bottom-right" })).toBe("focus=bottom-right");
  });
});

describe("twicpics manipulation param", () => {
  it("builds v1 with output and quality for an empty chain", () => {
    expect(twicParam(defaultTwicPicsState)).toBe("v1/output=auto/quality=80");
  });

  it("preserves chain order in the param", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "2", anchor: "top-left" },
        { type: "resize", id: "3", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
      ],
    };
    expect(twicParam(state)).toBe("v1/resize=340/focus=top-left/resize=50p/output=auto/quality=80");
  });

  it("emits explicit output and quality", () => {
    expect(twicParam({ ...defaultTwicPicsState, output: "webp", quality: 65 })).toBe(
      "v1/output=webp/quality=65",
    );
  });
});

describe("twicpics fetch and browser paths", () => {
  it("uses /twic for fetch and /twicpics for the browser, source in the path", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [{ type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } }],
    };
    expect(twicFetchPath(state)).toBe("/twic/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80");
    expect(twicBrowserPath(state)).toBe(
      "/twicpics/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80",
    );
  });
});

describe("defaultStep factory", () => {
  it("produces a parser-acceptable token for each transform type", () => {
    const types: TransformStep["type"][] = ["resize", "cover", "contain", "inside", "crop", "focus"];
    for (const type of types) {
      const created = defaultStep(type, `id-${type}`);
      expect(created.type).toBe(type);
      expect(created.id).toBe(`id-${type}`);
      expect(stepToken(created)).toContain(`${type}=`);
    }
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run twicpics-path.test.ts`
Expected: FAIL — `Failed to resolve import "./twicpics-path"` (module does not exist).

- [ ] **Step 3: Implement the module (types + encoding + defaults)**

Create `fiddle/assets/twicpics-path.ts`:
```ts
import { sampleImages, type SourceImage } from "./processing-path";

export type TwicAnchor =
  | "top"
  | "bottom"
  | "left"
  | "right"
  | "top-left"
  | "top-right"
  | "bottom-left"
  | "bottom-right";

// 3x3 reading order (no center — center is the default focus, not an anchor literal).
export const twicAnchors: readonly TwicAnchor[] = [
  "top-left",
  "top",
  "top-right",
  "left",
  "right",
  "bottom-left",
  "bottom",
  "bottom-right",
];

// A resize dimension. unit "auto" emits "-" and ignores value (normalized to 0).
export type TwicResizeUnit = "px" | "p" | "s" | "auto";
export type TwicDim = { unit: TwicResizeUnit; value: number };

export type TransformStep =
  | { type: "resize"; id: string; w: TwicDim; h: TwicDim }
  | { type: "cover"; id: string; mode: "size" | "ratio"; w: number; h: number }
  | { type: "contain"; id: string; w: number; h: number }
  | { type: "inside"; id: string; w: number; h: number }
  | { type: "crop"; id: string; w: number; h: number; origin: { x: number; y: number } | null }
  | { type: "focus"; id: string; anchor: TwicAnchor };

export type TransformType = TransformStep["type"];

export type TwicOutput = "auto" | "avif" | "webp" | "jpeg" | "png";
export const twicOutputs: readonly TwicOutput[] = ["auto", "avif", "webp", "jpeg", "png"];

export type TwicPicsState = {
  source: SourceImage;
  chain: TransformStep[];
  output: TwicOutput;
  quality: number;
};

export const defaultTwicPicsState: TwicPicsState = {
  source: "images/dog.jpg",
  chain: [],
  output: "auto",
  quality: 80,
};

const sourceSet = new Set<string>(sampleImages.map((image) => image.path));

export function sourceForTwicPath(path: string): SourceImage | null {
  return sourceSet.has(path) ? (path as SourceImage) : null;
}

// Session-local monotonic id generator. Ids are never serialized into the URL —
// they only key the sortable list across reorders. Both the "+ Add" menu and
// parseTwicTail draw from this single counter, so ids never collide.
let idCounter = 0;
export function nextStepId(): string {
  idCounter += 1;
  return `t${idCounter}`;
}

export function defaultStep(type: TransformType, id: string): TransformStep {
  switch (type) {
    case "resize":
      return { type: "resize", id, w: { unit: "px", value: 300 }, h: { unit: "auto", value: 0 } };
    case "cover":
      return { type: "cover", id, mode: "size", w: 200, h: 200 };
    case "contain":
      return { type: "contain", id, w: 300, h: 300 };
    case "inside":
      return { type: "inside", id, w: 300, h: 300 };
    case "crop":
      return { type: "crop", id, w: 200, h: 200, origin: null };
    case "focus":
      return { type: "focus", id, anchor: "top" };
  }
}

// --- encoding ---

function encodeDim(dim: TwicDim): string {
  switch (dim.unit) {
    case "auto":
      return "-";
    case "px":
      return `${dim.value}`;
    case "p":
      return `${dim.value}p`;
    case "s":
      return `${dim.value}s`;
  }
}

export function stepToken(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return step.h.unit === "auto"
        ? `resize=${encodeDim(step.w)}`
        : `resize=${encodeDim(step.w)}x${encodeDim(step.h)}`;
    case "cover":
      return step.mode === "ratio" ? `cover=${step.w}:${step.h}` : `cover=${step.w}x${step.h}`;
    case "contain":
      return `contain=${step.w}x${step.h}`;
    case "inside":
      return `inside=${step.w}x${step.h}`;
    case "crop":
      return step.origin === null
        ? `crop=${step.w}x${step.h}`
        : `crop=${step.w}x${step.h}@${step.origin.x}x${step.origin.y}`;
    case "focus":
      return `focus=${step.anchor}`;
  }
}

export function twicParam(state: TwicPicsState): string {
  const segments = [
    ...state.chain.map(stepToken),
    `output=${state.output}`,
    `quality=${state.quality}`,
  ];
  return `v1/${segments.join("/")}`;
}

export function twicFetchPath(state: TwicPicsState): string {
  return `/twic/${state.source}?twic=${twicParam(state)}`;
}

export function twicBrowserPath(state: TwicPicsState): string {
  return `/twicpics/${state.source}?twic=${twicParam(state)}`;
}

// --- summaries (display only; not part of the wire contract) ---

function dimLabel(dim: TwicDim): string {
  switch (dim.unit) {
    case "auto":
      return "auto";
    case "px":
      return `${dim.value}px`;
    case "p":
      return `${dim.value}%`;
    case "s":
      return `${dim.value}s`;
  }
}

export function stepSummary(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return `${dimLabel(step.w)} × ${dimLabel(step.h)}`;
    case "cover":
      return step.mode === "ratio" ? `${step.w}:${step.h}` : `${step.w}×${step.h}`;
    case "contain":
    case "inside":
      return `${step.w}×${step.h}`;
    case "crop":
      return step.origin === null
        ? `${step.w}×${step.h}`
        : `${step.w}×${step.h} @ ${step.origin.x},${step.origin.y}`;
    case "focus":
      return step.anchor;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run twicpics-path.test.ts`
Expected: PASS (all encoding/param/path/defaultStep tests green).

- [ ] **Step 5: Type-check**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: PASS, no errors (the new module + test type-check; nothing else imports
them yet).

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/twicpics-path.ts fiddle/assets/twicpics-path.test.ts
git commit -m "feat(fiddle): TwicPics state model + URL encoding (#306)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `twicpics-path.ts` — parsing (TDD)

Add the URL → state direction (`parseTwicTail`) with round-trip and rejection
coverage. Round-trip tests strip ids (ids are session-local, never serialized).

**Files:**
- Modify: `fiddle/assets/twicpics-path.ts` (append parsing)
- Modify: `fiddle/assets/twicpics-path.test.ts` (append parsing tests)

- [ ] **Step 1: Append the failing parsing tests**

Append to `fiddle/assets/twicpics-path.test.ts`. First extend the import at the top
of the file to also pull in `parseTwicTail`:
```ts
import {
  defaultStep,
  defaultTwicPicsState,
  parseTwicTail,
  stepToken,
  twicBrowserPath,
  twicFetchPath,
  twicParam,
  type TransformStep,
  type TwicPicsState,
} from "./twicpics-path";
```

Then append these blocks at the end of the file:
```ts
// Chain ids are session-local (never serialized), so round-trip comparisons drop
// them: the URL preserves order + params, not the synthetic id.
function stripIds(state: TwicPicsState) {
  return { ...state, chain: state.chain.map(({ id: _id, ...rest }) => rest) };
}

// Build the location.search string the SPA would read back for a given state.
function searchFor(state: TwicPicsState): string {
  return `?twic=${twicParam(state)}`;
}

describe("twicpics round-trips (browser path -> state)", () => {
  const cases: TwicPicsState[] = [
    defaultTwicPicsState,
    {
      ...defaultTwicPicsState,
      chain: [{ type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } }],
    },
    // the relative-unit showcase: order matters; percents resolve against the running image
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "resize", id: "2", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "px", value: 200 } },
        { type: "resize", id: "2", w: { unit: "auto", value: 0 }, h: { unit: "px", value: 100 } },
        { type: "resize", id: "3", w: { unit: "s", value: 0.5 }, h: { unit: "auto", value: 0 } },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "focus", id: "1", anchor: "top-left" },
        { type: "cover", id: "2", mode: "size", w: 100, h: 100 },
      ],
    },
    { ...defaultTwicPicsState, chain: [{ type: "cover", id: "1", mode: "ratio", w: 16, h: 9 }] },
    { ...defaultTwicPicsState, chain: [{ type: "contain", id: "1", w: 200, h: 200 }] },
    { ...defaultTwicPicsState, chain: [{ type: "inside", id: "1", w: 200, h: 200 }] },
    { ...defaultTwicPicsState, chain: [{ type: "crop", id: "1", w: 200, h: 150, origin: null }] },
    {
      ...defaultTwicPicsState,
      chain: [{ type: "crop", id: "1", w: 200, h: 150, origin: { x: 10, y: 20 } }],
    },
    { ...defaultTwicPicsState, output: "avif", quality: 50 },
    {
      ...defaultTwicPicsState,
      source: "images/beach.jpg",
      chain: [
        { type: "resize", id: "1", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "2", anchor: "top-left" },
      ],
      output: "png",
      quality: 90,
    },
  ];

  for (const state of cases) {
    it(`round-trips ${twicParam(state)}`, () => {
      const parsed = parseTwicTail(state.source, searchFor(state));
      expect(parsed).not.toBeNull();
      expect(stripIds(parsed!)).toEqual(stripIds(state));
    });
  }

  it("preserves a long chain order exactly", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "resize", id: "2", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "3", anchor: "top-left" },
        { type: "cover", id: "4", mode: "size", w: 100, h: 100 },
        { type: "crop", id: "5", w: 80, h: 80, origin: null },
      ],
    };
    const parsed = parseTwicTail(state.source, searchFor(state));
    expect(parsed!.chain.map((s) => s.type)).toEqual(["resize", "resize", "focus", "cover", "crop"]);
  });

  it("assigns a non-empty, unique id to every parsed step", () => {
    const parsed = parseTwicTail("images/dog.jpg", "?twic=v1/resize=340/resize=50p/output=auto/quality=80");
    const ids = parsed!.chain.map((s) => s.id);
    expect(ids).toHaveLength(2);
    expect(new Set(ids).size).toBe(2);
    expect(ids.every((id) => id.length > 0)).toBe(true);
  });
});

describe("twicpics parse rejection", () => {
  it("rejects an unknown source", () => {
    expect(parseTwicTail("images/nope.jpg", "?twic=v1/output=auto/quality=80")).toBeNull();
  });

  it("rejects a missing v1 prefix", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v2/resize=340")).toBeNull();
  });

  it("rejects an unsupported transform", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/zoom=2")).toBeNull();
  });

  it("rejects an unsupported focus anchor (no center)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=center")).toBeNull();
  });

  it("rejects a malformed segment without '='", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/resize")).toBeNull();
  });

  it("rejects an out-of-range quality", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/quality=0")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/quality=101")).toBeNull();
  });

  it("rejects an unsupported output format", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/output=heif")).toBeNull();
  });

  it("returns an empty chain for a valid source with no twic param", () => {
    const parsed = parseTwicTail("images/dog.jpg", "");
    expect(parsed).not.toBeNull();
    expect(parsed!.chain).toEqual([]);
    expect(parsed!.output).toBe("auto");
    expect(parsed!.quality).toBe(80);
  });
});
```

- [ ] **Step 2: Run the parsing tests to verify they fail**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run twicpics-path.test.ts`
Expected: FAIL — `parseTwicTail` is not exported / not a function.

- [ ] **Step 3: Implement parsing**

Append to `fiddle/assets/twicpics-path.ts`:
```ts
// --- parsing (mirror lib/image_pipe/parser/twic_pics; pixel-only subset matching
// the UI surface — see the design spec) ---

const anchorSet = new Set<string>(twicAnchors);

function parsePositiveInt(value: string): number | null {
  return /^\d+$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parsePositiveNumber(value: string): number | null {
  return /^\d+(\.\d+)?$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parseResizeDim(token: string): TwicDim | null {
  if (token === "-") return { unit: "auto", value: 0 };
  if (token.endsWith("p")) {
    const n = parsePositiveNumber(token.slice(0, -1));
    return n === null ? null : { unit: "p", value: n };
  }
  if (token.endsWith("s")) {
    const n = parsePositiveNumber(token.slice(0, -1));
    return n === null ? null : { unit: "s", value: n };
  }
  const n = parsePositiveInt(token);
  return n === null ? null : { unit: "px", value: n };
}

function parsePxPair(args: string): { w: number; h: number } | null {
  const parts = args.split("x");
  if (parts.length !== 2) return null;
  const w = parsePositiveInt(parts[0]!);
  const h = parsePositiveInt(parts[1]!);
  return w === null || h === null ? null : { w, h };
}

function parseResize(args: string, id: string): TransformStep | null {
  if (args.includes(":")) return null; // ratio resize is rejected by the parser
  const parts = args.split("x");
  if (parts.length === 1) {
    const w = parseResizeDim(parts[0]!);
    if (w === null || w.unit === "auto") return null; // bare "-" / both-auto not emitted
    return { type: "resize", id, w, h: { unit: "auto", value: 0 } };
  }
  if (parts.length === 2) {
    const w = parseResizeDim(parts[0]!);
    const h = parseResizeDim(parts[1]!);
    if (w === null || h === null) return null;
    if (w.unit === "auto" && h.unit === "auto") return null;
    return { type: "resize", id, w, h };
  }
  return null;
}

function parseCover(args: string, id: string): TransformStep | null {
  if (args.includes(":")) {
    const parts = args.split(":");
    if (parts.length !== 2) return null;
    const w = parsePositiveNumber(parts[0]!);
    const h = parsePositiveNumber(parts[1]!);
    return w === null || h === null ? null : { type: "cover", id, mode: "ratio", w, h };
  }
  const pair = parsePxPair(args);
  return pair === null ? null : { type: "cover", id, mode: "size", w: pair.w, h: pair.h };
}

function parseCrop(args: string, id: string): TransformStep | null {
  const parts = args.split("@");
  if (parts.length > 2) return null;
  const size = parsePxPair(parts[0]!);
  if (size === null) return null;
  if (parts.length === 1) {
    return { type: "crop", id, w: size.w, h: size.h, origin: null };
  }
  const origin = parsePxPair(parts[1]!); // XxY
  return origin === null
    ? null
    : { type: "crop", id, w: size.w, h: size.h, origin: { x: origin.w, y: origin.h } };
}

function parseStep(name: string, args: string): TransformStep | null {
  const id = nextStepId();
  switch (name) {
    case "resize":
      return parseResize(args, id);
    case "cover":
      return parseCover(args, id);
    case "contain": {
      const pair = parsePxPair(args);
      return pair === null ? null : { type: "contain", id, w: pair.w, h: pair.h };
    }
    case "inside": {
      const pair = parsePxPair(args);
      return pair === null ? null : { type: "inside", id, w: pair.w, h: pair.h };
    }
    case "crop":
      return parseCrop(args, id);
    case "focus":
      return anchorSet.has(args) ? { type: "focus", id, anchor: args as TwicAnchor } : null;
    default:
      return null;
  }
}

export function parseTwicTail(sourceTail: string, search: string): TwicPicsState | null {
  const source = sourceForTwicPath(sourceTail);
  if (source === null) return null;

  const twic = new URLSearchParams(search).get("twic");
  if (twic === null || twic === "") {
    return { source, chain: [], output: "auto", quality: 80 };
  }

  if (twic !== "v1" && !twic.startsWith("v1/")) return null;
  const body = twic === "v1" ? "" : twic.slice("v1/".length);
  const segments = body.split("/").filter((segment) => segment !== "");

  const chain: TransformStep[] = [];
  let output: TwicOutput = "auto";
  let quality = 80;

  for (const segment of segments) {
    const eq = segment.indexOf("=");
    if (eq <= 0) return null; // every segment must be name=args

    const name = segment.slice(0, eq);
    const args = segment.slice(eq + 1);

    if (name === "output") {
      if (!twicOutputs.includes(args as TwicOutput)) return null;
      output = args as TwicOutput;
      continue;
    }
    if (name === "quality") {
      const q = parsePositiveInt(args);
      if (q === null || q > 100) return null;
      quality = q;
      continue;
    }

    const step = parseStep(name, args);
    if (step === null) return null;
    chain.push(step);
  }

  return { source, chain, output, quality };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run twicpics-path.test.ts`
Expected: PASS (all encoding + parsing + round-trip + rejection tests green).

- [ ] **Step 5: Type-check**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/twicpics-path.ts fiddle/assets/twicpics-path.test.ts
git commit -m "feat(fiddle): TwicPics URL parsing + round-trip tests (#306)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `TwicPicsControls.svelte` — the chain builder

The reorderable collapsible-card UI. No unit test (this repo has no Svelte
component harness); verified by `svelte-check`/`tsgo` + the build, and by the
acceptance pass in Task 7. Built before Task 6 so the App import resolves.

**Files:**
- Create: `fiddle/assets/TwicPicsControls.svelte`

- [ ] **Step 1: Create the component**

`fiddle/assets/TwicPicsControls.svelte`:
```svelte
<script lang="ts">
  import { SortableList, sortItems } from "@rodrigodagostino/svelte-sortable-list";
  import "@rodrigodagostino/svelte-sortable-list/styles.css";
  import RangeNumber from "./RangeNumber.svelte";
  import { type SourceImage } from "./processing-path";
  import {
    defaultStep,
    nextStepId,
    stepSummary,
    twicAnchors,
    twicOutputs,
    type TransformStep,
    type TransformType,
    type TwicAnchor,
    type TwicPicsState,
    type TwicResizeUnit,
  } from "./twicpics-path";

  type Props = {
    twicpicsState: TwicPicsState;
    source: SourceImage;
  };

  let { twicpicsState = $bindable(), source: _source }: Props = $props();

  // Which cards are expanded. New cards open by default; parsed/reloaded cards are
  // collapsed (falsy) and show their summary.
  let openCards = $state<Record<string, boolean>>({});

  const transformTypes: { type: TransformType; label: string }[] = [
    { type: "resize", label: "resize" },
    { type: "cover", label: "cover" },
    { type: "contain", label: "contain" },
    { type: "inside", label: "inside" },
    { type: "crop", label: "crop" },
    { type: "focus", label: "focus" },
  ];

  const resizeUnits: { value: TwicResizeUnit; label: string }[] = [
    { value: "px", label: "px" },
    { value: "p", label: "%" },
    { value: "s", label: "scale" },
    { value: "auto", label: "auto" },
  ];

  // 3x3 anchor grid (center cell is null — TwicPics has no center anchor).
  const anchorGrid: (TwicAnchor | null)[] = [
    "top-left",
    "top",
    "top-right",
    "left",
    null,
    "right",
    "bottom-left",
    "bottom",
    "bottom-right",
  ];
  const anchorGlyph: Record<TwicAnchor, string> = {
    "top-left": "↖",
    top: "↑",
    "top-right": "↗",
    left: "←",
    right: "→",
    "bottom-left": "↙",
    bottom: "↓",
    "bottom-right": "↘",
  };

  function addStep(type: TransformType): void {
    const step = defaultStep(type, nextStepId());
    twicpicsState.chain = [...twicpicsState.chain, step];
    openCards[step.id] = true;
  }

  function onAddSelect(event: Event & { currentTarget: HTMLSelectElement }): void {
    const value = event.currentTarget.value;
    if (value !== "") {
      addStep(value as TransformType);
      event.currentTarget.value = "";
    }
  }

  function removeStep(id: string): void {
    twicpicsState.chain = twicpicsState.chain.filter((step) => step.id !== id);
  }

  function toggleCard(id: string): void {
    openCards[id] = !openCards[id];
  }

  function handleDragEnd(event: {
    draggedItemIndex: number;
    targetItemIndex: number | null;
    isCanceled: boolean;
  }): void {
    if (event.isCanceled || event.targetItemIndex === null) return;
    twicpicsState.chain = sortItems(
      twicpicsState.chain,
      event.draggedItemIndex,
      event.targetItemIndex,
    );
  }

  function setResizeUnit(
    step: Extract<TransformStep, { type: "resize" }>,
    axis: "w" | "h",
    unit: TwicResizeUnit,
  ): void {
    if (unit === "auto") {
      step[axis] = { unit: "auto", value: 0 };
      return;
    }
    const prev = step[axis].value;
    const value = prev > 0 ? prev : unit === "s" ? 1 : unit === "p" ? 100 : 300;
    step[axis] = { unit, value };
  }

  function toggleCropOrigin(step: Extract<TransformStep, { type: "crop" }>, on: boolean): void {
    step.origin = on ? { x: 1, y: 1 } : null;
  }
</script>

{#snippet resizeAxis(step: Extract<TransformStep, { type: "resize" }>, axis: "w" | "h", label: string)}
  <div class="field">
    <span>{label}</span>
    <div class="resize-axis">
      <select
        value={step[axis].unit}
        onchange={(e) => setResizeUnit(step, axis, e.currentTarget.value as TwicResizeUnit)}
      >
        {#each resizeUnits as unit}
          <option value={unit.value}>{unit.label}</option>
        {/each}
      </select>
      {#if step[axis].unit !== "auto"}
        <input
          class="text-input resize-value"
          type="number"
          min="1"
          step={step[axis].unit === "s" ? "any" : "1"}
          bind:value={step[axis].value}
        />
      {/if}
    </div>
  </div>
{/snippet}

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Transform chain</h2>
      <p>{twicpicsState.chain.length} step{twicpicsState.chain.length === 1 ? "" : "s"}</p>
    </div>
  </div>

  {#if twicpicsState.chain.length === 0}
    <p class="chain-empty">No transforms yet — add one below.</p>
  {/if}

  <SortableList.Root gap={8} ondragend={handleDragEnd}>
    {#each twicpicsState.chain as step, index (step.id)}
      <SortableList.Item id={step.id} {index}>
        <div class="chain-card">
          <div class="chain-card-head">
            <SortableList.ItemHandle>
              <span class="drag-handle" aria-hidden="true">⠿</span>
            </SortableList.ItemHandle>
            <button
              type="button"
              class="card-toggle"
              aria-expanded={openCards[step.id] ? "true" : "false"}
              onclick={() => toggleCard(step.id)}
            >
              <span class="card-name">{step.type}</span>
              <span class="card-summary">{stepSummary(step)}</span>
            </button>
            <SortableList.ItemRemove
              class="card-remove"
              aria-label={`Remove ${step.type}`}
              onclick={() => removeStep(step.id)}
            >
              ×
            </SortableList.ItemRemove>
          </div>

          {#if openCards[step.id]}
            <div class="chain-card-body">
              {#if step.type === "resize"}
                {@render resizeAxis(step, "w", "Width")}
                {@render resizeAxis(step, "h", "Height")}
              {:else if step.type === "cover"}
                <label class="field">
                  <span>Mode</span>
                  <select bind:value={step.mode}>
                    <option value="size">size (WxH px)</option>
                    <option value="ratio">ratio (W:H)</option>
                  </select>
                </label>
                <RangeNumber label={step.mode === "ratio" ? "W" : "Width"} bind:value={step.w} min={1} max={8000} step={1} />
                <RangeNumber label={step.mode === "ratio" ? "H" : "Height"} bind:value={step.h} min={1} max={8000} step={1} />
              {:else if step.type === "contain" || step.type === "inside"}
                <RangeNumber label="Width" bind:value={step.w} min={1} max={8000} step={1} suffix="px" />
                <RangeNumber label="Height" bind:value={step.h} min={1} max={8000} step={1} suffix="px" />
              {:else if step.type === "crop"}
                <RangeNumber label="Width" bind:value={step.w} min={1} max={8000} step={1} suffix="px" />
                <RangeNumber label="Height" bind:value={step.h} min={1} max={8000} step={1} suffix="px" />
                <label class="switch-field">
                  <input
                    type="checkbox"
                    checked={step.origin !== null}
                    onchange={(e) => toggleCropOrigin(step, e.currentTarget.checked)}
                  />
                  <span>Origin (@ XxY)</span>
                </label>
                {#if step.origin !== null}
                  <RangeNumber label="X" bind:value={step.origin.x} min={1} max={8000} step={1} suffix="px" />
                  <RangeNumber label="Y" bind:value={step.origin.y} min={1} max={8000} step={1} suffix="px" />
                {/if}
              {:else if step.type === "focus"}
                <div class="anchor-grid" role="group" aria-label="Focus anchor">
                  {#each anchorGrid as cell}
                    {#if cell === null}
                      <span class="anchor-cell anchor-cell-empty" aria-hidden="true"></span>
                    {:else}
                      <button
                        type="button"
                        class="anchor-cell"
                        aria-pressed={step.anchor === cell ? "true" : "false"}
                        aria-label={cell}
                        onclick={() => (step.anchor = cell)}
                      >
                        {anchorGlyph[cell]}
                      </button>
                    {/if}
                  {/each}
                </div>
              {/if}
            </div>
          {/if}
        </div>
      </SortableList.Item>
    {/each}
  </SortableList.Root>

  <label class="field add-transform">
    <span>Add transform</span>
    <select value="" onchange={onAddSelect}>
      <option value="" disabled>+ Add transform…</option>
      {#each transformTypes as item}
        <option value={item.type}>{item.label}</option>
      {/each}
    </select>
  </label>
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Output</h2>
      <p>{twicpicsState.output} · q{twicpicsState.quality}</p>
    </div>
  </div>

  <label class="field">
    <span>Format</span>
    <select bind:value={twicpicsState.output}>
      {#each twicOutputs as format}
        <option value={format}>{format}</option>
      {/each}
    </select>
  </label>

  <RangeNumber label="Quality" bind:value={twicpicsState.quality} min={1} max={100} step={1} />
</section>

<style>
  .chain-empty {
    margin: 0 0 8px;
    color: var(--text-muted);
    font-size: 13px;
  }

  .chain-card {
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    background: var(--surface-control);
    overflow: hidden;
  }

  .chain-card-head {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
  }

  .drag-handle {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 28px;
    color: var(--text-muted);
    cursor: grab;
    font-size: 16px;
    line-height: 1;
  }

  .card-toggle {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: baseline;
    gap: 8px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    text-align: start;
    padding: 4px 2px;
  }

  .card-name {
    font-weight: 700;
    font-size: 13px;
  }

  .card-summary {
    min-width: 0;
    overflow: hidden;
    color: var(--text-muted);
    font-family: var(--font-mono);
    font-size: 12px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chain-card :global(.card-remove) {
    width: 26px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    font-size: 18px;
    line-height: 1;
  }

  .chain-card :global(.card-remove:hover) {
    background: var(--surface-button-quiet);
    color: var(--text-heading);
  }

  .chain-card-body {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 8px;
    border-block-start: 1px solid var(--border-subtle);
  }

  .resize-axis {
    display: flex;
    gap: 8px;
  }

  .resize-value {
    width: 96px;
  }

  .anchor-grid {
    display: grid;
    grid-template-columns: repeat(3, 36px);
    grid-auto-rows: 36px;
    gap: 4px;
  }

  .anchor-cell {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: var(--surface-control);
    color: var(--text-primary);
    cursor: pointer;
    font-size: 16px;
    line-height: 1;
  }

  .anchor-cell[aria-pressed="true"] {
    border-color: var(--accent);
    background: var(--accent);
    color: var(--surface-sidebar);
  }

  .anchor-cell-empty {
    border: 1px dashed var(--border-subtle);
    border-radius: 6px;
  }

  .add-transform {
    margin-block-start: 10px;
  }

  /* Keep the sortable list flush with the surrounding panel. */
  .tool-section :global(.ssl-list) {
    padding: 0;
  }
</style>
```

- [ ] **Step 2: Type-check + svelte-check**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: PASS, no errors. (If svelte-check flags the `{#snippet}` param types or
the sortable event shape, fix inline against the library's `dist/types/*.d.ts`;
the event payload is `{ draggedItemIndex: number; targetItemIndex: number | null;
isCanceled: boolean }` on `ondragend`.)

- [ ] **Step 3: Commit**

```bash
git add fiddle/assets/TwicPicsControls.svelte
git commit -m "feat(fiddle): TwicPics reorderable chain-builder controls (#306)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Shared wiring — `fiddle-url-state.ts` + test + `App.svelte`

The `AppState` shape change forces matching edits in `App.svelte`'s object
literals, so these land together to keep `check` green. TDD the dispatch logic in
`fiddle-url-state.test.ts` first; the `App.svelte` structural rewrite is verified
by `check` + the existing test suite.

**Files:**
- Modify: `fiddle/assets/fiddle-url-state.ts`
- Modify: `fiddle/assets/fiddle-url-state.test.ts`
- Modify: `fiddle/assets/App.svelte`

- [ ] **Step 1: Write the failing dispatch tests**

In `fiddle/assets/fiddle-url-state.test.ts`, extend the imports and `baseAppState`,
and add a twicpics dispatch describe block.

Replace the top of the file (lines 1–12) with:
```ts
import { describe, expect, it } from "vitest";
import { defaultFiddleState } from "./processing-path";
import { defaultIiifState } from "./iiif-path";
import { defaultTwicPicsState } from "./twicpics-path";
import { appPathForState, parseAppPath, type AppState } from "./fiddle-url-state";

function baseAppState(): AppState {
  return {
    provider: "imgproxy",
    imgproxy: { ...defaultFiddleState },
    iiif: { ...defaultIiifState },
    twicpics: { ...defaultTwicPicsState },
  };
}
```

Append this describe block at the end of the file:
```ts
describe("twicpics provider dispatch", () => {
  it("emits the twicpics browser path when the provider is twicpics", () => {
    const state: AppState = {
      ...baseAppState(),
      provider: "twicpics",
      twicpics: {
        ...defaultTwicPicsState,
        chain: [{ type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } }],
      },
    };
    expect(appPathForState(state)).toBe(
      "/twicpics/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80",
    );
  });

  it("routes a twicpics-prefixed path + search to the twicpics slice", () => {
    const parsed = parseAppPath(
      "/twicpics/images/dog.jpg",
      "?twic=v1/resize=340/resize=50p/output=webp/quality=70",
    );
    expect(parsed.provider).toBe("twicpics");
    expect(parsed.twicpics.chain.map((s) => s.type)).toEqual(["resize", "resize"]);
    expect(parsed.twicpics.output).toBe("webp");
    expect(parsed.twicpics.quality).toBe(70);
  });

  it("stays on the twicpics provider for a malformed tail, with a default slice", () => {
    const parsed = parseAppPath("/twicpics/images/dog.jpg", "?twic=v1/zoom=2");
    expect(parsed.provider).toBe("twicpics");
    expect(parsed.twicpics).toEqual(defaultTwicPicsState);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run fiddle-url-state.test.ts`
Expected: FAIL — `appPathForState` returns the imgproxy path for a twicpics
provider / `parsed.provider` is not `"twicpics"` (dispatch not implemented).

- [ ] **Step 3: Implement url-state dispatch**

In `fiddle/assets/fiddle-url-state.ts`:

(a) Extend the iiif import (line 20) to add the twicpics imports immediately after:
```ts
import { defaultIiifState, iiifBrowserPath, parseIiifTail, type IiifState } from "./iiif-path";
import {
  defaultTwicPicsState,
  parseTwicTail,
  twicBrowserPath,
  type TwicPicsState,
} from "./twicpics-path";
```

(b) Replace the `Provider` / `providers` / `AppState` / `defaultAppState` block
(lines 1115–1134) with:
```ts
export type Provider = "imgproxy" | "iiif" | "twicpics";

export const providers: readonly { id: Provider; label: string }[] = [
  { id: "imgproxy", label: "imgproxy" },
  { id: "iiif", label: "IIIF (Image API 3.0)" },
  { id: "twicpics", label: "TwicPics" },
];

export type AppState = {
  provider: Provider;
  imgproxy: FiddleState;
  iiif: IiifState;
  twicpics: TwicPicsState;
};

export function defaultAppState(): AppState {
  return {
    provider: "imgproxy",
    imgproxy: { ...defaultFiddleState },
    iiif: { ...defaultIiifState },
    twicpics: { ...defaultTwicPicsState },
  };
}
```

(c) Replace `appPathForState` (lines 1138–1144) with:
```ts
export function appPathForState(state: AppState): string {
  if (state.provider === "iiif") {
    return iiifBrowserPath(state.iiif);
  }

  if (state.provider === "twicpics") {
    return twicBrowserPath(state.twicpics);
  }

  return `/imgproxy${fiddlePathForState(state.imgproxy)}`;
}
```

(d) Replace `parseAppPath` (lines 1149–1170) with:
```ts
export function parseAppPath(pathname: string, search = ""): AppState {
  const [, first = "", ...rest] = pathname.split("/");

  if (first === "twicpics") {
    const twicpics = parseTwicTail(rest.join("/"), search);
    return {
      provider: "twicpics",
      imgproxy: { ...defaultFiddleState },
      iiif: { ...defaultIiifState },
      twicpics: twicpics ?? { ...defaultTwicPicsState },
    };
  }

  if (first === "iiif") {
    const iiif = parseIiifTail(rest.join("/"));
    return {
      provider: "iiif",
      imgproxy: { ...defaultFiddleState },
      iiif: iiif ?? { ...defaultIiifState },
      twicpics: { ...defaultTwicPicsState },
    };
  }

  if (first === "imgproxy") {
    return {
      provider: "imgproxy",
      imgproxy: parseFiddlePath("/" + rest.join("/")),
      iiif: { ...defaultIiifState },
      twicpics: { ...defaultTwicPicsState },
    };
  }

  return defaultAppState();
}
```

- [ ] **Step 4: Run the url-state tests to verify they pass**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run fiddle-url-state.test.ts`
Expected: PASS (existing imgproxy/iiif cases + new twicpics cases).

- [ ] **Step 5: Rewrite the App.svelte binary sites to three-way**

In `fiddle/assets/App.svelte`:

(a) After the IIIF import (line 5 `import IiifControls from "./IiifControls.svelte";`)
add:
```ts
  import TwicPicsControls from "./TwicPicsControls.svelte";
```
and after the iiif-path import (line 14) add:
```ts
  import { defaultTwicPicsState, twicFetchPath } from "./twicpics-path";
```

(b) Replace the `path` initializer (lines 44–48) with:
```ts
  let path = $state(
    initial.provider === "imgproxy"
      ? buildProcessingPath(initial.imgproxy)
      : initial.provider === "iiif"
        ? iiifFetchPath(initial.iiif)
        : twicFetchPath(initial.twicpics),
  );
```

(c) Replace the provider `$effect` (lines 104–111) with:
```ts
  $effect(() => {
    if (appState.provider === "imgproxy") {
      updateProcessingPath(appState.imgproxy);
    } else if (appState.provider === "iiif") {
      pathRequestId += 1; // invalidate any in-flight imgproxy signing so it can't clobber `path`
      path = iiifFetchPath(appState.iiif);
    } else {
      pathRequestId += 1;
      path = twicFetchPath(appState.twicpics);
    }
  });
```

(d) Replace the `updateFiddleLocation` guard (lines 76–82) with:
```ts
  const updateFiddleLocation = debounce((nextPath: string) => {
    if (typeof window === "undefined" || window.location.pathname + window.location.search === nextPath) {
      return;
    }

    window.history.replaceState(null, "", nextPath);
  }, 150);
```

(e) Replace the four `$derived` (lines 125–143) with explicit three-way forms:
```ts
  const previewParameters = $derived(
    appState.provider === "imgproxy"
      ? path.replace(/^\/[^/]+\/[^/]+\//, "")
      : appState.provider === "iiif"
        ? path.replace(/^\/iiif-image\//, "")
        : path.replace(/^\/twic\//, ""),
  );
  const outputLabel = $derived(
    appState.provider === "imgproxy"
      ? resolvedOutputLabel(appState.imgproxy, processedMetadata)
      : appState.provider === "iiif"
        ? appState.iiif.format
        : appState.twicpics.output,
  );
  const sizeLabel = $derived(previewError ?? processedSizeLabel(processedMetadata));
  const requestSummary = $derived(
    appState.provider === "imgproxy"
      ? `${appState.imgproxy.source.replace(/^images\//, "")} / ${requestSignatureLabel(appState.imgproxy, signingError)}`
      : appState.provider === "iiif"
        ? appState.iiif.source.replace(/^images\//, "")
        : appState.twicpics.source.replace(/^images\//, ""),
  );
  const currentSource = $derived(
    appState.provider === "iiif"
      ? appState.iiif.source
      : appState.provider === "twicpics"
        ? appState.twicpics.source
        : appState.imgproxy.source,
  );
```

(f) Replace `initialAppState` (lines 145–151) with:
```ts
  function initialAppState(): AppState {
    if (typeof window === "undefined") {
      return defaultAppState();
    }

    return parseAppPath(window.location.pathname, window.location.search);
  }
```

(g) Replace `restoreStateFromLocation` (lines 153–159) with:
```ts
  function restoreStateFromLocation(): void {
    const parsed = parseAppPath(window.location.pathname, window.location.search);

    switch (parsed.provider) {
      case "iiif":
        appState = {
          provider: "iiif",
          imgproxy: appState.imgproxy,
          iiif: parsed.iiif,
          twicpics: appState.twicpics,
        };
        break;
      case "twicpics":
        appState = {
          provider: "twicpics",
          imgproxy: appState.imgproxy,
          iiif: appState.iiif,
          twicpics: parsed.twicpics,
        };
        break;
      default:
        appState = {
          provider: "imgproxy",
          imgproxy: parsed.imgproxy,
          iiif: appState.iiif,
          twicpics: appState.twicpics,
        };
    }
  }
```

(h) In `updateSource` (lines 331–344), add the twicpics slice update after the
iiif line (line 343):
```ts
    appState.twicpics = { ...appState.twicpics, source };
```

(i) Replace `resetSettings` (lines 350–356) with:
```ts
  function resetSettings(): void {
    if (appState.provider === "imgproxy") {
      appState.imgproxy = resetFiddleSettings(appState.imgproxy);
    } else if (appState.provider === "iiif") {
      appState.iiif = { ...defaultIiifState, source: appState.iiif.source };
    } else {
      appState.twicpics = { ...defaultTwicPicsState, source: appState.twicpics.source };
    }
  }
```

(j) Replace the controls block (lines 523–527) with:
```svelte
      {#if appState.provider === "imgproxy"}
        <ImgproxyControls bind:fiddleState={appState.imgproxy} source={appState.imgproxy.source} />
      {:else if appState.provider === "iiif"}
        <IiifControls bind:iiifState={appState.iiif} source={appState.iiif.source} />
      {:else}
        <TwicPicsControls bind:twicpicsState={appState.twicpics} source={appState.twicpics.source} />
      {/if}
```

- [ ] **Step 6: Run JS tests + type-check**

Run:
```bash
mise exec -- pnpm -C fiddle/assets run test
mise exec -- pnpm -C fiddle/assets run check
```
Expected: both PASS — all test files green, no type/svelte-check errors.

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/fiddle-url-state.ts fiddle/assets/fiddle-url-state.test.ts fiddle/assets/App.svelte
git commit -m "feat(fiddle): wire TwicPics provider into App + url-state (#306)

Rewrites the binary imgproxy/iiif provider sites (provider effect,
restoreStateFromLocation, the four \$derived, controls branch) to
three-way, threads window.location.search through parseAppPath for the
?twic= chain, and fixes the updateFiddleLocation guard to compare
pathname+search.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full gate + acceptance verification

**Files:** none (verification only), plus the branch rename.

- [ ] **Step 1: Run the full fiddle gate**

Run: `mise run precommit:fiddle`
Expected: PASS — Elixir gate (format, compile-warnings-as-errors, credo, test) +
fiddle Elixir checks + `pnpm` test/check/format:check/lint/build all green.

If `format:check` or `lint` flags the new files, run
`mise exec -- pnpm -C fiddle/assets run format` and fix any lint findings, then
re-run the gate and amend the relevant commit.

- [ ] **Step 2: Acceptance pass against a running fiddle**

Start the server: `mise run server` (or the project's documented dev command), then
verify each acceptance criterion from issue #306:

1. **Provider selector** shows "TwicPics"; selecting it renders the chain builder.
2. **Add / remove / reorder** — add `resize`, `cover`, `focus`; drag to reorder;
   reorder by keyboard (focus a card, Space to grab, ↑/↓ to move, Space to drop);
   confirm the preview image and the address-bar URL update live.
3. **Relative units compound** — add `resize` (px 340) then `resize` (% 50);
   confirm the processed image is ~170px wide (50% of the running 340), proving
   order-dependent relative resolution.
4. **Real render through `/twic`** — confirm the preview loads a processed image and
   the generated request matches `?twic=v1/…`. Spot-check by opening the "Open" link.
5. **URL round-trip** — copy the URL, reload the page (and use browser back/forward);
   confirm the exact chain + order + output/quality are restored.
6. (Re-confirm) `mise run precommit:fiddle` passes.

Note in the task tracker any criterion that fails, and fix before proceeding.

- [ ] **Step 3: Rename the branch (pre-push, per AGENTS.md)**

```bash
git branch -m feat/fiddle-twicpics-provider
```
(Rename only the branch — leave the worktree directory as-is.)

- [ ] **Step 4: Final status check**

Run: `git log --oneline -8` and `git status`
Expected: a clean tree with the Task 1–6 commits on `feat/fiddle-twicpics-provider`;
no stray uncommitted files (the earlier draft test is now the committed test).

PR body (when opened) carries a bare `Fixes #306` line so the issue auto-closes;
verify with `gh pr view <n> --json closingIssuesReferences` after opening.

---

## Self-Review

**Spec coverage:**
- Chain transforms (resize/cover/contain/inside/crop/focus) → Tasks 3–5. ✓
- Output footer (output/quality) → Task 3 (encoding) + Task 5 (UI). ✓
- Request contract `/twic/<source>?twic=v1/…` → Task 2 (backend) + Task 3
  (`twicFetchPath`). ✓
- Browser path `/twicpics/…` + query-string plumbing → Task 6. ✓
- State model + round-trip + order preservation → Tasks 3–4 (tests). ✓
- Reorder by drag + keyboard → Task 5 (library) + Task 7 (acceptance). ✓
- Three-way rewrite of binary App sites → Task 6 (steps 5a–5j). ✓
- `fiddle-url-state.test.ts` `baseAppState` field → Task 6 step 1. ✓
- Dependency → Task 1. Backend opts/router/plug → Task 2. ✓
- No support-matrix change (spec §10) → not a task; nothing in the plan touches the
  parser or `docs/twicpics_support_matrix.md`. ✓
- Gate + branch rename + `Fixes #306` → Task 7. ✓

**Placeholder scan:** no TBD/TODO; every code step contains complete code and exact
commands with expected output.

**Type consistency:** `TwicDim` is `{ unit, value }` everywhere (encoding, parsing,
tests, controls); `TransformStep` member shapes match across `defaultStep`,
`stepToken`, `parseStep`, the tests, and the controls template; the sortable
`ondragend` payload shape (`draggedItemIndex`/`targetItemIndex`/`isCanceled`) is
consistent between Task 5's `handleDragEnd` and the design spec; `parseTwicTail`,
`twicParam`, `twicFetchPath`, `twicBrowserPath`, `defaultTwicPicsState`,
`nextStepId`, `defaultStep`, `stepSummary`, `twicAnchors`, `twicOutputs`,
`TwicResizeUnit` names match across module, tests, and component.
