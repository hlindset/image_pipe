# Imgproxy path API

## Mental model

An Imgproxy URL describes desired output, not a step-by-step image pipeline.
ImagePipe normalizes aliases and conflicts, converts supported options into
`ImagePipe.Plan` operations, then runs those operations in a fixed order.

For a feature-by-feature comparison with Imgproxy's processing URL surface, see
[Imgproxy support matrix](imgproxy_support_matrix.md).

## Mounting

`ImagePipe.Dialect.Imgproxy` is a dialect driven by the shared
`ImagePipe.Plug` runner — mount it with `dialect:`:

```elixir
plug ImagePipe.Plug,
  dialect: ImagePipe.Dialect.Imgproxy,
  sources: [...],
  source_url_encryption_key: "..."
```

Configuration is one flat keyword list. `ImagePipe.Plug` reads only `:dialect`
and hands everything else to the dialect's `validate_config!/1`.

The dialect's config validates strictly: an unknown key raises out of
`ImagePipe.Plug.init/1` rather than being ignored, so a typo or an unsupported
option fails loudly at boot. See
[Dialect-stack divergences](imgproxy_support_matrix.md#dialect-stack-divergences)
for the (small) set of ImagePipe-side implementation facts a host mounting the
dialect should know.

### Mount point

The dialect reads the request path the same way regardless of mount point: it
may be mounted at the root or below a prefix (`Plug.Router.forward/2`, or any
mount that sets `script_name`). The mount prefix is stripped before the
signature segment is read, so it is **not** part of the signed material: one
signed path verifies at `/` and under `/img` alike. The same holds for the
`/info` prefix, which is stripped before the signature is checked (matching
upstream). Query strings are excluded from the signed material and from the
response's identity.

## Path shape

The general shape is:

    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]
    /<signature>/option[:arg...]/option[:arg...]/<base64-url>[.<extension>]
    /<signature>/option[:arg...]/option[:arg...]/enc/<encrypted-url>[.<extension>]

ImagePipe verifies the signature segment first. Unsigned development URLs must
use `_` or `unsafe`. Signed URLs must use a valid configured HMAC or trusted
signature.

Before verification, ImagePipe applies Imgproxy-compatible `fixPath`
normalization for encoded option separators and plain URL schemes.

`plain` starts the source path. Add `@extension` to the end of the source path
to request an explicit output format and bypass `Accept` negotiation. The suffix
doesn't declare the source image format. ImagePipe still detects the source
family from decoded image metadata.

Without `plain` or `enc`, ImagePipe treats the remaining path segments as an
Imgproxy Base64URL source value. It joins those segments without `/`, trims
trailing `=`, decodes URL-safe Base64, and passes the decoded string through the
same source translation used by plain sources. A decoded `images/cat.jpg`,
`local:///images/cat.jpg`, `https://example.com/cat.jpg`, `s3://bucket/key`, or
configured custom scheme produces the same `ImagePipe.Plan` source as the
matching plain request.

`enc` starts an encrypted source URL. Configure it through the mount's
`ImagePipe.Plug.init/1` (which delegates to
`ImagePipe.Dialect.Imgproxy.validate_config!/1` for the `dialect:` key):

```elixir
source_url_encryption_key: "000102030405060708090a0b0c0d0e0f"
```

The encrypted value is `base64url(iv <> aes-cbc-pkcs7(source_url))`. The key
must be a hex string that decodes to 16, 24, or 32 bytes. The IV is the first 16
decoded bytes. Decryption failures return the same parser error and happen
before source identity resolution, cache lookup, or source fetch.

Base64 and encrypted sources use `.extension`, not `@extension`, for explicit
output format selection:

    /_/aW1hZ2VzL2NhdC5qcGc.webp
    /_/enc/EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ.webp

Base64URL is reversible path encoding. Treat it as routing syntax, not a
secrecy boundary. The received request path can still appear in request logs
wherever the host application logs paths.

Encrypted URLs hide the source string from the path, but unsigned encrypted
URLs don't prove source authorization and don't give ciphertext integrity.
Because the IV is part of the path token, a caller who can see an unsigned
encrypted URL can change first-block plaintext bytes without the key. If the
changed plaintext is still a valid configured source, ImagePipe will plan it.
Sign production encrypted URLs. Signature verification happens before
decryption, so a tampered encrypted segment or SEO filename fails before padding
checks when callers enable signing.

