# Resize and layout

[All processing options](../processing.md) · [Orientation and cropping](crop.md)

Pass these options to `ImagePipe.group/2`; the `resize` fields go inside its
`resize: [...]` keyword list.

## Resize

| URL | Elixir | Values / behavior |
| --- | --- | --- |
| `w=400`, `h=300` | `resize: [width: 400, height: 300]` | Positive integer or `auto`; omitted/automatic axis follows aspect ratio |
| `fit=contain` | `resize: [fit: :contain]` | Fit mode below; requires a concrete dimension |
| `enlarge` | `resize: [enlarge: true]` | Allow upscaling; default false |
| `min-w=200`, `min-h=150` | `resize: [min_width: 200, min_height: 150]` | Positive integer minimum target dimensions, subject to enlargement cap |
| `dpr=2` | `dpr: 2` | Positive density factor; default 1 |
| `zoom=1.5` or `zoom=2,1` | `resize: [zoom: 1.5]` or `[zoom: {2, 1}]` | Positive factor(s); default 1; non-unit zoom needs a dimension or minimum |

| Fit | Result |
| --- | --- |
| `contain` / `:contain` | Preserve aspect ratio within the target box; default |
| `cover` / `:cover` | Fill the target box, cropping excess using the guide |
| `cover-down` / `:cover_down` | Cover without upscaling |
| `stretch` / `:stretch` | Resize axes independently to the target ratio |
| `auto` / `:auto` | Cover when source and target orientations match, contain otherwise |

```text
/w=400/h=300/fit=cover/dpr=2/src/photos/beach.jpg
```

```elixir
ImagePipe.new()
|> ImagePipe.group(resize: [width: 400, height: 300, fit: :cover], dpr: 2)
```

Without enlargement, small sources can produce smaller results. Zoom scales
the requested resize box before the fit mode is applied; it does not select
a source region. Use [crop](crop.md) to select a region.

## Canvas, padding, and background

| URL | Elixir | Values / behavior |
| --- | --- | --- |
| `extend` | `extend: true` | Expand to the `w`/`h` canvas |
| `extend-ratio` | `extend_ratio: true` | Expand to the `w`:`h` aspect ratio |
| `extend-at=top-left` | `extend_at: :top_left` | Named placement anchor; center by default |
| `extend-offset=10,-5pct` | `extend_offset: {10, {:pct, -5}}` | Signed pixels or percentages of the realized canvas |
| `pad=12` or `pad=10,20,30,40` | `padding: 12` or `padding: {10, 20, 30, 40}` | Nonnegative integers; one to four CSS-order values |
| `bg=fff` or `bg=fff,0.5` | `background: "fff"` or `background: {"fff", 0.5}` | Color with optional alpha from 0 to 1 |

Both canvas modes require concrete `w` and `h` and cannot be enabled together.
Canvas expansion preserves the image's scale and never crops it. Placement
anchors are `center`, `top`, `bottom`, `left`, `right`, `top-left`, `top-right`,
`bottom-left`, and `bottom-right` (underscores in Elixir atoms).
Added space is transparent until a background is supplied.

```text
/w=400/h=400/extend/pad=12/bg=fff/src/photos/beach.jpg
```

```elixir
ImagePipe.new()
|> ImagePipe.group(
  resize: [width: 400, height: 400],
  extend: true,
  padding: 12,
  background: "fff"
)
```

This contains the image, extends the canvas, then adds padding and a white
background. Padding increases the final dimensions beyond the canvas size.

## Density and small sources

DPR scales resize targets, pixel offsets, and padding. If enlargement is off
and source size caps resizing, the same clamp reduces effective DPR for layout.
A 150×150 source with `w=100/h=100/dpr=2/pad=10` produces 150×150 image pixels
plus 15px on each side: 180×180 overall. Adding `enlarge` produces 240×240.

Percentage offsets resolve once against their frame and are not multiplied by
DPR. Zoom affects resize alone; DPR also affects the canvas. With no resize,
DPR can scale padding without scaling source pixels. See the
[geometry contract](../api_contract.md#dpr-zoom-offsets-and-padding).
