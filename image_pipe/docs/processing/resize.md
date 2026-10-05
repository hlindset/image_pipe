# Resize and layout

These options set the size and shape of the image, its pixel density, and the
canvas, padding, and background around it. Values use the shared
[option value syntax](../requesting-images.md#option-values), and
[processing order](../processing.md#processing-order) shows which steps run
before and after the resize.

The result can't exceed the maximum output size set in the
[Plug configuration](`ImagePipe.config/1`) or
[server configuration](../../../image_pipe_server/docs/server-configuration.md#processing).
A larger result is scaled down to fit rather than rejected.

## Resize

### w and h

Accepts a [pixel length](../requesting-images.md#pixel-lengths) of 1 or more,
in whole pixels, or `auto`. Default: none.

Sets the width and height of the box the image is resized into. How the image
fills the box is set by [`fit`](#fit), which defaults to `contain`. With only
one of them, or with the other set to `auto`, the other dimension follows the
image's aspect ratio, except under `fit=stretch`. `auto` needs a number in the
other dimension or in [`min-w` or `min-h`](#min-w-and-min-h), and is
[ignored](../requesting-images.md#ignored-options) without one.

Without [`enlarge`](#enlarge), the resized image is never larger than the
source. A 300-pixel-wide source requested with `w=400` comes out 300 pixels
wide.

<!-- tabs-open -->

### URL

```text
/w=400/h=300/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 300])
```

<!-- tabs-close -->

### fit

Accepts one of these [named values](../requesting-images.md#named-values).
Default: `contain`.

- `contain` fits the whole image inside the box. One side can come out
  shorter than the box.
- `cover` fills the box and cuts off what doesn't fit. The center is kept
  unless [`anchor`, `focus`, or `detect`](crop.md#crop-guides) sets another
  part.
- `stretch` resizes the width and height separately to the box, which
  distorts the image when the aspect ratios differ. With only `w`, the height
  stays at the source height, and with only `h`, the width does.
- `auto` uses `cover` when the source and the box are both landscape or both
  portrait, and `contain` otherwise. A square counts as landscape. With only
  one of `w` and `h`, it uses `contain`.

`fit` needs a number in `w`, `h`, `min-w`, or `min-h` in the same group, and
is ignored without one.

Without `enlarge`, a `cover` result for a small source keeps the box's aspect
ratio at a smaller size, because the box is scaled down to fit the source
before cropping. A 300×300 source with `w=400/h=300/fit=cover` comes out
300×225.

<!-- tabs-open -->

### URL

```text
/w=400/h=300/fit=cover/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 300, fit: :cover])
```

<!-- tabs-close -->

### enlarge

A [boolean](../requesting-images.md#booleans). Default: `false`.

Allows the result to be larger than the source. Without it, a source smaller
than the requested size keeps its own size, or shrinks to keep the box's aspect
ratio under [`fit=cover`](#fit). `enlarge` needs a number in `w`, `h`, `min-w`,
or `min-h` in the same group, and is ignored without one.

<!-- tabs-open -->

### URL

```text
/w=1200/enlarge/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 1200, enlarge: true])
```

<!-- tabs-close -->

### min-w and min-h

Accepts a pixel length of 1 or more, in whole pixels. Default: none.

Sets the smallest width or height the resized image may have. When the
target from `w` and `h` is smaller, ImagePipe enlarges the whole target,
keeping its aspect ratio, until it meets both minimums. Without `w` or `h`,
the target starts at the source's own size.

The minimums don't override [`enlarge`](#enlarge): without it, the result
still can't be larger than the source, so `min-w` or `min-h` alone changes
nothing.

A 2:1 source at least 600 pixels wide, requested with `w=400/min-h=300`,
comes out 600×300, because 400 pixels wide would make it only 200 pixels high.

<!-- tabs-open -->

### URL

```text
/w=400/min-h=300/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, min_height: 300])
```

<!-- tabs-close -->

### zoom

Accepts a positive [number](../requesting-images.md#numbers), or an `x,y`
[pair](../requesting-images.md#pairs-and-lists) of them. Default: `1`.

Multiplies `w` and `h` before `fit` is applied, both by the one number or each
by its own. With only `min-w` or `min-h`, it multiplies the source's size. An
`auto` dimension follows the zoomed one, so `w=400/zoom=2,1` gives an
800-pixel-wide image that keeps its aspect ratio.

Zoom doesn't change the [canvas](#extend-and-extend-ratio), padding, or
offsets. A `zoom` other than `1` needs a number in `w`, `h`, `min-w`, or
`min-h` in the same group, and is ignored without one.

<!-- tabs-open -->

### URL

```text
/w=400/zoom=1.5/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, zoom: 1.5])
```

<!-- tabs-close -->

### dpr

Accepts a positive number, the device pixel ratio. Default: `1`.

Multiplies the sizes you request in pixels: `w`, `h`, `min-w`, `min-h`, the
`extend` canvas, `pad`, `extend-offset`, and an `anchor-offset` on a cover
resize. `/w=400/dpr=2` gives an 800-pixel-wide image, from a source at least
that wide, for a 400-pixel slot on a high-density screen.

`dpr` doesn't change percentages, or the sizes and offsets of a
[`crop` or `region`](crop.md#trim-and-crop), which are measured in pixels of
the image being cropped.

- Without `w`, `h`, `min-w`, or `min-h` there is nothing to resize, so the
  image keeps its own size. `pad` is still multiplied: `/pad=10/dpr=2` adds
  20 pixels on each side.
- Without [`enlarge`](#enlarge), a source too small to reach the requested
  size lowers the density used for padding, the canvas, and offsets to match
  the size actually reached. It never goes below the smaller of 1 and the
  requested `dpr`. A 150×150 source with `w=100/h=100/dpr=2/pad=10`
  reaches 1.5× instead of 2×, so it comes out as 150×150 pixels of image with
  15 pixels of padding on each side, 180×180 in all. Adding `enlarge` gives
  240×240.

<!-- tabs-open -->

### URL

```text
/w=400/h=300/fit=cover/dpr=2/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 300, fit: :cover], dpr: 2)
```

<!-- tabs-close -->

## Canvas, padding, and background

Added space is transparent until [`bg`](#bg) fills it.

### extend and extend-ratio

Each is a [boolean](../requesting-images.md#booleans). Default: `false`.

- `extend` places the image on a canvas of `w` × `h` pixels (times `dpr`).
- `extend-ratio` adds space along one axis so the result has the aspect ratio
  `w`:`h`.

[`extend-at`](#extend-at-and-extend-offset) sets where the image sits on the
canvas, the center by default.

Neither scales nor crops the image. Each needs numbers in both `w` and `h`,
and is ignored without them. Using both in one group fails with `400`. The
canvas is never smaller than the image, so `extend` changes nothing when the
image already fills the box, as with `fit=cover`.

A source smaller than the box keeps its size without [`enlarge`](#enlarge): a
120×90 source with `w=300/h=200/extend` sits at 120×90 in the middle of a
300×200 canvas.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/extend/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 400], extend: true)
```

<!-- tabs-close -->

### extend-at and extend-offset

`extend-at` accepts an [anchor](../requesting-images.md#anchors). Default:
`center`.

`extend-offset` accepts an `x,y` pair of pixel lengths or
[percentages](../requesting-images.md#percentages), either of which can be
negative. Percentages are of the canvas width and height. Pixels are
multiplied by `dpr`. Default: `0,0`.

`extend-at` sets where the image sits on the canvas, and `extend-offset` moves
it from there. Positive values move it right and down from a left, top, or
center anchor, and inward from a right or bottom anchor. The image always stays
inside the canvas. Both need `extend` or `extend-ratio` in the same group, and
are ignored without one.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/extend/extend-at=bottom/extend-offset=0,10/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  resize: [width: 400, height: 400],
  extend: true,
  extend_at: :bottom,
  extend_offset: {0, 10}
)
```

<!-- tabs-close -->

### pad

Accepts one to four whole pixel lengths of 0 or more, in CSS order. Default:
none.

- One value pads every side.
- Two values pad the top and bottom, then the left and right.
- Three values pad the top, then the left and right, then the bottom.
- Four values pad the top, right, bottom, and left.

Adds space outside the image and any canvas, so the result grows by the
padding. Padding is multiplied by `dpr`.

<!-- tabs-open -->

### URL

```text
/w=400/pad=10,20/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400], padding: {10, 20})
```

<!-- tabs-close -->

### bg

Accepts a [color](../requesting-images.md#colors), optionally followed by an
alpha [fraction](../requesting-images.md#fractions). Default: none.

Fills every transparent pixel in the group's result: canvas, padding, the
corners left by [`rotate`](crop.md#rotate), and transparent areas of the image
itself. An opaque `bg` makes the image fully opaque. With an alpha below 1,
those areas stay partly transparent.

Without `bg`, transparent areas stay transparent in formats that support it,
such as PNG, WebP, and AVIF. JPEG has no transparency, so it turns any
remaining transparency white.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/extend/pad=12/bg=fff/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  resize: [width: 400, height: 400],
  extend: true,
  padding: 12,
  background: "fff"
)
```

<!-- tabs-close -->
