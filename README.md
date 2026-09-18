# ImagePipe

ImagePipe is a Plug-based image optimization server with a native path API.
It resolves a configured image source, executes the requested transforms,
negotiates the output format, and sends the encoded image response.

## Project status

ImagePipe is a greenfield, unreleased library. The codebase includes working
native request parsing, request safety checks, transform execution,
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

Mount ImagePipe from a Plug router or Phoenix endpoint with a configured
source adapter:

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
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
      sources: [
        path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}
      ]
    ]
end
```

With that router running at `http://localhost:4000`, this unsigned development
URL requests a 300-pixel-wide image from `/images/beach.jpg`:

```text
http://localhost:4000/w=300/src/images/beach.jpg
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

Configure `keys: [hex_encoded_key]` to require signed native URLs. The
`sig=<mac>` segment authenticates the complete mount-relative request path
after the signature segment. Key lists support rotation: the first key signs,
and all configured keys can verify. Unsigned requests are accepted when no
keys are configured.

## Current support boundaries

The native API currently supports EXIF orientation policy, arbitrary rotation,
resize modes, minimum dimensions, DPR and zoom, guided and explicit-region crops,
flips, anchors and focal points, anchor offsets, crop-ratio correction,
symmetric trimming, canvas extension and placement, object and face cropping,
blur, sharpen, pixelate, grayscale, bitonal, monochrome, duotone, brightness,
contrast, saturation, colorize, gradients, padding, background, image formats,
per-format quality, automatic quality search, byte budgets, encoder controls,
BlurHash, debug headers, expiry, presets, and signed URLs. It accepts local
paths and HTTP(S) source URLs. Invalid requests fail before cache lookup or
source fetch.

EXIF orientation applies once by default. Use `orient=none` to keep the stored
pixel orientation; user rotation and flips still apply. Native trim runs after
orientation, rotation, and flips, so its automatic background comes from the
displayed top-left corner.

Use `dpr=2` for twice the output density and `zoom=1.5` (or `zoom=2,1`)
to scale resize targets. Padding follows DPR; source crops keep their physical
pixel coordinates. `min-w` and `min-h` raise the resize target's minimum size.
Without `enlarge`, source dimensions cap the resize and padding scales down
proportionally. Each `then` group starts with DPR and zoom of 1.

Configure reusable native presets with option strings:

```elixir
plug ImagePipe.Plug,
  sources: [...],
  presets: %{
    "card" => "w=400/h=400/fit=cover",
    "framed" => "preset=card/then/pad=20/bg=fff/format=webp"
  }
```

`/preset=framed/src/images/photo.jpg` expands before request validation.
Preset names use letters, digits, dots, underscores, and hyphens. Nested
references compile at initialization; invalid names, unknown references, and
cycles fail there. Precedence is `default`, named presets in listed order, then explicit
URL options. Single-group presets contribute to the first group. A pipeline
preset supplies the complete sequence and allows request-wide overrides
such as `format=png`, but rejects explicit group options or another pipeline
preset. Presets share cache identity with equivalent explicit requests.

Overrides replace related alternatives: an explicit `anchor`, `focus`, or
`detect` replaces the inherited guide, and `region` replaces an inherited
`crop` together with its ratio settings. Changing a guide also resets its inherited offset. Canvas
mode, anchor, and offset form one override family: supply the desired canvas
settings together. `extend=false` or `extend-ratio=false` disables an inherited
canvas and clears its placement settings. Conflicting alternatives written
together in one preset or the explicit URL are still rejected.

Options within a group have a fixed processing order. Use `then` for a second
pass, for example `/w=500/then/trim=fff/src/images/beach.jpg` to trim after
resizing.

Use `detect=face`, `detect=car,dog`, or `detect=all,face:3` with a crop or
cover resize to select subjects. `anchor=smart-face` blends face detection
with attention. The [content-aware cropping guide](docs/content-aware-gravity.md)
covers optional detector setup, weights, fallback, and strict availability checks.

The [native API contract and capability inventory](docs/native_api_contract.md)
distinguishes implemented options from planned ports. The imgproxy entry point
remains available during the native-only migration while its useful capabilities
are being moved to native.

## Documentation

- [Native API contract](docs/native_api_contract.md) defines native semantics,
  capability retention, and migration ownership.
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
  between dialect request syntax, semantic plan operations, and executable
  transform operations.
- [Execution flow](docs/execution_flow.md) documents the runtime call spine and
  the neutral runtime-geometry resolve loop.
- [Source network policy](docs/source-network-policy.md) documents the default
  SSRF protection on HTTP/HTTPS sources, how to allow private origins
  (`address_policy`), custom DNS resolution (`address_resolver`), and the
  DNS-rebinding limitation.

## Demo

The interactive demo (ImagePipe Fiddle) is a standalone Phoenix app in `fiddle/`.

```sh
mise run setup       # installs library + fiddle deps
mise run fiddle      # boots Phoenix (:4000) + Vite (:5173)
```

Open http://localhost:4000. Native is selected by default; its processing
endpoint is `/native-image`. The option editor supports native paths and
`then` groups, with examples for geometry, object and face crops, pixel effects,
canvas placement, padding, and trim.

![Demo fiddle desktop screenshot](docs/assets/demo-fiddle-desktop.png)

### Tracing (OpenTelemetry → Jaeger)

The fiddle can export its `image_pipe.*` spans to a local Jaeger, demonstrating
the library's OpenTelemetry exporter end to end (see
[the cookbook](docs/cookbook/opentelemetry-jaeger.md)):

```sh
mise run fiddle:sidecars jaeger   # start Jaeger (OTLP + UI) via fiddle/docker-compose.yml
mise run fiddle otel              # boots the dev server with tracing on (FIDDLE_OTEL=1)
```

Issue an `/img` request, then open the Jaeger UI at http://localhost:16686 and
look for the `image_pipe.request` trace under the `image_pipe_fiddle` service.
Plain `mise run fiddle` leaves tracing off (no `FIDDLE_OTEL`), so it needs no
Jaeger.

### Source types (local / S3 / HTTP)

The imgproxy provider can fetch the sample images through three source adapters,
chosen with the fiddle's **Source type** control: the local filesystem, a fake S3,
or HTTP. All three resolve to byte-identical bytes from `priv/static/images`, so
switching source types is a clean adapter comparison.

The **S3** source type needs the opt-in s3proxy sidecar — a fake S3 over the local
filesystem that mirrors `priv/static/images` (`mise run fiddle:sidecars` brings up
both Jaeger and s3proxy; `mise run fiddle:sidecars s3proxy` starts just the fake S3):

```sh
mise run fiddle:sidecars s3proxy   # fake S3 at http://localhost:8081, bucket "sources"
```

The **HTTP** source type needs no sidecar — it fetches the fiddle's own
`Plug.Static` at `http://localhost:4000/images/<file>`.
