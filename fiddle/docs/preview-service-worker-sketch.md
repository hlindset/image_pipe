# Fiddle preview via Service Worker — design sketch

## Problem (recap)

The preview pane drives image loading with `fetch()` ([App.svelte:252](../assets/App.svelte)),
sending a hardcoded `previewAcceptHeader` ([App.svelte:90](../assets/App.svelte)) that contains
`image/*`. After JXL output landed, the negotiator (`@modern_formats = [jpeg_xl, avif, webp]`)
matches `image/jxl` against that `image/*` wildcard and serves **JXL**, which the browser cannot
decode in the `imageDimensions()` `<img>` probe → "Preview image could not be decoded". Opening the
URL directly works because a real navigation sends no `image/*`, so AVIF is negotiated.

**Root cause:** the preview guesses the browser's `Accept` header instead of using the real one.
There is no JS API to read the browser's native image `Accept`; only the browser, when *it* issues
an image request, attaches it.

## Goal

Make the preview negotiate exactly as the user's browser would, **and** keep the metadata panel
(byte size, content-type/format label) that the `fetch` approach currently provides — which a bare
`<img>` swap would lose.

## Why a Service Worker solves both

1. The page loads the preview as a real `<img src={previewPath}>`. The browser builds the request
   with its **true** image `Accept` header.
2. A Service Worker intercepts that request (`fetch` event). It can:
   - **Read the real `Accept`** — `event.request.headers.get("accept")`. `Accept` is CORS-safelisted,
     and `/img` is same-origin, so it's fully readable.
   - **Forward the request unchanged** — `fetch(event.request)` preserves the real `Accept`, so the
     server negotiates a format the browser can decode. Decode error becomes structurally impossible.
   - **Read the response** — same-origin, so content-type header + body bytes are fully readable.
   - **Report back** — `postMessage` the `{accept, contentType, bytes}` to the page for the panel.

Net: `<img>` gives correct rendering + dimensions; the SW recovers `bytes` + `contentType` (and, as a
bonus demo feature, the actual `Accept` string).

## Data flow

```
controls change
  → buildProcessingPath(state)  (unchanged)
  → previewPath
  → <img src={previewPath}>                      [browser attaches real Accept]
      → SW fetch event
          → accept = request.headers.get("accept")
          → res = await fetch(request)           [real Accept forwarded → decodable format]
          → blob = await res.clone().blob()
          → client.postMessage({url, accept, contentType, bytes})   [via matched clientId]
          → return res                            [<img> renders it]
      → img.onload  → naturalWidth/Height → dimensions
      → page message handler → bytes + contentType → processedMetadata
```

