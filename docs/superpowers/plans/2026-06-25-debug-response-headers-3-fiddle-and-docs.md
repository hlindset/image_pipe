# Debug Response Headers — Plan 3: Fiddle Consumption + Operator/Catalogue Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the already-shipped `X-ImagePipe-*` + `Server-Timing` debug headers in the fiddle demo UI (read by its service worker, against debug-enabled mounts), and write the user-facing operator guide + header-catalogue reference. No library behavior changes.

**Architecture:** The fiddle's service worker (`preview-sw.ts`) already intercepts every preview image request and reports response metadata to the page over `postMessage`. We extend that pipe to also carry the `X-ImagePipe-*` headers and `Server-Timing`, validate them at the existing boundary parser, parse them into display groups with a new pure module, thread them through the metadata tracker, and render them in a collapsible debug panel. The three fiddle mounts gain `allow_debug_headers: true`, and the preview `<img>` request gains a `_debug=1` query param (preview-only — the copyable/"Open" URL stays clean). Docs land as a new `docs/debug_headers.md` (operator guide + full catalogue) registered in ExDoc, plus a pointer from `docs/operational_notes.md`.

**Tech Stack:** Svelte 5 (runes), TypeScript, Vitest, Vite (dual config: app + service worker), Elixir/Plug (fiddle mount config), ExDoc.

**Spec:** `docs/superpowers/specs/2026-06-25-debug-response-headers-design.md` (esp. *Fiddle consumption* and *Docs updates*).

