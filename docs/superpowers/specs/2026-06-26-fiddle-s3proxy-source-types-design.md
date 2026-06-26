# Fiddle: s3proxy fake-S3 + multi-source-type selector

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — pending implementation plan
**Scope:** `fiddle/` demo app only. No `ImagePipe` library changes.

## Problem

The fiddle exercises the imgproxy compatibility provider against sample images, but
only through the **local filesystem** source adapter (`local:///images/<file>` →
`ImagePipe.Source.File`). The S3 (`ImagePipe.Source.S3`) and HTTP
(`ImagePipe.Source.HTTP`) source adapters already exist and are already understood by
the imgproxy parser (`s3://bucket/key`, `http(s)://host/path`), but there is no way to
drive them from the demo. We want to:

1. Stand up a **fake S3** endpoint, backed by the local filesystem, that mirrors the
   existing sample images — so the fiddle can exercise the S3 source path end-to-end
   without a real cloud bucket.
2. Extend the fiddle's imgproxy request toolbox with a **source-type selector** so a
   demo user can pick whether a given sample image is fetched via local, S3, or HTTP.

## Key insight

All three source adapters can resolve to **byte-identical bytes** from the same
`fiddle/priv/static/images/` set:

| Source type | Request source identifier         | Adapter              | Backing bytes                         |
|-------------|-----------------------------------|----------------------|---------------------------------------|
| local       | `local:///images/dog.jpg`         | `Source.File`        | `priv/static/images/dog.jpg`          |
| s3          | `s3://sources/dog.jpg`            | `Source.S3` → s3proxy| `priv/static/images/dog.jpg` (mounted)|
| http        | `http://localhost:4000/images/dog.jpg` | `Source.HTTP`   | `priv/static/images/dog.jpg` (Plug.Static) |

This makes the fiddle a true **side-by-side comparison of source adapters on identical
inputs**. The library needs **zero changes** — all three adapters and the imgproxy
scheme parsing already exist.

Confirmed facts:
- `ImagePipe.Source.S3` requires a `region`, an `endpoint` (http allowed, with a port),
  and `credentials` (validated at `Plug.init`). All satisfiable by s3proxy.
- The `sources:` keyword routes an `s3://` `Plan.Source.Object` (`adapter: :s3`) to the
  adapter mounted under the `s3:` key, and `http(s)://` `Plan.Source.URL` to the adapter
  mounted under `url:` (which `expand_url_source_config/1` fans out to `:http`/`:https`).
- `ImagePipe.Source.HTTP` requires explicit `allowed_hosts` and denies loopback by
  default; permitting `localhost`/`127.0.0.1` needs `allow_loopback: true`.
- Phoenix serves `priv/static/images/` via `Plug.Static` (`static_paths/0` includes
  `images`) on the endpoint's own HTTP listener, dev port **4000**
  (`PORT` default in `runtime.exs`). `static_url: [port: 5173]` only affects generated
  asset URLs, not where `Plug.Static` listens — so a server-side fetch of
  `http://127.0.0.1:4000/images/<file>` is served by `Plug.Static`.

## Design

### 1. Compose service — `fiddle/docker-compose.yml`

Add an `s3proxy` service alongside the existing `jaeger` service, using the
`andrewgaul/s3proxy` image with the jclouds **filesystem** backend:

- `JCLOUDS_PROVIDER=filesystem`, filesystem basedir `/data`.
- Bind-mount `./priv/static/images` → `/data/sources:ro` (read-only). The top-level dir
  under basedir becomes the bucket, so bucket `sources` == the images dir.
- Fixed dev credentials via `S3PROXY_AUTHORIZATION=aws-v2-or-v4`,
  `S3PROXY_IDENTITY`, `S3PROXY_CREDENTIAL`.
