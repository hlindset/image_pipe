# API semantics

For setup and everyday usage, start with the [documentation overview](index.md).
The [processing reference](processing.md) organizes options by task with URL and
Elixir examples. This contract specifies public processing and request semantics.

## Processing model

URL requests and typed Elixir plans share one declarative processing model.
Options within a group have a fixed processing order. Explicit group boundaries
sequence processing (`-` in URLs, `ImagePipe.URL.group/2` in Elixir).
Request options apply to the whole request wherever a URL writes them, so a
URL group holding only request options adds no group.
Sources, caches, detectors, and telemetry exporters are host extension points.

## Capabilities

| Area | Supported behavior |
| --- | --- |
| Validation | Reject duplicate, conflicting, inert, or invalid options before side effects; ignore valid image-only output options on non-image outputs; canonicalize equivalent requests |
| Requests | Presets, signing, expiry, GET/HEAD/OPTIONS, conditional GET, negotiation, caching, and streamed delivery |
| Resize | Contain, cover, cover-down, stretch, auto, enlargement, minimum dimensions, independent zoom axes, and DPR |
| Crop | Guided and explicit regions, anchors, focal points, attention, face/object detection, offsets, and ratio correction |
| Geometry | EXIF policy, arbitrary rotation, flips, symmetric trim, canvas placement, padding, and alpha-aware background |
| Watermarks | Host-named or opt-in request-supplied image assets with opacity, scale, anchored placement, offsets, and tiling |
| Effects | Blur, progressive blur, sharpen, pixelate, grayscale, bitonal, monochrome, duotone, brightness, contrast, saturation, colorize, and gradient |
| Encoding | Explicit or negotiated formats, quality and per-format quality, byte budgets, SSIMULACRA2/Butteraugli/size search, and JPEG/PNG/WebP/AVIF controls |
| Color and metadata | Copyright and metadata policy, ICC conversion and preservation, and HDR preservation |
| Sources | Filesystem, HTTP(S), S3, host adapters, custom schemes, and authenticated source concealment |
| Delivery | Images, BlurHash, LQIP CSS, info JSON, filenames, attachments, cachebusters, opt-in debug headers, and clock injection |

## Host configuration

URL configuration owns signing/encryption keys and the URL prefix. Server
configuration owns source/cache adapters, generation limits, output defaults,
detection, watermarks, storage partitions, presets, request defaults, and the
preset lookup. Plug configuration adds
HTTP delivery controls. Source adapters validate their own options, including
network limits and credentials. See the [configuration reference](configuration.md).

Request defaults can set options such as `orient` and `anchor=smart-face` for
every request. Generated [HTTP cache policy](cdn-http-cache.md) respects
host headers and source storage permission.

## Processing semantics

The fixed stage order is rotate, flip, trim, source crop, resize/result
crop, effects, canvas, padding, background, watermark. Within effects the order is
blur, progressive blur, sharpen, pixelate, gray, bitonal, monochrome, duotone, brightness,
contrast, saturation, colorize, gradient. Units are explicit and `-`
groups are ordered. Rotate accepts arbitrary angles; `flip=h`, `flip=v`, and
`flip=hv` reflect horizontally, vertically, or both after rotation.
For example, `/w=500/-/trim=fff/src/image.jpg` deliberately trims the
smaller intermediate image. It must remain observably different from
`/w=500/trim=fff/src/image.jpg`, which trims before resizing.

### Coordinates and group boundaries

Every operation addresses the display frame produced by preceding stages.
Request-level `orient=auto` applies the source EXIF orientation once, before
the first group's logical operations; `orient=none` uses stored axes.
For example, a stored 400×300 image with EXIF orientation 6 has a 300×400
display frame. A top-left crop addresses the displayed top-left corner.
The executor may defer physical rotation only when coordinate compensation
produces the same result as this logical order.

Automatic trim samples the displayed top-left corner. Pending orientation is
applied before trim so that both background sampling and trim axes follow this
frame. The request-wide `orient` value also applies to BlurHash and LQIP CSS. A default
preset can set `orient=none`; an explicit URL value overrides that preset.