**Depends on:** Plan 1 (`…-1-boundary-and-miss-path.md`, PR #392/#395) and Plan 2 (`…-2-cache-hybrid.md`, PR #396), both merged to `main`. **Resolves:** issue #394.

---

## Scope of Plan 3

In scope:
- Fiddle mounts: `allow_debug_headers: true` on all three (`/img`, `/iiif-image`, `/twic`).
- Fiddle preview request: append `_debug=1` to the `<img>` request only.
- Service worker: extract `X-ImagePipe-*` + `Server-Timing` from the fetched response.
- Boundary parsing: validate the new header record in `parsePreviewMeta`.
- A new pure `debug-headers.ts` module that turns the raw header record (+ output byte length) into ordered display groups, deriving the compression ratio from `X-ImagePipe-Source-Size ÷ body length`.
- Tracker threading + a collapsible `DebugInfoPanel.svelte` rendered under the preview.
- Docs: new `docs/debug_headers.md` (operator guide + header catalogue + accurate signed-URL safety note + disclosure list + fiddle note), registered in `mix.exs` (ExDoc extras + package files); a pointer from `docs/operational_notes.md`.
- A flagged library follow-up (out of scope here) for the signed-URL gap — see *Out of scope* and Task F3.

Out of scope:
- Any library behavior change (no `lib/image_pipe/**` edits except none — all library code shipped in Plans 1/2).
- **Library follow-up #N (signing gap):** making `_debug` a *signed* trigger (path segment, or signature-over-query) so imgproxy's own HMAC covers it. The docs here accurately describe the *current* posture (`_debug` is a query param, not covered by imgproxy path signatures); the fix is a separate issue created in Task F3.

---

## Key facts verified against the merged code (read before implementing)

These were confirmed against `main` @ `2a6aa4c4`; treat them as ground truth and do **not** re-derive from the spec, which has stale examples.

1. **Header names + units are owned by `lib/image_pipe/debug/headers.ex`.** That module is the single source of truth. The docs and the fiddle parser must match it exactly. The full surface is reproduced in the catalogue (Task E1) — cross-check it against the file when implementing.
2. **`Server-Timing` stages are `[:decode, :transform, :encode, :cache, :total]`** (`@stage_order` in `headers.ex`). There is **no `fetch` stage** — fetch is folded into `decode`. The spec's `Server-Timing: fetch;dur=12, …` example is **stale**; docs must list decode/transform/encode/(cache on hit)/total.
3. **Durations render in milliseconds**, rounded to 3 decimals (`ms(us) = Float.round(us / 1000, 3)`), e.g. `decode;dur=8.123`. Not microseconds.
4. **`X-ImagePipe-Cache-Key` is the 64-char sha256 hex** (`Cache.Key` hash). Long — render monospace/truncatable.
5. **`X-ImagePipe-Output-Quality` may be the literal string `default`** — the sentinel meaning ImagePipe set no quality and the encoder default applied. The fiddle parser must render non-numeric quality values verbatim (do not coerce to a number).
6. **`X-ImagePipe-Output-Accept` can be long** and is emitted as-is. The fiddle should render it but allow it to wrap/truncate.
7. **`_debug=1` is a reserved query param**, read from `conn.query_params` ([plug.ex:265-269](../../lib/image_pipe/plug.ex)). It is **not stripped**, is ignored by every dialect parser, and is excluded from the cache key + ETag — so it never changes the produced image bytes. It is honored only when `allow_debug_headers: true`.
8. **Signed-URL caveat (drives the docs):** imgproxy's signature covers the request **path only** (`Path.extract/1` → `parser_request_path/1` = `conn.request_path`, [path.ex:212](../../lib/image_pipe/parser/imgproxy/path.ex); [signature.ex:42](../../lib/image_pipe/parser/imgproxy/signature.ex)). The `_debug` query param is therefore **not** covered by imgproxy's own HMAC. The operator docs must say so accurately (Task E1) and must not claim imgproxy path signing protects `_debug`.
9. **Fiddle SW already reads response headers** (`response.headers.get("content-type")`) and the requests are **same-origin** (Phoenix at `:4000`), so all `X-ImagePipe-*` headers are readable with no `Access-Control-Expose-Headers` needed.

---

## File Structure

**Create:**
- `fiddle/assets/debug-headers.ts` — pure: raw header record (+ output byte length) → ordered `DebugGroup[]`, deriving the compression ratio. The tested core.
- `fiddle/assets/debug-headers.test.ts` — Vitest unit tests for the parser.
- `fiddle/assets/DebugInfoPanel.svelte` — dumb presentational component rendering `DebugGroup[]` in a collapsible panel.
- `docs/debug_headers.md` — operator guide + header catalogue + signed-URL safety note + disclosure list + fiddle note.

**Modify (fiddle):**
- `fiddle/lib/image_pipe_fiddle/application.ex` — `allow_debug_headers: true` on all three mounts.
- `fiddle/assets/preview-intercept.ts` — `extractDebugHeaders/1`, extend `PreviewMetaMessage` + `parsePreviewMeta`.
- `fiddle/assets/preview-intercept.test.ts` — cover the new extraction + validation.
- `fiddle/assets/preview-sw.ts` — emit the extracted headers in the metadata message.
- `fiddle/assets/preview-bridge.ts` — thread `debugHeaders` onto `ProcessedImageMetadata`.
- `fiddle/assets/preview-bridge.test.ts` — update the exact `toEqual` metadata assertions for the new field.
- `fiddle/assets/processing-path.ts` — add `debugHeaders` to the `ProcessedImageMetadata` type.
- `fiddle/assets/App.svelte` — append `_debug=1` to the preview request; derive + render the debug panel.

**Modify (docs):**
- `docs/operational_notes.md` — short pointer to `docs/debug_headers.md` (signature-section adjacent).
- `mix.exs` — register `docs/debug_headers.md` in the ExDoc `extras:` list and the package `files:` list.

---

## Conventions used in this plan

- Run fiddle JS tooling through `mise exec -- pnpm -C fiddle/assets <script>` (repo tool versioning). The scripts are: `test` (Vitest), `check` (two `tsgo` typechecks + `svelte-check`), `format` / `format:check` (oxfmt), `lint` (oxlint), `build` (app + SW).
- **Fresh-worktree setup (do once, before any gate):** `mise trust`, then `mise exec -- pnpm -C fiddle/assets install --frozen-lockfile`, then `mise exec -- pnpm -C fiddle/assets run build` (writes the gitignored Vite manifest the fiddle's `mix test` needs — without it `precommit:fiddle` fails on unrelated page/wire tests). See the repo memory notes *fiddle-precommit-needs-built-assets* and *fresh-worktree-mise-trust*.
- **Do NOT self-preview the fiddle UI** (Preview MCP / browser MCP). It mis-mounts the SPA at a 0×0 viewport and produces false bugs. Gate with the non-visual scripts + `mise run precommit:fiddle`, commit, and let the user verify the look in a real browser. See memory *no-self-preview-for-fiddle-ui*.
- Commit after every green step. Conventional Commits, trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Comment-only / docs-only commits skip the compile/test gate (repo memory *no-verify-on-comment-only*).

---

## Phase A — Fiddle: enable debug emission and trigger it

### Task A1: `allow_debug_headers: true` on all three mounts

The service worker intercepts `/img/`, `/iiif-image/`, and `/twic/` (`PREVIEW_PREFIXES`), so every mount must permit debug headers for the panel to populate regardless of provider.

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex` (`build_imgproxy_opts/0` ~50-66, `build_iiif_opts/0` ~68-84, `build_twicpics_opts/0` ~108-119)

> **Important — keep the pipe tail.** Each `build_*_opts/0` ends the keyword list with `]` **and then pipes it** through `|> maybe_put_cache(...) |> ImagePipe.Plug.init()`. Add `allow_debug_headers: true` as the **last entry inside the `[ ... ]` list** (before the closing `]`); do **not** delete the `maybe_put_cache`/`Plug.init` tail. Each block below shows the full function tail so a literal replacement stays whole.

- [ ] **Step 1: Add the option to the imgproxy mount**

In `build_imgproxy_opts/0`, the list currently ends `detector_required: false\n    ]`. Add the new line and keep the pipe tail:

```elixir
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      imgproxy: imgproxy,
      # Graceful fallback: detection failures degrade to attention crop (200) rather
      # than erroring; the default Logger surfaces any detection fallback.
      detector_required: false,
      # Demo deployment: emit the opt-in X-ImagePipe-* / Server-Timing debug headers.
      # The fiddle adds `_debug=1` to its preview requests so the panel always populates.
      allow_debug_headers: true
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
```

- [ ] **Step 2: Add the option to the IIIF mount**

In `build_iiif_opts/0`, add `allow_debug_headers: true` as the last list entry and keep the pipe tail:

```elixir
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()},
        max_width: 4000,
        max_height: 4000
      ],
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      allow_debug_headers: true
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
```

- [ ] **Step 3: Add the option to the TwicPics mount**

In `build_twicpics_opts/0`, add `allow_debug_headers: true` as the last list entry and keep the pipe tail:

```elixir
    [
      parser: ImagePipe.Parser.TwicPics,
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      allow_debug_headers: true
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
```

- [ ] **Step 4: Compile the fiddle**

Run: `cd fiddle && mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. `allow_debug_headers` is a known `ImagePipe.Request.Options` key (added in Plan 1), so `ImagePipe.Plug.init/1` accepts it. (`Plug.init/1` is what *validates* the option, so a dropped pipe tail would surface here as a confusing failure — confirm the tail survived.)

- [ ] **Step 5: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle/application.ex
git commit -m "feat(fiddle): enable allow_debug_headers on all three mounts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: send `_debug=1` on the preview request only

The preview `<img>` request gets `_debug=1`; the copyable URL and the "Open" link (both derived from `path`, not `previewImageUrl`) stay clean. `_debug` is a reserved query param — it changes nothing about the produced image and is safe across all three dialects.

**Files:**
- Modify: `fiddle/assets/App.svelte` (`updatePreviewPath`, ~77-90)

- [ ] **Step 1: Augment the preview URL with `_debug=1`**

Replace the `updatePreviewPath` debounced callback:

```ts
  const updatePreviewPath = debounce((nextPath: string) => {
    // Request the preview with `_debug=1` so the debug-enabled mounts emit the
    // X-ImagePipe-* + Server-Timing headers the SW reads. `_debug` is a reserved
    // query param (ignored by every dialect parser, excluded from the cache key /
    // ETag), so it changes nothing about the produced image. It rides ONLY the
    // preview <img> request — the copyable / "Open" URL (`path`) stays clean.
    const debugUrl = new URL(nextPath, window.location.origin);
    debugUrl.searchParams.set("_debug", "1");
    const absolute = debugUrl.href;
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
    previewImageUrl = absolute; // same-origin → <img> triggers the real, SW-intercepted request (with _debug=1)
  }, 150);
```

(The only behavioral changes vs. the current code: `absolute` now carries `_debug=1`, and `previewImageUrl` is set to `absolute` instead of the raw `nextPath` so the `<img>` request and the SW correlation key are byte-identical. `previewMetadata.begin(absolute)` already used the resolved URL; the TwicPics `?twic=…` query is preserved because `URL.searchParams.set` appends `&_debug=1`.)

- [ ] **Step 2: Typecheck (no Vitest yet — App.svelte is gate-verified, not unit-tested)**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: clean (`tsgo` ×2 + `svelte-check`).

- [ ] **Step 3: Commit**

```bash
git add fiddle/assets/App.svelte
git commit -m "feat(fiddle): request previews with _debug=1 (preview-only, URL stays clean)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase B — Fiddle: service worker reads the headers (boundary + extraction)

### Task B1: `extractDebugHeaders/1` + extend the message contract

`postMessage` data is untrusted (any page script can post), so the new header record is validated at the existing boundary parser, mirroring how every other optional field is coerced to a safe default.

**Files:**
- Modify: `fiddle/assets/preview-intercept.ts`
- Test: `fiddle/assets/preview-intercept.test.ts`

- [ ] **Step 1: Write the failing tests**

Add to `fiddle/assets/preview-intercept.test.ts`:

```ts
import { isPreviewUrl, parsePreviewMeta, PREVIEW_PREFIXES, extractDebugHeaders } from "./preview-intercept";

describe("extractDebugHeaders", () => {
  it("collects X-ImagePipe-* headers and Server-Timing, lowercased, ignoring others", () => {
    const headers = new Headers({
      "content-type": "image/avif",
      "x-imagepipe-source-format": "jpeg",
      "X-ImagePipe-Output-Format": "avif",
      "server-timing": "decode;dur=8.1, total;dur=181.0",
      "cache-control": "public",
    });

    expect(extractDebugHeaders(headers)).toEqual({
      "x-imagepipe-source-format": "jpeg",
      "x-imagepipe-output-format": "avif",
      "server-timing": "decode;dur=8.1, total;dur=181.0",
    });
  });

  it("returns null when no debug headers are present", () => {
    expect(extractDebugHeaders(new Headers({ "content-type": "image/png" }))).toBeNull();
  });
});

describe("parsePreviewMeta debugHeaders", () => {
  it("accepts a string→string record and drops non-string values", () => {
    const message = parsePreviewMeta({
      type: "preview-meta",
      url: "http://x/img/y",
      debugHeaders: { "x-imagepipe-cache": "hit", "x-imagepipe-source-width": 4000, bad: null },
    });
    expect(message?.debugHeaders).toEqual({ "x-imagepipe-cache": "hit" });
  });

  it("coerces a missing or non-object debugHeaders to null", () => {
    expect(parsePreviewMeta({ type: "preview-meta", url: "http://x/img/y" })?.debugHeaders).toBeNull();
    expect(
      parsePreviewMeta({ type: "preview-meta", url: "http://x/img/y", debugHeaders: "nope" })
        ?.debugHeaders,
    ).toBeNull();
    expect(
      parsePreviewMeta({ type: "preview-meta", url: "http://x/img/y", debugHeaders: {} })
        ?.debugHeaders,
    ).toBeNull();
  });
});
```

(Also update the existing `parsePreviewMeta` "coerces missing/wrong-typed optional fields" test's `toEqual` to include `debugHeaders: null` — see Step 3.)

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: FAIL — `extractDebugHeaders` not exported; `debugHeaders` missing from parsed message.

- [ ] **Step 3: Implement**

In `fiddle/assets/preview-intercept.ts`:

Add the extractor (pure; `Headers` iteration yields lowercased names per the Fetch spec):

```ts
// Collect the opt-in debug headers (X-ImagePipe-* + standard Server-Timing) off a
// response. Returns null when none are present so the message stays compact.
export function extractDebugHeaders(headers: Headers): Record<string, string> | null {
  const out: Record<string, string> = {};
  for (const [name, value] of headers) {
    if (name.startsWith("x-imagepipe-") || name === "server-timing") out[name] = value;
  }
  return Object.keys(out).length > 0 ? out : null;
}
```

Extend the message type with the new field:

```ts
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
  debugHeaders: Record<string, string> | null;
};
```

Add a boundary validator and wire it into `parsePreviewMeta`:

```ts
export function parsePreviewMeta(data: unknown): PreviewMetaMessage | null {
  if (typeof data !== "object" || data === null) return null;
  const m = data as Record<string, unknown>;
  if (m.type !== "preview-meta" || typeof m.url !== "string") return null;
  return {
    type: "preview-meta",
    url: m.url,
    accept: typeof m.accept === "string" ? m.accept : null,
    ok: m.ok === true,
    status: typeof m.status === "number" && Number.isFinite(m.status) ? m.status : 0,
    statusText: typeof m.statusText === "string" ? m.statusText : "",
    contentType: typeof m.contentType === "string" ? m.contentType : null,
    bytes: typeof m.bytes === "number" && Number.isFinite(m.bytes) ? m.bytes : null,
    error: typeof m.error === "string" ? m.error : null,
    debugHeaders: parseDebugHeaderRecord(m.debugHeaders),
  };
}

