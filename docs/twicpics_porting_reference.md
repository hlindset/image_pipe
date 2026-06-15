# TwicPics porting reference

Use this when implementing a TwicPics-compatible parser or renderer. It tracks
vendor behavior, not ImagePipe support. For the current ImagePipe implementation
status, see [TwicPics support matrix](twicpics_support_matrix.md).

Sources checked on 2026-06-15:

- <https://www.twicpics.com/llms.txt>
- <https://www.twicpics.com/llms-full.txt>
- <https://www.twicpics.com/docs/essentials/api.md>
- <https://www.twicpics.com/docs/reference/parameters.md>
- <https://www.twicpics.com/docs/reference/transformations.md>
- <https://www.twicpics.com/docs/reference/color-chaining.md>
- <https://www.twicpics.com/docs/essentials/path-configuration.md>
- <https://www.twicpics.com/docs/basics/limits-and-restrictions.md>
- <https://www.twicpics.com/docs/basics/supported-formats.md>

## Request model

An API request has this shape:

```text
https://<twicpics-domain>/<path_to_image>?twic=v1/<manipulation>
```

`<manipulation>` is a slash-separated chain of transformation segments. The
`twic` query parameter doesn't have to be the first query parameter. Source
query parameters may appear before or after it.

Most segments use:

```text
<name>=<parameters>
```

These transforms also have bare forms with no `=`: `achromatopsia`, `achro`,
`deuteranopia`, `deut`, `download`, `noop`, `protanopia`, `prot`, `tritanopia`,
`trit`, and `truecolor`.

Transformations apply left to right. Each segment sees the image state produced
by the previous segment. Relative units and focus coordinates resolve using that
running state:

- `resize=340/resize=50p` returns a 170-pixel-wide image.
- `resize=50p/focus=20x10` places the focus at source coordinates `40x20`.

TwicPics may collapse work while preserving the result. The docs give
`resize=50p/resize=340` as an example: TwicPics ignores the first resize, and
the result is 340 pixels wide. Treat this as an optimization boundary, not as a
different semantic model.

## Parameter grammar

The full grammar needs a parser, not repeated string splits. Parenthesized
numbers can contain `/`, `+`, `-`, `*`, and nested parentheses. Colors can
contain function arguments. Padding uses commas. Background colors use `+`.
Split only at separators that are outside parentheses.

| Type | Syntax | Values and notes |
| --- | --- | --- |
| `number` | JSON number literal or parenthesized expression | `50`, `7.2`, `(1/3)`, `(5*(7+2)/3)`. Operators are `+`, `-`, `*`, `/`; normal precedence applies. |
| `length` | `<number>`, `<number>p`, `<number>s` | Bare values use pixel units. `p` means percentage. `s` means scale. The API grammar has no `px` suffix. Sign and zero handling belongs to the consuming parameter type. |
| `size` | `<length>x<length>`, `<length>x-`, `-x<length>`, `<length>` | Width then height. Both supplied axes must be greater than zero. A single value means `<width>x-`. `-` asks TwicPics to preserve aspect ratio for that axis. A value may mix units. `10px150` is a `10p` width, the `x` separator, and a `150` height. |
| `pixel size` | documented as `<size>` for `*-min` and `*-max` | The transform docs call these values pixel sizes but link to the normal `size` grammar. Test `p` and `s` units before accepting them in a strict port. |
| `ratio` | `<number>:<number>` | Width-to-height ratio. Both sides must be greater than zero. |
| `coordinates` | `<length>x<length>` | X then Y in CSS image coordinates: zero-based, left to right, top to bottom. `0x0` is the top-left pixel; for an image 640 pixels wide and 480 pixels high, `639x479` is the bottom-right pixel. A value may mix units, for example `100x50p`. |
| `crop size` | `<size>` with different `-` semantics | Omitted dimensions mean the full input axis, not aspect-ratio auto. `320` and `320x-` mean `320x1s`; `-x240` means `1sx240`. |
| `padding` | `top,right,bottom,left`; `top,horizontal,bottom`; `vertical,horizontal`; `both` | Each item is a `length`. Examples include `10,100,23,47`, `0,25p`, `(1/3)s`. |
| `anchor` | one of eight literals | `top`, `bottom`, `left`, `right`, `top-left`, `top-right`, `bottom-left`, `bottom-right`. The API anchor list excludes `center`, although center is the default focus. Overlay path config has its own anchor list and does accept `center`. |
| `axis` | `both`, `h`, `horizontal`, `v`, `vertical`, `x`, `y` | `h`, `horizontal`, and `x` mean horizontal. `v`, `vertical`, and `y` mean vertical. |
| `angle` | `<number>` or named literal | TwicPics rounds numeric degrees to the nearest quarter-turn. Named forms: `anticlockwise`, `counterclockwise`, and `left` mean a counterclockwise quarter-turn; `clockwise` and `right` mean a clockwise quarter-turn; `flip` and `reverse` mean a half-turn. |
| `boolean` | `true`, `yes`, `on`, `false`, `no`, `off` | Used by `truecolor=<boolean>`. |
| `color` | name, hex, RGB/RGBA, HSL/HSLA, `transparent` | Hex forms: 3, 4, 6, or 8 characters. Function forms: `rgb(...)`, `rgba(...)`, `hsl(...)`, `hsla(...)`. Color names, 3-char hex, and 6-char hex can take an alpha suffix: `violet.25`, `008.75`, `808080.3`. |