Use `ImagePipe.Dialect.Imgproxy.encrypt_source_url/3` to generate only the
encrypted source segment:

```elixir
{:ok, segment} =
  ImagePipe.Dialect.Imgproxy.encrypt_source_url(
    "images/cat.jpg",
    "000102030405060708090a0b0c0d0e0f"
  )
```

The helper doesn't add `/enc/`, processing options, output suffixes, or
signatures. By default it uses a random IV, so the same source URL can produce
different path strings. Pass `iv: <<...::binary-size(16)>>` only when the
calling application owns IV derivation and storage. Don't derive IVs from the
URL signing key.

For encoded sources, ImagePipe follows Imgproxy's split rule: path segments
remain options only while they contain the argument separator, currently `:`.
The first bare segment starts the source. If that first bare segment is
`plain`, the request uses plain source parsing. If it's `enc`, the next
segments are the encrypted source value. Later source chunks named `plain`,
`enc`, `ar`, `fl`, `padding`, or another option name remain encoded source
chunks. Explicit `/plain/` requests can still use ImagePipe's `-` pipeline
separator before the plain marker.

With `base64_url_includes_filename: true`, Base64 and encrypted sources discard
the final source segment before joining chunks and before parsing `.extension`.
This matches imgproxy's `IMGPROXY_BASE64_URL_INCLUDES_FILENAME` behavior:

    /_/aW1hZ2VzL2NhdC5qcGc.webp/puppy.jpg
    /_/enc/EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ.webp/puppy.jpg

Both examples parse the `.webp` suffix from the encoded or encrypted segment.
The final `puppy.jpg` segment doesn't enter the source, plan, or cache key. For
signed URLs, it remains part of the signed path. Changing it invalidates the
signature.

In URL paths, option segments before the source need the `:` separator. Use
`ar:true`, `fl:true:true`, and `pd:10`, not bare `ar`, `fl`, or `pd`, before a
source marker. ImagePipe parses a bare option name as the start of an encoded
source.

Signature verification uses the received fixed path before Base64 decoding or
encrypted-source decryption. For signed URLs, sign the encoded or encrypted path
and suffix exactly as sent after Imgproxy `fixPath` normalization.

ImagePipe doesn't build Imgproxy source preprocessing controlled by
`IMGPROXY_BASE_URL` or `IMGPROXY_URL_REPLACEMENTS`. Requests with malformed
Base64URL values, malformed encrypted source values, and unsupported decoded
source schemes fail before source identity resolution, cache lookup, or source
fetch.

## Pipeline groups

`-` separates Imgproxy pipeline groups. Non-empty groups execute in path group
order. ImagePipe ignores empty pipeline groups.

Within each pipeline group, ImagePipe uses this fixed operation order:

1. orientation, in `auto_orient`, `rotate`, then `flip` order
2. explicit crop
3. resize intent, including `mode: :auto`
4. result crop for `fill`, `fill-down`, and `auto` target geometry
5. effects, in `blur`, `sharpen`, `pixelate`, `brightness`, `contrast`, then `saturation` order
6. canvas extension
7. padding
8. background flattening

## Option ordering and conflict resolution

ImagePipe normalizes aliases before conflict resolution. If more than one URL
option maps to the same canonical request field, the last occurrence in the URL
wins.

Examples:

- `w:100/width:200` resolves width to `200`.
- `width:200/w:100` resolves width to `100`.
- `rt:fit/resizing_type:force` resolves resizing type to `force`.

Conflict resolution applies to canonical request fields, not raw option names.
For example, `w` and `width` conflict when both map to width. `rt` and
`resizing_type` conflict when both map to resizing type.

Pipeline separators scope transform fields to each pipeline group. Duplicate
transform fields stay in their pipeline group. Global fields such as output
format, quality, cachebuster, expiry, filename, and response disposition can
appear across groups and still resolve by canonical field.

Generic quality and format-specific quality are separate canonical fields.

## Presets

Normal processing URLs support configured Imgproxy presets:

    ImagePipe.Plug.init(
      dialect: ImagePipe.Dialect.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
      ],
      presets: %{
        "default" => "rt:fill/el:1",
        "thumb" => "rs:fit:120:120",
        "sharp-thumb" => "pr:thumb/q:82",
        "responsive" => "w:900/-/w:450"
      }
    )

