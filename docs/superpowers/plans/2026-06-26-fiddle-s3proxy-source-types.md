# Fiddle s3proxy + multi-source-type selector — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the fiddle's imgproxy provider fetch the same sample images through three source adapters — local filesystem, a local s3proxy fake-S3, and HTTP against the fiddle's own static server — selectable from a new "Source type" UI control.

**Architecture:** No `ImagePipe` library changes. Add an opt-in `s3proxy` Docker Compose service mirroring `priv/static/images`, mount the existing `Source.S3` and `Source.HTTP` adapters in the fiddle's imgproxy options (config-driven), and encode the chosen source type into the imgproxy processing path's source identifier scheme (`local:///…` / `s3://sources/…` / `http://localhost:4000/images/…`), which round-trips through the fiddle's URL state.

**Tech Stack:** Elixir/Phoenix (fiddle backend + config), Docker Compose + mise tasks, Svelte 5 + TypeScript (fiddle UI), Vitest (JS tests).

**Spec:** `docs/superpowers/specs/2026-06-26-fiddle-s3proxy-source-types-design.md`

**Conventions for every task below:** run JS commands from `fiddle/assets` and Elixir/mix commands from `fiddle/` via `mise exec -- …`. Commit after each task.

---

## File Structure

- `fiddle/docker-compose.yml` — add `s3proxy` service alongside `jaeger`; update header comment.
- `mise.toml` — scope `[tasks.jaeger]` to `up jaeger`; add `[tasks.s3proxy]`.
- `fiddle/config/config.exs` — add `:s3_source` config block (endpoint/region/credentials).
- `fiddle/lib/image_pipe_fiddle/application.ex` — add `s3:`/`url:` mounts to the imgproxy `sources:` (imgproxy only); read s3 config.
- `fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs` — Elixir test that the mounts validate via `ImagePipe.Plug.init/1`.
- `fiddle/assets/processing-path.ts` — `SourceType` type, `sourceIdentifierForRequest(source, sourceType)`, inverse `parseSourceIdentifier(identifier)`, `FiddleState.sourceType`, `defaultFiddleState.sourceType`, `signedPathForState`.
- `fiddle/assets/fiddle-url-state.ts` — route `sourceFromIdentifier`/`parseFiddlePathParts`/`parseFiddlePath` through `parseSourceIdentifier`; carry `sourceType`.
- `fiddle/assets/App.svelte` — "Source type" `<select>` in the imgproxy request section.
- `fiddle/assets/processing-path.test.ts` — build/parse unit tests.
- `fiddle/assets/fiddle-url-state.test.ts` — round-trip test.

---

## Task 1: s3proxy Compose service + mise tasks

**Files:**
- Modify: `fiddle/docker-compose.yml`
- Modify: `mise.toml` (`[tasks.jaeger]` ~line 91, add `[tasks.s3proxy]`)

This task is infra config (no unit test); verification is `docker compose config` parsing the file.

- [ ] **Step 1: Add the s3proxy service to `fiddle/docker-compose.yml`**

Replace the existing header comment + `services:` block so the file reads:

```yaml
# Local sidecar services for the fiddle demo (opt-in; not needed for `mise run server`).
#
# Jaeger — OpenTelemetry traces:
#   mise run jaeger                 # docker compose ... up jaeger
#   FIDDLE_OTEL=1 mise run server   # emit traces; UI at http://localhost:16686
#
# s3proxy — fake S3 over the local filesystem, mirrors priv/static/images so the
# fiddle's "S3" source type can fetch the sample images as s3://sources/<file>:
#   mise run s3proxy                # docker compose ... up s3proxy
# Endpoint http://localhost:8081, bucket "sources" == ./priv/static/images (read-only).
services:
  jaeger:
    image: cr.jaegertracing.io/jaegertracing/jaeger:2.19.0
    container_name: jaeger
    ports:
      - "16686:16686" # Jaeger UI
      - "4317:4317" # OTLP gRPC
      - "4318:4318" # OTLP HTTP (the fiddle exports here)
      - "5778:5778" # sampling/config
      - "9411:9411" # Zipkin

  s3proxy:
    image: andrewgaul/s3proxy:sha-ba0b833
    container_name: fiddle-s3proxy
    ports:
      - "8081:80" # s3proxy listens on container port 80
    environment:
      S3PROXY_AUTHORIZATION: aws-v2-or-v4
      S3PROXY_IDENTITY: fiddle
      S3PROXY_CREDENTIAL: fiddlesecret
      JCLOUDS_PROVIDER: filesystem
      JCLOUDS_FILESYSTEM_BASEDIR: /data
    volumes:
      # Mounted read-only: the demo only reads. Bucket name == the subdir under basedir.
      - ./priv/static/images:/data/sources:ro
```

