# Watermarks

Beads `image_plug-j2z`. Draft for agreement; nothing here is implemented.

## Summary

Add image watermarks as the last stage of a group. A watermark asset is a
second source: either a host-named entry (`wm=logo`) or, when the host opts
in, a request-supplied source (`wm-src64=…`, `wm-enc=…`). Both resolve
through the configured source mounts and the input cache exactly like the
main source, so fetch restrictions, limits, revalidation, and identity work
unchanged. Placement reuses named anchors and signed offsets; size is a
fraction of the frame; tiling is optional. Text, rotation, and shadows are
later slices.

## Findings

**imgproxy.** OSS has one server-wide asset (`IMGPROXY_WATERMARK_PATH`,
`_URL`, or `_DATA`) with base opacity `IMGPROXY_WATERMARK_OPACITY`.
`wm:opacity:position:x:y:scale` multiplies the request opacity by the base,
places by compass gravity or `re` (replicate), and runs after every other
step. With `scale > 0` the asset is fitted, with enlargement, into
`scale × result width` by `scale × result height`; without it the asset keeps
its natural size, ignoring DPR. Offsets scale with DPR. Under `re` the
offsets become tile spacing, and values below 1 are fractions of the image.
The asset's headers are stripped before compositing. Pro adds `wmu:<url>`
with an ARC cache of 256 assets (`processing/watermark.go`,
`auximageprovider/static_config.go`).

**ImagePipe today.** The fixed stage order ends with canvas, padding,
background. Named anchors and signed pixel/percentage offsets already exist
for `extend-at`/`extend-offset`. A multi-page or animated source decodes one
image, so output is always a single frame. `Execution` prepares exactly one
source: one `Acquisition`, one input-cache record, and one `stale?` flag,
which also gate the pre-fetch `304`.

## Design

### Request options

Group options, reset at `-` like canvas options:

| Option | Values and default |
| --- | --- |
| `wm` | Host asset name |
| `wm-src64` | Unpadded base64url source reference, decoded like `src64` |
| `wm-enc` | Source concealment token, decoded like `enc` |
| `wm-opacity` | 0 to 1, default 1; multiplies the asset's base opacity |
| `wm-scale` | Fraction of the frame, greater than 0 and at most 1 |
| `wm-at` | Named anchor, default `center` |
| `wm-offset` | `x,y` signed pixels or percentages, default `0,0` |
| `wm-tile` | Bare flag; `=false` disables |
| `wm-gap` | `x,y` non-negative pixels or percentages, requires `wm-tile` |

Exactly one of `wm`, `wm-src64`, and `wm-enc` names the asset. The other
`wm-*` options require one of them; without an asset they are inert and
reject. Option values are single path segments, so a request source cannot
use the `src/…` tail form. The URL builder takes
`watermark: [asset: :logo | source: …, opacity:, scale:, at:, offset:,
tile:, gap:]`.

A zero effective opacity canonicalizes to absence: no asset is resolved or
fetched, and identity matches the unwatermarked request.

### Host configuration

```elixir
watermarks: %{
  logo: [source: "s3://brand/logo.png", opacity: 0.6],
  badge: [source: "brand/badge.svg"]
},
request_watermarks: false
```

Names match `[a-z0-9_-]+`. `source` uses the `src` grammar and is parsed
at initialization; it must route to a configured mount, and an invalid
entry raises. `opacity` is the base opacity, default 1. Presets may set
`wm` and the other options like any group option. `request_watermarks`
gates `wm-src64` and `wm-enc`; it defaults to `false` because overlaying
caller-chosen content is a product decision, even where mounts already
confine what can be fetched.

### Stage and geometry

The fixed stage order becomes rotate, flip, trim, source crop,
resize/result crop, effects, canvas, padding, background, watermark. The
watermark addresses the display frame left by background, including canvas
and padding, so `pad=20/wm=logo/wm-at=bottom-right` sits in the padding
corner. A later `-` group receives the watermarked result.

Sizing:

- With `wm-scale=s`, the asset is fitted into `s × frame width` by
  `s × frame height`, preserving aspect ratio and allowing enlargement.
  Upscaled raster assets soften; vector assets stay sharp.
- Without `wm-scale`, the asset is drawn at its natural size times the
  group's effective DPR, so a `dpr=2` request does not get a half-size mark.
- Dimensions round once to integer pixels, minimum 1.

Placement uses the canvas-offset rules: the anchor places the asset inside
the frame, positive offsets move inward from right/bottom and forward from
left/top/center, pixels scale by effective DPR, and percentages resolve
against the frame. Unlike canvas placement the result is not clamped: an
offset may push the asset partly off the frame, and the overflow is clipped.
An asset entirely outside the frame is a no-op, not an error.

Tiling repeats the sized asset across the whole frame. One tile sits where
the non-tiled asset would; the grid extends in every direction from it.
`wm-gap` adds spacing between tiles, pixels scaled by effective DPR and
percentages resolved against the frame; it replaces imgproxy's
offsets-as-spacing and below-1 fraction rule with explicit units.

### Compositing, color, and alpha

The asset decodes its default image (first frame or page) with EXIF
auto-orientation, and goes through the same input color management as the
main source into the working space, including a high-bit-depth working
space under effective HDR preservation. All asset metadata, including its
ICC profile, is dropped: output metadata and profile policy describe the
main source only.

An asset without alpha gets an opaque alpha band. Opacity multiplies the
asset alpha, then the asset composites `over` the frame (libvips handles
premultiplication). A frame without alpha keeps none; a transparent frame
gains coverage where the asset is opaque, and background does not fill
behind a watermark because background runs first.