`preset` and `pr` accept one or more preset names in a single option segment:

    /_/preset:thumb/plain/images/cat.jpg
    /_/pr:thumb:sharp-thumb/plain/images/cat.jpg

`ImagePipe.Dialect.Imgproxy` expands presets before plan construction, source
identity resolution, cache lookup, or source fetch. Preset names aren't stored
in `ImagePipe.Plan`, runtime state, output negotiation, transform state, or
cache data. A request using `pr:thumb` and a request spelling out the same
expanded options share the same cache key for the same resolved source identity
and vary inputs.

ImagePipe applies a configured preset named `default` to every normal
processing request before URL options. URL assignments in the same merged
pipeline group can override fields from `default`.

Presets may reference other presets. ImagePipe skips recursive re-entry,
matching Imgproxy behavior: if `a` expands to `pr:a/w:100`, ImagePipe ignores
the nested `pr:a` and still applies `w:100`.

Preset values may contain `-` pipeline separators. ImagePipe applies the first
preset group to the current URL pipeline group. It queues later preset groups
for following URL groups, where URL options can override queued preset fields.
Remaining queued groups become trailing pipelines.

## Supported options and aliases

| Concept | Options | Accepted values |
| --- | --- | --- |
| Resize tuple | `resize`, `rs` | `:<resizing_type>:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Size tuple | `size`, `s` | `:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Resizing type | `resizing_type`, `rt` | `fit`, `fill`, `fill-down`, `force`, `auto` |
| Width | `width`, `w` | non-negative pixel integer. `0` means `auto` |
| Height | `height`, `h` | non-negative pixel integer. `0` means `auto` |
| Min width | `min-width`, `mw` | non-negative pixel integer |
| Min height | `min-height`, `mh` | non-negative pixel integer |
| Enlarge | `enlarge`, `el` | boolean: `1`, `t`, `true`, `0`, `f`, `false` |
| Zoom | `zoom`, `z` | positive number, or positive `x:y` numbers |
| Device pixel ratio (DPR) | `dpr` | positive number |
| Extend canvas | `extend`, `ex` | boolean, optionally followed by extend gravity and offsets |
| Extend aspect ratio | `extend_aspect_ratio`, `extend_ar`, `exar` | boolean, optionally followed by extend gravity |
| Crop aspect ratio | `crop_aspect_ratio`, `crop_ar`, `car` | non-negative `<aspect_ratio>`, optionally followed by an enlarge boolean |
| Padding | `padding`, `pd` | CSS-style top/right/bottom/left non-negative pixel integers |
| Background | `background`, `bg` | `R:G:B`, 3 digit hex, 6 digit hex, or empty to clear |
| Blur | `blur`, `bl` | non-negative sigma number. `0` means no-op |
| Sharpen | `sharpen`, `sh` | non-negative sigma number. `0` means no-op |
| Pixelate | `pixelate`, `pix` | non-negative integer block size. `0` and `1` mean no-op |
| Brightness | `brightness`, `br` | number from `-100` to `100`. `0` means no-op |
| Contrast | `contrast`, `co` | number from `-100` to `100`. `0` means no-op |
| Saturation | `saturation`, `sa` | number from `-100` to `100`. `0` means no-op |
| Crop | `crop`, `c` | `<width>:<height>`, optional gravity, optional offsets |
| Gravity | `gravity`, `g` | anchor, anchor with offsets `<anchor>:<x_offset>:<y_offset>`, or focal point `fp:<x>:<y>` |
| Auto rotate | `auto_rotate`, `ar` | boolean |
| Rotate | `rotate`, `rot` | integer degrees |
| Flip | `flip`, `fl` | one boolean for horizontal, or horizontal and vertical booleans |
| Quality | `quality`, `q` | integer quality. `0` means configured default |
| Format quality | `format_quality`, `fq` | `<format>:<quality>` |
| Format | `format`, `f`, `ext` | `webp`, `avif`, `jpeg`/`jpg`, `png` |
| cachebuster | `cachebuster`, `cb` | string value |
| Expires | `expires`, `exp` | Unix timestamp integer |
| Filename | `filename`, `fn` | filename stem, optional encoded flag |
| Attachment disposition | `return_attachment`, `att` | boolean |
| Preset | `preset`, `pr` | one or more configured preset names |
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`/`jpg`, `png` |
| Encoded source output extension | source path `.extension` | `webp`, `avif`, `jpeg`/`jpg`, `png` |

## Resize and dimensions

Supported resizing types are `fit`, `fill`, `fill-down`, `force`, and `auto`.

`0` width or height values map to `auto`. For `force`, an `auto` side preserves
the source dimension. For `fit` and proportional resize rules, ImagePipe
resolves an `auto` side from source aspect ratio. Min dimensions, zoom, DPR,
and `enlarge` apply when ImagePipe computes target dimensions.

The `dpr` option multiplies requested output dimensions. When `enlarge` is
false, ImagePipe may use a smaller multiplier than requested so raster output
doesn't grow beyond the source image. Gravity pixel offsets and padding use
that same resize multiplier, so surrounding geometry stays aligned with the
resized image.

ImagePipe keeps `auto` as `mode: :auto` in final cache key data. After a cache
miss, it compares the current image dimensions with the requested target box.
Matching current and target orientation selects `cover`. Differing or unknown
orientation selects `fit`.

`rt:force/w:0/h:200` preserves source width and forces height to `200`.
`rt:force/w:300/h:0` forces width to `300` and preserves source height.

`fit`/`fill` with both width and height set to `0` produces no geometry
transform unless min dimensions or another meaningful size constraint is
present. Zoom and DPR don't force raster enlargement for `0`-derived `auto`
sides when `enlarge` is false.

## Crop and gravity

Crop accepts dimensions, optional crop gravity, and optional offsets. If an
explicit crop omits gravity, it inherits top-level `g`/`gravity`.

### Gravity values

Gravity supports anchors and focal points. Focal point gravity uses `fp:x:y`,
where `x` and `y` range from `0.0` to `1.0`.

Anchor gravity values are `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`,
`soea`, and `sowe`.

### Gravity scope

| Source | Applies to |
| --- | --- |
| Top-level `g`/`gravity` | Result crops produced by `fill`, `fill-down`, and `auto` resize planning |
| Explicit crop without gravity | Inherits top-level `g`/`gravity` |
| Explicit crop with gravity | Uses its own gravity instead of top-level `g`/`gravity` |

### Gravity offsets

Gravity offsets are optional `x_offset` and `y_offset` values attached to the
gravity option that provided them:

| Offset source | Applies to |
| --- | --- |
| Top-level `g`/`gravity` | Result crops produced by resize planning |
| Explicit crop gravity | That explicit crop |

ImagePipe parses offset units like Imgproxy:

| Offset value | Unit |
| --- | --- |
| `abs(value) >= 1` | pixels |
| `abs(value) < 1` | relative scale |

Execution scales pixel offsets by the resize multiplier described in
[Resize and dimensions](#resize-and-dimensions).

## Orientation

Orientation options are `auto_rotate`/`ar`, `rotate`/`rot`, and `flip`/`fl`.

- `ar:true` applies embedded orientation metadata, such as EXIF orientation.
  `ar:false` disables it.
- `auto_rotate: true` in the dialect config applies EXIF autorotation when the
  URL doesn't specify `auto_rotate`/`ar`. The default config value is `true`,
  matching Imgproxy's `IMGPROXY_AUTO_ROTATE` default.
- URL `ar:true` and `ar:false` resolve as request-scoped EXIF decode policy,
  not as pipeline-local pixel operations. If more than one URL group contains
  `ar`, the last `ar` in path order wins.
- When the resolved request policy is `true`, ImagePipe carries it on the
  canonical plan (`Plan.auto_rotate`), not as a pipeline pixel operation. EXIF
  auto-orient is applied late at the orientation-flush boundary, after
  crop/resize, with crop gravity and resize dimensions compensated into the
  storage frame so the observable result matches EXIF-normalized geometry (issue
  #146). That keeps cache keys, ETags, and transform execution on the same
  canonical plan machinery.
- `rotate` and `flip` stay pipeline-scoped. They don't suppress the configured
  `auto_rotate` default and don't move across pipeline separators.
- `rot` accepts integer degrees in multiples of 90 and stores them as `0`,
  `90`, `180`, or `270`.
- `fl:true:true` flips both axes.
- `fl:true:false` flips horizontally.
- `fl:false:true` flips vertically.
- `fl:false:false` emits no flip operation.

## Canvas extension

Canvas options are `extend`/`ex`, the extend arguments inside `resize`/`size`,
and `extend_aspect_ratio`/`extend_ar`/`exar`.

- `extend:true` requests canvas extension for the requested resize box.
- `extend:false` disables canvas extension even when `resize`/`size` extend
  arguments are present.
- `exar:%extend` and `exar:%extend:%gravity` extend the canvas to match the
  aspect ratio of the requested resize dimensions (`width` and `height` from
  the same pipeline group). `%extend` is a boolean; omitted gravity defaults to
  `ce`. The ratio comes from the resize target dimensions. This option is a
  no-op when either the resize width or height is auto or zero.
- Extend gravity uses anchor values only (`ce`, `no`, `so`, `ea`, `we`,
  `noea`, `nowe`, `soea`, `sowe`), with optional numeric offsets. Focal-point
  extend gravity (`fp`) isn't supported for `exar`.

The `resize`/`size` extend arguments accept anchor gravity alone, or anchor
gravity plus `x_offset` and `y_offset`.

## Crop aspect ratio

`crop_aspect_ratio:%aspect_ratio` and `crop_ar:%aspect_ratio:%enlarge` (imgproxy
Pro) correct the aspect ratio of the active crop area:

- `%aspect_ratio` is a non-negative decimal number expressing width divided by
  height. `0` is a no-op.
- `%enlarge` is an optional boolean. When true, the crop area grows to match the
  target ratio and then clamps to image bounds. When false or omitted, the crop
  area shrinks to match the target ratio (default behavior).
- Aspect-ratio correction adjusts the crop area size only, not its gravity or
  position.
- This option applies through gravity crops only. Requests without a crop or
  with a non-gravity crop path ignore this option.

Examples:

| Goal | Imgproxy path |
| --- | --- |
| Crop at 16:9, reducing area | `/_/c:400:400/car:1.7778/plain/images/cat.jpg` |
| Crop at 4:3, enlarging to fill | `/_/c:300:300/car:1.3333:true/plain/images/cat.jpg` |

## Composition

### Padding

`padding:%top:%right:%bottom:%left` and `pd:%top:%right:%bottom:%left` add
transparent edge padding after resize and canvas extension. Missing values use
the same order as CSS padding shorthand:

- one value applies to all sides
- two values apply vertical, then horizontal sides
- three values apply top, horizontal, then bottom
- four values apply top, right, bottom, and left.

When a request repeats padding, later values update only the sides they name.
For example, `pd:10:20:30:40/padding::5` keeps top at `10` and bottom at `30`,
then sets right and left to `5`. `padding:` and all-zero padding are valid
no-ops.

Padding uses the same resize multiplier as gravity offsets. For requests that
combine no-enlarge resize with canvas extension, ImagePipe follows Imgproxy's
canvas-preserving DPR behavior instead of using only the requested `dpr`.

### Background

`background:%R:%G:%B`, `bg:%R:%G:%B`, `background:%hex`, and `bg:%hex`
flatten the current image over an sRGB color after padding. Decimal channels
are `0..255`. Hex accepts 3-digit RGB and 6-digit RRGGBB forms.

`background_alpha:%alpha` and `bga:%alpha` set background alpha. Alpha accepts
values from `0` to `1`, including decimals such as `0.5`. The alpha value
applies to the current background color or the next background color in the
same request. Without an explicit background color, `background_alpha` uses
Imgproxy's default black background.

`background:` clears an earlier background value and alpha in the same resolved
request.

Composition order is canvas extension, padding, then `background`.

## Effects

`blur:%sigma` and `bl:%sigma` apply Gaussian blur. `sharpen:%sigma` and
`sh:%sigma` apply sharpening. Sigma values must be non-negative numbers. A
sigma value of `0` parses and emits no operation.

`pixelate:%size` and `pix:%size` pixelate the current image. Size must be a
non-negative integer. `pix:0` and `pix:1` parse and emit no operation, matching
Imgproxy's pixelation no-op threshold.

`monochrome:%intensity`/`monochrome:%intensity:%color` and the `mc` short form
map image luminance into a single-color palette. Intensity must be from `0` to
`1`. `0` parses and emits no operation. Omitted color uses Imgproxy's `b3b3b3`
default. Colors use 3- or 6-digit hex without `#`.