> Note: the `andrewgaul/s3proxy` image tag above pins a known-good digest-style tag. If it does not resolve at implementation time, substitute the current `andrewgaul/s3proxy:latest` digest and record it here.

- [ ] **Step 2: Scope the jaeger mise task and add the s3proxy task in `mise.toml`**

Replace the existing `[tasks.jaeger]` block (currently `run = "docker compose -f fiddle/docker-compose.yml up"`) with:

```toml
[tasks.jaeger]
description = "Run a local Jaeger (OTLP + UI) for the fiddle's OpenTelemetry traces"
run = "docker compose -f fiddle/docker-compose.yml up jaeger"

[tasks.s3proxy]
description = "Run a local s3proxy (fake S3 over priv/static/images) for the fiddle's S3 source type"
run = "docker compose -f fiddle/docker-compose.yml up s3proxy"
```

- [ ] **Step 3: Verify Compose file parses**

Run: `docker compose -f fiddle/docker-compose.yml config >/dev/null && echo OK`
Expected: prints `OK` (both `jaeger` and `s3proxy` services resolve, no YAML/schema errors).

If Docker is unavailable in the working environment, instead run `mise exec -- ... ` is not applicable; verify by eye that YAML indentation matches the block above and move on — the live check happens in manual verification.

- [ ] **Step 4: Commit**

```bash
git add fiddle/docker-compose.yml mise.toml
git commit -m "feat(fiddle): add opt-in s3proxy compose service + mise task"
```

---

## Task 2: Fiddle `:s3_source` config block

**Files:**
- Modify: `fiddle/config/config.exs` (after the existing `:imgproxy` block, ~line 25)

- [ ] **Step 1: Add the config block**

Insert directly after the `config :image_pipe_fiddle, :imgproxy, …` block:

```elixir
# Connection coordinates for the fiddle's S3 source type, served by the opt-in
# s3proxy compose service (see fiddle/docker-compose.yml). These mirror the
# s3proxy env: bucket "sources" == priv/static/images. Dev-only fake credentials.
config :image_pipe_fiddle, :s3_source,
  region: "us-east-1",
  endpoint: "http://localhost:8081",
  access_key_id: "fiddle",
  secret_access_key: "fiddlesecret"
```

- [ ] **Step 2: Verify it compiles**

Run (from `fiddle/`): `mise exec -- mix compile --warnings-as-errors`
Expected: compiles with no warnings/errors.

- [ ] **Step 3: Commit**

```bash
git add fiddle/config/config.exs
git commit -m "feat(fiddle): add :s3_source config for s3proxy connection"
```

---

## Task 3: Mount S3 + HTTP source adapters in the imgproxy options (TDD)

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex` (`build_imgproxy_opts/0`, lines 50-69)
- Test: `fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs` (create)

The test asserts the exact mount shapes the app builds are accepted by the library's host-config validation (`ImagePipe.Plug.init/1` raises on invalid source config). It reads the same `:s3_source` config the app uses, so there are no duplicated literals.

- [ ] **Step 1: Write the failing test**

Create `fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs`:

```elixir
defmodule ImagePipeFiddle.ImgproxySourceMountsTest do
  use ExUnit.Case, async: true

  # The fiddle mounts three source adapters for the imgproxy provider so the demo
  # can fetch the same sample images via local / s3 / http. This pins that the s3
  # and http mount shapes are accepted by ImagePipe's host-config validation
  # (Plug.init raises on an invalid source config).
  test "imgproxy_source_mounts/0 is accepted by ImagePipe.Plug.init/1" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: Application.fetch_env!(:image_pipe_fiddle, :imgproxy),
        sources: ImagePipeFiddle.Application.imgproxy_source_mounts()
      )

    assert is_list(opts)
    sources = Keyword.fetch!(opts, :sources)
    # url: fans out to :http/:https inside ImagePipe; s3 stays under :s3.
    assert Map.has_key?(sources, :s3)
    assert Map.has_key?(sources, :http)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `fiddle/`): `mise exec -- mix test test/image_pipe_fiddle/imgproxy_source_mounts_test.exs`