// Untrusted postMessage record: keep only string→string entries; null if empty.
function parseDebugHeaderRecord(value: unknown): Record<string, string> | null {
  if (typeof value !== "object" || value === null) return null;
  const out: Record<string, string> = {};
  for (const [name, raw] of Object.entries(value as Record<string, unknown>)) {
    if (typeof raw === "string") out[name] = raw;
  }
  return Object.keys(out).length > 0 ? out : null;
}
```

Then update the existing test that asserts the full coerced shape (the "coerces missing/wrong-typed optional fields to safe defaults" case) to include `debugHeaders: null` in its `toEqual`.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/preview-intercept.ts fiddle/assets/preview-intercept.test.ts
git commit -m "feat(fiddle): extract + validate X-ImagePipe debug headers at the SW boundary

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: service worker emits the debug headers

**Files:**
- Modify: `fiddle/assets/preview-sw.ts` (`reportMetadata`, ~30-53)

- [ ] **Step 1: Read the headers and include them in the message**

In `reportMetadata`, import is already present (`PreviewMetaMessage` via `preview-intercept`). Add the `extractDebugHeaders` import and populate the message. The SW reads off the same `response` clone it already buffers:

Change the import line at the top of `preview-sw.ts`:

```ts
import { isPreviewUrl, extractDebugHeaders, type PreviewMetaMessage } from "./preview-intercept";
```

In `reportMetadata`, add `debugHeaders` to the message object (read it *before* `response.arrayBuffer()` consumes the body — headers are available immediately on the clone):

```ts
async function reportMetadata(
  clientId: string,
  url: string,
  accept: string | null,
  response: Response,
): Promise<void> {
  try {
    const debugHeaders = extractDebugHeaders(response.headers);
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
      debugHeaders,
    };
    await postToClient(clientId, message);
  } catch {
    // Metadata is best-effort; never disrupt the image render.
  }
}
```

- [ ] **Step 2: Typecheck the SW project**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: clean (the `tsconfig.sw.json` typecheck covers `preview-sw.ts`).

- [ ] **Step 3: Commit**

```bash
git add fiddle/assets/preview-sw.ts
git commit -m "feat(fiddle): report X-ImagePipe debug headers from the preview SW

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase C — Fiddle: parse headers into display groups (the tested core)