`duotone:%intensity`/`duotone:%intensity:%shadow:%highlight` and the `dt` short
form map dark and light image areas into two colors. Intensity must be from `0`
to `1`. `0` parses and emits no operation. Omitted shadow and highlight colors
use Imgproxy's black and white defaults. For example, `dt:0.5::ffeecc` keeps the
default shadow color and sets the highlight color.

`brightness:%value` and `br:%value` adjust brightness. `contrast:%value` and
`co:%value` adjust contrast. `saturation:%value` and `sa:%value` adjust
saturation. Values must be numbers from `-100` to `100`. `0` parses and emits
no operation.

Effects run after result cropping and before canvas extension, padding, and
background composition. When more than one effect appears in a pipeline group,
ImagePipe runs them in `blur`, `sharpen`, `pixelate`, `monochrome`, `duotone`,
`brightness`, `contrast`, then `saturation` order.

## Output format and quality

When a request omits an explicit output format, ImagePipe negotiates the output
from `Accept` and sets `Vary: Accept`. To force a format, use `format`, `f`,
`ext`, put `@extension` at the end of a plain-source path, or put `.extension`
at the end of a Base64 or encrypted source path. Forced formats bypass `Accept`
negotiation and don't set `Vary: Accept`.
Missing, empty, and global wildcard-only `Accept` values fall back to the
decoded source format when ImagePipe can encode it. Explicit `image/avif`,
`image/webp`, and `image/*` media ranges still advertise modern output support.

