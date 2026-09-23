# Processing options

URL requests and Elixir plans use the same processing model. Choose a category
below; each page pairs URL syntax with typed Elixir options and explains the
constraints that affect the result.

## Option index

| Category | URL options |
| --- | --- |
| [Resize](processing/resize.md#resize) | `w`, `h`, `fit`, `enlarge`, `min-w`, `min-h`, `dpr`, `zoom` |
| [Canvas and padding](processing/resize.md#canvas-padding-and-background) | `extend`, `extend-ratio`, `extend-at`, `extend-offset`, `pad`, `bg` |
| [Orientation](processing/crop.md#orientation) | `orient`, `rotate`, `flip` |
| [Trim and crop](processing/crop.md#trim-and-crop) | `trim`, `trim-symmetry`, `crop`, `crop-ratio`, `crop-ratio-enlarge`, `region` |
| [Crop guides](processing/crop.md#crop-guides) | `anchor`, `focus`, `detect`, `anchor-offset` |
| [Effects](processing/effects.md) | `blur`, `sharpen`, `pixelate`, `gray`, `bitonal`, `monochrome`, `duotone`, `brightness`, `contrast`, `saturation`, `colorize`, `gradient` |
| [Formats and quality](processing/output.md) | `output`, `format`, `q`, `format-q`, `autoquality`, `max-bytes` |
| [Encoders](processing/output.md#encoder-options) | `jpeg-options`, `png-options`, `webp-options`, `avif-options` |
| [Metadata and color](processing/output.md#metadata-color-profiles-and-hdr) | `meta`, `profile`, `hdr` |
| [Request controls](processing/request.md) | `filename`, `attachment`, `cb`, `expires`, `debug` |
| [URL structure and presets](urls.md) | `preset`, `-`, `sig`, `src`, `src64`, `enc` |

## Processing order

EXIF auto-orientation applies once, then each group runs:

1. Rotate and flip.
2. Trim.
3. Source crop or region.
4. Resize and result crop.
5. Effects.
6. Canvas extension.
7. Padding and background.

Output encoding or a placeholder/info terminal finishes the request. Moving
options within a group does not change execution order. Use `-` in a URL
or another `ImagePipe.group/2` call to process an intermediate result:

```text
/w=500/-/trim=fff/src/photos/beach.jpg
```

```elixir
ImagePipe.new()
|> ImagePipe.group(resize: [width: 500])
|> ImagePipe.group(trim: "fff")
```

Each group starts with fresh settings, including DPR, zoom, guide, and effects.
The next group receives the previous result including canvas, padding, and
background. Request-wide orientation policy, output policy, and delivery
controls are set once for the whole request.

## Values and defaults

| Kind | URL | Elixir |
| --- | --- | --- |
| Pixel length | `100` or `100px` | `100` or `{:px, 100}` |
| Percentage length | `50pct` | `{:pct, 50}` |
| Color | `fff`, `123456`, `white` | `"fff"`, `"#123456"`, `"white"`, RGB tuple with channels in `0..255` |
| Boolean | `enlarge` or `enlarge=true`; `enlarge=false` | `enlarge: true` or `false` |
| Named value | `cover-down`, `top-left` | `:cover_down`, `:top_left` |

Length syntax applies to crop/region/offset coordinates; resize dimensions are
positive integers or `auto`. Crop percentages use the display frame **after
trim**. Source crops use physical pixels and are unaffected by DPR. DPR scales
output targets and pixel padding/offsets; zoom scales resize targets only.

Defaults preserve aspect ratio (`contain`), disable enlargement, use DPR/zoom
of 1, center crops, and preserve alpha until a background is requested.
Effects are disabled. EXIF orientation defaults to `auto`. Encoding defaults
come from [host configuration](configuration.md).

## Common recipes

These paths are relative to the mount; add your `/images` prefix if configured.

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
| Source dimensions | `/output=info/src/photos/beach.jpg` |

See the [API contract](api_contract.md#processing-semantics) for exact coordinate,
rounding, identity, and cross-option semantics.