Crop and region percentages use their operation's input dimensions, after
rotation, flip, and trim. Trimming a 1000px-wide input to 800px and then
applying `crop=50pct,100pct` requests 400px in width. Decode shrink-on-load
preserves these source-pixel coordinates. Region coordinates are
relative to the trimmed image, with no hidden original-image offset.
Crop and region widths and heights must be positive; invalid sizes fail
during request parsing before source resolution or cache access.

Each `-` group receives the previous group's complete result, including
canvas, padding, background, and watermark. Group parameters do not carry forward:
guide, rotation, DPR, and effects must be stated again to apply again.
EXIF is not reapplied. Internal orientation/color/materialization state may
survive a group boundary when doing so is observably equivalent. Decode
happens once, and only the first group may inform shrink-on-load.
BlurHash's terminal reduction contributes a decode hint only for a single
group, sized against its source crop when present so the crop retains enough
detail for the terminal's working frame. Multi-group requests preserve the first
group's input scale unless that group explicitly resizes it.

### Pages and frames

A multi-page or animated source (a TIFF, a HEIF/AVIF collection, an animated
WebP, JPEG XL, or GIF) decodes one image. Without `page`, that is the source's
default image: the primary image of a HEIF collection, the default image of an
APNG, and the first page or frame otherwise. `page=N` selects page or frame N,
0-based in file order, so `page=0` can differ from the default for HEIF. A still
image has one page. A page past the last fails with `422` before decoding.
Selecting frame N of an animation composites the frames before it, so the input
pixel limit counts `N + 1` frames; a selected page of a TIFF or HEIF collection
counts its own dimensions. `page` applies to every output, including info, and
is part of the request's cache identity.

### Crop ratios and trim symmetry

`crop-ratio=16:9` (or a positive decimal such as `1.5`) corrects the guided
crop box to that aspect ratio by reducing one dimension. Add
`crop-ratio-enlarge` to grow the other dimension instead. The corrected box
is uniformly capped to the current image bounds, then placed using the crop
guide. Ratio correction uses display axes and physical source pixels.

`trim-symmetry=h`, `v`, or `hv` removes equal amounts from opposing edges
on the selected display axes. It uses the smaller detected inset, preserving
all foreground content. It requires `trim` in the same group.

### DPR, zoom, offsets, and padding

DPR scales output targets and
pixel padding/offsets. Source crop and region lengths are physical source
pixels, unaffected by DPR. Percentages resolve once against their declared
physical frame: crop input for anchor offsets, target canvas for extension
offsets. A 60px percentage result stays 60px when DPR is 2.

Resize computes its target using `w`/`h`, minimum dimensions, per-axis zoom,
and DPR. Zoom affects only resize targets. With enlargement disabled, cap
the resize scale to avoid increasing source pixels; reduce the effective
DPR by the same uniform clamp factor. Use this effective DPR for pixel
offsets, padding, and canvas target sizes. For example, a square 150px
source with `w=100/h=100/dpr=2/pad=10` becomes a 150px image with 15px
padding on each side, a 180px result. With `enlarge`, it becomes a 200px
image with 20px padding, a 240px result. With no resize operation, effective
DPR is the requested DPR; padding alone does not scale the source image.
For stretch, use a uniform enlargement clamp across both axes so that
clamping does not change the requested target aspect ratio.

Default resize mode is `contain`, enlargement is off, DPR and zoom are 1,
the default crop anchor is center, and alpha is preserved unless a
background is requested. `auto` selects cover when source and target
orientation match on display axes, contain otherwise. All geometry is
resolved before final integer-pixel rounding.

`dpr` accepts a positive decimal. `zoom` accepts a positive decimal for both
axes, or an `x,y` pair. It scales the requested box before the resize mode
is applied; an automatic axis follows the aspect ratio after the specified
axis is zoomed. `min-w` and `min-h` accept positive integer logical pixels;
they uniformly expand the resize target as necessary before the enlargement
cap. With minimum dimensions alone, the starting target is the current image.
A non-unit zoom requires a width, height, or minimum dimension. DPR alone
can scale padding without resizing the source. These options reset at `-`.

