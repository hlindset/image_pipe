# Transform operations

## Purpose

This guide is for parser and dialect authors translating external URL syntax into
`ImagePipe.Plan`. It explains where semantic request intent belongs, where
executable transform work belongs, and how to keep parser-specific behavior out
of runtime/cache boundaries.

Parser authors should construct canonical semantic operations under
`ImagePipe.Plan.Operation.*` through `ImagePipe.Plan.Operation`. The executable
modules under `ImagePipe.Transform.Operation.*` are local execution targets used
by Transform Plan execution and `ImagePipe.Transform.Chain`. Parsers shouldn't
emit executable transform operations.

## Request flow

Parser code translates external syntax into parser-owned request structs, then
into `ImagePipe.Plan`, then into executable transform work only after the final
cache lookup boundary.

The request flow is:

1. A parser reads external syntax and validates parser-level fields.
2. Parser-owned request structs keep dialect syntax and compatibility details
   isolated.
3. Planner code translates compatible semantics into canonical
   `ImagePipe.Plan.Operation.*` structs.
4. ImagePipe builds cache keys from source-fetch-free Plan key data plus source
   freshness, output, config, and the cache key's transform key data version.
5. On cache miss, `ImagePipe.Transform.execute_plan/3` executes semantic Plan
   operations in order, converting each one to executable
   `ImagePipe.Transform.Operation.*` work as an implementation detail.
6. Runtime observes only the final transform state returned by
   `ImagePipe.Transform`.

Runtime code shouldn't reference concrete operation modules such as
`ImagePipe.Plan.Operation.Resize` or `ImagePipe.Transform.Operation.Resize`.
For Plan execution, runtime calls `ImagePipe.Transform.execute_plan/3`.
Executable structs stay inside Transform execution.

## Operation ordering

ImagePipe orders operation chains once they reach `ImagePipe.Plan`.

Imgproxy URLs are declarative. Imgproxy planner code emits semantic Plan
operations in Imgproxy canonical order. URL option order doesn't define
Imgproxy transform order. `docs/imgproxy_path_api.md` documents that order for
Imgproxy paths, but future dialects may use different ordering rules.

Other dialects may have order-sensitive semantics. When the ordered semantics
map cleanly, emit an ordered `ImagePipe.Plan`. Otherwise keep dialect-specific
quirks isolated in the parser/adapter layer. Don't force ordered command
semantics into the Imgproxy API or into product-neutral Plan operations.

