# Transform pipeline and operations

## Overview

ImagePipe's native URL parser produces an `ImagePipe.Native.Request` containing
ordered groups and an output policy. `ImagePipe.Native.Pipeline` executes those
groups against a decoded image.

The pipeline uses two operation layers internally:

- `ImagePipe.Plan.Operation.*` structs describe validated, product-neutral
  image intent such as resize, crop, rotate, trim, and effects.
- `ImagePipe.Transform.Operation.*` structs describe executable libvips work
  over `ImagePipe.Transform.State`.

`ImagePipe.Transform.NeutralResolver` resolves source-dependent geometry and
lowers semantic operations into executable operations. `ImagePipe.Transform.Chain`
executes the resulting work. Request orchestration stays in the native or
imgproxy pipeline; the transform facade owns generic execution and
materialization.

## Native request flow

For an image response, the shared Plug lifecycle is:

1. Parse and validate the native path into an `ImagePipe.Native.Request`.
2. Apply expiry and source-translation gates.
3. Resolve source identity, output negotiation, representation identity, and
   conditional/cache decisions.
4. On a generation path, inspect source geometry and plan shrink-on-load.
5. Decode the image and condition its input color space.
6. Execute every native group in order through `ImagePipe.Native.Pipeline`.
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
7. `gray`
8. `bitonal`
9. `pad`
10. `bg`

`then` starts another group. Each group receives the complete result of the
previous group, while group options themselves do not carry forward. Decode
happens once, so only the first group can influence shrink-on-load planning.

The [native API contract](native_api_contract.md#native-semantics)
defines the fixed ordering and the additional retained stages as the native
surface grows.

## Coordinate frames

Every operation uses the display frame produced by preceding stages. Crop and
region percentages therefore resolve after rotation, flip, and trim. A trim
that reduces an input from 1000 pixels wide to 800 pixels makes a subsequent
`50pct` crop width resolve to 400 pixels.

Each `then` boundary establishes a new input frame from the previous group's
final output. Region coordinates in a later group start at that new frame's
origin; they do not retain a hidden offset into the original source.

Native EXIF auto-orientation is always enabled at present. It is carried as
pending-orientation state and may be applied late when coordinate compensation
preserves the logical display result. EXIF is applied once per request, not once
per group.

## Semantic operation catalog

`ImagePipe.Plan.Operation` provides constructors for the internal semantic
operation structs. Constructors validate and canonicalize their fields before
the native or imgproxy pipeline hands them to the resolver.

### Geometry and composition

- `Resize` supports `:fit`, `:cover`, `:stretch`, and source-dependent `:auto`
  modes. It carries enlargement policy, guide, offsets, minimums, zoom, DPR,
  and result bounds where the requesting pipeline needs them. Cover resize may
  resolve into a resize followed by a result crop.
- `CropGuided` crops to a width and height using an anchor, focal point, smart
  guide, or detector guide. It can carry offsets and optional aspect-ratio
  correction.
- `CropRegion` crops an explicit x/y/width/height rectangle. Its out-of-bounds
  policy is either clamp or reject.
- `Canvas` places the current image on a target canvas with placement, offsets,
  and transparent or solid fill.
- `Padding` expands the current image by logical top/right/bottom/left sides.
  Its pixel ratio supports compatibility behavior that scales padding with a
  preceding resize.
- `Background` composites an alpha-capable sRGB color behind the current
  image. An opaque background removes alpha as a consequence of composition.
- `Trim` removes a uniform border using an automatic or explicit background
  and supports horizontal or vertical margin equalization.

Native currently exposes guided crop, region crop, resize, padding,
background, and trim. Canvas and the broader compatibility parameters remain
available to the imgproxy pipeline and shared resolver.

### Orientation

- `Rotate` accepts clockwise angles in `[0, 360]`; the constructor folds 360
  to 0 and canonicalizes whole-number floats. Right angles can use lossless
  orientation routing, while arbitrary angles use resampling.
- `Flip` represents horizontal, vertical, or both-axis reflection.

User rotation and flip compose with pending EXIF orientation. The resolver may
combine them before emitting executable work, so there is no requirement for a
one-to-one executable operation per semantic orientation operation.

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

Native currently exposes blur, gray, and bitonal. The imgproxy compatibility
path retains the broader effect set. Request parsers canonicalize their own
documented identity values before constructing operations.

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
gradient. Some semantic operations lower to a differently named executable
operation: both crop variants become `Transform.Operation.Crop`, and `Canvas`
becomes `Transform.Operation.ExtendCanvas`. One semantic operation may also
produce multiple executable operations.

`Transform.Operation.Flush` applies surviving pending orientation at a safe
boundary. `AlphaPremultiply` is an internal helper used where an effect needs
premultiplied alpha. Neither represents independent request syntax.

Orientation state, flip composition, and resize branch selection are resolved
before executable work reaches the chain.

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

`ImagePipe.Native.Pipeline.decode_request/2` derives shrink-on-load information
from the first group. Resize targets, crop extent, quarter-turn rotation, trim,
and a reducing terminal can contribute. An arbitrary-angle rotation disables
shrink-on-load planning because resampling changes the crop frame.

The selected load shrink is an optimization. Geometry continues to use source
pixel coordinates through `SourceShape`, and lowering applies the realized
decode shrink exactly once.

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

## Boundary rules

The native and imgproxy pipelines own request-specific assembly and group
execution. Shared request orchestration calls their concrete lifecycle
callbacks and depends on the `ImagePipe.Transform` facade rather than concrete
executable operation modules.

Transform operations depend on `Transform.State` and product-neutral values.
They do not parse URLs, resolve sources, read caches, negotiate output, or send
responses. Source-dependent planning stays in the pipelines and neutral
resolver; execution stays in the transform chain.