## Transform syntax

### Geometry

| Transform | Syntax variations | Behavior |
| --- | --- | --- |
| `resize` | `resize=<size>`; `resize=<ratio>` | `size` form resizes to the requested dimensions. One omitted dimension preserves aspect ratio. Two dimensions may distort. `ratio` form keeps the output surface close to the current surface while matching the ratio. |
| `resize-max` | `resize-max=<pixel size>` | Conditional resize applied only when one requested length is smaller than the corresponding current dimension. |
| `resize-min` | `resize-min=<pixel size>` | Conditional resize applied only when one requested length is larger than the corresponding current dimension. |
| `contain` | `contain=<size>` | Fits the image inside the target box while preserving aspect ratio. Result may be smaller than the box. |
| `contain-max` | `contain-max=<pixel size>` | Conditional contain applied only when one requested length is smaller than the corresponding current dimension. |
| `contain-min` | `contain-min=<pixel size>` | Conditional contain applied only when one requested length is larger than the corresponding current dimension. |
| `max` | `max=<pixel size>` | Short name for `contain-max`. |
| `min` | `min=<pixel size>` | Short name for `contain-min`. |
| `cover` | `cover=<size>`; `cover=<ratio>` | `size` form covers the target box and crops overflow. `ratio` form extracts the largest area matching the ratio. Both use the current focus point as placement input. |
| `cover-max` | `cover-max=<pixel size>` | Conditional cover applied only when one requested length is smaller than the corresponding current dimension. |
| `cover-min` | `cover-min=<pixel size>` | Conditional cover applied only when one requested length is larger than the corresponding current dimension. |
| `inside` | `inside=<size>`; `inside=<ratio>` | Fits the image inside the target area and adds translucent borders so the final image has the requested physical size or ratio. `background` fills those borders unless `border` overrides it. |
| `crop` | `crop=<crop size>`; `crop=<crop size>@<coordinates>` | Without coordinates, crops using the current focus point. With coordinates, uses them as the top-left crop origin and resets focus to the center of the crop result. |
| `zoom` | `zoom=<number>` | Zooms by a factor greater than or equal to 1 toward the current focus point while preserving current image dimensions. |
| `flip` | `flip=<axis>` | Flips horizontally, vertically, or both. |
| `turn` | `turn=<angle>` | Rotates. TwicPics rounds numeric angles to the nearest quarter-turn. |

### Focus and content-aware placement

| Transform | Syntax variations | Behavior |
| --- | --- | --- |
| `focus` | `focus=<coordinates>`; `focus=<anchor>`; `focus=auto` | Sets focus state without modifying image data. `auto` chooses a focus point automatically. The docs name `cover`, `crop`, and `zoom` as focus consumers. TwicPics hasn't implemented `auto` for videos. |
| `refit` | `refit=<size-or-ratio>[@<anchor>][(<padding>)]` | Short name for `refit-cover`. |
| `refit-cover` | `refit-cover=<size-or-ratio>[@<anchor>][(<padding>)]` | Resizes around detected object or objects, maximizing occupied area. It never creates image data outside the original image; padding and anchor placement are best effort when the source lacks enough room. |
| `refit-inside` | `refit-inside=<size-or-ratio>[@<anchor>][(<padding>)]` | Resizes around detected object or objects and may create borders to keep the subject centered or aligned. |

