# Orientation and cropping

[All processing options](../processing.md) · [Resize and layout](resize.md)

Coordinates refer to the displayed image produced by preceding stages. EXIF
orientation happens first, then rotation, flip, trim, crop, and resize.

## Orientation

| URL | Elixir | Values / default |
| --- | --- | --- |
| `orient=auto` | `ImagePipe.new(orient: :auto)` | Request-wide `auto` or `none`; default auto |
| `rotate=90` | `ImagePipe.group(plan, rotate: 90)` | Clockwise degrees from 0 through 360; default 0 |
| `flip=h` | `ImagePipe.group(plan, flip: :horizontal)` | `h`, `v`, `hv` → `:horizontal`, `:vertical`, `:both` |

`orient=none` retains the stored pixel axes; user rotation and flips still
apply. EXIF is applied once per request, not once per group. Output orientation
metadata describes the delivered pixels, including under `meta=keep`.

## Trim and crop

Except for `orient`, pass this page's Elixir options to `ImagePipe.group/2`.

| URL | Elixir | Values / behavior |
| --- | --- | --- |
| `trim=auto`, `trim=fff,10` | `trim: :auto`, `trim: {"fff", 10}` | Automatic displayed top-left color, or explicit color with optional nonnegative tolerance |
| `trim-symmetry=hv` | `trim_symmetry: :both` | `h`, `v`, `hv`; requires trim; use the smaller opposing inset |
| `crop=400,300` | `crop: {400, 300}` | Positive source width and height, pixels or percentages |
| `crop=50pct,100pct` | `crop: {{:pct, 50}, {:pct, 100}}` | Percentages resolve after trim |
| `crop-ratio=16:9` | `crop_ratio: {16, 9}` | Positive integer pair; correct guided crop ratio by reducing one dimension; URL also accepts a positive decimal |
| `crop-ratio-enlarge` | `crop_ratio_enlarge: true` | Grow the other crop dimension instead, capped to image bounds |
| `region=10,20,400,300` | `region: {10, 20, 400, 300}` | Explicit x, y, width, height; positive width/height |

`region` and guided `crop` are alternatives. Crop-ratio settings require a
guided crop. Percentages use the current display frame after rotation, flip,
and trim; there is no hidden offset back into the original image.

```text
/crop=50pct,100pct/anchor=left/w=300/src/photos/beach.jpg
```

```elixir
ImagePipe.new()
|> ImagePipe.group(
  crop: {{:pct, 50}, {:pct, 100}},
  anchor: :left,
  resize: [width: 300]
)
```

This selects the left half of the source and then resizes it. Crop dimensions
are physical source coordinates, unaffected by DPR.

## Crop guides

Guides select which part of the image a guided crop or cover-family resize
keeps. Supply only one of `anchor`, `focus`, and `detect` in a group.

| URL | Elixir | Behavior |
| --- | --- | --- |
| `anchor=top-left` | `anchor: :top_left` | Named anchor; default crop position is center |
| `anchor=smart` | `anchor: :smart` | Attention-based cropping |
| `anchor=smart-face` | `anchor: :smart_face` | Attention with optional face assistance |
| `focus=0.25,0.75` | `focus: {0.25, 0.75}` | Relative focal point; each coordinate is in `0..1` |
| `detect=face` | `detect: ["face"]` | Detected subject classes |
| `detect=all` | `detect: :all` | All detected classes |
| `detect=all,face:3` | `detect: [:all, {"face", 3}]` | All classes, with weighted face priority |
| `anchor-offset=10,-5pct` | `anchor_offset: {10, {:pct, -5}}` | Signed shift from an explicit named anchor |

Named anchors are `center`, `top`, `bottom`, `left`, `right`, `top-left`,
`top-right`, `bottom-left`, and `bottom-right`. Elixir uses underscore atoms.
Offsets require an explicit non-smart anchor. Positive offsets move inward
from right/bottom edges and forward from left/top/center; placement stays
inside the crop input. Pixel offsets use effective DPR; percentages use the
crop's input frame.

Detection class names use lowercase letters, digits, underscores, and hyphens,
starting with a letter or digit. Weights are positive and at most 1,000,000.
Optional detection falls back to attention when unavailable, empty, or failed.
Set `detector_required: true` to reject unavailable explicitly requested classes.

See [content-aware cropping](../content-aware-gravity.md) for detector setup,
weights, warmup, and custom detectors. See the
[coordinate contract](../api_contract.md#coordinates-and-group-boundaries)
for exact frame semantics.
