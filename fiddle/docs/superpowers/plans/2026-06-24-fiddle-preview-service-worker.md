# Fiddle Preview via Service Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fiddle preview pane render via a real `<img>` element (so the browser performs the request with its true `Accept` header and negotiates a decodable format) and use a Service Worker to recover the response metadata (`bytes`, `contentType`) the old `fetch` path provided — across all three processing dialects (`/img`, `/iiif-image`, `/twic`).

**Architecture:** The decode bug is fixed by the `<img>` swap alone: an `<img>` always sends the browser's real image `Accept`, so the negotiator never picks a format the browser can't decode. The Service Worker is a *separate, additive* concern — it intercepts the same-origin `/img|/iiif-image|/twic` requests the `<img>` makes, forwards them unchanged (preserving the real `Accept`), reads the response off a clone, and `postMessage`s `{bytes, contentType, status, …}` back to the page. All testable logic lives in three small TS modules (`preview-intercept`, `preview-bridge`, `preview-sw`); `App.svelte` stays thin. The worker is served same-origin from Phoenix (`:4000`) — it cannot be a Vite module (`:5173` is a different origin) — built one-shot by a dedicated Vite config into `priv/static/preview-sw.js`.

**Tech Stack:** Svelte 5 (runes), TypeScript, Vite (build) + Vitest (test), Phoenix `Plug.Static`, the Service Worker API.

---

## Background / why

`App.svelte`'s `loadPreview` does `fetch(path, { headers: { accept: previewAcceptHeader } })` where `previewAcceptHeader` contains `image/*`. After JXL output landed, `ImagePipe.Output.Negotiation` (`@modern_formats = [jpeg_xl, avif, webp]`) matches `image/jxl` against that `image/*` wildcard and serves JXL, which the `imageDimensions()` `<img>` probe cannot decode → "Preview image could not be decoded". A real browser navigation sends no `image/*`, so it negotiates AVIF and works.

Confirmed empirically against the running server:
- `Accept: …,image/*,*/*;q=0.8` → `content-type: image/jxl`
- `Accept: …image/avif,image/webp,image/apng,*/*;q=0.8` → `content-type: image/avif`

All three endpoints (`ImagePipeFiddleWeb.{Imgproxy,IIIF,TwicPics}`) run the same `Plan.Output` negotiation, so the bug and the fix are dialect-uniform.

See the design sketch: `fiddle/docs/preview-service-worker-sketch.md`.

## File structure