`<size-or-ratio>` means either a `size` or a `ratio`. Refit padding is optional
and follows the `padding` grammar.

### Color and alpha

| Transform | Syntax variations | Behavior |
| --- | --- | --- |
| `background` | `background=<background-step>[+<background-step>]*` | Each step is a `color` or `remove`. Colors fill transparent and translucent areas and borders created by `inside`. Repeated colors and repeated `background` transforms alpha-composite in order. An opaque color stops later background work. `remove` cancels previous background colors, runs background removal, and leaves a translucent image for later colors. |
| `border` | `border=<color>` | Fills borders created by `inside`, overriding `background` for that border area. Repeated borders apply in order; an opaque border stops later border work. No effect without `inside` or mask-created border area. |
| `colorize` | `colorize=<black-color>[:<white-color>]`; `colorize=monochrome`; `colorize=sepia` | Replaces the black-to-white range with a gradient between the supplied colors, or applies a named scheme. |
| `achromatopsia` | `achromatopsia=<number>`; `achro=<number>`; `achromatopsia`; `achro` | Colorblindness correction. Number must be between 0 and 1. Bare form means `1`. Experimental. |
| `deuteranopia` | `deuteranopia=<number>`; `deut=<number>`; `deuteranopia`; `deut` | Colorblindness correction. Number must be between 0 and 1. Bare form means `1`. Experimental. |
| `protanopia` | `protanopia=<number>`; `prot=<number>`; `protanopia`; `prot` | Colorblindness correction. Number must be between 0 and 1. Bare form means `1`. Experimental. |
| `tritanopia` | `tritanopia=<number>`; `trit=<number>`; `tritanopia`; `trit` | Colorblindness correction. Number must be between 0 and 1. Bare form means `1`. Experimental. |

### Output and response

| Transform | Syntax variations | Behavior |
| --- | --- | --- |
| `output` | `output=<format>`; `output=<preview-type>`; `output=auto` | TwicPics uses only the last `output` in the manipulation. `auto` re-enables TwicPics' browser-dependent format choice, including when a path default set a format. |
| `quality` | `quality=<number>` | Output quality from 1 to 100. Ignored when output is a preview format, or when output is PNG and `truecolor` is on. |
| `quality-max` | `quality-max=<number>` | Applies only when the supplied quality is below current quality. Example: `quality=100/quality-max=50` -> `50`; `quality=20/quality-max=50` -> `20`. |
| `quality-min` | `quality-min=<number>` | Applies only when the supplied quality is greater than current quality. Example: `quality=20/quality-min=50` -> `50`; `quality=100/quality-min=50` -> `100`. |
| `truecolor` | `truecolor=<boolean>`; `truecolor` | Controls PNG quantization. Bare form means `true`; default is `false`, allowing PNG quantization. |
| `download` | `download`; `download=<base-name>`; `download=<base-name>.<extension>` | Forces browser download. With no name, TwicPics derives `image` or `video` plus the final output extension. With a base name only, TwicPics still uses the final output extension. |
| `noop` | `noop` | Passes the media through without re-encoding and without API or default-manipulation transforms. Path configuration must permit it; TwicPics ignores it by default. |

`output=<format>` accepts these image formats: `auto`, `avif`, `heif`, `image`,
`jpeg`, `png`, `webp`. `image` means JPEG or WebP depending on browser support,
and can return the first frame of a video.

Video output formats: `h264`, `h265`, `vp9`.

Preview output types: `blank`, `blurhash`, `maincolor`, `meancolor`,
`preview`. `blank`, `maincolor`, `meancolor`, and `preview` responses carry
`X-Robots-Tag: noindex`.

### Video slicing

