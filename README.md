# ImagePipe

ImagePipe is a Plug-based image optimization server. It parses path-oriented
image requests, resolves a configured image source, executes a product-neutral
`ImagePipe.Plan`, negotiates output format, and sends the encoded image
response.

The current public compatibility target is an Imgproxy-style path API through
`ImagePipe.Parser.Imgproxy`. Internally, ImagePipe translates Imgproxy syntax
into its own plan, output, transform, cache, and response data structures.

## Project status

ImagePipe is a greenfield, unreleased library. The codebase includes working
Imgproxy-style request parsing, request safety checks, transform execution,
source adapters, output negotiation, filesystem response caching, telemetry
spans, and a local demo server.

The package metadata exists for release evaluation, but no Hex package exists
yet. Treat the `0.1.0` API as subject to change until the first release.

## Installation

For local evaluation, depend on a checkout:

```elixir
def deps do
  [
    {:image_pipe, path: "../image_pipe"}
  ]
end
```

After the Hex package exists, depend on the package version:

```elixir
def deps do
  [
    {:image_pipe, "~> 0.1.0"}
  ]
end
```

## Minimal mount

Mount ImagePipe from a Plug router or Phoenix endpoint with a configured source
adapter and parser:

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ]
  ]
```

For a local Plug server that reads files from `priv/static/images`, point the
path source adapter at `priv/static`:

```elixir
defmodule MyApp.ImageRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/",
    to: ImagePipe.Plug,
    init_opts: [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}
      ]
    ]
end
```

With that router running at `http://localhost:4000`, this unsigned development
URL requests a 300-pixel-wide image from `/images/beach.jpg`:

```text
http://localhost:4000/_/w:300/plain/images/beach.jpg
```

To accept both HTTP and HTTPS source URLs, configure the shared `:url` source
adapter:

```elixir
sources: [
  url: {ImagePipe.Source.HTTP, allowed_hosts: ["assets.example.com"]}
]
```

Use `:http` or `:https` instead to enable only one scheme, or when the schemes
need different adapter options.

By default, HTTP/HTTPS sources refuse to connect to non-public addresses and
re-check the policy on every redirect hop. See
[Source network policy](docs/source-network-policy.md) to allow private origins.

`_` and `unsafe` work only without Imgproxy signing. Configured signing requires
a valid HMAC signature or an exact configured trusted signature.

## Current support boundaries

ImagePipe currently supports the Imgproxy-style path parser, selected resize,
crop, orientation, canvas, padding, background, blur, sharpen, pixelate, output,
cachebuster, expiry, filename, attachment, and preset options documented in the
support matrix.
Unsupported parser and planner requests fail before cache lookup or source
fetch.

The first slice supports local path sources, HTTP and HTTPS URL sources, and
S3-compatible object sources. ImagePipe currently lacks other provider dialects,
object detection, watermarking, metadata stripping, video processing, and raw
source passthrough. Missing Imgproxy options fail or remain absent as
documented. ImagePipe doesn't ignore them.

URL option order doesn't define transform execution order. The Imgproxy parser
normalizes aliases and conflict resolution, then the planner emits operations in
ImagePipe's fixed plan order.

## Documentation

- [Imgproxy path API](docs/imgproxy_path_api.md) documents URL shape, option
  parsing, conflict resolution, signing, presets, output selection, and
  fixed operation ordering.
- [Imgproxy support matrix](docs/imgproxy_support_matrix.md) lists supported,
  partial, rejected, missing, and out-of-scope Imgproxy features.
- [Content-aware gravity](docs/content-aware-gravity.md) documents smart crop
  (`g:sm`) and how a host enables optional ML face detection (`g:obj:face`,
  face-assisted `g:sm`) — the `image_vision` + `ortex` dependencies, the
  `detector` / `detector_required` options, fallback behavior, warmup, and
  custom detectors.
- [Cache](docs/cache.md) documents filesystem response caching, cache keys,
  stored headers, failure modes, and cache safety boundaries.
- [CDN HTTP caching](docs/cdn-http-cache.md) documents generated
  `Cache-Control`, ETags, `Vary: Accept`, source stability, and CDN behavior.
- [Operational notes](docs/operational_notes.md) documents request safety,
  source fetching, decode planning, multi-pipeline behavior, and automatic
  output negotiation.
- [Telemetry](docs/telemetry.md) documents emitted span events, measurements,
  metadata, and handler examples.
- [Transform operations](docs/transform_operations.md) documents the boundary
  between parser request syntax, semantic plan operations, and executable
  transform operations.
- [Source network policy](docs/source-network-policy.md) documents the default
  SSRF protection on HTTP/HTTPS sources, how to allow private origins
  (`address_policy`), custom DNS resolution (`address_resolver`), and the
  DNS-rebinding limitation.

## Demo

The interactive demo (ImagePipe Fiddle) is a standalone Phoenix app in `fiddle/`.

```sh
mise run setup       # installs library + fiddle deps
mise run server      # boots Phoenix (:4000) + Vite (:5173)
```

Open http://localhost:4000. The imgproxy-compatible processing endpoint is
mounted at `/img`.

![Demo fiddle desktop screenshot](docs/assets/demo-fiddle-desktop.png)

### Tracing (OpenTelemetry → Jaeger)

The fiddle can export its `image_pipe.*` spans to a local Jaeger, demonstrating
the library's OpenTelemetry exporter end to end (see
[the cookbook](docs/cookbook/opentelemetry-jaeger.md)):

```sh
mise run sidecars jaeger   # start Jaeger (OTLP + UI) via fiddle/docker-compose.yml
mise run server:otel       # boots the dev server with tracing on (FIDDLE_OTEL=1)
```

Issue an `/img` request, then open the Jaeger UI at http://localhost:16686 and
look for the `image_pipe.request` trace under the `image_pipe_fiddle` service.
Plain `mise run server` leaves tracing off (no `FIDDLE_OTEL`), so it needs no
Jaeger.

### Source types (local / S3 / HTTP)

The imgproxy provider can fetch the sample images through three source adapters,
chosen with the fiddle's **Source type** control: the local filesystem, a fake S3,
or HTTP. All three resolve to byte-identical bytes from `priv/static/images`, so
switching source types is a clean adapter comparison.

The **S3** source type needs the opt-in s3proxy sidecar — a fake S3 over the local
filesystem that mirrors `priv/static/images` (`mise run sidecars` brings up both
Jaeger and s3proxy; `mise run sidecars s3proxy` starts just the fake S3):

```sh
mise run sidecars s3proxy   # fake S3 at http://localhost:8081, bucket "sources"
```

The **HTTP** source type needs no sidecar — it fetches the fiddle's own
`Plug.Static` at `http://localhost:4000/images/<file>`.