The asset decodes at full resolution: its target size depends on the
watermark-stage frame, which is unknown at decode time. Decode follows the
loader allowlist, which rejects SVG like any other source, and counts against
`max_input_pixels` and `max_input_frames` on its own.

### Materialization

The sized asset or tile is small and held in memory. Compositing it at a
fixed position, and compositing a replicated tile plane, are expected to be
sequential-safe on the frame: `requires_materialization?/1` returns `false`
only after the sequential-vs-random equivalence test and property test pass
for placed, clipped, and tiled cases.

### Second-source execution

`Execution` gains auxiliary inputs. After parsing, each distinct watermark
asset across all groups resolves through `Source.resolve/3` with the same
mounts and runtime options as the main source, then goes through the same
input-cache preparation, giving its own `Acquisition`, input key, record, and
staleness. Assets with equal source identity are fetched once per request.

Stale asset records revalidate synchronously during prepare rather than in
the background: the asset's byte identity must be current before the
conditional gate. Asset bodies are read into memory and their input leases
released before generation. Response freshness headers follow the most
restrictive input record, and a storage-denying or unstable asset narrows the
main source's cache semantics.

- Parse and configuration failures (unknown name, `wm-src64` without
  `request_watermarks`, malformed token, inert options) return before any
  source or cache access.
- Asset fetch failures map to the same statuses as main-source failures; a
  request never silently drops its watermark. Asset decode failures are
  `{:decode, _}` (415).
- The pre-fetch `304` requires every input's byte identity; the context is
  stale when any input is stale.

### Concurrency

Asset acquisition runs concurrently with the main source, so a cold request
waits for the slower fetch rather than the sum of both. Named assets are
usually input-cache hits, so this matters most for request-supplied assets
and cold caches.

- Acquisition starts in `Execution.open` after an output-cache miss, where
  the main acquisition starts. Output-cache hits and `304` responses fetch
  neither source.
- Each distinct asset runs in a `Task.Supervisor.async_nolink` task under
  `ImagePipe.ProcessingPool.Tasks`, adopting the trace context the way
  `Execution.Overlap` does. The task reads the input cache or fetches,
  revalidating when stale, and loads the asset header. The main source is
  acquired in the calling process as today.
- Execution awaits every asset before transform execution, because the
  executor builds the whole pipeline at once. Sizing happens in the
  operation, since the target depends on the watermark-stage frame.
- A main-source fetch or decode failure shuts the asset tasks down. An
  asset failure determines the request status when awaited; the main fetch
  is not interrupted by it, since that would require a cancellable main
  acquisition.
- Without the input cache, the main source is fetched inside the decode
  bracket on a processing-pool worker. A task can only be awaited by the
  process that started it, so that worker starts the asset reads itself,
  just before its source fetch, and awaits them before transforming.
- Asset acquisition skips `Execution.Overlap`. Overlap starts processing the
  main request against a partially downloaded body; the asset is not that
  body. A request with any watermark skips overlap entirely.

The transform boundary stays free of sources: execution decodes assets and
hands them to the executor as data keyed by the operation's asset reference.
The `Watermark` operation struct carries the reference and resolved
parameters, never a source.

### Identity

Representation identity includes, per group, the resolved asset's source
identity, its base opacity, and every canonical `wm-*` value. The host entry
name is excluded, like preset names: renaming an entry keeps identity, and
pointing it at a different source changes it. The cache key and ETag both
take the asset's byte-identity seed; the ETag is strong only when every
input's seed is strong, and any `:none` input yields no ETag and
`Cache-Control: no-store`. A conditional GET answers `304` before fetching
either source.

### Telemetry

Each asset acquisition runs in a `[:source, :watermark]` span with `:phase`
(`:prepare` or `:open`); the asset's resolve, fetch, and input-cache spans
nest inside it, across the task hop. This avoids threading a role through every
source adapter. The default Logger and Capture subscribe to it. The watermark
operation uses the existing per-operation span.

### Terminals

`output=info` rejects `wm-*` like other group options. BlurHash and LQIP CSS
apply all groups, so a watermark affects their pixels like any other stage.

### Out of scope

Text watermarks, rotation, shadows, blend modes other than `over`, per-frame
animation handling, and asset page selection.

## Implementation slices

1. Auxiliary inputs in `Execution` and host-named assets: config, `wm` and
   placement options, operation, identity, telemetry, Fiddle, docs.
2. `wm-src64`, `wm-enc`, and `request_watermarks`: grammar, the opt-in gate,
   and builder support on top of slice 1.

The standalone server takes `[processing] watermarks.<name>` tables and
`request_watermarks`.

## Tests

- `image_pipe_url`: parse and build every option, mutual exclusion of asset
  forms, inert-option and range errors, order-insensitivity, zero opacity
  canonicalizing to absence.
- Config: entry validation, unknown mount, init-time source parse failures.
- Wire: decoded-pixel tests for each anchor, signed offsets, DPR scaling of
  natural size and offsets, `wm-scale`, tiling and gaps, partial clipping,
  off-frame no-op, alpha and non-alpha assets on opaque and transparent
  frames, EXIF-rotated asset, watermark in padding after background, and a
  watermark followed by a `-` group.
- Failures before side effects: unknown name and gated request sources fetch
  neither source nor cache. Asset 404 and decode failures map to their
  statuses.
- Cache and conditional: asset revision changes key and ETag, renamed entry
  keeps both, `:none` asset yields `no-store`, `304` without fetching either
  source, deduplicated fetch for a repeated asset, stale asset revalidation.
- Sequential-safety harness and property test for the operation.
- Telemetry: role metadata in Logger output and Capture spans, with a private
  `telemetry_prefix`.
