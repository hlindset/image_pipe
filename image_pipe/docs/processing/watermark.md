# Watermarks

Watermark options draw an image, such as a logo, over the result of a
[group](../requesting-images.md#processing-groups).

The watermark is the last step of its group, after effects, canvas, padding,
and background, so it covers the whole frame, padding included (see
[processing order](../processing.md#processing-order)). Each group starts
without a watermark. The other `wm-*` options need [`wm`](#wm),
[`wm-src64`, or `wm-enc`](#wm-src64-and-wm-enc) in the same group.

<!-- tabs-open -->

### URL

```text
/w=800/wm=logo/wm-at=bottom-right/wm-offset=16,16/wm-scale=0.2/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(
  resize: [width: 800],
  watermark: :logo,
  watermark_at: :bottom_right,
  watermark_offset: {16, 16},
  watermark_scale: 0.2
)
```

<!-- tabs-close -->

## Watermark assets

### wm

Accepts the name of a watermark defined in the server's configuration:
lowercase letters, digits, `_`, and `-`. Default: no watermark.

Draws that named image. The server's configuration defines which names
exist. A name it doesn't define fails with `400` and `unknown watermark`. The watermark
may come with its own opacity, which [`wm-opacity`](#wm-opacity) multiplies.

<!-- tabs-open -->

### URL

```text
/wm=logo/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, watermark: :logo)
```

<!-- tabs-close -->

### wm-src64 and wm-enc

`wm-src64` accepts an image path in unpadded base64url, written the same way as
after the [`src64/` marker](../requesting-images.md#image-paths). `wm-enc`
accepts an encrypted token, like the `enc/` marker. These tokens need the
server's encryption key, so they are created server-side, for example by the
application that builds your URLs. Default: no watermark.

Draws the image at that path, from the same image sources as the main image.
Both options work only when the server's configuration allows watermarks
named by the request. Otherwise they fail with `400` and
`request watermark sources are not enabled`. A `wm-enc` token that can't be
decrypted answers `404`.

A group takes one watermark: `wm`, `wm-src64`, and `wm-enc` can't be combined,
and using two fails with `400`, such as `wm and wm-src64 are mutually exclusive`.

<!-- tabs-open -->

### URL

```text
/wm-src64=YnJhbmQvbG9nby5wbmc/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, watermark_source: "brand/logo.png")
```

<!-- tabs-close -->

Watermark names, and whether requests may name their own watermarks, are set
in the [Plug configuration](`ImagePipe.config/1`) or the
[server configuration](../../../image_pipe_server/docs/server-configuration.md#processing).

## Size and placement

### wm-opacity

Accepts a [fraction](../requesting-images.md#fractions). Default: `1`.

Sets how opaque the watermark is. The value multiplies any opacity the named
watermark already has, so `wm-opacity=0.5` on a watermark defined at `0.6`
draws it at `0.3`. `wm-opacity=0` draws nothing, and the watermark image isn't
fetched.

<!-- tabs-open -->

### URL

```text
/wm=logo/wm-opacity=0.5/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, watermark: :logo, watermark_opacity: 0.5)
```

<!-- tabs-close -->

### wm-scale

Accepts a number greater than `0` and at most `1`. Default: the watermark's own
size, multiplied by the group's [`dpr`](resize.md#dpr).

Fits the watermark inside that fraction of the frame's width and height,
keeping its aspect ratio. With `wm-scale=0.25` on an 800×600 result, a
watermark fits inside 200×150. A small watermark is enlarged to fit, so a
raster logo can look soft.

<!-- tabs-open -->

### URL

```text
/w=800/wm=logo/wm-scale=0.25/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 800], watermark: :logo, watermark_scale: 0.25)
```

<!-- tabs-close -->

### wm-at

Accepts an [anchor](../requesting-images.md#anchors). Default: `center`.

Places the watermark at that position in the frame.

<!-- tabs-open -->

### URL

```text
/wm=logo/wm-at=bottom-right/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, watermark: :logo, watermark_at: :bottom_right)
```

<!-- tabs-close -->

### wm-offset

Accepts `x,y`, each a [pixel length](../requesting-images.md#pixel-lengths) or
a [percentage](../requesting-images.md#percentages), and either may be
negative. Default: `0,0`.

Moves the watermark from its [`wm-at`](#wm-at) position:

- With a `right` or `bottom` anchor, positive values move it inward, away from
  that edge.
- With a `left`, `top`, or `center` anchor, positive values move it right or
  down.

Pixels are multiplied by the group's `dpr`. A percentage `x` is of the frame
width, and a percentage `y` of the frame height. The offset isn't limited to
the frame: the part of the watermark outside it is cut off, and a watermark
moved completely outside draws nothing.

<!-- tabs-open -->

### URL

```text
/wm=logo/wm-at=bottom-right/wm-offset=16,5pct/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  watermark: :logo,
  watermark_at: :bottom_right,
  watermark_offset: {16, {:pct, 5}}
)
```

<!-- tabs-close -->

### wm-tile

A [flag](../requesting-images.md#flags). Default: off.

Repeats the watermark across the whole frame. One copy sits where the single
watermark would be, after [`wm-at`](#wm-at) and [`wm-offset`](#wm-offset), and
the copies repeat from there in every direction.

<!-- tabs-open -->

### URL

```text
/wm=logo/wm-tile/wm-scale=0.1/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, watermark: :logo, watermark_tile: true, watermark_scale: 0.1)
```

<!-- tabs-close -->

### wm-gap

Accepts `x,y`, each a pixel length or a percentage, not negative. Default:
`0,0`.

Adds space to the right of and below each tiled copy. Pixels are multiplied by
the group's `dpr`, and percentages are of the frame width (`x`) and height
(`y`). Requires [`wm-tile`](#wm-tile). Without it, the request fails with `400`
and `wm-gap requires wm-tile`.

<!-- tabs-open -->

### URL

```text
/wm=logo/wm-tile/wm-gap=20,5pct/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  watermark: :logo,
  watermark_tile: true,
  watermark_gap: {20, {:pct, 5}}
)
```

<!-- tabs-close -->

## Watermark appearance

- Transparent parts of the watermark leave the image underneath unchanged.
- An image without transparency stays opaque. A transparent image becomes
  opaque where the watermark is opaque.
- The watermark is turned upright according to its own EXIF orientation.
- An animated or multi-page watermark file draws a single still frame.
- A color watermark on a grayscale image turns the result into a color image.
- The response's metadata and color profile come from the main image, never
  from the watermark.

## Watermark errors

These fail with `400` before any image is fetched:

- An unknown `wm` name, or `wm-src64` or `wm-enc` when request-named watermarks
  aren't allowed.
- Two of `wm`, `wm-src64`, and `wm-enc` in one group.
- Another `wm-*` option without a watermark in its group, such as
  `wm-opacity requires wm, wm-src64, or wm-enc`.

A watermark image that can't be fetched fails the whole request with the same
status as a main image would, such as `404` when it doesn't exist or `413` when
it is too large. A watermark file that isn't a supported image answers `415`.
[Error responses](../errors.md) lists the statuses.
