# Transform pipeline and operations

## Overview

ImagePipe's native URL parser produces an `ImagePipe.Plan.Request` containing
ordered groups and an output policy. `ImagePipe.Transform.Executor` executes those
groups against a decoded image.

`ImagePipe.Plan.Request.Group` holds validated options. The executor resolves
their source-dependent geometry in fixed stage order and constructs
`ImagePipe.Transform.Operation.*` structs over `ImagePipe.Transform.State`.
`ImagePipe.Transform.Chain` executes those operations and applies their
materialization requirements.

## Native request flow

For an image response, the shared Plug lifecycle is:

1. Parse and validate the native path into an `ImagePipe.Plan.Request`.
2. Apply expiry and source-translation gates.
3. Resolve source identity, output negotiation, representation identity, and
   conditional/cache decisions.
4. On a generation path, inspect source geometry and plan shrink-on-load.
5. Decode the image and condition its input color space.
6. Execute every native group in order through `ImagePipe.Transform.Executor`.
7. Flush any deferred orientation, clamp output dimensions, materialize, and
   encode the negotiated format.

Parsing and static validation happen before source fetch or cache access.
Output selection, expiry, source location, and response presentation are not
transform operations.

## Fixed native stage order

Option order inside one group does not control processing order. The currently
implemented native stages run in this order:

1. `rotate`
2. `flip`
3. `trim`
4. `region` or guided `crop`
5. resize from `w`, `h`, `fit`, and `enlarge`, including the automatic result
   crop for cover modes
6. `blur`
7. `sharpen`
8. `pixelate`
9. `gray`
10. `bitonal`
11. `monochrome`
12. `duotone`
13. `brightness`
14. `contrast`
15. `saturation`
16. `colorize`
17. `gradient`
18. canvas extension
19. `pad`
20. `bg`

`then` starts another group. Each group receives the complete result of the
previous group, while group options themselves do not carry forward. Decode
happens once, so only the first group can influence shrink-on-load planning.

