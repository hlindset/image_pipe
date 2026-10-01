# Transform pipeline and operations

## Overview

ImagePipe's URL parser produces an `ImagePipe.Plan.Spec` containing
ordered groups and an output policy. `ImagePipe.Transform.Executor` executes those
groups against a decoded image.

`ImagePipe.Plan.Spec.Group` holds validated options. The executor resolves
their source-dependent geometry in fixed stage order and constructs
`ImagePipe.Transform.Operation.*` structs over `ImagePipe.Transform.State`.
`ImagePipe.Transform.run/3` runs each operation with telemetry, materialization,
and error handling. The executor owns stage and group order.

`Plan.Spec` describes request intent; operation structs hold the parameters
resolved for a particular image. For example, crop coordinates change with
decode shrink and orientation, while resize dimensions are final pixel sizes.
The executor constructs each operation when its inputs are known and runs it
immediately.

## Fixed stage order

The executor follows the [processing stage order](../../image_pipe/docs/processing.md#processing-order)
and [effect order](../../image_pipe/docs/processing/effects.md#order-effects-deliberately), regardless
of URL option order. See [execution flow](execution_flow.md) for the surrounding
request lifecycle.

`-` starts another group. Each group receives the complete result of the
previous group, while group options themselves do not carry forward. Decode
happens once, so only the first group can influence shrink-on-load planning.

The [API contract](../../image_pipe/docs/api_contract.md#processing-semantics)
defines the ordering and parameter semantics.

## Coordinate frames

Every operation uses the display frame produced by preceding stages. Crop and
region percentages therefore resolve after rotation, flip, and trim. A trim
that reduces an input from 1000 pixels wide to 800 pixels makes a subsequent
`50pct` crop width resolve to 400 pixels.

Each `-` boundary establishes a new input frame from the previous group's
final output. Region coordinates in a later group start at that new frame's
origin; they do not retain a hidden offset into the original source.

EXIF auto-orientation defaults to `orient=auto`; `orient=none` uses stored
pixels as the initial frame. Pending orientation may be applied late when
coordinate compensation preserves the logical display result. It is flushed
before trim, whose automatic background samples the displayed top-left corner.
EXIF is applied once per request, not once per group.

## Group options and operation geometry

The parser validates and canonicalizes group fields before execution. The
executor resolves lengths, placement, and resize targets against the image at
the corresponding stage.

### Orientation

- Rotation accepts clockwise angles in `[0, 360]`; parsing folds 360
  to 0 and canonicalizes whole-number floats. Right angles can use lossless
  orientation routing, while arbitrary angles use resampling.
- Flip represents horizontal, vertical, or both-axis reflection.

User rotation and flip compose with pending EXIF orientation. The executor
can defer the composed orientation until a stage needs displayed pixels.

### Effects

The parser removes identity values before constructing operations.
Sigma and pixelate block size use physical pixels
without DPR scaling. Pixelate and gradient flush pending orientation so their
grid and direction use the current display frame. See the
[effect vocabulary](../../image_pipe/docs/api_contract.md#pixel-effects) for ranges,
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

Both crop forms use `Transform.Operation.Crop`; canvas extension uses
`Transform.Operation.ExtendCanvas`. A cover resize uses separate resize and
crop operations with an image measurement between them.

`Transform.Materializer.flush/1` applies surviving pending orientation at a safe
boundary. `AlphaPremultiply` is an internal helper used where an effect needs
premultiplied alpha. Neither represents independent request syntax.

The executor resolves orientation state, flip composition, and resize branches
before running each operation.

`Transform.Executor.Geometry` resolves the resize intent,
including zoom, minimum dimensions, effective DPR, enlargement, and cover
dimensions, against the current display frame. The executable `Resize` carries
only the final pixel width and height; a cover request follows it with a crop.

## Streaming and materialization

Decode always opens sequentially. `ImagePipe.Transform.DecodePlanner` computes
only shrink/scale load options; it does not switch the loader to random access.

`ImagePipe.Transform.run/3` checks the operation's
`requires_materialization?/1` callback. Immediately before the first operation
that needs random access, it copies the image to memory through
`ImagePipe.Transform.Materializer` and marks the state as materialized. Smart
or detector-guided crop and trim require this barrier. Sequential-safe
operations remain lazy until a later barrier or delivery.

Orientation flushes prepare random access when required, then buffer the
display frame for downstream operations, including horizontal flips. A final
delivery barrier materializes any image that has not already been buffered.

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

`ImagePipe.Transform.InputColorManagement` inspects the decoded image and imports
an embedded profile into
the working space before any group runs. The resulting color-management data
is recorded on `Transform.State` and passed directly to the encoder after the
final group.

Output format, quality, metadata, profile, copyright, HDR, and automatic
negotiation policies belong to output planning and encoding.

## Boundary rules

The executor owns fixed group ordering and source-dependent geometry.
Request orchestration calls the transform boundary's concrete entry points
rather than constructing executable operation modules.

Transform operations depend on `Transform.State` and product-neutral values.
They do not parse URLs, resolve sources, read caches, negotiate output, or send
responses. The executor resolves source-dependent geometry and calls
`Transform.run/3` for each image operation.