For a stage-by-stage mapping of imgproxy's internal processing pipeline onto
ImagePipe's execution layers (decode planning, transform chain, output
boundary) — including stages realized outside the transform chain such as
`scaleOnLoad` and `fixSize` — see the "Processing pipeline conformance" section
of [imgproxy_support_matrix.md](imgproxy_support_matrix.md#processing-pipeline-conformance).

## Request fields that aren't transform operations

These request fields affect source selection, response policy, cache identity,
or output encoding. Translate them into the appropriate `ImagePipe.Plan` facets
instead of transform operations:

- source path, source URL handling, and source identity
- output format and automatic output negotiation
- quality and format-specific quality
- cachebuster
- expires
- filename
- attachment disposition

Keeping these fields out of transform chains matters for cache key data and
runtime boundaries. Output negotiation, for example, may change the encoded
format without changing the transform operation sequence.

## Semantic operation catalog

Parser/planner code should use these semantic operations:

- `ImagePipe.Plan.Operation.Resize`: product-neutral resize intent with
  `mode: :fit`, `:cover`, `:stretch`, or `:auto`. `mode: :auto` is semantic
  Plan intent. The selected fit/cover branch is post-fetch execution state, not
  cache key data.
- `ImagePipe.Plan.Operation.CropGuided`: crop by size plus guide.
- `ImagePipe.Plan.Operation.CropRegion`: explicit region crop.
- `ImagePipe.Plan.Operation.Canvas`: place the current image on a target canvas.
- `ImagePipe.Plan.Operation.Padding`: add edge padding around the current image.
- `ImagePipe.Plan.Operation.Background`: place an alpha-capable color behind
  the current image.
- `ImagePipe.Plan.Operation.AutoOrient`: apply embedded orientation metadata.
- `ImagePipe.Plan.Operation.Rotate`: right-angle rotation intent.
- `ImagePipe.Plan.Operation.Flip`: horizontal, vertical, or both-axis flip
  intent.
- `ImagePipe.Plan.Operation.Blur`: Gaussian blur with a positive sigma.
- `ImagePipe.Plan.Operation.Sharpen`: sharpening with a positive sigma.
- `ImagePipe.Plan.Operation.Pixelate`: pixelation with a block size greater
  than one pixel.
- `ImagePipe.Plan.Operation.Brightness`: additive brightness offset, an integer
  from `-255` to `255` (`0` unchanged).
- `ImagePipe.Plan.Operation.Contrast`: contrast scale, a positive float
  (`1` unchanged).
- `ImagePipe.Plan.Operation.Saturation`: saturation scale, a positive float
  (`1` unchanged).
- `ImagePipe.Plan.Color`: canonical product-neutral sRGB color data with alpha.

Plan pipelines should contain semantic Plan operation structs only. Transform
execution lowers those structs into executable `ImagePipe.Transform.Operation.*`
work after cache lookup.

## Executable operation catalog

`ImagePipe.Transform.Operation.*` modules are executable operation targets. They
describe work over `ImagePipe.Transform.State`, not parser request syntax:

- `ImagePipe.Transform.Operation.Resize`: executable resize with flattened mode
  and dimension fields.
- `ImagePipe.Transform.Operation.Crop`: resolved crop using gravity, offsets,
  and explicit crop dimensions.
- `ImagePipe.Transform.Operation.ExtendCanvas`: resolved canvas/letterbox work.
- `ImagePipe.Transform.Operation.Padding`: resolved edge-padding work.
- `ImagePipe.Transform.Operation.Background`: resolved background composition.
- `ImagePipe.Transform.Operation.AutoOrient`: executable EXIF autorotation.
- `ImagePipe.Transform.Operation.Rotate`: executable right-angle rotation.
- `ImagePipe.Transform.Operation.Flip`: executable flip.
- `ImagePipe.Transform.Operation.Blur`: executable Gaussian blur.
- `ImagePipe.Transform.Operation.Sharpen`: executable sharpening.
- `ImagePipe.Transform.Operation.Pixelate`: executable pixelation.
- `ImagePipe.Transform.Operation.Brightness`: executable brightness change.
- `ImagePipe.Transform.Operation.Contrast`: executable contrast change.
- `ImagePipe.Transform.Operation.Saturation`: executable saturation change.

`ImagePipe.Transform.Operation.AdaptiveResize` is obsolete. Resize
`mode: :auto` belongs in `ImagePipe.Plan.Operation.Resize`. Parsers must not emit
an executable adaptive-resize operation.

## Choosing resize-like semantic operations

Use `ImagePipe.Plan.Operation.Resize` with `mode: :fit` for aspect-preserving
fit semantics, `mode: :cover` for cover/fill semantics that require result
cropping, and `mode: :stretch` for force/stretch semantics.

Use `mode: :auto` only for the product-neutral source-dependent rule (imgproxy
`rt:auto` parity, owned by the neutral resolver — no custom strategy required):
orientation match derives cover, orientation mismatch derives fit, and unknown
target orientation derives fit. The unresolved semantic resize operation
addresses the cache key. The selected branch resolves after a cache miss.

Don't use `mode: :auto` as a generic conditional resize operation. If a future
adapter has different source-dependent branch rules, add a new semantic
operation or adapter policy instead of extending `mode: :auto` implicitly.

## Crop and gravity

Use `CropGuided` for visible crop operations expressed as size plus guide. Use
`CropRegion` for explicit source/current-space region crops. Parser-specific
gravity spellings, focal-point tokens, and default inheritance rules should
translate into explicit Plan guide values before ImagePipe builds cache key
data.

Current Imgproxy focal-point gravity maps to semantic guide values. The first
slice doesn't model a separate focus operation. Future dialects can add one if
they expose focus state independently from visible crop/canvas/cover work.

`CropGuided` supports an optional aspect-ratio correction field. When present,
execution adjusts the crop area size to the target ratio before applying the
guide. The correction has two modes: reduce (default, shrinks the area to the
ratio) and enlarge with clamp (grows the area then clamps to image bounds).
`aspect_ratio` zero disables correction. Correction adjusts the crop area
size only. The guide position and gravity stay fixed.

## Orientation operations

Use `ImagePipe.Plan.Operation.AutoOrient`, `Rotate`, and `Flip` for orientation
intent.

Imgproxy orientation suborder is auto-orient, rotate, then flip. Other dialects
should preserve their own semantics in the adapter layer and emit the ordered
Plan operation chain that matches those semantics.

## Input color management

Input working-space conditioning (`ImagePipe.Transform.InputColorManagement`) is
a fixed pipeline preamble, not a Plan operation. Every profiled/wide-gamut/CMYK
source is unconditionally imported to a working space before trim, crop, resize,
and effects. The output profile policy (`Plan.Output.color_profile`) is the only
parser-controlled knob; imgproxy `scp` maps to `:strip` (default) or
`:preserve_source`. The encoder finalize re-embeds or drops the source profile
per that policy.

## Canvas operations

Use semantic `Canvas` when a dialect requests target canvas expansion,
letterboxing, or aspect-ratio extension around the transformed image. Don't use
it as a substitute for resize, contain, or cover semantics unless the dialect
requests a larger canvas around image content.

Aspect-ratio canvas extension (Imgproxy `exar`) derives the target ratio from
the resolved resize dimensions in the same pipeline group. This is a no-op when
either resize dimension is auto or zero. Extend gravity for `exar` uses
directional anchors only (the nine anchor values). Focal-point extend gravity
isn't supported for this operation.

The `Canvas.fill` value applies only to output from that canvas operation. The
default is `:transparent`, and callers can also set
`{:solid, ImagePipe.Plan.Color.t()}`. Don't use canvas fill to model a
whole-image background flattening request.

Use semantic `Padding` when a dialect requests edge insets around the current
image. Padding expands relative to current dimensions rather than targeting a
canvas size. Padding has logical top/right/bottom/left sides, a requested pixel
ratio, and a fill value. The pixel ratio can be explicit, or it can use the
resize multiplier produced by a preceding resize for compatibility dialects
whose padding follows resize DPR semantics. Execution scales sides with
round-half-to-even semantics.

Use semantic `Background` when a dialect requests a color behind the current
image. Opaque backgrounds remove alpha as a consequence of composition. Alpha
backgrounds preserve alpha until output encoding resolves a non-alpha format.
Background composition applies to source alpha and to transparent areas
generated by earlier canvas or padding operations, and it doesn't change
dimensions.

`ImagePipe.Plan.Color` is the canonical Plan color model. It represents sRGB
RGB channels with alpha and serializes into structured cache key data.
Third-party color package structs stay behind `ImagePipe.Plan.Color` and must
not leak into parser request structs, runtime state, or cache key data.

## Effect operations

Use semantic `Blur`, `Sharpen`, `Pixelate`, `Monochrome`, `Duotone`,
`Brightness`, `Contrast`, and `Saturation` when a dialect requests full-image
effects. These operations are product-neutral image effects. Parser aliases
such as Imgproxy `bl`, `sh`, `pix`, `mc`, `dt`, `br`, `co`, and `sa` stay in
parser code.

Imgproxy effect order is blur, sharpen, pixelate, monochrome, duotone,
brightness, contrast, saturation, colorize, then gradient. Effects run after result
cropping and before canvas extension, padding, and background composition.

Imgproxy treats these effect values as no-ops:

- blur and sharpen sigma `0`
- pixelate sizes of `1` or lower
- zero-intensity tone effects
- zero-valued color adjustments

ImagePipe accepts those no-op values in the Imgproxy parser and emits no
semantic operation.

## Decode planning

Before source metadata is available, decode/open planning must treat semantic
Plan operations conservatively. After a cache miss, Transform Plan execution may
discover source metadata and convert semantic intent to executable work.
`ImagePipe.Transform.DecodePlanner` owns source-open access decisions over
semantic Plan operations. Executable transform operation modules shouldn't
define separate decode-access metadata.

## Cache key data

Final output cache key data captures canonical semantic intent, not resolved
execution details. It should be stable for matching plans and independent of
parser-specific spelling, aliases, and compatibility quirks.

Parser-specific quirks must not leak into transform key data. Keep behavior in
parser/adapter code when product-neutral Plan operations can't represent it.
Don't encode dialect syntax into operation cache key data.

Some source-aware choices affect executable work after a cache miss. Examples
include resize `mode: :auto` selecting fit/cover, ratio crop resolution, and DPR
conversion. They don't enter the normal final output cache key.

## Mapping examples

These examples show current Imgproxy URL concepts translated into semantic Plan
operations. They describe Imgproxy planner behavior only. Future dialect docs
should describe their own URL syntax.

| Imgproxy URL concept | Semantic Plan operations |
| --- | --- |
| `w:300` | `Resize` with `mode: :fit` |
| `rt:force/w:0/h:200` | `Resize` with `mode: :stretch` and auto width |
| `rt:auto/w:300/h:200` | `Resize` with `mode: :auto` |
| `rt:fill/w:300/h:200/g:fp:0.25:0.75` | `Resize` with `mode: :cover` and focal-point guide |
| `rt:fill/w:300/h:200/g:soea:12:-0.25` | `Resize` with `mode: :cover` and top-level gravity offsets |
| `c:100:100/g:so` | `CropGuided` inheriting explicit top-level guide |
| `c:100:100:fp:0.25:0.75` | `CropGuided` with crop-specific focal-point guide |
| `ar/rot:90/fl:true:false/c:100:100` | `AutoOrient`, `Rotate`, `Flip`, `CropGuided` |
| `extend:true/w:300/h:200` | `Resize` with `mode: :fit`, `Canvas` |
| `pd:10/bg:f00` | `Padding`, `Background` |
| `scp:0` | `Plan.Output.color_profile: :preserve_source` (output policy, not an operation) |
| `scp:1` (default) | `Plan.Output.color_profile: :strip` (output policy, not an operation) |
| `bl:2/sh:0.7/pix:8/br:20/co:-10/sa:35` | `Blur`, `Sharpen`, `Pixelate`, `Brightness`, `Contrast`, `Saturation` |

## Boundary rules

Runtime dispatches through `ImagePipe.Transform` and must not depend on concrete
Plan or Transform operation modules. Runtime shouldn't depend on parser-specific
Imgproxy structs, and parser-specific request structs must not leak into runtime
execution.

Parser and planner modules construct exported semantic Plan operation structs
when they translate syntax into `ImagePipe.Plan`. Transform Plan execution may
reference both semantic Plan operations and executable Transform operations
because it owns conversion between those boundaries.

Boundary exports should stay narrow: export behaviours and stable
public/internal entry points, not implementation helpers.
