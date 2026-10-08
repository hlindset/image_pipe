# Orientation and cropping

These options turn, flip, trim, and crop the image, and set which part of it
a crop or cover resize keeps. Values use the shared
[option value syntax](../requesting-images.md#option-values).

## Orientation

### orient

Accepts `auto` or `none`. Default: `auto`.

`auto` turns the image upright as its EXIF orientation tag says, before any
other processing. `none` ignores the tag and uses the pixels as stored.
[`rotate`](#rotate) and [`flip`](#flip) apply either way.

`orient` applies to the whole request, so you write it once, in any group.
The delivered image's orientation tag always matches its pixels, so viewers
don't turn it again, even when the output keeps
[metadata](output.md#meta).

<!-- tabs-open -->

### URL

```text
/orient=none/w=400/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(orient: :none)
|> ImagePipe.URL.group(resize: [width: 400])
```

<!-- tabs-close -->

### rotate

Accepts any [number](../requesting-images.md#numbers) of degrees. Default: `0`.

Rotates the image clockwise. Negative angles rotate counterclockwise, and
angles wrap around at 360, so `rotate=-90` is the same as `rotate=270`.

`90`, `180`, and `270` turn the image exactly. Any other angle makes the image
larger, to fit the rotated picture, and leaves transparent corners. Use
[`bg`](resize.md#bg) to fill them. JPEG output turns them white.

<!-- tabs-open -->

### URL

```text
/rotate=90/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, rotate: 90)
```

<!-- tabs-close -->

### flip

Accepts `h`, `v`, or `hv`. Default: none.

Mirrors the image horizontally (`h`), vertically (`v`), or both (`hv`), after
[`rotate`](#rotate).

<!-- tabs-open -->

### URL

```text
/flip=h/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, flip: :horizontal)
```

<!-- tabs-close -->

## Trim and crop

`crop` and `region` measure positions and percentages on the image as it is
after `rotate`, `flip`, and `trim` in the same group. Their pixel values are pixels
of that image, so [`dpr`](resize.md#dpr) doesn't change them.

### trim

Accepts `auto`, or a [color](../requesting-images.md#colors) followed by an
optional tolerance, a number of 0 or more. Default: none. The tolerance
defaults to `10`.

Removes a border of one color from every edge. `auto` uses the color of the
top-left pixel. The tolerance sets how far a pixel's color may differ from the
border color and still be removed. Higher values remove more.

- Transparent pixels count as magenta (`ff00ff`) when finding the border, so
  `trim=auto` removes a transparent border.
- An image that is all border color, or narrower or shorter than 3 pixels,
  stays unchanged.
- Trim runs before crop and resize in the same group. To trim the resized
  image instead, put `trim` in a later
  [group](../requesting-images.md#processing-groups).

<!-- tabs-open -->

### URL

```text
/trim=fff,20/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, trim: {"fff", 20})
```

<!-- tabs-close -->

### trim-symmetry

Accepts `h`, `v`, or `hv`. Default: none.

Removes the same amount from opposite edges: left and right (`h`), top and
bottom (`v`), or both (`hv`). It uses the smaller of the two borders, so no
content is lost. `trim-symmetry` needs `trim` in the same group, and is
[ignored](../requesting-images.md#ignored-options) without it.

<!-- tabs-open -->

### URL

```text
/trim=auto/trim-symmetry=hv/src/photos/logo.png
```

### Elixir

```elixir
ImagePipe.URL.group(builder, trim: :auto, trim_symmetry: :both)
```

<!-- tabs-close -->

### crop

Accepts a `width,height` [pair](../requesting-images.md#pairs-and-lists), each
a positive [pixel length](../requesting-images.md#pixel-lengths) or
[percentage](../requesting-images.md#percentages). Percentages are of the
image's width and height. Default: none.

Cuts an area of that size out of the image before it is resized. The area
is centered unless [`anchor`, `focus`, or `detect`](#crop-guides) sets
another position. A size larger than the image is cut to the image's size on
that axis. `crop` and [`region`](#region) can't be used together.

This example keeps the left half of the image and resizes it to 300 pixels
wide.

<!-- tabs-open -->

### URL

```text
/crop=50pct,100pct/anchor=left/w=300/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  crop: {{:pct, 50}, {:pct, 100}},
  anchor: :left,
  resize: [width: 300]
)
```

<!-- tabs-close -->

### crop-ratio and crop-ratio-enlarge

`crop-ratio` accepts a ratio of two whole numbers, such as `16:9`, or a
positive decimal, such as `1.5`. Default: none.

`crop-ratio-enlarge` is a [boolean](../requesting-images.md#booleans). Default: `false`.

`crop-ratio` changes the [`crop`](#crop) size to that aspect ratio by
shrinking one side. With `crop-ratio-enlarge`, it grows the other side
instead. A corrected size larger than the image is scaled down to fit,
keeping the ratio. `crop-ratio` needs `crop` in the same group, and
`crop-ratio-enlarge` needs `crop-ratio`. `crop-ratio` is ignored without
`crop`, and `crop-ratio-enlarge` without `crop-ratio`.

This example keeps the largest 16:9 area of the image.

<!-- tabs-open -->

### URL

```text
/crop=100pct,100pct/crop-ratio=16:9/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, crop: {{:pct, 100}, {:pct, 100}}, crop_ratio: {16, 9})
```

<!-- tabs-close -->

### region

Accepts `x,y,width,height`. Each is a pixel length or percentage. `x` and `y`
are measured from the top-left corner and can't be negative, and `width` and
`height` must be positive. A request that breaks either rule fails with `400`.
Percentages are of the image's width and height. Default: none.

Cuts out exactly that rectangle. `anchor`, `focus`, and `detect` don't move
it. A rectangle that runs past an edge is moved inside the image, keeping its
size. One larger than the image is cut to the image's size. A rectangle that
starts at or beyond the right or bottom edge fails with `400` once the image
has been fetched. `region` and [`crop`](#crop) can't be used together.

<!-- tabs-open -->

### URL

```text
/region=100,50,400,300/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, region: {100, 50, 400, 300})
```

<!-- tabs-close -->

## Crop guides

`anchor`, `focus`, and `detect` set which part of the image a
[`crop`](#crop) or a cover resize keeps. Without them, the center is kept.
A cover resize is [`fit=cover`](resize.md#fit) with a number in `w`, `h`,
`min-w`, or `min-h`, or `fit=auto` with numbers in both `w` and `h`.

Use one of them per group, since two fail with `400`. Each needs a `crop` or
a cover resize in the same group, and is ignored without one.
With `fit=auto`, a guide has no effect on the resize when it picks contain,
which happens when the image and the box differ in orientation. With both a
`crop` and a cover resize, the guide applies to each.

### anchor

Accepts an [anchor](../requesting-images.md#anchors), `smart`, or
`smart-face`. Default: `center`.

- A named anchor keeps that edge or corner of the image.
- `smart` keeps the area most likely to draw attention, judged from edges,
  saturated color, and skin tones. It needs no detector on the server.
- `smart-face` combines `smart` with detected faces. When the server has no
  face detector, it works like `smart`.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/fit=cover/anchor=smart/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 400, fit: :cover], anchor: :smart)
```

<!-- tabs-close -->

### anchor-offset

Accepts an `x,y` pair of pixel lengths or percentages, either of which can be
negative. Default: `0,0`.

Moves the crop from its anchor. Positive values move it right and down from a
left, top, or center anchor, and inward from a right or bottom anchor. The
crop always stays inside the image. `anchor-offset` needs an `anchor` other
than `smart` or `smart-face` in the same group, and is ignored without one.

Percentages are of the image being cropped. On a `crop`, pixels are pixels
of the image being cropped, like the crop size. On a cover resize, pixels are
multiplied by [`dpr`](resize.md#dpr), since that crop happens after the
resize.

<!-- tabs-open -->

### URL

```text
/crop=600,400/anchor=top/anchor-offset=0,50/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, crop: {600, 400}, anchor: :top, anchor_offset: {0, 50})
```

<!-- tabs-close -->

### focus

Accepts an `x,y` pair of [fractions](../requesting-images.md#fractions) of the
image's width and height. Default: none.

Centers the crop on that point, as far as the image's edges allow. `0,0` is
the top-left corner and `1,1` the bottom-right.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/fit=cover/focus=0.3,0.6/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400, height: 400, fit: :cover], focus: {0.3, 0.6})
```

<!-- tabs-close -->

### detect

Accepts a comma-separated list of object classes, such as `face` or
`car,dog`, or `all` for every class the server detects. Each class can carry
a weight, as in `face:3`, a positive number up to 1,000,000. Default: none.

Centers the crop on the objects found, larger and more heavily weighted ones
counting more. Class names use lowercase letters, digits, `_`, and `-`, and
start with a letter or digit. A class listed twice fails with `400`.
Weights only count relative to other classes, so `detect=face:3` crops like
`detect=face`. `all` takes a weight too, used for every class not named, as
in `detect=all:2,face:3`.

The server's default detector supports `face` and the 80 COCO object classes:
`person`, `bicycle`, `car`, `motorcycle`, `airplane`, `bus`, `train`,
`truck`, `boat`, `traffic_light`, `fire_hydrant`, `stop_sign`,
`parking_meter`, `bench`, `bird`, `cat`, `dog`, `horse`, `sheep`, `cow`,
`elephant`, `bear`, `zebra`, `giraffe`, `backpack`, `umbrella`, `handbag`,
`tie`, `suitcase`, `frisbee`, `skis`, `snowboard`, `sports_ball`, `kite`,
`baseball_bat`, `baseball_glove`, `skateboard`, `surfboard`,
`tennis_racket`, `bottle`, `wine_glass`, `cup`, `fork`, `knife`, `spoon`,
`bowl`, `banana`, `apple`, `sandwich`, `orange`, `broccoli`, `carrot`,
`hot_dog`, `pizza`, `donut`, `cake`, `chair`, `couch`, `potted_plant`,
`bed`, `dining_table`, `toilet`, `tv`, `laptop`, `mouse`, `remote`,
`keyboard`, `cell_phone`, `microwave`, `oven`, `toaster`, `sink`,
`refrigerator`, `book`, `clock`, `vase`, `scissors`, `teddy_bear`,
`hair_drier`, and `toothbrush`. A server with a custom detector has its own
list.

- A class the server's detector doesn't support, such as `detect=unicorn`,
  fails with `400` before the image is fetched.
- When detection finds nothing, the crop falls back to `anchor=smart`.
- When the server has no detector, or detection fails, the crop also falls
  back to `anchor=smart`. A fallback after a failure is sent with
  `Cache-Control: no-store`. A server that requires detection fails the
  request instead, with `501`, `503`, or `500` (see
  [error responses](../errors.md)).

[Content-aware cropping](../content-aware-gravity.md) explains how regions
and weights become the crop's center.

<!-- tabs-open -->

### URL

```text
/w=400/h=400/fit=cover/detect=all,face:3/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  resize: [width: 400, height: 400, fit: :cover],
  detect: [:all, {"face", 3}]
)
```

<!-- tabs-close -->