Expected: FAIL — `ImagePipeFiddle.Application.imgproxy_source_mounts/0` is undefined.

- [ ] **Step 3: Extract the source mounts into a public function and add the s3/url mounts**

In `fiddle/lib/image_pipe_fiddle/application.ex`, change `build_imgproxy_opts/0` to use a new public `imgproxy_source_mounts/0`. Replace the `sources:` keyword inside `build_imgproxy_opts/0` (currently lines 56-58) with `sources: imgproxy_source_mounts(),` and add the new function:

```elixir
  @doc false
  # Source adapters mounted for the imgproxy provider. The local File source is
  # always available; s3 (via the opt-in s3proxy compose service) and http (the
  # fiddle's own Plug.Static over loopback) let the demo compare source adapters
  # on byte-identical sample images. Scoped to imgproxy — iiif/twicpics keep File.
  def imgproxy_source_mounts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")
    s3 = Application.fetch_env!(:image_pipe_fiddle, :s3_source)

    [
      path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted},
      s3:
        {ImagePipe.Source.S3,
         default: [
           region: Keyword.fetch!(s3, :region),
           endpoint: Keyword.fetch!(s3, :endpoint),
           credentials: [
             access_key_id: Keyword.fetch!(s3, :access_key_id),
             secret_access_key: Keyword.fetch!(s3, :secret_access_key)
           ]
         ],
         buckets: %{"sources" => []}},
      # DEV-ONLY SSRF relaxation: the http source type fetches the fiddle's own
      # Plug.Static over loopback, so localhost must be explicitly allowed. This
      # lives only in the fiddle demo — never in ImagePipe library defaults.
      url:
        {ImagePipe.Source.HTTP, allowed_hosts: ["localhost", "127.0.0.1"], allow_loopback: true}
    ]
  end
```

The `static_root` local previously declared at the top of `build_imgproxy_opts/0` is now only used inside `imgproxy_source_mounts/0`; remove the now-unused binding from `build_imgproxy_opts/0` so it doesn't warn.

- [ ] **Step 4: Run the test to verify it passes**

Run (from `fiddle/`): `mise exec -- mix test test/image_pipe_fiddle/imgproxy_source_mounts_test.exs`
Expected: PASS.

- [ ] **Step 5: Verify no compile warnings**

Run (from `fiddle/`): `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (no "unused variable static_root" warning).

- [ ] **Step 6: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle/application.ex fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs
git commit -m "feat(fiddle): mount s3 + http source adapters for imgproxy provider"
```

---

## Task 4: Source-type-aware path building (TDD)

**Files:**
- Modify: `fiddle/assets/processing-path.ts` (add `SourceType`, source-id constants, `sourceIdentifierForRequest`, `parseSourceIdentifier`, `FiddleState.sourceType`, `defaultFiddleState.sourceType`, `signedPathForState`)
- Test: `fiddle/assets/processing-path.test.ts`

- [ ] **Step 1: Write the failing tests**

`processing-path.test.ts` already imports `{ afterEach, describe, expect, it, vi }` from `vitest` and a large block from `./processing-path`. **Add `sourceIdentifierForRequest` and `parseSourceIdentifier` to the existing `./processing-path` import block** (do not add a duplicate `vitest` import), then append these `describe` blocks:

```ts
describe("sourceIdentifierForRequest", () => {
  it("builds a local:/// identifier", () => {
    expect(sourceIdentifierForRequest("images/dog.jpg", "local")).toBe("local:///images/dog.jpg");
  });

  it("builds an s3://sources/<file> identifier from the basename", () => {
    expect(sourceIdentifierForRequest("images/dog.jpg", "s3")).toBe("s3://sources/dog.jpg");
  });

  it("builds an http://localhost:4000 identifier", () => {
    expect(sourceIdentifierForRequest("images/dog.jpg", "http")).toBe(
      "http://localhost:4000/images/dog.jpg",
    );
  });
});

describe("parseSourceIdentifier", () => {
  it("round-trips each source type", () => {
    for (const sourceType of ["local", "s3", "http"] as const) {
      const id = sourceIdentifierForRequest("images/dog.jpg", sourceType);
      expect(parseSourceIdentifier(id)).toEqual({ source: "images/dog.jpg", sourceType });
    }
  });

  it("returns null for an unknown scheme", () => {
    expect(parseSourceIdentifier("ftp://nope/dog.jpg")).toBeNull();
  });

  it("returns null when the identifier does not map to a known sample image", () => {
    expect(parseSourceIdentifier("s3://sources/not-a-real-image.jpg")).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `fiddle/assets`): `mise exec -- pnpm vitest run processing-path.test.ts`
Expected: FAIL — `parseSourceIdentifier` not exported / `sourceIdentifierForRequest` takes one arg.

- [ ] **Step 3: Implement the type, constants, builder, and parser**

In `fiddle/assets/processing-path.ts`, add near the `SourceImage` type (after line 18):

```ts
export type SourceType = "local" | "s3" | "http";