### Task C1: `debug-headers.ts` parser

A pure module: `(rawHeaders, outputBytes) → DebugGroup[] | null`. Output byte size comes from the fetched body length (`outputBytes`); the compression ratio is derived from `X-ImagePipe-Source-Size ÷ outputBytes`. This is the unit-tested core; the Svelte component just renders the groups.

**Files:**
- Create: `fiddle/assets/debug-headers.ts`
- Test: `fiddle/assets/debug-headers.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `fiddle/assets/debug-headers.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { parseDebugHeaders, type DebugGroup } from "./debug-headers";

function group(groups: DebugGroup[] | null, title: string): DebugGroup | undefined {
  return groups?.find((g) => g.title === title);
}

describe("parseDebugHeaders", () => {
  it("returns null when there are no debug headers", () => {
    expect(parseDebugHeaders(null, 40000)).toBeNull();
    expect(parseDebugHeaders({}, 40000)).toBeNull();
  });

  it("groups source / output rows and derives output size + compression ratio", () => {
    const groups = parseDebugHeaders(
      {
        "x-imagepipe-source-format": "jpeg",
        "x-imagepipe-source-size": "184320",
        "x-imagepipe-source-width": "4000",
        "x-imagepipe-source-height": "3000",
        "x-imagepipe-source-icc": "true",
        "x-imagepipe-source-alpha": "false",
        "x-imagepipe-output-format": "avif",
        "x-imagepipe-output-negotiated": "true",
        "x-imagepipe-output-width": "1200",
        "x-imagepipe-output-height": "900",
        "x-imagepipe-output-quality": "72",
      },
      40000,
    );

    const source = group(groups, "Source");
    expect(source?.rows).toContainEqual({ label: "Format", value: "jpeg" });
    expect(source?.rows).toContainEqual({ label: "Size", value: "180.0 kB" });
    expect(source?.rows).toContainEqual({ label: "Dimensions", value: "4000 × 3000" });
    expect(source?.rows).toContainEqual({ label: "ICC profile", value: "yes" });
    expect(source?.rows).toContainEqual({ label: "Alpha", value: "no" });

    const output = group(groups, "Output");
    expect(output?.rows).toContainEqual({ label: "Format", value: "avif" });
    expect(output?.rows).toContainEqual({ label: "Negotiated", value: "yes" });
    expect(output?.rows).toContainEqual({ label: "Dimensions", value: "1200 × 900" });
    expect(output?.rows).toContainEqual({ label: "Quality", value: "72" });
    expect(output?.rows).toContainEqual({ label: "Output size", value: "39.1 kB" });
    expect(output?.rows).toContainEqual({ label: "Compression", value: "4.6×" });
  });

  it("renders the 'default' quality sentinel verbatim", () => {
    const groups = parseDebugHeaders({ "x-imagepipe-output-quality": "default" }, null);
    expect(group(groups, "Output")?.rows).toContainEqual({ label: "Quality", value: "default" });
  });

  it("emits the autoquality group only when AQ headers are present", () => {
    const none = parseDebugHeaders({ "x-imagepipe-output-format": "avif" }, null);
    expect(group(none, "Autoquality")).toBeUndefined();

    const groups = parseDebugHeaders(
      {
        "x-imagepipe-aq-metric": "ssimulacra2",
        "x-imagepipe-aq-score": "78.4",
        "x-imagepipe-aq-target": "78.0",
        "x-imagepipe-aq-quality-min": "60",
        "x-imagepipe-aq-quality-max": "65",
        "x-imagepipe-aq-outcome": "hit",
        "x-imagepipe-aq-scorer": "crop",
        "x-imagepipe-aq-tiles": "9",
      },
      null,
    );
    const aq = group(groups, "Autoquality");
    expect(aq?.rows).toContainEqual({ label: "Metric", value: "ssimulacra2" });
    expect(aq?.rows).toContainEqual({ label: "Score", value: "78.4" });
    expect(aq?.rows).toContainEqual({ label: "Quality min", value: "60" });
    expect(aq?.rows).toContainEqual({ label: "Tiles", value: "9" });
  });

  it("renders cache status + key and the pipeline list", () => {
    const groups = parseDebugHeaders(
      {
        "x-imagepipe-cache": "hit",
        "x-imagepipe-cache-key": "a1b2c3",
        "x-imagepipe-pipeline": "scale,crop,sharpen",
      },
      null,
    );
    expect(group(groups, "Cache")?.rows).toContainEqual({ label: "Status", value: "hit" });
    expect(group(groups, "Cache")?.rows).toContainEqual({ label: "Key", value: "a1b2c3" });
    expect(group(groups, "Pipeline")?.rows).toContainEqual({
      label: "Operations",
      value: "scale,crop,sharpen",
    });
  });

  it("parses Server-Timing into per-stage millisecond rows", () => {
    const groups = parseDebugHeaders(
      { "server-timing": "decode;dur=8.1, transform;dur=21, encode;dur=140, cache;dur=1.5, total;dur=181" },
      null,
    );
    const timing = group(groups, "Timing");
    expect(timing?.rows).toContainEqual({ label: "Decode", value: "8.1 ms" });
    expect(timing?.rows).toContainEqual({ label: "Cache", value: "1.5 ms" });
    expect(timing?.rows).toContainEqual({ label: "Total", value: "181 ms" });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: FAIL — `./debug-headers` module not found.

- [ ] **Step 3: Implement the parser**

Create `fiddle/assets/debug-headers.ts`:

```ts
// Pure rendering helper for the fiddle's debug panel. Turns the raw X-ImagePipe-*
// + Server-Timing header record (read by the service worker) plus the fetched body
// length into ordered display groups. The header surface and units mirror
// ImagePipe.Debug.Headers exactly (Server-Timing in milliseconds; no output-size
// header by design — the browser supplies the body length, from which we derive
// the compression ratio).

export type DebugRow = { label: string; value: string };
export type DebugGroup = { title: string; rows: DebugRow[] };

type Raw = Record<string, string> | null;

export function parseDebugHeaders(raw: Raw, outputBytes: number | null): DebugGroup[] | null {
  if (raw === null || Object.keys(raw).length === 0) return null;

  const get = (name: string): string | undefined => raw[name];
  const groups: DebugGroup[] = [];

  pushGroup(groups, "Source", [
    row("Format", get("x-imagepipe-source-format")),
    row("Size", formatBytes(toNumber(get("x-imagepipe-source-size")))),
    dimensionsRow(get("x-imagepipe-source-width"), get("x-imagepipe-source-height")),
    row("Color space", get("x-imagepipe-source-color-space")),
    boolRow("ICC profile", get("x-imagepipe-source-icc")),
    row("Bit depth", get("x-imagepipe-source-bit-depth")),
    boolRow("Alpha", get("x-imagepipe-source-alpha")),
    row("Orientation", get("x-imagepipe-source-orientation")),
    row("Shrink", get("x-imagepipe-shrink")),
  ]);

  const sourceBytes = toNumber(get("x-imagepipe-source-size"));
  pushGroup(groups, "Output", [
    row("Format", get("x-imagepipe-output-format")),
    boolRow("Negotiated", get("x-imagepipe-output-negotiated")),
    dimensionsRow(get("x-imagepipe-output-width"), get("x-imagepipe-output-height")),
    row("Quality", get("x-imagepipe-output-quality")),
    boolRow("Stripped", get("x-imagepipe-output-stripped")),
    row("Color profile", get("x-imagepipe-output-color-profile")),
    row("Distance", get("x-imagepipe-output-distance")),
    row("Accept", get("x-imagepipe-output-accept")),
    row("Output size", formatBytes(outputBytes)),
    row("Compression", compressionRatio(sourceBytes, outputBytes)),
  ]);

  pushGroup(groups, "Autoquality", [
    row("Metric", get("x-imagepipe-aq-metric")),
    row("Score", get("x-imagepipe-aq-score")),
    row("Target", get("x-imagepipe-aq-target")),
    row("Quality min", get("x-imagepipe-aq-quality-min")),
    row("Quality max", get("x-imagepipe-aq-quality-max")),
    row("Iterations", get("x-imagepipe-aq-iterations")),
    row("Outcome", get("x-imagepipe-aq-outcome")),
    row("Limiting factor", get("x-imagepipe-aq-limiting-factor")),
    row("Scorer", get("x-imagepipe-aq-scorer")),
    row("Tiles", get("x-imagepipe-aq-tiles")),
  ]);

  pushGroup(groups, "Cache", [
    row("Status", get("x-imagepipe-cache")),
    row("Key", get("x-imagepipe-cache-key")),
  ]);

  pushGroup(groups, "Pipeline", [row("Operations", get("x-imagepipe-pipeline"))]);

  pushGroup(groups, "Timing", parseServerTiming(get("server-timing")));

  return groups.length > 0 ? groups : null;
}

function pushGroup(groups: DebugGroup[], title: string, rows: (DebugRow | null)[]): void {
  const present = rows.filter((r): r is DebugRow => r !== null);
  if (present.length > 0) groups.push({ title, rows: present });
}

function row(label: string, value: string | undefined): DebugRow | null {
  return value === undefined || value === "" ? null : { label, value };
}

function boolRow(label: string, value: string | undefined): DebugRow | null {
  if (value === undefined) return null;
  return { label, value: value === "true" ? "yes" : value === "false" ? "no" : value };
}

function dimensionsRow(w: string | undefined, h: string | undefined): DebugRow | null {
  return w !== undefined && h !== undefined ? { label: "Dimensions", value: `${w} × ${h}` } : null;
}

function compressionRatio(sourceBytes: number | null, outputBytes: number | null): string | undefined {
  if (sourceBytes === null || outputBytes === null || outputBytes <= 0) return undefined;
  return `${(sourceBytes / outputBytes).toFixed(1)}×`;
}

function parseServerTiming(value: string | undefined): (DebugRow | null)[] {
  if (value === undefined) return [];
  return value.split(",").map((entry) => {
    const name = entry.split(";")[0]?.trim() ?? "";
    const dur = /dur=([\d.]+)/.exec(entry)?.[1];
    if (name === "" || dur === undefined) return null;
    return { label: capitalize(name), value: `${dur} ms` };
  });
}

function toNumber(value: string | undefined): number | null {
  if (value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function formatBytes(bytes: number | null): string | undefined {
  if (bytes === null) return undefined;
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} kB`;
}

function capitalize(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/debug-headers.ts fiddle/assets/debug-headers.test.ts
git commit -m "feat(fiddle): parse X-ImagePipe debug headers into display groups

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase D — Fiddle: thread to the UI and render

### Task D1: tracker threads `debugHeaders` onto `ProcessedImageMetadata`

**Files:**
- Modify: `fiddle/assets/processing-path.ts` (`ProcessedImageMetadata` type, ~224-229)
- Modify: `fiddle/assets/preview-bridge.ts` (`PreviewMetadataTracker`)
- Test: `fiddle/assets/preview-bridge.test.ts`

- [ ] **Step 1: Add the field to the metadata type**

In `fiddle/assets/processing-path.ts`, extend `ProcessedImageMetadata`:

```ts
export type ProcessedImageMetadata = {
  width: number;
  height: number;
  bytes: number | null;
  contentType: string | null;
  debugHeaders: Record<string, string> | null;
};
```

- [ ] **Step 2: Update the failing tracker tests**

In `fiddle/assets/preview-bridge.test.ts`:

Add `debugHeaders: null` to the `meta()` default object (so messages carry the field):

```ts
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
  debugHeaders: null,
  ...over,
});
```

Update **every** exact `toEqual({ width, height, bytes, contentType })` metadata assertion to include `debugHeaders` — there are **five** of them (lines ~33, ~40, ~46, ~56, ~78): the `width:10/height:10` merge, the `width:5/height:7, bytes:null` merge, the `width:5/height:7, bytes:99` after-onload merge, the `width:1/height:1` stale-drop case, and the `width:3/height:4` null-bytes case. All five are driven by `meta()` (which now defaults `debugHeaders: null`), so append `debugHeaders: null` to each expected object. (Do not miss the after-onload `bytes:99` case — its non-null `bytes` makes it easy to overlook.) Then add one new assertion that the tracker threads a present record:

```ts
  it("threads debugHeaders from the SW message onto the metadata", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/img/x");
    t.applyDimensions({ width: 5, height: 7 }, id);
    t.applyMessage(
      meta({ url: "http://localhost:4000/img/x", debugHeaders: { "x-imagepipe-cache": "miss" } }),
      id,
    );
    expect(t.metadata).toEqual({
      width: 5,
      height: 7,
      bytes: 4321,
      contentType: "image/webp",
      debugHeaders: { "x-imagepipe-cache": "miss" },
    });
  });
```

- [ ] **Step 3: Run to verify failures**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: FAIL — `ProcessedImageMetadata` now requires `debugHeaders`, tracker does not set it.

- [ ] **Step 4: Implement the threading**

In `fiddle/assets/preview-bridge.ts`, carry `debugHeaders` through the pending stash and into the recomputed metadata:

In `applyMessage`, capture it alongside bytes/contentType:

```ts
    this.#pending = {
      bytes: message.bytes,
      contentType: message.contentType,
      debugHeaders: message.debugHeaders,
    };
    this.#recompute();
```

Widen the `#pending` field type:

```ts
  #pending: {
    bytes: number | null;
    contentType: string | null;
    debugHeaders: Record<string, string> | null;
  } | null = null;
```

And in `#recompute`, include it in the built metadata:

```ts
    this.metadata = {
      width: this.#dimensions.width,
      height: this.#dimensions.height,
      bytes: this.#pending?.bytes ?? null,
      contentType: this.#pending?.contentType ?? null,
      debugHeaders: this.#pending?.debugHeaders ?? null,
    };
```

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets run test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/processing-path.ts fiddle/assets/preview-bridge.ts fiddle/assets/preview-bridge.test.ts
git commit -m "feat(fiddle): thread debug headers through the preview metadata tracker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D2: `DebugInfoPanel.svelte` + wire into App.svelte

**Files:**
- Create: `fiddle/assets/DebugInfoPanel.svelte`
- Modify: `fiddle/assets/App.svelte`

- [ ] **Step 1: Create the presentational component**

Create `fiddle/assets/DebugInfoPanel.svelte`. It takes the parsed `DebugGroup[]` and renders a collapsible panel (closed by default). Uses the same `bits-ui` `Collapsible` already imported elsewhere in the app, and the existing CSS variables for theming:

```svelte
<script lang="ts">
  import { Collapsible } from "bits-ui";
  import { type DebugGroup } from "./debug-headers";

  let { groups }: { groups: DebugGroup[] | null } = $props();
</script>

{#if groups !== null}
  <Collapsible.Root class="debug-panel">
    <Collapsible.Trigger class="debug-panel-trigger">Debug headers</Collapsible.Trigger>
    <Collapsible.Content class="debug-panel-content">
      {#each groups as group (group.title)}
        <section class="debug-group">
          <h4 class="debug-group-title">{group.title}</h4>
          <dl class="debug-rows">
            {#each group.rows as detail (detail.label)}
              <div class="debug-row">
                <dt>{detail.label}</dt>
                <dd>{detail.value}</dd>
              </div>
            {/each}
          </dl>
        </section>
      {/each}
    </Collapsible.Content>
  </Collapsible.Root>
{/if}

<style>
  .debug-group-title {
    margin: 0 0 4px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-muted);
  }

  .debug-rows {
    margin: 0 0 10px;
    display: grid;
    gap: 2px;
  }

  .debug-row {
    display: grid;
    grid-template-columns: 120px 1fr;
    gap: 8px;
    font-size: 12px;
  }

  .debug-row dt {
    color: var(--text-muted);
  }

  .debug-row dd {
    margin: 0;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
</style>
```

(Theme tokens are confirmed against `fiddle/assets/styles.css`: the app defines `--text-primary`, `--text-muted`, and `--text-heading` — there is **no** `--text-secondary`, so the component uses `--text-muted` for labels/titles and `--text-primary` for values. The bits-ui `Collapsible` namespace is already imported and used in `ImgproxyControls.svelte`, so the import shape is known-good. The trigger/content visual styling is intentionally minimal — the user does the visual pass in Phase D3 Step 4; add `:global(.debug-panel-trigger)` polish only if they ask.)

- [ ] **Step 2: Derive the groups and render the panel in App.svelte**

In `fiddle/assets/App.svelte`:

Add the imports (alongside the existing `processing-path` and component imports):

```ts
  import DebugInfoPanel from "./DebugInfoPanel.svelte";
  import { parseDebugHeaders } from "./debug-headers";
```

Add a `$derived` near the other derived values (e.g. after `sizeLabel`, ~179):

```ts
  const debugGroups = $derived(
    parseDebugHeaders(processedMetadata?.debugHeaders ?? null, processedMetadata?.bytes ?? null),
  );
```

Render the panel in the preview area. Place it inside `.preview-canvas`, after the `.image-frame` block (~604) so it sits under the image:

```svelte
      <DebugInfoPanel groups={debugGroups} />
```

- [ ] **Step 3: Typecheck**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add fiddle/assets/DebugInfoPanel.svelte fiddle/assets/App.svelte
git commit -m "feat(fiddle): render the debug-headers panel under the preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D3: full fiddle gate

**Files:** none (verification only).

- [ ] **Step 1: Run every non-visual fiddle script**

Run each and confirm PASS:
- `mise exec -- pnpm -C fiddle/assets run test`
- `mise exec -- pnpm -C fiddle/assets run check`
- `mise exec -- pnpm -C fiddle/assets run lint`
- `mise exec -- pnpm -C fiddle/assets run format:check`
- `mise exec -- pnpm -C fiddle/assets run build`

If `format:check` flags anything, run `mise exec -- pnpm -C fiddle/assets run format` and re-stage.

- [ ] **Step 2: Run the full fiddle gate**

Run: `mise run precommit:fiddle`
Expected: PASS (Elixir gate + fiddle Elixir checks + JS test/check/lint/format/build). The earlier `build` ensures the Vite manifest exists for the fiddle's `mix test`.

- [ ] **Step 3: Commit any format fixups**

```bash
git add -A
git commit -m "chore(fiddle): formatting + gate fixups for the debug panel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

(Skip if there is nothing to commit.)

- [ ] **Step 4: Hand off the visual check to the user**

Do **not** self-preview. Tell the user the fiddle gate is green and ask them to confirm the look in a real browser (toggle a few options — including an autoquality method and a JXL output — and watch the **Debug headers** panel and the **Cache: miss → hit** flip on a repeat request).

---

## Phase E — Docs

### Task E1: `docs/debug_headers.md` (operator guide + catalogue)

**Files:**
- Create: `docs/debug_headers.md`
- Modify: `mix.exs` (ExDoc `extras:` ~24-36 and package `files:` ~99-115)

- [ ] **Step 1: Write the doc**

Create `docs/debug_headers.md`. Reproduce the catalogue **from `lib/image_pipe/debug/headers.ex`** (verify each name/example against that file as you write). Use the accurate signed-URL note (per the design decision) and the corrected `Server-Timing` stage list (decode/transform/encode/cache/total — **no `fetch`**, ms units).

```markdown
# Debug response headers

ImagePipe can attach opt-in `X-ImagePipe-*` response headers and a standard
`Server-Timing` header that expose how a response was produced: source
properties, the negotiated output, autoquality search results, cache status, the
applied pipeline, and per-stage timings. They are **off by default**.

## Enabling

Two independent controls must both be satisfied for any header to be emitted:

1. **Mount option `allow_debug_headers: true`** (default `false`) — the
   deployment-level switch. When `false`, no debug headers are ever rendered.

   ```elixir
   plug ImagePipe.Plug,
     parser: ImagePipe.Parser.Imgproxy,
     sources: [...],
     allow_debug_headers: true
   ```

2. **Per-request `_debug=1` query parameter** — the trigger. Dialect-neutral
   (works for imgproxy / IIIF / TwicPics / native), parsed at the request entry
   boundary. Honored only when `allow_debug_headers: true`; otherwise ignored.

`_debug=1` does **not** change the produced image bytes: it is excluded from the
cache key and the ETag, so a `_debug` request and a normal request resolve to the
same cache entry. (Facts are collected and stored on every generation regardless
of the flag, so enabling `allow_debug_headers: true` immediately surfaces headers
for already-cached items, with no cache invalidation.)

## Security and disclosure

> **Signed-URL caveat — read before enabling in production.**
> `_debug=1` is a **query parameter**. imgproxy's built-in signature signs the
> request **path only**, so it does **not** cover `_debug`. Enabling
> `allow_debug_headers: true` is safe in production **only** if your URL signing
> covers the full URL **including the query string** (e.g. CDN/edge signed URLs).
> If you rely solely on imgproxy path signatures, an attacker can append
> `?_debug=1` to any otherwise-valid URL and read the debug headers — so leave
> `allow_debug_headers: false`, or front the deployment with whole-URL signing.

When triggered, a response discloses: internal source dimensions and
format/color/ICC/bit-depth/alpha facts; the negotiated output and its
dimensions/quality/profile; autoquality scores and search internals; the applied
pipeline operations; the cache key; and per-stage timings. None of these are
secrets, but operators who consider any of it sensitive should leave the mount
flag off.

## Header catalogue

All `X-ImagePipe-*` values are flat (one fact per header). `nil`/absent facts are
omitted. Names and units are owned by `ImagePipe.Debug.Headers`.

### Source

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Source-Format` | `jpeg` | Decoded source format |
| `X-ImagePipe-Source-Size` | `184320` | Source byte count |
| `X-ImagePipe-Source-Width` | `4000` | Source pixel width |
| `X-ImagePipe-Source-Height` | `3000` | Source pixel height |
| `X-ImagePipe-Source-Color-Space` | `srgb` | Source interpretation |
| `X-ImagePipe-Source-ICC` | `true` | Embedded ICC profile present |
| `X-ImagePipe-Source-Bit-Depth` | `8` | Bits per sample |
| `X-ImagePipe-Source-Alpha` | `false` | Source has an alpha channel |
| `X-ImagePipe-Source-Orientation` | `6` | EXIF orientation (1–8), pre-auto-orient |
| `X-ImagePipe-Shrink` | `w=2.0;h=2.0` | Shrink-on-load factors applied at decode |

### Output

No output-size header is sent (it is unknown up front for a streamed encode). The
browser obtains the size from the response body; the fiddle derives the
compression ratio from `X-ImagePipe-Source-Size ÷ body length`.

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Output-Format` | `avif` | Concrete encoded format |
| `X-ImagePipe-Output-Negotiated` | `true` | `Accept`-negotiated vs explicitly requested |
| `X-ImagePipe-Output-Accept` | `image/avif,…` | Request `Accept` echoed |
| `X-ImagePipe-Output-Width` | `1200` | Finalized output width |
| `X-ImagePipe-Output-Height` | `900` | Finalized output height |
| `X-ImagePipe-Output-Quality` | `72` | Effective quality (or `default` when the encoder default applied) |
| `X-ImagePipe-Output-Stripped` | `true` | Metadata stripped |
| `X-ImagePipe-Output-Color-Profile` | `srgb` | Output color profile |
| `X-ImagePipe-Output-Distance` | `1.0` | JXL native distance (JXL output only) |

### Autoquality (present only when a quality search ran)

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-AQ-Metric` | `ssimulacra2` | Search metric (`ssimulacra2`/`butteraugli`/`size`) |
| `X-ImagePipe-AQ-Score` | `78.4` | Achieved score (metric units) |
| `X-ImagePipe-AQ-Target` | `78.0` | Search target/threshold (metric units) |
| `X-ImagePipe-AQ-Quality-Min` | `60` | Per-format-clamped search floor |
| `X-ImagePipe-AQ-Quality-Max` | `65` | Per-format-clamped search roof |
| `X-ImagePipe-AQ-Iterations` | `5` | Search iterations |
| `X-ImagePipe-AQ-Outcome` | `hit` | `hit`/`best_effort`/`skipped`/`native` |
| `X-ImagePipe-AQ-Limiting-Factor` | `ceiling` | Why the search stopped |
| `X-ImagePipe-AQ-Scorer` | `crop` | `full`/`crop` |
| `X-ImagePipe-AQ-Tiles` | `9` | Tiles scored (crop mode only) |

### Cache / pipeline

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Cache` | `hit` | Delivery path — `hit`/`miss` |
| `X-ImagePipe-Cache-Key` | `a1b2c3…` | Cache key (64-char sha256 hex) |
| `X-ImagePipe-Pipeline` | `scale,crop,sharpen` | Applied plan operations, in order |

### Timings — `Server-Timing`

Durations are in **milliseconds**. On a miss, the live per-stage durations plus
`total` are emitted; on a hit, the stored origin durations are replayed plus a
live `cache` entry for the cache read.

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, total;dur=181.2
```

On a cache hit:

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, cache;dur=1.5, total;dur=181.2
```

(There is no separate `fetch` stage — source fetch is folded into `decode`.)

## Demo (fiddle)

The bundled demo (`fiddle/`) configures its three mounts with
`allow_debug_headers: true` and adds `_debug=1` to its preview requests. Its
service worker reads these headers off the fetched response and surfaces them in
a **Debug headers** panel under the preview, including the derived output size and
compression ratio.
```

- [ ] **Step 2: Register the doc in `mix.exs`**

Add `"docs/debug_headers.md"` to the ExDoc `extras:` list (after `docs/telemetry.md`, ~line 30):

```elixir
        extras: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE.md",
          "docs/cache.md",
          "docs/operational_notes.md",
          "docs/telemetry.md",
          "docs/debug_headers.md",
          {"docs/cookbook/opentelemetry-jaeger.md", title: "OpenTelemetry → Jaeger"},
          "docs/imgproxy_path_api.md",
          "docs/imgproxy_support_matrix.md",
          "docs/iiif_3_support_matrix.md",
          "docs/transform_operations.md"
        ],
```

And add it to the package `files:` list so it ships with the Hex package. The `extras:` and `files:` lists are ordered differently, so locate the insertion by the **anchor string** `"docs/telemetry.md",` (not by line number) and add the new entry right after it (list order is irrelevant to Hex):

```elixir
        "docs/operational_notes.md",
        "docs/telemetry.md",
        "docs/debug_headers.md",
        "docs/cookbook/opentelemetry-jaeger.md",
```

- [ ] **Step 3: Verify the doc builds**

Run: `mise exec -- mix docs`
Expected: clean (no broken-extra warning for the new file). If `mix docs` is slow/heavy, at minimum run `mise exec -- mix compile --warnings-as-errors` to confirm `mix.exs` parses.

- [ ] **Step 4: Commit**

```bash
git add docs/debug_headers.md mix.exs
git commit -m "docs: add debug response headers operator guide + catalogue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task E2: pointer from `docs/operational_notes.md`

The signed-URL caveat is signature-adjacent, so cross-link from the operational notes.

**Files:**
- Modify: `docs/operational_notes.md`

- [ ] **Step 1: Add a short pointer**

Append a brief section to `docs/operational_notes.md` (at the end of the file, matching its prose style):

```markdown
## Debug response headers

ImagePipe can attach opt-in `X-ImagePipe-*` and `Server-Timing` debug headers,
gated by the `allow_debug_headers` mount option and a per-request `_debug=1`
query parameter. They are off by default. Note that `_debug=1` is a query
parameter and is **not** covered by imgproxy's path signature — only enable
`allow_debug_headers: true` in production behind whole-URL (query-covering)
signing. See [Debug response headers](debug_headers.md) for the full catalogue
and the security/disclosure details.
```

- [ ] **Step 2: Commit**

(Docs-only; no gate per the comment-only convention.)

```bash
git add docs/operational_notes.md
git commit -m "docs: cross-link debug response headers from operational notes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase F — Final review, follow-up, and PR

### Task F1: final review of the complete diff

**Files:** none (review only).

- [ ] **Step 1: Review the whole diff**

Run: `git diff main...HEAD --stat` then read the full diff. Confirm:
- No `lib/image_pipe/**` changes (Plan 3 is docs + fiddle only).
- The doc catalogue matches `lib/image_pipe/debug/headers.ex` name-for-name.
- The fiddle parser key strings match the header names exactly (lowercased).
- `_debug=1` rides only `previewImageUrl`; `path` (copy/Open) is unchanged.

- [ ] **Step 2: Re-run the full fiddle gate once more on the final state**

Run: `mise run precommit:fiddle`
Expected: PASS.

### Task F2: PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/debug-headers-3-fiddle-and-docs
```

Open a PR whose body includes, each on its own bare line:

```
Fixes #394
```

(Only `#394` — Plan 3 fully resolves it. Verify after creation: `gh pr view <n> --json closingIssuesReferences`.)

### Task F3: file the library follow-up for the signing gap

The accurate docs describe the current posture; a separate library issue tracks closing the gap so imgproxy's own signature can cover the debug trigger.

- [ ] **Step 1: Create the follow-up issue**

```bash
gh issue create \
  --title "debug headers: make _debug a signed trigger (imgproxy path HMAC doesn't cover the query)" \
  --body "Plan 3 (#394) documents that \`_debug=1\` is a query parameter NOT covered by imgproxy's path signature, so \`allow_debug_headers: true\` is only safe behind whole-URL (query-covering) signing. Consider making \`_debug\` a signed trigger — e.g. a reserved path segment folded into the signed path, or signature-over-query support — so imgproxy's own HMAC protects it. Out of scope for the docs-only Plan 3.

Evidence: \`_debug\` is read from \`conn.query_params\` (lib/image_pipe/plug.ex), but the imgproxy signature covers \`conn.request_path\` only (lib/image_pipe/parser/imgproxy/path.ex \`parser_request_path/1\`; lib/image_pipe/parser/imgproxy/signature.ex \`verify/3\`)."
```

(Reference the new issue number in the PR description as related context, without a closing keyword.)

---

## Self-review (run before declaring the plan ready)

- **Spec coverage (Fiddle consumption):** SW reads `X-ImagePipe-*` + `Server-Timing` (B1/B2); `_debug=1` added against debug-enabled mounts (A1/A2); output size from body length + compression ratio from `Source-Size ÷ length` (C1); full surface — all `Source-*`, `Shrink`, all `Output-*` incl. `Cache-Key`/`Distance`, all `AQ-*`, `Pipeline`, `Cache`, and per-stage + total + (hit) `cache` timings — covered by the parser groups (C1) and catalogue (E1). ✓
- **Spec coverage (Docs):** `allow_debug_headers`, `_debug=1`, signed-URL note (accurate variant per the user decision), disclosure list, header-catalogue table, fiddle note — all in E1; cross-link in E2. ✓
- **Catalogue correctness:** built from `headers.ex`, with the stale-spec corrections (no `fetch` stage; ms units; `default` quality sentinel) called out in *Key facts*. ✓
- **Placeholder scan:** every code/edit step shows the actual content; verification steps name exact commands + expected outcomes. ✓
- **Type consistency:** `DebugGroup`/`DebugRow`/`parseDebugHeaders` (C1) match their uses in D1/D2; `debugHeaders: Record<string,string> | null` is consistent across `PreviewMetaMessage` (B1), `ProcessedImageMetadata` (D1), tracker (D1), and the App derive (D2). ✓
```