The [native API contract](native_api_contract.md#native-semantics)
defines the ordering and parameter semantics.

## Coordinate frames

Every operation uses the display frame produced by preceding stages. Crop and
region percentages therefore resolve after rotation, flip, and trim. A trim
that reduces an input from 1000 pixels wide to 800 pixels makes a subsequent
`50pct` crop width resolve to 400 pixels.

Each `then` boundary establishes a new input frame from the previous group's
final output. Region coordinates in a later group start at that new frame's
origin; they do not retain a hidden offset into the original source.

Native EXIF auto-orientation defaults to `orient=auto`; `orient=none` uses stored
pixels as the initial frame. Pending orientation may be applied late when
coordinate compensation preserves the logical display result. It is flushed
before trim, whose automatic background samples the displayed top-left corner.
EXIF is applied once per request, not once per group.

## Group options and operation geometry

The parser validates and canonicalizes group fields before execution. The
executor resolves lengths, placement, and resize targets against the image at
the corresponding stage.

### Geometry and composition

- Resize supports contain, cover, stretch, and source-dependent automatic
  modes, with enlargement policy, guide, offsets, minimums, zoom, and DPR.
  Cover resize executes a resize followed by a measured result crop.
- Guided crop resolves a width and height using an anchor, focal point, smart
  guide, or detector guide, with offsets and optional aspect-ratio correction.
- Region crop resolves an explicit x/y/width/height rectangle and clamps it
  to the available image.
- Canvas extension places the current image on a target canvas with placement, offsets,
  and transparent or solid fill.
- Padding expands the current image by logical top/right/bottom/left sides,
  scaled by the effective DPR of the preceding resize.
- `Background` composites an alpha-capable sRGB color behind the current
  image. An opaque background removes alpha as a consequence of composition.
- `Trim` removes a uniform border using an automatic or explicit background
  and supports horizontal or vertical margin equalization.

Native exposes guided and region crops, crop ratios, anchor offsets,
resize, canvas extension and placement, padding, background, and symmetric trim.
Object and face guides share the displayed crop frame.

### Orientation

- Rotation accepts clockwise angles in `[0, 360]`; parsing folds 360
  to 0 and canonicalizes whole-number floats. Right angles can use lossless
  orientation routing, while arbitrary angles use resampling.
- Flip represents horizontal, vertical, or both-axis reflection.

User rotation and flip compose with pending EXIF orientation. The executor
can defer the composed orientation until a stage needs displayed pixels.

### Effects

- `Blur` and `Sharpen` use a positive sigma.
- `Pixelate` uses a block size greater than one pixel.
- `Gray` performs true grayscale conversion.
- `Bitonal` converts to grayscale and thresholds at 128 while preserving alpha.
- `Monochrome` applies a single-color luminance tint.
- `Duotone` maps luminance between shadow and highlight colors.
- `Brightness` is an additive integer adjustment from `-255` to `255`.
- `Contrast` and `Saturation` are positive factors, with `1` as identity.
- `Colorize` overlays a color with an opacity and optional alpha preservation.
- `Gradient` overlays a transparency-to-color gradient with angle and stop
  positions.

Native exposes all these effects and canonicalizes identity values before
constructing operations. Sigma and pixelate block size use physical pixels
without DPR scaling. Pixelate and gradient flush pending orientation so their
grid and direction use the current display frame. See the
[native effect vocabulary](native_api_contract.md#pixel-effects) for ranges,
defaults, color syntax, and alpha behavior.

### Color values

`ImagePipe.Plan.Color` is the canonical sRGB color value used by composition
and color effects. It carries RGB channels plus alpha and serializes as
structured representation material. Third-party color structs do not cross
the planning boundary.

## Executable transform operations

Executable modules implement the `ImagePipe.Transform` behaviour:

- `name/1` returns the stable operation name used in telemetry.
- `execute/2` updates `ImagePipe.Transform.State`.
- `requires_materialization?/1` declares whether the operation needs random
  pixel access; the default is `false`.

The executable catalog includes resize, crop, canvas extension, padding,
background composition, rotate, trim, blur, sharpen, pixelate, grayscale,
bitonal, monochrome, duotone, brightness, contrast, saturation, colorize, and
gradient. Both crop forms use `Transform.Operation.Crop`; canvas extension uses
`Transform.Operation.ExtendCanvas`. A cover resize uses separate resize and
crop operations with an image measurement between them.

`Transform.Operation.Flush` applies surviving pending orientation at a safe
boundary. `AlphaPremultiply` is an internal helper used where an effect needs
premultiplied alpha. Neither represents independent request syntax.

Orientation state, flip composition, and resize branch selection are resolved
before executable work reaches the chain.

`Transform.Executor.Geometry` resolves the native resize intent,
including zoom, minimum dimensions, effective DPR, enlargement, and cover
dimensions, against the current display frame. The executable `Resize` carries
only the final pixel width and height; a cover request follows it with a crop.

## Streaming and materialization

Decode always opens sequentially. `ImagePipe.Transform.DecodePlanner` computes
only shrink/scale load options; it does not switch the loader to random access.

`ImagePipe.Transform.Chain` checks each executable operation's
`requires_materialization?/1` callback. Immediately before the first operation
that needs random access, it copies the image to memory through
`ImagePipe.Transform.Materializer` and marks the state as materialized. Smart
or detector-guided crop and trim require this barrier. Sequential-safe
operations remain lazy until a later barrier or delivery.

Deferred orientation is data-dependent. Orientations that need random access
materialize when flushed; identity and horizontal-only cases can retain the
streaming path. A final delivery materialization ensures encoding owns a stable
image.

## Decode planning

`ImagePipe.Transform.Executor.decode_request/2` derives shrink-on-load information
from the first group. Resize targets, crop extent, quarter-turn rotation, trim,
and a reducing terminal can contribute. An arbitrary-angle rotation disables
shrink-on-load planning because resampling changes the crop frame.
BlurHash's terminal hint applies only to single-group requests, preserving
the input scale of later groups that may trim or crop.

The selected load shrink is an optimization. `Transform.State` retains source
dimensions and realized decode scaling so geometry applies the shrink exactly
once when resolving source-pixel coordinates into decoded pixels.

## Input and output color handling

`ImagePipe.Transform.InputColorManagement` is a fixed preamble, not an
operation. It inspects the decoded image and imports an embedded profile into
the working space before any group runs. The resulting color-management carry
is stamped for output encoding after the final group.

Output format, quality, metadata, profile, copyright, HDR, and automatic
negotiation policies belong to output planning and encoding. They do not
appear in the transform chain.

## Native examples

| Native path fragment | Transform meaning |
| --- | --- |
| `/w=300/format=jpeg/src/images/beach.jpg` | Contain resize to width 300 |
| `/w=300/h=200/fit=cover/anchor=top/src/images/beach.jpg` | Cover resize and top-guided result crop |
| `/crop=100,100/focus=0.25,0.75/src/images/beach.jpg` | Guided crop around a focal point |
| `/region=10,20,100,80/src/images/beach.jpg` | Explicit region crop |
| `/rotate=90/flip=h/trim=auto/src/images/beach.jpg` | Rotate, flip, then trim regardless of URL option ordering |
| `/w=500/then/trim=fff/src/images/beach.jpg` | Resize first; trim the smaller intermediate image in group two |
| `/trim=fff/w=500/src/images/beach.jpg` | Trim first; resize within the same fixed-order group |
| `/blur=2.5/gray/pad=10/bg=fff/src/images/beach.jpg` | Blur, grayscale, padding, then background composition |
| `/sharpen=2/pixelate=7/src/images/beach.jpg` | Sharpen before pixelating, without resizing |
| `/duotone=1,123456,efab89/gradient=0.5,black/src/images/beach.jpg` | Duotone followed by a downward dark gradient |
| `/contrast=2/then/brightness=30/src/images/beach.jpg` | Use a second group to apply brightness after contrast |

## Boundary rules

The native executor owns fixed group ordering and source-dependent geometry.
Request orchestration calls the transform boundary's concrete entry points
rather than constructing executable operation modules.

Transform operations depend on `Transform.State` and product-neutral values.
They do not parse URLs, resolve sources, read caches, negotiate output, or send
responses. Source-dependent planning stays in the executor; individual image
operations execute through the transform chain.
