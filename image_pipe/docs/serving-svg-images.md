# Serving SVG images

Serve SVG originals like any other image: resized, cropped, and encoded as
PNG, WebP, AVIF, or JPEG. An SVG renders straight at the size each request
needs, so it stays sharp at any size. This guide assumes ImagePipe is running
in your app (see [Getting started with Phoenix](phoenix-getting-started.md))
or as `image_pipe_server`.

## Install SVG support

<!-- tabs-open -->

### Plug

Add `image_pipe_svg` next to `image_pipe`:

```elixir
# mix.exs
defp deps do
  [
    {:image_pipe, "~> 0.4.0"},
    {:image_pipe_svg, "~> 0.1"}
  ]
end
```

`image_pipe_svg` downloads a precompiled native library, so the build needs
no Rust toolchain. ImagePipe renders SVG originals as soon as the package is
compiled in. Without the package, an SVG original fails with `415`.

### image_pipe_server

Every server image renders SVG originals.

<!-- tabs-close -->

## Add fonts for SVG text

SVG text renders only in fonts you supply. ImagePipe never uses the
machine's own fonts, so the same SVG renders the same everywhere. Without
fonts, SVG text isn't drawn at all.

Point `font_dirs` at directories of TrueType or OpenType files (`.ttf`,
`.otf`, `.ttc`, `.otc`), which are searched with their subdirectories. Set
`fallback_family` to one of those fonts for text in a family you didn't
supply, or in a generic family such as `sans-serif`:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe,
   name: MyApp.Images,
   sources: [...],
   svg: [font_dirs: ["/usr/share/fonts/noto"], fallback_family: "Noto Sans"]},
  MyAppWeb.Endpoint
]
```

### image_pipe_server

```toml
[processing.svg]
font_dirs = ["/fonts"]
fallback_family = "Noto Sans"
```

Mount the font directory into the container:

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro -v ./fonts:/fonts:ro ghcr.io/hlindset/image_pipe_server:0.4
```

<!-- tabs-close -->

ImagePipe loads the fonts when it starts and keeps them until it restarts.
A directory that doesn't exist, a file that isn't a valid font, or a
`fallback_family` that none of the fonts has stops ImagePipe from starting.
Cache keys include the fonts and the fallback family, so changing either
makes every cached image miss once.

## Limit the work an SVG can cause

A small SVG can describe a lot of work, such as hundreds of blurred layers,
so ImagePipe estimates the cost of rendering each SVG at the requested size
and rejects one that's too expensive before rendering it. The defaults suit
most images. To allow heavier SVGs, raise `max_render_work`, the estimated
rendering work, which defaults to about a second of rendering:

<!-- tabs-open -->

### Plug

```elixir
svg: [max_render_work: 500_000_000]
```

The `svg` option of `ImagePipe.config/1` lists the other limits.

### image_pipe_server

```toml
[processing.svg]
max_render_work = 500000000
```

The [`[processing]` reference](../../image_pipe_server/docs/server-configuration.md#processing)
lists the other limits.

<!-- tabs-close -->

An SVG original is rejected too when the whole SVG is larger than the
[input pixel limit](deployment.md) at its own size, unless the request
shrinks it below the limit, or has:

- more than 200,000 elements, counting reused content at each use, such as
  `<use>` copies and markers at each point of a line
- entities that expand past 1,000,000 characters
- more than 10,000 bytes of text in one `<text>` element, or 1,000,000 in
  all
- shapes that reach more than 32,767 pixels from the image at the size it
  renders, which the renderer can't draw

Rejected SVGs fail with `413`. An SVG fails with `415` when it isn't valid
XML, nests elements more than 1,024 levels deep, chains references such as
`<use>` too deep, has elements that refer to each other in a loop, defines
an entity whose value holds markup, or has a number larger than 10^15.

## Embed images in SVGs

ImagePipe never reads a file or opens a connection for an SVG, so references
to other files and URLs, in `<image>`, `<use>`, or CSS, render as nothing.
Embed images as `data:` URLs instead. They render when they are PNG, JPEG,
GIF, or WebP and their media type matches their contents, and as nothing
otherwise. Embedded SVGs nest at most two levels deep. An embedded image
over the input pixel limit, or SVGs nested deeper, fail the request with
`413`.

## Size SVGs in requests

An SVG's own size, rounded to whole pixels, is its `width` and `height` at
96 pixels per inch, or its `viewBox` when those are missing, or the extent
of its content when it has neither. Crops and regions measure the SVG at that
size, and resizes keep its aspect ratio. In a very small SVG, rounding
changes that ratio: a `viewBox` of `0 0 1 1.5` is 1×2 pixels, so a resize
makes it twice as tall as it is wide. Give such an SVG a larger `width` and
`height`.

A resize renders the SVG at the requested size, larger than its own size
too, without [`enlarge`](processing/resize.md#enlarge), except in two
cases:

- The SVG at that size would be larger than the input pixel limit. It
  renders as large as the limit allows, and the rendered image is enlarged
  the rest of the way, so its edges blur. A crop with a large resize
  renders the whole SVG at the zoomed scale, so it reaches the limit
  sooner.
- The request [trims](processing/crop.md#trim) in its first
  [group](requesting-images.md#processing-groups). The SVG renders at its
  own size, and `enlarge` applies as it does to a raster image.

Without [`format`](processing/output.md#format), the result is a PNG, or
AVIF or WebP when the browser accepts them, unless an opaque
[`bg`](processing/resize.md#bg) fills its transparency. SVG watermarks
render at the size they are drawn, so a small logo stays sharp at any
[`wm-scale`](processing/watermark.md#wm-scale).

## Check that SVGs render

Turn on the default request log with a line for each stage:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app/application.ex, in start/2
ImagePipe.Telemetry.attach_default_logger(stages: true)
```

### image_pipe_server

```toml
[telemetry]
log_stages = true
```

<!-- tabs-close -->

Then request an SVG original at a width larger than its own. Use your
server's address, and for a Plug add the path you forwarded to
`ImagePipe.Plug`, such as `/images`:

```bash
curl -o logo.png "http://localhost:8080/w=400/src/logo.svg"
```

The log names what rendered (an original or a watermark), the SVG's own
size, and the size it rendered at:

```text
[info] image_pipe source svg_render: ok (original 40x20 rendered at 400x200, 0 images)
```

A rejected SVG names the limit, such as
`svg_render: processing_error (original, input_limit, svg_render_work limit)`.
The [`[:source, :svg_render]`](telemetry-events.md#source-svg_render) event
lists every limit. A watermark SVG that is rejected before it renders logs
[`[:source, :svg_parse]`](telemetry-events.md#source-svg_parse) instead, such as
`svg_parse: processing_error (watermark, input_limit, svg_bytes limit)`.
