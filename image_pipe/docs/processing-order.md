# Processing order and groups

ImagePipe applies the options in a group in a fixed
[stage order](processing.md#processing-order), not in the order you write
them. `/w=400/rotate=90/src/photos/beach.jpg` is 400 pixels wide after
turning, whichever of the two options is written first. To run options in a
different order, you split them into
[groups](requesting-images.md#processing-groups) with `-`.

## Option order in a group

Inside a group, an option means the same thing wherever it's written, which
has two effects:

- Equivalent URLs are one request. `/w=64/fit=contain/src/cat.jpg` and
  `/fit=contain/w=64/src/cat.jpg` return the same bytes, and the second is
  served from the cached copy the first one created.
- [Presets](requesting-images.md#named-presets) and the server's defaults can
  add options to a group without a position of their own.
  `/preset=card/w=600` and `/w=600/preset=card` are the same request.

## Stage order

Each group turns the image, trims it, crops it, resizes it, applies effects,
builds a frame around it, and draws the watermark last. Each stage works on
what the stages before it produced, so the order decides what an option
measures:

- Rotation comes first, so `w` sets the width of the turned image.
- Crop comes before resize, so `crop` selects pixels of the original and `w`
  sets the size of what was cut out.
- Effects run on the resized image, so `blur=2` blurs by 2 pixels of the
  resized image, however large the original is.
- Canvas, padding, and background build the frame around the picture. The
  watermark goes on last, so it can sit anywhere on that frame, padding
  included.

## Starting a new group

A `-` ends a group. The next group starts from the finished result of the one
before, with its canvas, padding, background, and watermark, and runs the
stages again in the same order. You need a new group only when a stage must
run after one that the fixed order puts later.

The common orders need no group. `/crop=50pct,100pct/w=400/src/photos/beach.jpg`
cuts out the middle half of the width, then resizes it to 400 pixels wide.
`/w=800/wm=logo/src/photos/beach.jpg` draws the logo on the 800-pixel image,
at the logo's own size.

The opposite orders do:

- Resize, then crop: `/w=800/-/crop=400,300/src/photos/beach.jpg` cuts
  400×300 pixels out of the 800-pixel image. In one group, `crop=400,300`
  would count pixels of the original and keep a much smaller part of a large
  photo.
- Watermark, then resize: `/wm=logo/-/w=400/src/photos/beach.jpg` draws the
  logo on the full-size image and then shrinks both together, so the logo
  keeps its size relative to the picture.
- Effects in another order: `/contrast=2/-/brightness=30/src/photos/beach.jpg`
  adjusts brightness after contrast. In one group, brightness comes first.

Only the image passes to the next group, and the EXIF orientation isn't
applied again. Each group works on the pixels it receives, so detail lost in
an earlier group doesn't come back. `/w=200/-/w=800/src/photos/beach.jpg`
returns a 200-pixel image, because the second group gets a 200-pixel image
and doesn't enlarge it without [`enlarge`](processing/resize.md#enlarge).

## Positions and percentages

Every option measures the image as the stages before it left it:

- After orientation. A photo stored as 400×300 pixels, with an EXIF tag that
  turns it upright, is 300×400 for every option. A crop anchored at
  `top-left` keeps the top-left corner as the picture is seen. With
  `orient=none`, options measure the pixels as stored.
- After trim. `crop` and `region` sizes, positions, and percentages refer to
  the trimmed image. Trimming a 1000-pixel-wide image to 800 pixels and then
  applying `crop=50pct,100pct` keeps 400 pixels of width, and a `region`
  starts from the trimmed image's top-left corner.
- After resize and canvas. `extend-offset` percentages are of the new canvas.
  `wm-offset` and `wm-gap` percentages are of the frame the watermark is
  drawn on, padding included.

In a later group, all of these measure the previous group's result.

## DPR and request-wide options

[`dpr`](processing/resize.md#dpr) multiplies its group's output sizes and
spacing (`w`, `h`, `pad`, and pixel offsets), not `crop`, `region`, or a
crop's `anchor-offset`. A later
group doesn't inherit it, so `/w=400/dpr=2/-/pad=10/src/photos/beach.jpg`
adds 10 pixels of padding to the 800-pixel image, not 20. The `dpr` that an
[`info`](processing/output.md#output) request reports is the last group's.

[Request-wide options](requesting-images.md#processing-groups) sit outside
the groups: `page` picks the page that enters the first group,
`orient=none` skips the EXIF turn, and the output options encode the last
group's result.

The exact rules for every stage are in the
[API contract](api_contract.md#processing-semantics).