| File | Responsibility |
|------|----------------|
| `fiddle/assets/preview-intercept.ts` (new) | Single source of truth shared by SW + page: the three URL prefixes, `isPreviewUrl`, the `PreviewMetaMessage` shape, and a `parsePreviewMeta` boundary parser. |
| `fiddle/assets/preview-intercept.test.ts` (new) | Vitest for the predicate + parser. |
| `fiddle/assets/preview-sw.ts` (new) | The worker: `install`/`activate`/`fetch` listeners; forwards the request, reads a clone, reports metadata to the originating client. Imports `preview-intercept`. |
| `fiddle/assets/preview-bridge.ts` (new) | Page side: `registerPreviewWorker` (register + ready + message subscription, SW-absent fallback) and `PreviewMetadataTracker` (merges async dimensions + SW metadata, requestId-guarded, yields `ProcessedImageMetadata`/error). |
| `fiddle/assets/preview-bridge.test.ts` (new) | Vitest for registration fallback + the tracker merge/stale-guard logic. |
| `fiddle/assets/vite.sw.config.ts` (new) | One-shot Vite build that bundles `preview-sw.ts` → `priv/static/preview-sw.js` (fixed name, no hash). |
| `fiddle/assets/tsconfig.sw.json` (new) | Worker-only TS project (`lib: ESNext + WebWorker`) so the worker's worker-global types never merge with the DOM app's and break `pnpm check`. |
| `fiddle/assets/tsconfig.json` (modify) | Exclude `preview-sw.ts` from the DOM project (it's checked by `tsconfig.sw.json` instead). |
| `fiddle/assets/package.json` (modify) | Add `build:sw`; chain it into `build`; add the worker tsconfig to `check`. |
| `fiddle/.gitignore` (modify) | Ignore the generated `/priv/static/preview-sw.js` (it is build output, like `assets/` and `.vite/`). |
| `fiddle/lib/image_pipe_fiddle_web.ex:20` (modify) | Add `preview-sw.js` to `static_paths/0` so `Plug.Static` serves it from root on `:4000`. |
| `fiddle/assets/App.svelte` (modify) | Replace the `fetch`/objectURL/abort preview path with `<img src>` + `onload`/`onerror`; register the worker in `onMount`; feed SW messages into the tracker. Remove `previewAcceptHeader`, `loadPreview`, `imageDimensions`, `revokePreviewObjectUrl`, `activePreviewObjectUrl`, `previewAbortController`, `previewErrorFromResponse`, `previewErrorMessage`. |
| `mise.toml` (repo root — modify) | `setup` must build the worker (`pnpm -C fiddle/assets run build:sw`) so `priv/static/preview-sw.js` exists before `mix phx.server`. **There is no `fiddle/mise.toml`** — all fiddle tasks live in the root file. |

## Conventions to follow

- Tests use Vitest (`import { describe, expect, it } from "vitest"`), files named `*.test.ts`, colocated in `assets/`. Run with `pnpm -C fiddle/assets test` (or `mise exec -- pnpm ...`).
- Type/lint/format gate: `pnpm -C fiddle/assets check`, `lint`, `format:check`.
- Run JS commands through mise: `mise exec -- pnpm -C fiddle/assets <script>`. On a fresh worktree run `mise trust` + `mise exec -- mix deps.get` and `pnpm -C fiddle/assets install` first.
- Commit after each task.

---

### Task 1: Shared intercept module (`preview-intercept.ts`)

**Files:**
- Create: `fiddle/assets/preview-intercept.ts`
- Test: `fiddle/assets/preview-intercept.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// fiddle/assets/preview-intercept.test.ts
import { describe, expect, it } from "vitest";

import { isPreviewUrl, parsePreviewMeta, PREVIEW_PREFIXES } from "./preview-intercept";

describe("isPreviewUrl", () => {
  it("matches all three processing prefixes regardless of query", () => {
    expect(isPreviewUrl("http://localhost:4000/img/_/rs:fit:10:10/plain/local:///images/dog.jpg")).toBe(true);
    expect(isPreviewUrl("http://localhost:4000/iiif-image/dog/full/max/0/default.jpg")).toBe(true);
    expect(isPreviewUrl("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10")).toBe(true);
  });

  it("rejects the SPA shell, vite assets, and the display-only /twicpics path", () => {
    expect(isPreviewUrl("http://localhost:4000/")).toBe(false);
    expect(isPreviewUrl("http://localhost:4000/preview-sw.js")).toBe(false);
    expect(isPreviewUrl("http://localhost:5173/main.ts")).toBe(false);
    expect(isPreviewUrl("http://localhost:4000/twicpics/images/dog.jpg?twic=v1/cover=10x10")).toBe(false);
  });

  it("returns false for non-URL strings instead of throwing", () => {
    expect(isPreviewUrl("not a url")).toBe(false);
  });

  it("exposes the prefixes as a readonly list", () => {
    expect([...PREVIEW_PREFIXES]).toEqual(["/img/", "/iiif-image/", "/twic/"]);
  });
});

describe("parsePreviewMeta", () => {
  it("accepts a well-formed message", () => {
    const message = parsePreviewMeta({
      type: "preview-meta",
      url: "http://localhost:4000/img/x",
      accept: "image/avif",
      ok: true,
      status: 200,
      statusText: "OK",
      contentType: "image/avif",
      bytes: 1234,
      error: null,
    });
    expect(message).not.toBeNull();
    expect(message?.contentType).toBe("image/avif");
    expect(message?.bytes).toBe(1234);
  });

  it("coerces missing/wrong-typed optional fields to safe defaults", () => {
    const message = parsePreviewMeta({ type: "preview-meta", url: "http://x/img/y" });
    expect(message).toEqual({
      type: "preview-meta",
      url: "http://x/img/y",
      accept: null,
      ok: false,
      status: 0,
      statusText: "",
      contentType: null,
      bytes: null,
      error: null,
    });
  });

  it("rejects foreign messages", () => {
    expect(parsePreviewMeta(null)).toBeNull();
    expect(parsePreviewMeta("hi")).toBeNull();
    expect(parsePreviewMeta({ type: "other", url: "http://x/img/y" })).toBeNull();
    expect(parsePreviewMeta({ type: "preview-meta" })).toBeNull(); // no url
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-intercept`
Expected: FAIL — `Cannot find module './preview-intercept'`.

- [ ] **Step 3: Write minimal implementation**

```ts
// fiddle/assets/preview-intercept.ts

// The fiddle's three processing endpoints (router forwards: /img, /iiif-image, /twic).
// All run the same Plan.Output negotiation, so one interceptor covers them. Match on
// pathname so the TwicPics `?twic=…` query is ignored. `/twicpics/` is the display-only
// copy link (twicBrowserPath) and is intentionally excluded.
export const PREVIEW_PREFIXES = ["/img/", "/iiif-image/", "/twic/"] as const;

export function isPreviewUrl(url: string): boolean {
  let pathname: string;
  try {
    pathname = new URL(url).pathname;
  } catch {
    return false;
  }
  return PREVIEW_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

// The metadata the worker reports back to the page for the request the browser made.
export type PreviewMetaMessage = {
  type: "preview-meta";
  url: string;
  accept: string | null;
  ok: boolean;
  status: number;
  statusText: string;
  contentType: string | null;
  bytes: number | null;
  error: string | null;
};

// Boundary parser: postMessage data is untrusted (any page script can post). Validate
// shape, coerce optionals to safe defaults, reject anything that is not our message.
export function parsePreviewMeta(data: unknown): PreviewMetaMessage | null {
  if (typeof data !== "object" || data === null) return null;
  const m = data as Record<string, unknown>;
  if (m.type !== "preview-meta" || typeof m.url !== "string") return null;
  return {
    type: "preview-meta",
    url: m.url,
    accept: typeof m.accept === "string" ? m.accept : null,
    ok: m.ok === true,
    status: typeof m.status === "number" ? m.status : 0,
    statusText: typeof m.statusText === "string" ? m.statusText : "",
    contentType: typeof m.contentType === "string" ? m.contentType : null,
    bytes: typeof m.bytes === "number" ? m.bytes : null,
    error: typeof m.error === "string" ? m.error : null,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-intercept`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/preview-intercept.ts fiddle/assets/preview-intercept.test.ts
git commit -m "feat(fiddle): shared preview-intercept predicate + message parser"
```

---

### Task 2: Page-side bridge — metadata tracker (`preview-bridge.ts`, part 1)

The tracker merges two async arrivals — image dimensions (from `<img>.onload`) and SW metadata (from `postMessage`) — under a monotonic request-id guard, and produces the `ProcessedImageMetadata` the panel renders. Dimensions are the required core (`width`/`height` are non-null in `ProcessedImageMetadata`), so metadata stays `null` until they arrive; `bytes`/`contentType` fill in whenever the SW message lands (before or after `onload`). Correlation also checks the **full URL including query** (TwicPics previews can share a pathname).

**Files:**
- Create: `fiddle/assets/preview-bridge.ts`
- Test: `fiddle/assets/preview-bridge.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// fiddle/assets/preview-bridge.test.ts
import { describe, expect, it } from "vitest";

import { PreviewMetadataTracker } from "./preview-bridge";

const meta = (over: Partial<Parameters<PreviewMetadataTracker["applyMessage"]>[0]> = {}) => ({
  type: "preview-meta" as const,
  url: "http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10",
  accept: "image/avif",
  ok: true,
  status: 200,
  statusText: "OK",
  contentType: "image/webp",
  bytes: 4321,
  error: null,
  ...over,
});

describe("PreviewMetadataTracker", () => {
  it("yields null metadata until dimensions arrive, then merges SW bytes/contentType", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10");

    // SW message arrives before onload: stashed, not yet renderable (needs dimensions).
    t.applyMessage(meta(), id);
    expect(t.metadata).toBeNull();
    expect(t.error).toBeNull();

    t.applyDimensions({ width: 10, height: 10 }, id);
    expect(t.metadata).toEqual({ width: 10, height: 10, bytes: 4321, contentType: "image/webp" });
  });

  it("merges when the SW message arrives AFTER onload", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/img/x");
    t.applyDimensions({ width: 5, height: 7 }, id);
    expect(t.metadata).toEqual({ width: 5, height: 7, bytes: null, contentType: null });

    t.applyMessage(meta({ url: "http://localhost:4000/img/x", bytes: 99, contentType: "image/avif" }), id);
    expect(t.metadata).toEqual({ width: 5, height: 7, bytes: 99, contentType: "image/avif" });
  });

  it("drops stale messages from a superseded request id", () => {
    const t = new PreviewMetadataTracker();
    const stale = t.begin("http://localhost:4000/img/old");
    const fresh = t.begin("http://localhost:4000/img/new");

    t.applyMessage(meta({ url: "http://localhost:4000/img/old", bytes: 1 }), stale);
    t.applyDimensions({ width: 1, height: 1 }, fresh);
    expect(t.metadata).toEqual({ width: 1, height: 1, bytes: null, contentType: null });
  });

  it("drops a message whose url does not match the in-flight preview (query-sensitive)", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10");
    t.applyDimensions({ width: 10, height: 10 }, id);
    t.applyMessage(meta({ url: "http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=20x20" }), id);
    expect(t.metadata?.bytes).toBeNull(); // different query → ignored
  });

  it("records an error from a non-ok SW message", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/img/x");
    t.applyMessage(
      meta({ url: "http://localhost:4000/img/x", ok: false, status: 422, statusText: "Unprocessable Entity", contentType: "text/plain", bytes: null, error: "invalid image request: bad_option" }),
      id,
    );
    expect(t.error).toBe("422 Unprocessable Entity: invalid image request: bad_option");
    expect(t.metadata).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-bridge`
Expected: FAIL — `Cannot find module './preview-bridge'`.

- [ ] **Step 3: Write minimal implementation**

```ts
// fiddle/assets/preview-bridge.ts
import { type PreviewMetaMessage } from "./preview-intercept";
import { type ProcessedImageMetadata } from "./processing-path";

type Dimensions = { width: number; height: number };

export class PreviewMetadataTracker {
  metadata: ProcessedImageMetadata | null = null;
  error: string | null = null;

  #requestId = 0;
  #url: string | null = null;
  #dimensions: Dimensions | null = null;
  #pending: { bytes: number | null; contentType: string | null } | null = null;

  // Start tracking a new preview. Returns the request id callers thread back into
  // applyDimensions/applyMessage so stale async arrivals are dropped.
  begin(url: string): number {
    this.#requestId += 1;
    this.#url = url;
    this.#dimensions = null;
    this.#pending = null;
    this.metadata = null;
    this.error = null;
    return this.#requestId;
  }

  applyDimensions(dimensions: Dimensions, requestId: number): void {
    if (requestId !== this.#requestId) return;
    this.#dimensions = dimensions;
    this.#recompute();
  }

  applyMessage(message: PreviewMetaMessage, requestId: number): void {
    if (requestId !== this.#requestId) return;
    if (message.url !== this.#url) return; // full-URL match (query-sensitive for TwicPics)

    if (!message.ok) {
      const suffix = message.error ? `: ${message.error}` : "";
      this.error = `${message.status} ${message.statusText}`.trim() + suffix;
      this.metadata = null;
      return;
    }

    this.#pending = { bytes: message.bytes, contentType: message.contentType };
    this.#recompute();
  }

  #recompute(): void {
    if (this.#dimensions === null) {
      this.metadata = null;
      return;
    }
    this.metadata = {
      width: this.#dimensions.width,
      height: this.#dimensions.height,
      bytes: this.#pending?.bytes ?? null,
      contentType: this.#pending?.contentType ?? null,
    };
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-bridge`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/preview-bridge.ts fiddle/assets/preview-bridge.test.ts
git commit -m "feat(fiddle): PreviewMetadataTracker merges dimensions + SW metadata"
```

---

### Task 3: Page-side bridge — worker registration (`preview-bridge.ts`, part 2)

Add `registerPreviewWorker`: subscribe to SW messages (parsed at the boundary), register the worker, await control, and degrade gracefully when the SW API is absent or registration fails (the `<img>` still renders correctly — only metadata is lost).

**Files:**
- Modify: `fiddle/assets/preview-bridge.ts`
- Modify: `fiddle/assets/preview-bridge.test.ts`

- [ ] **Step 1: Write the failing test (append)**

```ts
// append to fiddle/assets/preview-bridge.test.ts
import { registerPreviewWorker, PREVIEW_WORKER_URL } from "./preview-bridge";

function fakeContainer(opts: { failRegister?: boolean } = {}) {
  const listeners = new Set<(e: MessageEvent) => void>();
  return {
    registered: [] as string[],
    removed: 0,
    ready: Promise.resolve({} as ServiceWorkerRegistration),
    addEventListener: (_t: string, cb: EventListener) => listeners.add(cb as never),
    removeEventListener: (_t: string, cb: EventListener) => {
      listeners.delete(cb as never);
    },
    register(url: string) {
      this.registered.push(url);
      return opts.failRegister ? Promise.reject(new Error("nope")) : Promise.resolve({} as ServiceWorkerRegistration);
    },
    emit(data: unknown) {
      for (const cb of listeners) cb({ data } as MessageEvent);
    },
    get listenerCount() {
      return listeners.size;
    },
  };
}

describe("registerPreviewWorker", () => {
  it("returns not-ready and never throws when the SW API is absent", async () => {
    const worker = await registerPreviewWorker(() => {}, undefined);
    expect(worker.ready).toBe(false);
  });

  it("registers the root-scoped worker and forwards parsed messages", async () => {
    const container = fakeContainer();
    const seen: string[] = [];
    const worker = await registerPreviewWorker((m) => seen.push(m.url), container as never);

    expect(worker.ready).toBe(true);
    expect(container.registered).toEqual([PREVIEW_WORKER_URL]);
    container.emit({ type: "preview-meta", url: "http://x/img/a" });
    container.emit({ type: "garbage" });
    expect(seen).toEqual(["http://x/img/a"]); // foreign message dropped by parser
  });

  it("cleans up the listener and reports not-ready when registration fails", async () => {
    const container = fakeContainer({ failRegister: true });
    const worker = await registerPreviewWorker(() => {}, container as never);
    expect(worker.ready).toBe(false);
    expect(container.listenerCount).toBe(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-bridge`
Expected: FAIL — `registerPreviewWorker`/`PREVIEW_WORKER_URL` not exported.

- [ ] **Step 3: Write minimal implementation (append to `preview-bridge.ts`)**

```ts
// append to fiddle/assets/preview-bridge.ts
import { parsePreviewMeta } from "./preview-intercept";

// Served by Phoenix from root (:4000), NOT Vite (:5173) — a SW script must be
// same-origin with the page. Root path ⇒ default scope "/" ⇒ covers /img,
// /iiif-image, /twic with no Service-Worker-Allowed header needed.
export const PREVIEW_WORKER_URL = "/preview-sw.js";

export type PreviewWorker = { ready: boolean; unsubscribe: () => void };

export async function registerPreviewWorker(
  onMeta: (message: PreviewMetaMessage) => void,
  container: ServiceWorkerContainer | undefined = typeof navigator !== "undefined"
    ? navigator.serviceWorker
    : undefined,
): Promise<PreviewWorker> {
  if (container === undefined) return { ready: false, unsubscribe: () => {} };

  const listener = (event: MessageEvent) => {
    const message = parsePreviewMeta(event.data);
    if (message !== null) onMeta(message);
  };
  container.addEventListener("message", listener);

  try {
    await container.register(PREVIEW_WORKER_URL);
    await container.ready;
    return { ready: true, unsubscribe: () => container.removeEventListener("message", listener) };
  } catch {
    container.removeEventListener("message", listener);
    return { ready: false, unsubscribe: () => {} };
  }
}
```

> Note: `PreviewMetaMessage` is already imported in part 1; if your editor flags a duplicate import, merge the two `preview-intercept` import lines into one.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets test -- preview-bridge`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/preview-bridge.ts fiddle/assets/preview-bridge.test.ts
git commit -m "feat(fiddle): registerPreviewWorker with SW-absent fallback"
```

---

### Task 4: The Service Worker (`preview-sw.ts`)

Thin glue over `preview-intercept`. The pure parts are already tested in Task 1; the event wiring here is integration-verified (Task 7). Keep it dependency-free except for `preview-intercept`.

**Files:**
- Create: `fiddle/assets/preview-sw.ts`

- [ ] **Step 1: Write the worker**

```ts
// fiddle/assets/preview-sw.ts
/// <reference lib="webworker" />
import { isPreviewUrl, type PreviewMetaMessage } from "./preview-intercept";

const sw = self as unknown as ServiceWorkerGlobalScope;

sw.addEventListener("install", () => {
  void sw.skipWaiting();
});

sw.addEventListener("activate", (event) => {
  event.waitUntil(sw.clients.claim());
});

sw.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || !isPreviewUrl(request.url)) return;
  event.respondWith(handlePreview(event, request));
});

async function handlePreview(event: FetchEvent, request: Request): Promise<Response> {
  // Forward the request UNCHANGED so the browser's real Accept reaches the server
  // and a decodable format is negotiated. Read metadata off a clone so the original
  // stream still reaches the <img> untouched.
  const accept = request.headers.get("accept");
  const response = await fetch(request);
  void reportMetadata(event.clientId, request.url, accept, response.clone());
  return response;
}

async function reportMetadata(
  clientId: string,
  url: string,
  accept: string | null,
  response: Response,
): Promise<void> {
  try {
    const body = await response.arrayBuffer(); // demo payloads are small; buffering to count bytes is fine
    const message: PreviewMetaMessage = {
      type: "preview-meta",
      url,
      accept,
      ok: response.ok,
      status: response.status,
      statusText: response.statusText,
      contentType: response.headers.get("content-type"),
      bytes: body.byteLength,
      error: response.ok ? null : errorSnippet(response, body),
    };
    await postToClient(clientId, message);
  } catch {
    // Metadata is best-effort; never disrupt the image render.
  }
}

// `event.clientId` is reliably populated for many subresource fetches, but Chromium
// has historically left it empty for some `<img>` loads depending on version/timing.
// When the specific client can't be resolved, broadcast to all window clients — the
// PAGE guards every message by full-URL + request id, so a broadcast can never
// mis-correlate metadata onto the wrong preview or the wrong tab.
async function postToClient(clientId: string, message: PreviewMetaMessage): Promise<void> {
  const client = clientId ? await sw.clients.get(clientId) : undefined;
  if (client !== undefined) {
    client.postMessage(message);
    return;
  }
  const windows = await sw.clients.matchAll({ type: "window" });
  for (const windowClient of windows) windowClient.postMessage(message);
}

function errorSnippet(response: Response, body: ArrayBuffer): string | null {
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.startsWith("text/")) return null;
  try {
    return new TextDecoder().decode(body).trim().slice(0, 180) || null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 2: Give the worker its own TS project (do NOT add `WebWorker` to the app's `lib`)**

The worker needs `ServiceWorkerGlobalScope`/`FetchEvent`/`clients`, which require `"WebWorker"` in `lib`. Adding `"WebWorker"` to the app's single `tsconfig.json` (which globs `**/*.ts` and already has `"DOM"`) merges conflicting worker/DOM globals (`self`, `fetch`, `MessageEvent`) project-wide and can break `pnpm check` for the whole DOM app. Isolate the worker instead.

Create `fiddle/assets/tsconfig.sw.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "lib": ["ESNext", "WebWorker"],
    "types": []
  },
  "include": ["preview-sw.ts", "preview-intercept.ts"]
}
```

Edit `fiddle/assets/tsconfig.json` to exclude the worker from the DOM project (must re-list `node_modules` because specifying `exclude` drops the default):

```json
  "include": ["**/*.ts", "**/*.svelte", "vite.config.ts"],
  "exclude": ["node_modules", "preview-sw.ts"]
```

Update the `check` script in `fiddle/assets/package.json` to type-check both projects:

```json
    "check": "tsgo --project tsconfig.json --noEmit && tsgo --project tsconfig.sw.json --noEmit && svelte-check --tsconfig tsconfig.json",
```

(`preview-intercept.ts` is checked by BOTH projects — it uses only `URL`, which exists in `DOM` and `WebWorker`, so no conflict. `preview-bridge.ts` uses DOM-only types and stays in the DOM project.)

- [ ] **Step 3: Type-check both projects**

Run: `mise exec -- pnpm -C fiddle/assets check`
Expected: PASS — the DOM app and the worker project both type-check, no `self`/`fetch` conflict.

- [ ] **Step 4: Commit**

```bash
git add fiddle/assets/preview-sw.ts fiddle/assets/tsconfig.sw.json \
        fiddle/assets/tsconfig.json fiddle/assets/package.json
git commit -m "feat(fiddle): preview service worker forwards request + reports metadata"
```

---

### Task 5: Build + serve the worker from Phoenix root

The worker must land at `priv/static/preview-sw.js` (fixed name, no hash) and be served from `:4000/preview-sw.js`. A dedicated one-shot Vite build bundles it; `static_paths/0` whitelists it for `Plug.Static`.

**Files:**
- Create: `fiddle/assets/vite.sw.config.ts`
- Modify: `fiddle/assets/package.json` (scripts)
- Modify: `fiddle/lib/image_pipe_fiddle_web.ex:20`
- Modify: `fiddle/mise.toml` (`setup` task)

- [ ] **Step 1: Add the SW build config**

```ts
// fiddle/assets/vite.sw.config.ts
import { defineConfig } from "vite";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDirectory = dirname(fileURLToPath(import.meta.url));

// One-shot build (NOT the dev server): emit a single, unhashed, root-served worker.
// emptyOutDir:false so we never wipe priv/static (images, main-app manifest).
export default defineConfig({
  build: {
    outDir: resolve(currentDirectory, "../priv/static"),
    emptyOutDir: false,
    manifest: false,
    rollupOptions: {
      input: resolve(currentDirectory, "preview-sw.ts"),
      output: { entryFileNames: "preview-sw.js", format: "iife" },
    },
  },
});
```

- [ ] **Step 2: Add the build scripts**

In `fiddle/assets/package.json`, change `build` and add `build:sw`:

```json
    "build": "vite build && pnpm run build:sw",
    "build:sw": "vite build --config vite.sw.config.ts",
```

- [ ] **Step 3: Build the worker and verify the artifact**

Run: `mise exec -- pnpm -C fiddle/assets build:sw`
Then: `ls -l fiddle/priv/static/preview-sw.js`
Expected: the file exists and contains the bundled worker (grep for `preview-meta`):
Run: `grep -c "preview-meta" fiddle/priv/static/preview-sw.js` → Expected: `>= 1`.

- [ ] **Step 4: Whitelist it for Plug.Static**

In `fiddle/lib/image_pipe_fiddle_web.ex`, line 20:

```elixir
  def static_paths, do: ~w(assets images preview-sw.js)
```

- [ ] **Step 5: Verify it is served from root with a JS content-type**

Start the server (`mise run server` from the worktree root, in the background), then:

Run: `curl -s -D - -o /dev/null http://localhost:4000/preview-sw.js | grep -i "content-type\|^HTTP"`
Expected: `HTTP/1.1 200 OK` and `content-type: text/javascript` (or `application/javascript`).
Stop the server afterward.

- [ ] **Step 6: Treat the artifact as generated — gitignore it and build it in `setup`**

`priv/static/preview-sw.js` is build output (like `priv/static/assets/` and `.vite/`, which are already ignored). It is currently **NOT** ignored (`git check-ignore fiddle/priv/static/preview-sw.js` → not matched), and the repo tracks only the sample `priv/static/images/*` — no built JS. So: ignore the artifact and ensure `setup` produces it.

Add to `fiddle/.gitignore` (next to the existing `/priv/static/assets/` and `/priv/static/.vite/` lines):

```gitignore
/priv/static/preview-sw.js
```

Then ensure `setup` builds it. **There is no `fiddle/mise.toml`** — edit the repo-root `mise.toml` `[tasks.setup]` (currently runs `mix deps.get` ×2 + `pnpm -C fiddle install --frozen-lockfile`, no asset build). Append a worker-build step:

```toml
  "pnpm -C fiddle/assets run build:sw",
```

(Use `-C fiddle/assets`, matching where the script lives — `setup`'s existing `pnpm -C fiddle install` targets a different dir.) This guarantees `priv/static/preview-sw.js` exists before `mix phx.server`. The `precommit:fiddle` gate already runs `pnpm -C fiddle/assets run build` last (now chained to `build:sw`), so the gate regenerates it too; confirm no `cd fiddle && mix test` in that gate asserts the worker is served (Task 7's checks are browser-manual, so this holds).

Add a one-line note to `fiddle/docs/preview-service-worker-sketch.md`: editing `preview-sw.ts` requires re-running `build:sw` + a browser reload (it is not hot-reloaded).

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/vite.sw.config.ts fiddle/assets/package.json \
        fiddle/lib/image_pipe_fiddle_web.ex fiddle/.gitignore mise.toml \
        fiddle/docs/preview-service-worker-sketch.md
git commit -m "build(fiddle): bundle preview-sw and serve it from Phoenix root"
```

> Do not `git add fiddle/priv/static/preview-sw.js` — it is now gitignored and regenerated by `build:sw`/`setup`.

---

### Task 6: Wire the preview into `App.svelte`

Replace the `fetch`-based preview with `<img src>` + `onload`/`onerror`, register the worker in `onMount`, and route SW messages + dimensions through `PreviewMetadataTracker`. The `<img>` swap is what fixes the decode bug; the tracker restores the metadata panel.

**Files:**
- Modify: `fiddle/assets/App.svelte`

- [ ] **Step 1: Imports + state**

Add to the `processing-path`-adjacent imports:

```ts
  import { PreviewMetadataTracker, registerPreviewWorker, type PreviewWorker } from "./preview-bridge";
```

Replace the preview state block (current lines ~53-56, 68-69, 90) so it reads:

```ts
  let previewImageUrl: string | null = $state(null);
  let previewLoading = $state(true);
  let previewError: string | null = $state(null);
  let processedMetadata: ProcessedImageMetadata | null = $state(null);
```

Remove `activePreviewObjectUrl`, `previewAbortController`, and the `previewAcceptHeader` constant. Add non-reactive bookkeeping near the other internal locals:

```ts
  const previewMetadata = new PreviewMetadataTracker();
  let previewWorker: PreviewWorker | null = null;
  let previewWorkerDisposed = false; // guards the register-promise-vs-unmount race
  let currentRequestId = 0;
  let lastPreviewAbsolute: string | null = null; // dedupe on resolved URL, not raw path
```

- [ ] **Step 2: Replace `loadPreview` and delete the old helpers**

Delete `loadPreview`, `imageDimensions`, `revokePreviewObjectUrl`, `previewErrorFromResponse`, and `previewErrorMessage` (current lines ~239-346). Replace `updatePreviewPath`'s body so it drives the `<img>` instead of fetching:

```ts
  const updatePreviewPath = debounce((nextPath: string) => {
    const absolute = new URL(nextPath, window.location.origin).href;
    // Dedupe on the RESOLVED url (not the raw path): a no-op must never flip
    // previewLoading=true without a following <img> load event, or the spinner
    // would strand. This same absolute is the SW-message correlation key.
    if (absolute === lastPreviewAbsolute) return;
    lastPreviewAbsolute = absolute;
    previewPath = nextPath;
    currentRequestId = previewMetadata.begin(absolute);
    previewLoading = true;
    previewError = null;
    processedMetadata = null;
    previewImageUrl = nextPath; // same-origin → <img> triggers the real, SW-intercepted request
  }, 150);
```

Add the `<img>` event handlers and a SW-message sink:

```ts
  function onPreviewLoaded(image: HTMLImageElement): void {
    previewMetadata.applyDimensions({ width: image.naturalWidth, height: image.naturalHeight }, currentRequestId);
    processedMetadata = previewMetadata.metadata;
    previewError = previewMetadata.error;
    previewLoading = false;
  }

  function onPreviewError(): void {
    // <img> gives no detail; if the SW already reported an error for this request, show it.
    previewError = previewMetadata.error ?? "Preview request failed";
    processedMetadata = null;
    previewLoading = false;
  }
```

- [ ] **Step 3: Register the worker in `onMount`; clean up**

Inside the existing `onMount` (after `restoreStateFromLocation()`), add:

```ts
    void registerPreviewWorker((message) => {
      previewMetadata.applyMessage(message, currentRequestId);
      // Reflect late-arriving bytes/contentType (and SW-reported errors) into the UI.
      if (previewMetadata.metadata !== null) processedMetadata = previewMetadata.metadata;
      if (previewMetadata.error !== null) {
        previewError = previewMetadata.error;
        processedMetadata = null;
        previewLoading = false; // an SW error may arrive before the <img> error event
      }
    }).then((worker) => {
      // If the component already unmounted while register/ready was awaiting, the
      // cleanup ran with previewWorker still null and could not unsubscribe — do it
      // here so the global navigator.serviceWorker listener can't leak across HMR.
      if (previewWorkerDisposed) {
        worker.unsubscribe();
        return;
      }
      previewWorker = worker;
    });
```

Update the `onMount` cleanup return to drop `previewAbortController?.abort()` and `revokePreviewObjectUrl()`, set `previewWorkerDisposed = true`, and call `previewWorker?.unsubscribe()`.

- [ ] **Step 4: Update the markup**

Replace the preview `<img>` (current lines ~655-661):

```svelte
          {#if previewImageUrl !== null}
            <img
              class:is-loading={previewLoading}
              src={previewImageUrl}
              alt="Processed sample source"
              onload={(event) => onPreviewLoaded(event.currentTarget)}
              onerror={onPreviewError}
            />
          {/if}
```

- [ ] **Step 5: Remove now-dead code**

Run: `mise exec -- pnpm -C fiddle/assets check`
Resolve every "unused" / "not found" error by deleting the dead symbol (e.g. leftover `metadataRequestId` if fully replaced by `currentRequestId`, `imageRequestBytesFromPerformance` if now unreferenced anywhere — grep first: `grep -rn imageRequestBytesFromPerformance fiddle/assets`). Remove cleanly per project guidelines (no narrating comments).

**Keep `pathRequestId`** — it guards `updateProcessingPath`'s async imgproxy signing (App.svelte ~lines 115, 215) and is unrelated to the preview-metadata flow. Only `metadataRequestId` is replaced by `currentRequestId`; do not let the grep sweep up `pathRequestId`.

Expected: `check` PASS with no unused-symbol diagnostics.

- [ ] **Step 6: Lint + format + unit tests**

Run: `mise exec -- pnpm -C fiddle/assets lint`
Run: `mise exec -- pnpm -C fiddle/assets format:check`
Run: `mise exec -- pnpm -C fiddle/assets test`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/App.svelte
git commit -m "feat(fiddle): render preview via <img> + service-worker metadata"
```

---

### Task 7: End-to-end verification across all three dialects

The SW event wiring and the cross-origin/scope assumptions can only be confirmed in a real browser. This task has no unit test; it is a manual gate plus the repo verify suite.

**Files:** none (verification only).

- [ ] **Step 1: Build assets + run the verify gate**

Run: `mise run precommit:fiddle`
Expected: Elixir gate + fiddle JS test/check/lint/format/build all green. (If a fresh worktree, `mise trust` + `mise exec -- mix deps.get` + `pnpm -C fiddle/assets install` first; the verify suite needs the Vite manifest — `pnpm -C fiddle/assets build` — and now also `preview-sw.js`.)

- [ ] **Step 2: Start the server**

Run (worktree root): `mise run server` (background). Open `http://localhost:4000` in Chrome.

- [ ] **Step 3: Confirm the worker controls the page**

On the **very first** load after a clean install, the worker registers but may not control the page until `clients.claim()` completes — so the first auto-preview can render without SW interception (image fine, metadata blank). **Reload once**, then verify in DevTools → Application → Service Workers that `preview-sw.js` is activated and controlling, and in Network the `/img…` request shows `(ServiceWorker)` and `content-type: image/avif` (or webp) — **not** `image/jxl`. No "Preview image could not be decoded".

- [ ] **Step 4: Exercise each dialect (including TwicPics URL-encoding correlation)**

For imgproxy, IIIF, and TwicPics tabs in turn, with Format left on **auto**:
- The preview renders.
- The metadata line shows a **real byte size** and the format label resolves (`auto → avif`/`webp`), sourced from the SW message.
- Network shows the negotiated content-type matches the label and is browser-decodable.

Pay special attention to **TwicPics**: its URL carries a `?twic=v1/cover=…` query with `=`/`/` characters. The page correlates SW messages by the full absolute URL (`new URL(path, origin).href`) against the worker's `request.url`; if the browser normalizes/encodes the query differently on the two sides, the match fails and **bytes/content-type stay blank while the image still renders**. So confirm TwicPics specifically *populates* the byte size — a blank size with a rendered image is the signature of a URL-encoding skew, and the fix is to normalize both sides through `new URL(...).href` (the worker's `request.url` is already normalized; ensure the page key is too).

- [ ] **Step 5: Confirm the underlying fix is robust without the SW**

In DevTools → Application → Service Workers, Unregister, then hard-reload. The preview must **still render** in all three dialects (the `<img>` sends the real Accept regardless) — only the byte size / content-type label goes blank. This proves the decode fix does not depend on the worker.

- [ ] **Step 6: Error path**

Force a bad request (e.g. an invalid imgproxy option, or signed mode with a wrong key) and confirm the preview area shows a status-bearing error message (from the SW error snippet, or the generic fallback if the SW is unavailable). Stop the server.

- [ ] **Step 7: Commit any doc updates**

If Step 3-6 surfaced wording fixes for `fiddle/docs/preview-service-worker-sketch.md`, apply and commit them.

```bash
git add fiddle/docs/preview-service-worker-sketch.md
git commit -m "docs(fiddle): note verified SW preview behavior"
```

---

## Self-review notes

- **Spec coverage:** all-three-dialects → Task 1 predicate + Task 7 Steps 4-5; real Accept → Task 6 `<img>` swap; metadata recovery → Tasks 2-4; same-origin/root-scope serving → Task 5; dev-only (no prod split) → Task 5 (Phoenix-served, one-shot build) + Task 7 (manual gate). 
- **Decode fix vs. metadata are decoupled** (Task 7 Step 5 proves it) — the SW is additive, so SW-absent/registration-failure degrades to "works, no metadata", never to the original bug.
- **Type consistency:** `PreviewMetaMessage`, `PreviewMetadataTracker.{begin,applyDimensions,applyMessage,metadata,error}`, `registerPreviewWorker`, `PREVIEW_WORKER_URL`, `PREVIEW_PREFIXES` are used with identical signatures across Tasks 1-6. `ProcessedImageMetadata` is the existing `{width,height,bytes,contentType}` from `processing-path.ts`.
## Review cycle (applied)

Three disjoint-lens reviewers (SW/browser-platform, Svelte reactivity/race, build/serving) ran against the first draft. Accepted and folded in:

- **[BLOCKER, SW lens] `event.clientId` may be empty for `<img>` subresource fetches** → metadata silently lost. Fixed: `postToClient` falls back from `clients.get(clientId)` to a `matchAll({type:"window"})` broadcast; the page's full-URL + request-id guard makes broadcast safe (Task 4).
- **[BLOCKER, build lens] `tsconfig` `WebWorker` lib would conflict with `DOM` project-wide** → separate `tsconfig.sw.json` + exclude the worker from the DOM project + dual `check` (Task 4 Step 2).
- **[BLOCKER, build lens] git/`mise` facts wrong:** `/priv/static/preview-sw.js` is not gitignored, and `fiddle/mise.toml` does not exist → gitignore the artifact + build it via the **root** `mise.toml` `setup` (Task 5 Step 6).
- **[SHOULD, Svelte lens] SW error before the `<img>` event leaves the spinner spinning** → clear `previewLoading` in the message-error branch (Task 6 Step 3).
- **[SHOULD, Svelte lens] listener leak on unmount-before-register-resolves (HMR)** → `previewWorkerDisposed` guard (Task 6 Steps 1, 3).
- **[SHOULD, SW lens] TwicPics URL-encoding skew** could blank metadata → explicit populate-check + absolute-URL dedupe key (Task 6 Step 2, Task 7 Step 4).

Considered and **downgraded** (with reasoning, not silently dropped):

- **[BLOCKER→non-blocker, Svelte lens] "stuck spinner from a string-distinct path resolving to the same `src`":** `previewImageUrl === nextPath === previewPath` always holds, and the top-of-function guard means any `nextPath` that passes always changes the `<img src>`, which always fires `onload`/`onerror`. The described state is unreachable. Adopted the absolute-URL dedupe anyway (it's cheap and also fixes the TwicPics correlation key).
- **[SHOULD→accepted-minor, SW lens] first-load re-kick:** forcing a re-request is fragile (HTTP cache means re-assigning the same `src` won't refetch). Kept "first auto-preview may lack metadata until the next interaction" as acceptable and made Task 7 Step 3 reload once before asserting interception.

## Open risks

- First auto-preview on a brand-new registration lacks SW metadata until the page is controlled (image still renders correctly). Accepted; Task 7 Step 3 reloads once.
- `tsgo` must accept two sequential `--project` invocations in `check` — verified shape in Task 4; if `tsgo` lacks `--project`, fall back to `tsc -p`.