ImagePipe supports `webp`, `avif`, `jpeg`/`jpg`, and `png` as explicit output
extensions. If a request includes both an option format and a source-path
suffix, the source-path suffix wins because the imgproxy parser treats it as
the final requested output format. Plain sources use `@extension`. Encoded and
encrypted sources use `.extension`.

Quality has two separate controls: `quality`/`q` sets generic output quality,
while `format_quality`/`fq` sets quality for one explicit format. In either
case, `0` resets quality to the configured default.

## Cache and expiry

`cachebuster`/`cb` changes cache key data without adding transform operations.
`expires`/`exp` is a Unix timestamp request validity policy.

Final cache lookup doesn't fetch, decode, or read source metadata. The key uses
canonical plan/output fields, resolved source identity,
configured vary inputs, output config, and the transform key data version.
Source-aware execution choices, such as `mode: :auto` selecting `fit` or
`cover`, don't enter the normal final cache key.

ImagePipe caches only successful encoded responses. Rejected Imgproxy requests
return before source fetch and cache lookup.

## Response filename and disposition

`filename`/`fn` sets the delivery filename stem. `return_attachment`/`att`
controls inline versus attachment `Content-Disposition`.

## Unsupported and rejected options

Unsupported and invalid Imgproxy requests fail before source fetch or cache
lookup.

These cases return HTTP 400:

- unknown option
- unsupported Imgproxy option
- supported option with invalid value
- unsupported option combination
- unknown preset
- unsupported option inside a used preset

## Examples

| Goal | Imgproxy path |
| --- | --- |
| Fit within a width | `/_/w:300/plain/images/cat.jpg` |
| Fill a box from a focal point | `/_/rt:fill/w:300/h:200/g:fp:0.25:0.75/plain/images/cat.jpg` |
| Force one side and preserve the other | `/_/rt:force/w:0/h:200/plain/images/cat.jpg` |
| Extend canvas to resize aspect ratio | `/_/rt:fit/w:300/h:200/exar:true/plain/images/cat.jpg` |
| Explicit crop with focal gravity | `/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg` |
| Auto-orient then crop | `/_/ar:true/c:100:100/plain/images/cat.jpg` |
| Explicit output format | `/_/f:webp/plain/images/cat.jpg` |
| Plain-source output format suffix | `/_/plain/images/cat.jpg@png` |
| Encoded-source output format suffix | `/_/aW1hZ2VzL2NhdC5qcGc.webp` |
| Encrypted-source output format suffix | `/_/enc/EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ.webp` |