### Anchor offsets and canvas placement

`anchor-offset=x,y` moves a guided crop or cover result crop from its named
anchor. Both components accept signed pixels or explicit percentages, such
as `anchor-offset=10,-5pct`. It requires an explicit non-smart `anchor`.
Positive values move inward from right/bottom edges and forward from
left/top/center; placement is clamped to retain the crop inside its input.
Each crop resolves percentages against its own input frame. Pixel offsets
use the group's effective DPR, including when the source crop precedes resize.

`extend` expands the canvas to the `w`/`h` box; `extend-ratio` expands it to
that aspect ratio. Both require concrete `w` and `h`, and cannot be enabled
together. Canvas expansion preserves the image's scale and never crops it.
The box dimensions use effective DPR; zoom affects the resize alone.

`extend-at` chooses a named anchor, defaulting to center. `extend-offset=x,y`
uses the same signed-length syntax, with percentages resolved against the
realized target canvas and pixels scaled by effective DPR. Placement is
clamped inside the canvas. Canvas placement runs in display coordinates,
after effects and before padding and background. Added space is transparent
until a background is requested. Canvas and offset options reset at `-`.

### Watermarks

`wm=name` selects a host-configured asset; `wm-src64` and `wm-enc` name a
request-supplied source, decoded like `src64` and `enc`, when the host sets
`request_watermarks`. Exactly one names the asset. `wm-opacity` (0 to 1,
default 1) multiplies the host entry's base opacity; zero canonicalizes to
absence. `wm-scale` (greater than 0, at most 1) fits the asset, with
enlargement, inside that fraction of the frame; without it the asset keeps its
natural size times effective DPR. `wm-at` and `wm-offset` use the canvas
anchor and signed-length rules, with pixels scaled by effective DPR and
percentages resolved against the frame, but placement is not clamped: overflow
is clipped and an asset entirely outside the frame draws nothing. `wm-tile`
repeats the asset in every direction from its anchored position; `wm-gap`
(non-negative lengths) spaces the tiles. The other `wm-*` options require an
asset, `wm-gap` requires `wm-tile`, and all reset at `-`.

The watermark runs last in its group, on the display frame left by
background. Assets resolve through the source mounts and input cache with the
main source's limits, decode their default frame with EXIF orientation, and
take the main source's input color management. Their metadata and profile are
dropped. The asset is converted into the frame's color space and band format
and composited `over` it; a frame without alpha keeps none. Unknown names,
disabled request sources, and inert options fail before source or cache
access. Asset fetch failures use the main source's statuses and decode failures
return `415`. Identity takes each asset's source identity, byte identity, and
effective opacity, never the host entry name.

### Object and face guides

`detect=face`, `detect=car,dog`, and `detect=all` guide a source crop or
cover-family resize using detected regions. Each comma-separated class may
include a positive decimal weight up to `1_000_000`, as in
`detect=all,face:3`. `all` includes every detected class; named classes alone
filter detection. Class order is canonical, duplicate names are rejected,
and integer/decimal weight spellings share identity. Names use lowercase
letters, digits, underscores, and hyphens, starting with a letter or digit.

`anchor=smart-face` combines attention with face detection; `anchor=smart`
uses attention alone. `anchor`, `focus`, and `detect` are mutually exclusive
guides and form one preset override family together with `anchor-offset`.
Detection and smart guides do not accept anchor offsets. Guides reset at `-`.

Mount options are `detector: :default | nil | module` and
`detector_required: boolean`. Strict mode checks the requested explicit
detection classes before source resolution or cache access and returns 501
when unavailable. Face-assisted attention remains optional. Missing, empty,
or failed optional detection falls back to attention cropping.

Representation identity includes the detector identities relevant to every
group, including face models used by `smart-face`. Both storage keys and
ETags change when a relevant model changes; unrelated model changes leave
them stable. See [content-aware cropping](content-aware-gravity.md) for host
configuration, weighting, and warmup.

### Sources