- Host port **8081** (avoids 4000/5173 and Jaeger's ports).

Because `andrewgaul/s3proxy` listens on container port 80 by default, map `8081:80`
(or set `S3PROXY_ENDPOINT=http://0.0.0.0:80`).

### 2. mise tasks — `mise.toml`

The existing `[tasks.jaeger]` runs `docker compose -f fiddle/docker-compose.yml up`,
which (once a second service exists) would start **both** services. Scope each task to
its own service so they start independently:

- `[tasks.jaeger]` → `... up jaeger`
- `[tasks.s3proxy]` (new) → `... up s3proxy`, described as starting the local fake-S3
  used by the fiddle's S3 source type.

### 3. Fiddle backend — `fiddle/lib/image_pipe_fiddle/application.ex`

In `build_imgproxy_opts/0`, add two mounts to the existing `sources:` keyword (which
currently only has `path:`):

```elixir
sources: [
  path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted},
  s3:   {ImagePipe.Source.S3, s3_source_opts},
  url:  {ImagePipe.Source.HTTP, allowed_hosts: ["localhost", "127.0.0.1"], allow_loopback: true}
]
```

The S3 options are **config-driven**, read from a new application-env block (see §4):

```elixir
s3_source_opts = [
  default: [
    region: s3_cfg[:region],
    endpoint: s3_cfg[:endpoint],
    credentials: [
      access_key_id: s3_cfg[:access_key_id],
      secret_access_key: s3_cfg[:secret_access_key]
    ]
  ],
  buckets: %{"sources" => []}
]
```

Scoped to the **imgproxy** provider only. `build_iiif_opts/0` and `build_twicpics_opts/0`
keep `path:` only.

> **Safety note (documented inline):** `allow_loopback: true` plus loopback
> `allowed_hosts` is a deliberate SSRF relaxation that exists **only in the fiddle demo**,
> never in the `ImagePipe` library defaults. The comment must say why (the fiddle's HTTP
> source type fetches the fiddle's own `Plug.Static` over loopback).

### 4. Config — `fiddle/config/config.exs` (+ `dev.exs` if needed)

New block with the s3proxy connection defaults:

```elixir
config :image_pipe_fiddle, :s3_source,
  region: "us-east-1",
  endpoint: "http://localhost:8081",
  access_key_id: "fiddle",
  secret_access_key: "fiddlesecret"
```

`build_imgproxy_opts/0` reads it via `Application.fetch_env!/2` (or `get_env` with a
fallback). Keeping it in config keeps the s3proxy credential/endpoint coordinates in one
place that matches the compose env values.

### 5. Svelte UI

**State — `fiddle/assets/fiddle-url-state.ts`:**
Add `sourceType: "local" | "s3" | "http"` to the **imgproxy** slice, default `"local"`,
serialized/round-tripped through the URL state exactly like the other imgproxy controls.
(iiif/twicpics slices unchanged.)

**Path building — `fiddle/assets/processing-path.ts`:**
`sourceIdentifierForRequest(source, sourceType)` branches on `sourceType`. `source`
is the sample path (e.g. `images/dog.jpg`); `<file>` is its basename:

- `local` → `local:///images/<file>`  (unchanged behavior)
- `s3`    → `s3://sources/<file>`
- `http`  → `http://localhost:4000/images/<file>`

The HTTP port `4000` is hard-coded (accepted coupling — breaks only if Phoenix is run on
a custom `PORT`, which the demo doesn't do).

**Control — `fiddle/assets/App.svelte`:**
A new **"Source type"** `<select>` (Local | S3 | HTTP) in the imgproxy request section,
adjacent to the existing "Source image" picker, bound to the imgproxy `sourceType` state.

### 6. Testing

- **JS (vitest):** unit-test `sourceIdentifierForRequest` for all three source types
  (correct scheme/host/key per type), and round-trip `sourceType` through the URL-state
  encode/decode.
- **Elixir:** a fiddle test asserting `build_imgproxy_opts/0` (i.e. `ImagePipe.Plug.init`)
  accepts the new `s3:` and `url:` mounts — config validation happens at boot, so this
  pins that the mounts are well-formed. No live s3proxy fetch in CI (the service is
  opt-in, the same way Jaeger isn't required for the default gate).
- **Manual:** run `mise run s3proxy`, toggle source types in the UI against the same
  sample image, confirm identical output across local/s3/http.

## Out of scope (YAGNI)

- Bucket browsing / object listing in the UI.
- Free-text bucket/key inputs (we mirror the fixed sample set).
- MinIO / LocalStack (s3proxy's filesystem backend mirrors the dir directly, which is
  exactly the "mirror the local sources" requirement).
- Always-on dev stack (s3proxy stays opt-in like Jaeger).
- HTTP/S3 source types for the iiif/twicpics providers.
- Threading the Phoenix `PORT` into the frontend (4000 hard-coded by decision).

## Files touched

- `fiddle/docker-compose.yml` — add `s3proxy` service.
- `mise.toml` — scope `jaeger` task, add `s3proxy` task.
- `fiddle/config/config.exs` — add `:s3_source` config block.
- `fiddle/lib/image_pipe_fiddle/application.ex` — add `s3:`/`url:` mounts (imgproxy only).
- `fiddle/assets/fiddle-url-state.ts` — `sourceType` state + serialization.
- `fiddle/assets/processing-path.ts` — `sourceIdentifierForRequest` branching.
- `fiddle/assets/App.svelte` — "Source type" select control.
- JS + Elixir tests per §6.
- A short README/usage note (where `mise run jaeger` is documented) for `mise run s3proxy`.