| Transform | Syntax variations | Behavior |
| --- | --- | --- |
| `duration` | `duration=<number>` | Extracts a duration in seconds. Starts at the beginning unless `from` sets a start point. |
| `from` | `from=<number>` | Slices from the given second. Ends at source end unless `duration` or `to` sets an end. |
| `to` | `to=<number>` | Slices up to the given second. Starts at source start unless `from` sets a start. |

## Focus state

The default focus point is the center of the image.

`focus` sets the focus point and emits no pixel operation. Coordinates resolve
using the current image state at the point where the `focus` segment appears.
Anchors set the focus to a corner or to the midpoint of an edge. `focus=auto`
selects a point through TwicPics' automatic subject detection.

The documented consumers are:

- `cover=<size>`: scales to cover, then crops overflow while keeping the focus
  as central as possible.
- `cover=<ratio>`: extracts the largest matching-ratio area while keeping the
  focus as central as possible.
- `crop=<crop size>`: chooses a crop origin from the focus.
- `zoom=<number>`: zooms toward the focus while preserving dimensions.

`crop=<crop size>@<coordinates>` is both a crop and a focus reset. It ignores
the previous focus for placement and resets focus to the center of the crop
result.

The official docs don't state how `turn`, `flip`, `inside`, `resize`, `contain`,
or color transforms update existing focus state. A faithful port should either:

- carry focus as part of image state and transform it with the image data, then
  confirm behavior with black-box TwicPics requests, or
- document any deliberate divergence.

Don't keep absolute focus coordinates unchanged across geometry transforms.
That contradicts the docs' running-state examples.

## Fixed or late processing

Most transforms obey chain order. These cases need separate handling:

- **Path default manipulation.** A path can define a default manipulation. By
  default, TwicPics appends it after the URL manipulation. If the default
  contains `*`, TwicPics inserts the URL manipulation at that point. For example,
  `quality=50/*/max=1000` wraps the URL chain between a default quality and a
  final max width.
- **`noop`.** When enabled in path configuration, `noop` bypasses API transforms
  and path default manipulation.
- **`output`.** TwicPics uses only the last output setting. `output=auto` can undo an
  earlier explicit output, including one from default manipulation.
- **Direct color transforms.** `background`, `border`, and `colorize` respect
  chain order relative to each other.
- **Colorblindness filters.** `achromatopsia`, `deuteranopia`, `protanopia`, and
  `tritanopia` are global filters applied at the end of image processing, after
  direct color transforms, mask, and overlay.
- **Mask.** Mask is path configuration, not a URL transform. TwicPics treats
  mask-created translucency as border area: final `border` fills it, otherwise
  final `background` fills it, otherwise it stays translucent.
- **Overlay.** Overlay is path configuration. TwicPics adds it after direct color
  transforms and mask, so the URL manipulation doesn't colorize or mask overlay
  content.
- **Fallback image.** If origin fetch returns a 4xx and the path has a fallback
  image, TwicPics applies the requested transformations to the fallback as if it
  were the requested media.
- **Metadata and orientation.** TwicPics strips metadata by default. The path
  configuration docs note that EXIF orientation and color profiles may change or
  disappear because they help generate output.

## Other implementation notes

- Original image inputs recognized as transformable are `AVIF`, `GIF`, `HEIF`,
  `JPEG`, `PNG`, and `WebP`. Unsupported file types return 415 unless the path
  enables passthrough.
- Original image limits are 36,000,000 pixels and 20 MB. Original video limits
  are 30 seconds, 30 FPS, 36,000,000 pixels, and 36 MB. Exceeding a limit returns
  502.
- Path resolution includes more than string prefixing. Paths can contain catch-all
  segments, can look like absolute URLs, and conflicts prefer the most specific
  path.
- Source query parameters are part of the same query string as `twic`; preserve
  non-`twic` parameters for the origin request.
- TwicPics Native adds client-side conveniences that the server URL API doesn't
  document as raw API grammar: `W` and `H` number aliases for element dimensions,
  comma-separated transforms for more than one background, and bare shortcuts such
  as `cover` meaning `cover=WxH`. Keep these in a separate Native layer unless
  the port explicitly targets Native attributes.
- The docs contain at least one wording bug: the `tritanopia` section describes
  protanopia in prose. The syntax list still names the tritanopia transform and
  `trit` short name.