`processedMetadata = { width, height, bytes, contentType }` is reassembled from two sources:
- `width`/`height` from `<img>.onload` (same as today's `imageDimensions`).
- `bytes`/`contentType` from the SW `postMessage`.

Correlate the two by `previewPath` + a monotonic request id (reuse the existing
`metadataRequestId` guard) so a stale SW message can't clobber a newer preview.

## Files

### New

- `fiddle/assets/preview-sw.ts` — the worker. Built by Vite as a **separate entry** so it lands at a
  predictable, root-scoped URL (see Scope below). Keep it tiny and dependency-free.

### Changed

- `fiddle/assets/App.svelte`
  - Delete `previewAcceptHeader`, `loadPreview`'s fetch/blob/objectURL path, `imageDimensions`,
    `revokePreviewObjectUrl`, `activePreviewObjectUrl`, `previewAbortController`.
  - `previewImageUrl` becomes just `previewPath` (no object URL); bind `<img src>` to it directly.
  - Add `<img onload>` (dimensions) + `onerror` (diagnostic-only, see below).
  - Register the SW in `onMount`; gate the *first* preview on the controller being ready.
  - Add a `navigator.serviceWorker` `message` listener → fold `{bytes, contentType}` into
    `processedMetadata` under the request-id guard.
- `fiddle/lib/.../router.ex` (or a Plug) — serve `preview-sw.js` from **root path** with
  `Service-Worker-Allowed: /` and the right content-type. (Scope detail below.)
- `fiddle/assets/vite.config.ts` — add the SW as a build input emitting a stable filename
  (no content hash, or a manifest lookup) so the root route can find it.

## The worker (sketch)

```ts
// preview-sw.ts
/// <reference lib="webworker" />
const sw = self as unknown as ServiceWorkerGlobalScope;

sw.addEventListener("install", () => sw.skipWaiting());
sw.addEventListener("activate", (e) => e.waitUntil(sw.clients.claim()));

// All three processing endpoints negotiate output the same way, so all three hit
// the JXL-via-`image/*` bug and all three need interception. Match on PATHNAME so
// the TwicPics `?twic=…` query is ignored.
const PREVIEW_PREFIXES = ["/img/", "/iiif-image/", "/twic/"];
const isPreview = (url: string) => {
  const { pathname } = new URL(url);
  return PREVIEW_PREFIXES.some((p) => pathname.startsWith(p));
};

sw.addEventListener("fetch", (event: FetchEvent) => {
  if (event.request.method !== "GET" || !isPreview(event.request.url)) return;

  event.respondWith((async () => {
    const accept = event.request.headers.get("accept");
    const response = await fetch(event.request);     // real Accept forwarded
    // Read metadata off a clone so the original stream still reaches <img>.
    void (async () => {
      try {
        const clone = response.clone();
        const buf = await clone.arrayBuffer();
        const client = await sw.clients.get(event.clientId);
        client?.postMessage({
          type: "preview-meta",
          url: event.request.url,
          accept,
          status: response.status,
          contentType: response.headers.get("content-type"),
          bytes: buf.byteLength,
        });
      } catch {
        /* metadata is best-effort; never block the image */
      }
    })();
    return response;
  })());
});
```

Notes:
- `clients.get(event.clientId)` targets the exact page that made the request — no broadcast, no
  cross-tab leakage.
- Reading bytes via `arrayBuffer()` on a clone is simplest; if we'd rather not buffer, read
  `Content-Length` when present and fall back to `imageRequestBytesFromPerformance` on the page.
- Non-2xx still returns to `<img>` (→ `onerror`); we forward `status` so the page can compose an
  error message without a second request when possible.

## Page side (sketch)

```ts
// in onMount
if ("serviceWorker" in navigator) {
  await navigator.serviceWorker.register("/preview-sw.js"); // root scope
  await navigator.serviceWorker.ready;                      // controller active
  navigator.serviceWorker.addEventListener("message", (e) => {
    const m = e.data;
    if (m?.type !== "preview-meta" || m.url !== absolute(previewPath)) return;
    if (currentRequestId !== metadataRequestId) return;     // stale guard
    processedMetadata = { ...processedMetadata, bytes: m.bytes, contentType: m.contentType };
    lastObservedAccept = m.accept;                          // optional: show in UI
  });
}
```

```svelte
{#if previewImageUrl}
  <img
    class:is-loading={previewLoading}
    src={previewImageUrl}
    onload={(e) => onPreviewLoaded(e.currentTarget)}
    onerror={() => onPreviewError()}
  />
{/if}
```

`onPreviewLoaded` sets `width/height` + clears loading; the message handler fills `bytes/contentType`.
The panel's format label (`resolvedOutputLabel` → `outputFormatFromContentType`) keeps working because
`contentType` still arrives — just from the SW instead of the fetch response.

Correlation key is the **full URL including query string** (`absolute(previewPath)` vs the SW's
`event.request.url`). This matters for TwicPics, whose `twicFetchPath` is `/twic/<src>?twic=<params>` —
two previews can share a pathname and differ only in the query, so a path-only match would mis-correlate
metadata. imgproxy/IIIF are path-only, so the full-URL key is a strict superset that just works.

## Topology — this is a dev-only app (the only mode)

There is no prod build to lean on. The fiddle runs as:

- **Page + `/img`** — Phoenix `mix phx.server` on `:4000`. The user navigates here; `<img src="/img/…">`
  is same-origin to `:4000`.
- **JS/CSS** — a **Vite dev server on `:5173`** (a Phoenix `:vite` watcher, `static_url` → `:5173`,
  via `PhoenixVite`). App scripts are loaded cross-origin from `:5173`.

**Load-bearing consequence:** a Service Worker script must be **same-origin with the registering page**
(`:4000`). So the SW *cannot* be a Vite-served module from `:5173` — Phoenix must serve it from `:4000`.
This is fine: the registration call runs in the `:4000` document context, so
`navigator.serviceWorker.register("/preview-sw.js")` resolves against `:4000` regardless of where the
*calling* script's bytes came from.

## Scope — simpler than it looks

A SW's default scope is the directory it's served from. Serve it from **root** (`/preview-sw.js`) and
the default scope is `/`, which already covers `/img/*` — **no `Service-Worker-Allowed` header needed**
(that header is only required when serving from a subdirectory but wanting a broader scope). One small
Phoenix route returning the file with `content-type: text/javascript` is all it takes.

Keep the `fetch` predicate **narrow — the three processing prefixes only** (`/img/`, `/iiif-image/`,
`/twic/`; match on pathname so the TwicPics `?twic=…` query is ignored). The SW then never touches Vite
assets (`:5173` is a different origin anyway), the HMR websocket, the SPA shell, or Phoenix
`live_reload`. And it uses **no Cache API** (live demo), so none of the classic SW stale-cache dev pain
applies.

All three endpoints (`ImagePipeFiddleWeb.{Imgproxy,IIIF,TwicPics}`, routed at those prefixes) run the
same `Plan.Output` negotiation, so a single interceptor fixes all three uniformly — there is no
per-dialect branching in the worker. `/twicpics/` (`twicBrowserPath`, the display/copy link) is not a
real route and is never fetched by the preview, so it is deliberately excluded.

## Lifecycle / first-load race

`skipWaiting()` + `clients.claim()` lets a freshly installed worker take control without a manual
reload, but the **very first** page load races: the `<img>` may fire before the controller is active.
Handle it explicitly:

- `await navigator.serviceWorker.ready` before issuing the first `previewPath`, **or**
- if `navigator.serviceWorker.controller == null` on mount, hold the first preview until a
  `controllerchange` event, then proceed.

Subsequent control + preview changes are uneventful.

## Authoring + serving the worker

Because the SW lives outside the Vite module graph (it's not UI, has no imports, does no caching), it
doesn't need HMR and shouldn't be dragged into the dev-server graph. Two ways to produce it; both serve
the result from Phoenix at `:4000`:

- **Plain JS, zero build (simplest):** commit `priv/static/preview-sw.js` (~30 lines, hand-written) and
  serve it via a Phoenix route at `/preview-sw.js`. No esbuild, no Vite, no watcher. Editing it is a
  manual reload to re-register — fine for a file that rarely changes.
- **TS + one-shot esbuild:** author `assets/preview-sw.ts`, add a tiny standalone esbuild step (a new
  `pnpm` script) that emits `priv/static/preview-sw.js`. Buys TS types; costs a build step run at
  setup / on change. Not part of the Vite dev server.

Recommendation: **plain JS** to start — the worker is small and DOM-less, and avoiding a second build
toolchain keeps the dev-only app simple. Promote to TS+esbuild only if the worker grows.

> Implementation note: the worker ships as TS built one-shot by `vite.sw.config.ts` (`pnpm build:sw`) into
> `priv/static/preview-sw.js`. It is **not** hot-reloaded — after editing `preview-sw.ts`, re-run
> `build:sw` and reload the browser (hard-reload to pick up the new worker bytes).

Note the Vite dev server doesn't write assets to disk, so the worker must NOT be expected to appear in
`priv/static` *via Vite* — it's an independently served file either way.

## Failure modes / fallbacks

- **No SW support / registration fails:** fall back to bare `<img>` (correct render + dimensions, no
  content-type; bytes via Resource Timing). The feature degrades, never breaks.
- **Cross-origin sources:** N/A today (fiddle `/img` is same-origin). If a future remote source is
  proxied through `/img` it stays same-origin to the SW; a *direct* cross-origin `<img>` would give an
  opaque response and no readable metadata — out of scope.
- **Caching:** the worker must not cache (it's a live demo). It only reads + forwards; no Cache API.
- **Errors:** `<img>.onerror` has no status/body. The SW forwards `status`; for a full message body,
  optionally do a one-off diagnostic `fetch` *on error only* (slow path, fidelity not required).

## Testing

- Unit (page): message-handler request-id guard drops stale/foreign-URL messages; `onload` sets
  dimensions; fallback path when `serviceWorker` is absent. (Vitest, mock `navigator.serviceWorker`.)
- The SW's `fetch` handler logic (predicate, clientId targeting) is plain functions — unit-test the
  pure parts; the event wiring is integration-only.
- Manual/e2e: load preview in Chrome + Firefox, confirm content-type label shows `avif`/`webp` (not
  `jxl`), confirm the displayed `Accept` matches DevTools' Network tab for the `/img` request.
- Keep the existing `fiddle-url-state` / `processing-path` tests green (path building is unchanged).

## Open questions

1. Worth surfacing the observed `Accept` in the UI as a demo feature, or keep it internal?
2. Worker authoring: plain committed JS vs TS + one-shot esbuild (recommendation: plain JS to start).
3. Byte size: buffer in the SW (`arrayBuffer`) vs `Content-Length`/Resource Timing — buffering is
   simplest and the demo payloads are small; fine to start.

## Effort / verdict

Heaviest of the three options (vs. bare `<img>` + Resource Timing, or just dropping `image/*` from the
hardcoded header). Justified only if "faithful, real-browser negotiation **with** full metadata" — and
optionally showing the real `Accept` — is a feature we want the fiddle to have. Otherwise the
`image/*` removal is a one-liner and bare `<img>` is a small refactor.