All source forms route through the configured source mounts (see
[sources](sources.md#mounts-and-routing)). `src/<source>` percent-decodes its
tail once; `src64/<source>` decodes unpadded base64url. After this outer
decoding:

- A relative path goes to the mount whose `prefix` is its first segment, which
  receives the remaining segments, or else to the `:path` mount. Its path
  segments are not percent-decoded again.
- An HTTP(S) URL goes to the mount matching its scheme. Its path components
  are decoded once as URL components and encoded by the adapter when fetching.
  The query stays an opaque encoded string. Userinfo, fragments, malformed
  escapes, and ports outside `1..65535` are rejected.
- `s3://bucket/key?revision` goes to the mount matching `s3`, with bucket,
  object key, and optional revision. Key and revision are percent-decoded
  once. The entire query is the revision, an S3 version ID the adapter sends
  as `versionId`; it is not written as a `versionId=` parameter. Empty keys,
  userinfo, fragments, and ports are rejected.
- Any other `scheme://rest` goes to the mount matching that scheme as the path
  `rest`, split on `/` with no further decoding. A scheme no mount matches is
  rejected as an invalid source before any source access.

Paths with nothing after their prefix or scheme, or with empty, `.`, or `..`
segments, are rejected before the adapter runs.

For example, an HTTP source whose filename contains `#` is
`https://images.example/cat%23one.jpg`. Its `src` spelling includes
`cat%2523one.jpg`, preserving the source URL's own escape through the outer
decoding layer. `src64` avoids this extra layer.

Source adapters remain responsible for filesystem confinement, allowed
origins, redirect and body limits, and object credentials.

### Source concealment

Use `enc/<token>` as an alternative to `src` and `src64`. The token is
canonical unpadded base64url of a version byte (`1`), a 16-byte IV,
PKCS#7-padded AES-256-CBC ciphertext (a positive multiple of 16 bytes), and
a 32-byte authentication tag. Source plaintext is nonempty UTF-8.

The authenticated encryption construction is **A256CBC-HS512** from
[RFC 7518 section 5.2.5](https://www.rfc-editor.org/rfc/rfc7518.html#section-5.2.5),
using OTP AES-CBC and HMAC primitives. For each 32-byte master key,
[HKDF-SHA256](https://www.rfc-editor.org/rfc/rfc5869.html) derives 96 bytes
with salt `image-pipe:source:v1` and info `A256CBC-HS512+IV` (literal UTF-8
bytes). The first 32 bytes are the MAC key, the next 32 the AES key, and
the last 32 the deterministic-IV key. Associated data is the literal
`image-pipe:source:v1`. The tag is the first 32 bytes of HMAC-SHA512 over
`AAD || IV || ciphertext || AL`, where `AL` is the AAD's bit length as an
unsigned 64-bit big-endian integer. Verify the tag before CBC decryption
or padding validation.

Encryption keys are a separate ordered list of 32-byte keys: encrypt with
the first, authenticate/decrypt against the configured list during rotation.
Set `source_encryption_keys: [key, previous_key]` using raw binary keys;
signing `keys` use hex-encoded strings. An empty encryption list disables
concealment. Encryption keys must differ from the signing keys.
Choose generation with `iv_mode: :deterministic` (default) or `:random`.
Deterministic generation uses the first 16 bytes of HMAC-SHA256 of the
complete source bytes under the derived IV key. Random generation uses
`crypto.strong_rand_bytes(16)`. Both modes have the same token framing and
decoder. Per-call `iv: :deterministic`, `iv: :random`, or `iv: <<16 bytes>>`
overrides the configured generation mode. Explicit IVs are an advanced
caller responsibility: use unpredictable random IVs or a secret-keyed
derivation over the complete source, and do not reuse an IV for different
sources under the same key. A constant IV or public hash of the source is
unsuitable. Reusable configuration accepts only a mode, never a fixed IV.
An explicit IV encrypts the main source. A concealed watermark source in the
same URL takes the first 16 bytes of HMAC-SHA256 under the derived IV key over
`0xFF || explicit IV || source bytes`; the `0xFF` byte, invalid in UTF-8,
keeps these inputs apart from deterministic derivation.

Configure signing keys whenever encryption is enabled, and verify the full
request signature before decrypting. This binds processing options and
expiry as well as the source token. Reject wrong token lengths/versions,
authentication failures, and invalid UTF-8 through the same external 404
response, before source resolution/fetch or cache access. Validate the framing
before calling OTP. Do not emit plaintext, token, or key
material in diagnostics or telemetry.

After decryption, use the same source validation and identity as plain sources.
Every encryption mode shares storage/ETag identity with the same plain source
and transform. Deterministic encryption also preserves browser/CDN URL identity:
identical source bytes and active encryption key yield identical tokens across
calls, processes, and independently built configurations. Transforms and expiry
do not affect the source token; they are covered by the outer URL signature.
Changing expiry or the signing key can still change the complete URL.

Deterministic tokens disclose source equality. CBC padding discloses source
length rounded up to a 16-byte block (including a full padding block when
already aligned). Neither mode hides this length information. Keep URL
generation server-side: a public arbitrary-source encryption oracle allows
guessing source values by comparison. Source hostnames, paths, filenames,
and query parameters are encrypted. Keys are redacted from configuration
inspection. Clients receive only the completed signed URL.

See [encrypted source examples](elixir-api.md#encrypted-sources) for builder
and mount setup. The generation mode does not restrict decryption, and the
mount prefix is outside the signed path. For lower-level integration,
`ImagePipe.URL.encrypt_source(source,
url_config, options)` returns only `{:ok, token}`; the caller must place it
after `enc/` and sign the complete mount-relative path, for example with
`ImagePipe.URL.sign_path/2`. Invalid source,
disabled encryption, and invalid IV overrides return tagged errors without
reflecting their values.

### Pixel effects

Effects work with or without geometry, and run after resize in the fixed
order listed above. Each group starts with its effects disabled. Use `-`
to change their relative order: `contrast=2/-/brightness=30` adjusts
brightness after contrast, while `contrast=2/brightness=30` applies
brightness first.

| Option | Values and defaults | Example |
| --- | --- | --- |
| `blur`, `sharpen` | Non-negative sigma; 0 disables the effect | `sharpen=1.5` |
| `progressive-blur` | Non-negative maximum sigma, optional direction, start, stop; 0 sigma disables | `progressive-blur=4,down,0.2,0.8` |
| `pixelate` | Integer block size at least 1; 1 disables the effect | `pixelate=8` |
| `gray`, `bitonal` | Bare flag; `=false` disables it | `gray` |
| `monochrome` | Intensity from 0 to 1, optional color (default `b3b3b3`) | `monochrome=0.8,704214` |
| `duotone` | Intensity from 0 to 1, optionally both shadow and highlight colors (default black and white) | `duotone=1,123456,efab89` |
| `brightness` | Integer additive adjustment from -255 to 255; 0 is identity | `brightness=30` |
| `contrast`, `saturation` | Positive factors; 1 is identity | `contrast=1.5/saturation=0.7` |
| `colorize` | Opacity from 0 to 1, required color, optional literal `keep-alpha` | `colorize=0.3,red,keep-alpha` |
| `gradient` | Opacity from 0 to 1, required color, optional direction, start, stop | `gradient=0.8,black,down,0.2,0.9` |

Colors accept bare 3/6-digit hex or CSS names. Positional values are comma
separated, without empty placeholders. Monochrome and duotone intensity,
and colorize and gradient opacity, use 0 as identity. Identity values share
representation identity with the absent effect; all supplied values are
still validated. Contrast and saturation retain their full positive factor
range rather than a bounded percentage scale.

Blur/progressive-blur/sharpen sigma and pixelate block size are physical effect parameters,
unaffected by DPR. Pixelate aligns its blocks with the current display axes.
Gradient direction also uses the current display frame, after resizing:
`down` (default) is 0°, `left` is 90°, `up` is 180°, and `right` is 270°.
Signed decimal angles wrap modulo 360. Start and stop are fractions from
0 to 1, defaulting to 0 and 1; reversing them reverses the ramp, and equal
values produce a hard step. Gradient preserves source alpha. Colorize
produces an opaque result unless `keep-alpha` preserves the source alpha;
zero opacity skips the operation and preserves the source unchanged.

Progressive blur shares gradient direction and stop semantics. It transitions
from no blur at start to maximum sigma at stop, interpolating eight Gaussian
sigma intervals with premultiplied alpha. It runs after uniform blur and before
sharpen, in the current display frame. Zero sigma canonicalizes to absence.

### Metadata, color profiles, and HDR

`meta` selects one metadata policy:

| Value | Retained metadata |
| --- | --- |
| `copyright` | Copyright and artist attribution; other optional metadata is stripped |
| `strip` | Optional metadata, including copyright and artist attribution, is stripped |
| `keep` | Source metadata is retained |

The default is `copyright`. Hosts may set `strip_metadata` and
`keep_copyright`; an explicit `meta` replaces both choices. Codec-required
metadata, such as JPEG dimensions, may still be written under `strip`.
Orientation metadata always describes the delivered pixels: `orient=none`
uses stored axes even under `meta=keep`, without leaving a source EXIF tag
that would rotate the result again in a viewer.

Physical density is metadata too. `dpi=N`, an integer from 1 to 65535,
writes N pixels per inch under every `meta` policy. Without `dpi`, `copyright`
and `strip` write the host `stripped_dpi` (default 72) and `keep` retains the
source density. Density never changes pixels, dimensions, or DPR scaling.
JPEG writes it to JFIF and EXIF, PNG to `pHYs` and EXIF, and WebP and AVIF
to EXIF only.

`profile=strip` converts to the standard working color space and omits the
source ICC profile. `profile=preserve` exports back to the source profile
and retains it. `profile=srgb`, `profile=display-p3`, and `profile=adobe-rgb`
convert to a shipped target profile and embed its bytes. Profile handling
is independent of `meta`: stripping optional metadata preserves a requested
output profile. The default is `strip`; host `strip_color_profile: false`
selects source-profile preservation. Input ICC conditioning happens before
transforms so operations work on interpreted colors. The executor retains an
imported source profile in its state and the runner passes it directly to the
encoder for source-profile restoration.

`hdr=preserve` retains a high-bit-depth working space when the selected
output format supports it. `hdr=tonemap` selects the standard working
space and is the default; host `preserve_hdr: true` changes that default.
JPEG falls back to standard output even under `hdr=preserve`. Named profile
conversion produces 8-bit output and cannot be combined with effective HDR
preservation; use `hdr=tonemap` with a named target. Conflicting URL and host
settings fail before source or cache access.

These policies enter image output identity. Non-image outputs validate them
and then ignore them, as described under [image quality and encoders](#image-quality-and-encoders).

### Image quality and encoders

`q=80` sets one explicit quality from 1 to 100. `format-q=avif:60,webp:70`
sets per-format qualities, using the same format names as `format`. Explicit
`q` wins over a matching `format-q`. Duplicate formats are invalid. Host
`quality` defaults to 80; `format_quality` defaults to WebP 79 and AVIF 63.
Sparse host and URL format maps preserve other configured formats.
A format-quality table may be shared across requests; only the selected
format's entry applies.
PNG ignores the implicit global quality default; an explicit quality can
request quantization.

`autoquality` starts with a metric name followed by optional named fields:

| Metric | Target | Example |
| --- | --- | --- |
| `size` | Positive byte count, required unless supplied by the host | `autoquality=size,target:15000,min:40,max:95` |
| `ssimulacra2` | Score from 0 to 100; default 78 | `autoquality=ssimulacra2,target:80,min:50,max:95,error:3` |
| `butteraugli` | Distance from 0 to 25; default 1 | `autoquality=butteraugli,target:1,error:0.1` |

`min` and `max` bound quality from 1 to 100. URL bounds override per-format
host bounds, which override the global host bounds. `error` is a non-negative
perceptual tolerance; size search does not accept it. Repeated or unknown
fields and inverted effective bounds are rejected before source access.
Supported formats use iterative search. Large-image SSIMULACRA2 searches use
crop scoring with a content-dependent correction.

`autoquality=none` disables a configured search. An explicit `q` also disables
inherited host search; combining it with an enabled URL `autoquality` is an
error. Presets treat `q` and `autoquality` as one override family.

`max-bytes=8000` adds a byte budget to fixed quality or quality search. Budgets
are best effort: if the minimum-quality encode cannot fit, ImagePipe still
returns the best available image. A byte budget without a quality-search
objective uses a quality floor of 10, or the requested quality when it is lower.
PNG and lossless WebP cannot use quality search. An explicit selection of
either with an enabled URL search or byte budget is rejected. Inherited
search defaults are inactive for these outputs. Under automatic format
negotiation, search and byte budgets apply when the selected encoder supports
them. WebP lossless `q` controls compression effort rather than pixel quality.

Host controls include `autoquality_method`, `autoquality_target`,
`autoquality_allowed_error`, global `autoquality_min_quality` and
`autoquality_max_quality`, per-format `autoquality_format_min_quality` and
`autoquality_format_max_quality`, `autoquality_max_resolution`, and
`autoquality_max_iterations`. The iteration budget defaults to 6 and bounds
the encoder search. Active search settings participate in storage and ETag
identity; changing an unused iteration budget leaves identity stable.

Each encoder option is a comma-separated list of bare boolean flags and
`name:value` pairs. Use `flag:false` to override a host-enabled flag. Sparse
URL fields override the corresponding host option struct. Unknown or repeated
fields are invalid, as are options for another explicitly selected format.
Under negotiation, per-format options are conditionally active.

| Option | Fields |
| --- | --- |
| `jpeg-options` | `progressive`, `subsample:auto\|on\|off`, `trellis-quant`, `overshoot-deringing`, `optimize-scans`, `quant-table:0..8` |
| `png-options` | `interlace`, `palette`, `bitdepth:1\|2\|4\|8\|16`, `filter:none\|sub\|up\|avg\|paeth\|all` |
| `webp-options` | `lossless`, `near-lossless`, `smart-subsample`, `preset:default\|photo\|picture\|drawing\|icon\|text`, `effort:0..6` |
| `avif-options` | `subsample:auto\|on\|off`, `effort:0..9` |

For example, `format=jpeg/jpeg-options=progressive,quant-table:3` requests a
progressive JPEG. Host keys `jpeg_options`, `png_options`, `webp_options`,
and `avif_options` accept their corresponding
`ImagePipe.Plan.Output.*Options` structs. JPEG's host struct calls its
progressive flag `interlace`.

Image-only output options (`format`, `q`, `format-q`, `meta`, `dpi`, `profile`,
`hdr`, `autoquality`, `max-bytes`, and the encoder options) apply only to image
output. BlurHash, LQIP CSS, and info validate them as an image request would,
including their conflicts, and then ignore them: a URL is valid with a
non-image output exactly when it is valid with `output=image`, and requests
that differ only in these options share cache entries and ETags. Non-image
outputs also ignore configured image output policy.

### Presets and terminals

Presets expand before validation and canonicalization. Precedence is request
defaults, named presets in listed order, then explicit values. Request defaults
are one group without preset references. Server configuration owns preset
definitions; Plug and direct execution use the same expansion. URL generation
preserves named references and explicit overrides; the builder validates
combined requests only when given the mount's presets. Resolve nested static
presets at initialization and reject cycles/unknown names. A host
preset lookup resolves names the static map does not define per request, after
signature verification and before source or cache access, with the same
precedence and composition; static names shadow it.
Single-group presets contribute to the first group. A preset containing
`-` supplies the complete group sequence and cannot combine with explicit
URL group options or another multi-group preset; request-scoped options may
still override it. Presets cannot supply a source or signature. Their names
do not participate in representation identity.

`output=image` uses negotiated or explicit format. `output=blurhash` returns
text. `output=lqip-css` returns Image's packed 8-digit `#rrggbbaa` placeholder
value as `text/plain; charset=utf-8`, with no `Vary: Accept`. Both placeholder
outputs apply all groups and orientation, normalize to sRGB with black-flattened
alpha and 8-bit channels, and retain source safety limits. LQIP CSS reduces to a
materialized 3×3 frame before sampling; it adds no terminal-specific decode hint.
The value is used as `style="--lqip: #22333091"` with the shared stylesheet in
[Image's LQIP CSS guide](https://hexdocs.pm/image/lqip_css.html). Successful
placeholder responses use the usual cache and pre-fetch conditional-request path.

`output=info` returns JSON describing the source and the result of the
request's groups:

```json
{
  "source": {"format": "jpeg", "mime_type": "image/jpeg", "width": 4000,
             "height": 3000, "orientation": 6, "pages": 1, "size": 2481920},
  "result": {"width": 600, "height": 450, "dpr": 1.0,
             "blurhash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "lqip_css": "#22333091"}
}
```

`source` has the source `format`, `mime_type`, display `width`/`height` under
its EXIF orientation regardless of `orient`, EXIF `orientation`, `pages` (the
number of pages or frames the source declares), and optional byte `size`. With
`page=N`, the dimensions and orientation describe page N. Format names use the
library's canonical vocabulary, including `heif`, `jpeg_xl`, and `jpeg2000`.

`result` has the `width` and `height` an image request for the same URL would
encode, and `dpr`, the effective DPR of the last group after the enlargement
clamp. A caller divides by `dpr` for CSS dimensions: without `enlarge`,
`w=100/dpr=2` on a 150px source reports width 150 at DPR 1.5. DPR does not
carry across groups, so `dpr` describes the last group's lengths; an earlier
group's enlargement clamp is not reflected in it.

Flags after `info` add placeholders to `result`: `output=info,blurhash,lqip-css`.
Each value equals what `output=blurhash` or `output=lqip-css` returns for the
same URL, and the source is fetched once. Info accepts every group option,
`orient`, and `page`, and ignores image-only output options. It uses fixed
`application/json`, does not set `Vary: Accept`, and retains source safety
limits. A request with no operations and no LQIP reads only the header; BlurHash
adds its own decode of the fetched source. Host image encoding policies do not
alter info.

### Skip processing

The host setting `skip_processing_formats` lists source formats that
ImagePipe may deliver as the unchanged source bytes. An image request is
skipped when the source signature names a listed format, the request draws no
watermark, and it names no `format` or names the source's own format. Accept
negotiation does not prevent a skip: a client that accepts AVIF receives a
listed GIF as `image/gif`. Other requests, and every `info`, `blurhash`, and
`lqip-css` request, are processed as usual.

A skipped request ignores every group option, `orient`, `page`, and every
output option, and its response keeps the source metadata. ImagePipe makes no
libvips call for it, so decode checks, `max_input_pixels`, frame limits, and
result limits do not apply; a corrupt or oversized listed source is delivered
as the origin holds it. Source limits, including `max_body_bytes`, still
apply, and parsing still validates every option before source access. The
response carries the source format's media type with
`X-Content-Type-Options: nosniff` and the same `Vary: Accept` as a processed
request. The listed formats contribute to cache keys and ETags; skipped
responses are not written to the output cache.

### Request delivery controls

`filename=photo` supplies a response filename stem. `attachment` (or
`attachment=true`) selects download disposition; `attachment=false` selects
inline disposition and overrides an inherited preset value. Both apply to image,
BlurHash, LQIP CSS, and info responses. ImagePipe adds the actual response's extension,
including `.txt` for BlurHash and LQIP CSS and `.json` for info. Filename and attachment
settings are applied from the current request on cache hits as well as misses.
They do not participate in cache keys or ETags, and `304` responses omit
`Content-Disposition`. HEAD preserves GET response headers; the HTTP adapter
suppresses its body.

`filename` and `cb` accept nonempty values containing ASCII letters, digits,
dots, underscores, and hyphens. Option values do not support percent escapes.
`cb=release-2` contributes only to storage identity: it selects a new cache entry
without changing the ETag of an otherwise identical representation. Debug intent
is also presentation-only and remains subject to the host disclosure gate.

`expires` is a UNIX timestamp in seconds. A request expires when it is less than
the current time; equality remains valid. Expired requests return `410` before
source fetch or cache access. Hosts may configure `clock: fn -> unix_seconds end`
for a controlled time source; the default is `System.os_time(:second)`.