const localSourceScheme = "local:///";
const s3SourceBucketPrefix = "s3://sources/";
const httpSourcePrefix = "http://localhost:4000/";
```

Add `sourceType: SourceType;` to the `FiddleState` type (next to `source: SourceImage;`, line 113) and `sourceType: "local",` to `defaultFiddleState` (next to `source: "images/dog.jpg",`, line 349).

Replace the existing `sourceIdentifierForRequest` (lines 942-944) with:

```ts
export function sourceIdentifierForRequest(source: SourceImage, sourceType: SourceType): string {
  switch (sourceType) {
    case "local":
      return `${localSourceScheme}${source}`;
    case "s3":
      // Bucket "sources" is rooted at priv/static/images, so the key is the basename.
      return `${s3SourceBucketPrefix}${source.slice(source.lastIndexOf("/") + 1)}`;
    case "http":
      // The fiddle's own Plug.Static serves priv/static/images at /images/<file>.
      return `${httpSourcePrefix}${source}`;
  }
}

// Inverse of sourceIdentifierForRequest: recovers (source, sourceType) from a
// processing-path source identifier, or null if it is not a known sample image.
export function parseSourceIdentifier(
  identifier: string,
): { source: SourceImage; sourceType: SourceType } | null {
  const candidate = sourceTypeAndPath(identifier);

  if (candidate === null) {
    return null;
  }

  const { source, sourceType } = candidate;
  const known = sampleImages.some((image) => image.path === source);
  return known ? { source: source as SourceImage, sourceType } : null;
}

function sourceTypeAndPath(identifier: string): { source: string; sourceType: SourceType } | null {
  if (identifier.startsWith(localSourceScheme)) {
    return { source: identifier.slice(localSourceScheme.length), sourceType: "local" };
  }

  if (identifier.startsWith(httpSourcePrefix)) {
    return { source: identifier.slice(httpSourcePrefix.length), sourceType: "http" };
  }

  if (identifier.startsWith(s3SourceBucketPrefix)) {
    // Reconstruct the images/<file> source from the basename key.
    return { source: `images/${identifier.slice(s3SourceBucketPrefix.length)}`, sourceType: "s3" };
  }

  return null;
}
```

> Membership is checked against the imported `sampleImages` array (already in scope at the top of `processing-path.ts`). `sampleImages.some(...)` is fine for the ~11-image sample set.

Update `signedPathForState` (line 947-950) to pass the source type:

```ts
export function signedPathForState(currentState: FiddleState): string {
  const options = optionSegments(currentState).join("/");
  const optionsPath = options === "" ? "" : `/${options}`;

  return `${optionsPath}/plain/${sourceIdentifierForRequest(currentState.source, currentState.sourceType)}`;
}
```

- [ ] **Step 4: Run to verify it passes**

Run (from `fiddle/assets`): `mise exec -- pnpm vitest run processing-path.test.ts`
Expected: PASS.

- [ ] **Step 5: Typecheck**

Run (from `fiddle/assets`): `mise exec -- pnpm check`
Expected: no type errors (every `FiddleState` literal now has `sourceType`; `defaultFiddleState` supplies it for spreads). The `check` script runs `tsgo --noEmit` (×2 projects) + `svelte-check`.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/processing-path.ts fiddle/assets/processing-path.test.ts
git commit -m "feat(fiddle): source-type-aware processing-path identifiers"
```

---

## Task 5: Round-trip source type through URL state (TDD)

**Files:**
- Modify: `fiddle/assets/fiddle-url-state.ts` (`sourceFromIdentifier` lines 158-165, `parseFiddlePathParts` lines 133-156, `parseFiddlePath` lines 74-100)
- Test: `fiddle/assets/fiddle-url-state.test.ts`

