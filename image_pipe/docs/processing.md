# Processing options

Processing options resize, crop, adjust, watermark, and encode an image, and
each page below covers one category of them.
[Requesting images](requesting-images.md) explains how options go into a URL
and the [value syntax](requesting-images.md#option-values) they use.

## Option index

| Category | URL options |
| --- | --- |
| [Resize](processing/resize.md#resize) | `w`, `h`, `fit`, `enlarge`, `min-w`, `min-h`, `dpr`, `zoom` |
| [Canvas and padding](processing/resize.md#canvas-padding-and-background) | `extend`, `extend-ratio`, `extend-at`, `extend-offset`, `pad`, `bg` |
| [Orientation](processing/crop.md#orientation) | `orient`, `rotate`, `flip` |
| [Page selection](processing/request.md#page) | `page` |
| [Trim and crop](processing/crop.md#trim-and-crop) | `trim`, `trim-symmetry`, `crop`, `crop-ratio`, `crop-ratio-enlarge`, `region` |
| [Crop guides](processing/crop.md#crop-guides) | `anchor`, `focus`, `detect`, `anchor-offset` |
| [Watermarks](processing/watermark.md) | `wm`, `wm-src64`, `wm-enc`, `wm-opacity`, `wm-scale`, `wm-at`, `wm-offset`, `wm-tile`, `wm-gap` |
| [Effects](processing/effects.md) | `blur`, `progressive-blur`, `sharpen`, `pixelate`, `gray`, `bitonal`, `monochrome`, `duotone`, `brightness`, `contrast`, `saturation`, `colorize`, `gradient` |
| [Formats and quality](processing/output.md#formats) | `output`, `format`, `q`, `format-q`, `autoquality`, `max-bytes` |
| [Encoders](processing/output.md#encoder-options) | `jpeg-options`, `png-options`, `webp-options`, `avif-options` |
| [Metadata and color](processing/output.md#metadata-color-profiles-and-hdr) | `meta`, `dpi`, `profile`, `hdr` |
| [Request controls](processing/request.md) | `filename`, `attachment`, `cb`, `expires`, `debug` |
| [Requesting images](requesting-images.md) | `preset`, `-`, `sig`, `src`, `src64`, `enc` |

## Processing order

The image is first turned upright from its EXIF orientation, unless the
request sets [`orient=none`](processing/crop.md#orientation). Then each
[group](requesting-images.md#processing-groups) applies its options in this
order, whatever order the URL lists them in:

1. Rotate and flip.
2. Trim.
3. Crop or region of the original.
4. Resize, and the crop that a cover fit makes.
5. Effects.
6. Canvas extension.
7. Padding and background.
8. Watermark.

Encoding, or a placeholder or `info` [output](processing/output.md#output),
finishes the request.

Because rotation comes before resizing, `w` in this URL sets the width of the
rotated image, whichever of the two options comes first:

<!-- tabs-open -->

### URL

```text
/w=400/rotate=90/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(rotate: 90, resize: [width: 400])
```

<!-- tabs-close -->

## Common recipes

Add these paths to your base URL.

| Goal | Path |
| --- | --- |
| Responsive photo | `/w=800/src/photos/beach.jpg` |
| Square thumbnail | `/w=240/h=240/fit=cover/src/photos/beach.jpg` |
| High-density thumbnail | `/w=240/h=240/fit=cover/dpr=2/src/photos/beach.jpg` |
| Contain inside a white square | `/w=400/h=400/extend/bg=fff/src/photos/beach.jpg` |
| Attention-guided cover crop | `/w=400/h=300/fit=cover/anchor=smart/src/photos/beach.jpg` |
| Grayscale without resizing | `/gray/src/photos/beach.jpg` |
| WebP with a byte budget | `/format=webp/max-bytes=30000/src/photos/beach.jpg` |
| Placeholder | `/w=400/h=300/fit=cover/output=blurhash/src/photos/beach.jpg` |
| Result dimensions and placeholders | `/w=400/output=info,blurhash,lqip-css/src/photos/beach.jpg` |