- [ ] **Step 1: Write the failing test**

`fiddle-url-state.test.ts` already imports `{ describe, expect, it }` from `vitest`, `defaultFiddleState` from `./processing-path`, and a block from `./fiddle-url-state`. **Add `parseFiddlePath` and `fiddlePathForState` to the existing `./fiddle-url-state` import block** (don't duplicate the others), then append:

```ts
describe("source type round-trip", () => {
  for (const sourceType of ["local", "s3", "http"] as const) {
    it(`preserves sourceType=${sourceType} through path build + parse`, () => {
      const state = { ...defaultFiddleState, source: "images/dog.jpg" as const, sourceType };
      const path = fiddlePathForState(state);
      const parsed = parseFiddlePath(path);
      expect(parsed.source).toBe("images/dog.jpg");
      expect(parsed.sourceType).toBe(sourceType);
    });
  }
});
```

- [ ] **Step 2: Run to verify it fails**

Run (from `fiddle/assets`): `mise exec -- pnpm vitest run fiddle-url-state.test.ts`
Expected: FAIL — `parsed.sourceType` is `undefined` (defaults to `"local"` via spread, so the s3/http cases fail).

- [ ] **Step 3: Route parsing through `parseSourceIdentifier` and carry `sourceType`**

In `fiddle/assets/fiddle-url-state.ts`:

Add `parseSourceIdentifier` and `type SourceType` to the existing import from `./processing-path` (line 16 area). Remove the now-unused `localSourcePrefix` constant (line 47) and the `sourceImages` set if it becomes unused (line 48 — keep it only if other code references it; otherwise delete).

Replace `sourceFromIdentifier` (lines 158-165) — change `parseFiddlePathParts` to return the parsed `{ source, sourceType }` pair. Update `parseFiddlePathParts` (lines 133-156):

```ts
function parseFiddlePathParts(
  pathname: string,
): { optionSegments: string[]; source: SourceImage; sourceType: SourceType } | null {
  const path = pathname.endsWith("/") && pathname !== "/" ? pathname.slice(0, -1) : pathname;

  const plainIndex = path.indexOf(plainSourceMarker);

  if (plainIndex === -1) {
    return null;
  }

  const optionSegments = path.slice(0, plainIndex).split("/").filter(Boolean);
  const parsedSource = parseSourceIdentifier(path.slice(plainIndex + plainSourceMarker.length));

  if (parsedSource === null) {
    return null;
  }

  return {
    optionSegments,
    source: parsedSource.source,
    sourceType: parsedSource.sourceType,
  };
}
```

Delete the standalone `sourceFromIdentifier` function (now replaced by `parseSourceIdentifier`).

Update `parseFiddlePath` (lines 74-100) so the seed state carries the source type:

```ts
  let state = resetCropPixelsToSource({
    ...defaultFiddleState,
    source: parsed.source,
    sourceType: parsed.sourceType,
  });
```

Ensure `SourceImage` and `SourceType` are imported from `./processing-path` (add `type SourceType` to the import list).

- [ ] **Step 4: Run to verify it passes**

Run (from `fiddle/assets`): `mise exec -- pnpm vitest run fiddle-url-state.test.ts`
Expected: PASS.

- [ ] **Step 5: Run the full JS test + typecheck**

Run (from `fiddle/assets`): `mise exec -- pnpm vitest run && mise exec -- pnpm check`
Expected: all suites PASS, no type errors. (Confirms no other caller of the removed `sourceFromIdentifier`/`localSourcePrefix` broke.)

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/fiddle-url-state.ts fiddle/assets/fiddle-url-state.test.ts
git commit -m "feat(fiddle): round-trip source type through imgproxy URL state"
```

---

## Task 6: "Source type" UI control

**Files:**
- Modify: `fiddle/assets/App.svelte` (inside the `{#if appState.provider === "imgproxy"}` block in the Request section, after the "Source image" `<label>`, ~line 477)

No unit test — behavior is covered by Tasks 4/5 (state) and manual verification. Svelte's `bind:value` writes the chosen type straight into `appState.imgproxy.sourceType`, which the path builder already consumes.

- [ ] **Step 1: Add the control**

Inside the imgproxy `{#if}` block, immediately after the closing `</label>` of the existing "Signature" field's sibling — placed as the first imgproxy-only field — add:

```svelte
              <label class="field">
                <span>Source type</span>
                <select bind:value={appState.imgproxy.sourceType}>
                  <option value="local">Local (filesystem)</option>
                  <option value="s3">S3 (s3proxy)</option>
                  <option value="http">HTTP (Plug.Static)</option>
                </select>
              </label>
```

(Place it directly after the `{#if appState.provider === "imgproxy"}` line and before the existing "Signature" `<label>`, so source-related controls sit together.)

- [ ] **Step 2: Typecheck / svelte-check**

Run (from `fiddle/assets`): `mise exec -- pnpm check`
Expected: no errors. (`appState.imgproxy.sourceType` is typed via `FiddleState`.)

> If the project has no `check` script, run `mise exec -- pnpm tsc --noEmit` and `mise exec -- pnpm svelte-check` as available; confirm the exact lint/check command from `fiddle/assets/package.json` scripts before running.

- [ ] **Step 3: Build the assets**

Run (from `fiddle/assets`): `mise exec -- pnpm build`
Expected: Vite build succeeds (produces the manifest the Elixir tests need).

- [ ] **Step 4: Commit**

```bash
git add fiddle/assets/App.svelte fiddle/assets/dist 2>/dev/null || git add fiddle/assets/App.svelte
git commit -m "feat(fiddle): add Source type selector to imgproxy request toolbox"
```

> Only stage built assets (`dist`) if the repo tracks them; check `git status` and match the existing convention.

---

## Task 7: Docs

**Files:**
- Modify: `fiddle/README.md` (or the doc where `mise run jaeger` is described — locate with `rg -l "mise run jaeger"`)

- [ ] **Step 1: Document the s3proxy workflow**

Add a short subsection next to the existing Jaeger instructions:

```markdown
### S3 source type (s3proxy)

The imgproxy provider can fetch the sample images through three source adapters,
chosen with the **Source type** control: local filesystem, a fake S3, or HTTP.

For the **S3** source type, start the opt-in s3proxy sidecar (a fake S3 over the
local filesystem that mirrors `priv/static/images`):

    mise run s3proxy

It serves at `http://localhost:8081` with bucket `sources` (== `priv/static/images`,
read-only). The **HTTP** source type needs no sidecar — it fetches the fiddle's own
`Plug.Static` at `http://localhost:4000/images/<file>`. All three resolve to
byte-identical bytes, so switching source types is a clean adapter comparison.
```

- [ ] **Step 2: Commit**

```bash
git add fiddle/README.md
git commit -m "docs(fiddle): document s3proxy / source type workflow"
```

---

## Task 8: Final gate

- [ ] **Step 1: Run the fiddle gate**

Run: `mise run precommit:fiddle`
Expected: Elixir gate (format/compile/credo/test) + fiddle JS verify (test/check/lint/format/build) all green.

- [ ] **Step 2: Manual verification (records the result; not a blocker for the gate)**

1. `mise run s3proxy` in one terminal.
2. `mise run server` in another.
3. Open the fiddle, imgproxy provider. Toggle **Source type** between Local / S3 / HTTP on the same sample image.
4. Confirm: all three render identically; the URL updates with `local:///…` / `s3://sources/…` / `http://localhost:4000/images/…`; reloading the page preserves the chosen source type.
5. Stop s3proxy and confirm only the S3 source type fails (Local/HTTP still work), proving the opt-in wiring.

- [ ] **Step 3: Final commit if the gate produced formatting changes**

```bash
git add -A
git commit -m "chore(fiddle): gate fixups for s3proxy source types" || echo "nothing to commit"
```

---

## Self-Review notes (for the executor)

- **Library untouched:** no task edits anything under `lib/` — confirm before finishing.
- **imgproxy-only scope:** `iiif`/`twicpics` opts in `application.ex` keep `path:` only; the `sourceType` field lives on `FiddleState` (imgproxy state) only.
- **HTTP port coupling:** `http://localhost:4000` is hard-coded by decision; if Phoenix runs on a custom `PORT`, the HTTP source type breaks (documented, accepted).
- **Naming consistency:** builder `sourceIdentifierForRequest(source, sourceType)` ↔ parser `parseSourceIdentifier(identifier)`; backend `imgproxy_source_mounts/0`; config key `:s3_source`; bucket `"sources"`.
