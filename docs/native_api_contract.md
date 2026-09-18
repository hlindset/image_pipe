# Native API contract and capability inventory

Status: implementation contract for Beads epic `image_plug-a0q`, defined in
task `image_plug-a0q.1`. This document records the intended product contract and
the capabilities to preserve. Beads owns execution status and dependencies.
Proposed names below are not a claim that those options are implemented.

## Direction

ImagePipe has one native URL API, one request lifecycle, and one executor.
The native API is path-oriented and declarative: options within a group
have a fixed processing order, and `then` explicitly sequences groups.
Imgproxy remains a useful source of image-processing behavior and reference
fixtures. Its URL grammar and complete pixel parity are not product goals.

Keep host extension points for sources, caches, detectors, and telemetry
exporters. Remove configurable dialects, generic parser/renderer dispatch,
and lifecycle callbacks whose only purpose is supporting several request
languages. Internal structs and functions should express the native
request and execution needs directly.

## Current implementation

The default `ImagePipe.Plug` mount selects native. The current checkout
mounts every API through `ImagePipe.Plug` and
`ImagePipe.Plug.DialectRunner`. There is no `ImagePipe.Parser` or
`ImagePipe.Request` framework left to remove. Native and imgproxy own their
pipelines. Shared regression tests cover the native request lifecycle,
streaming, cache, color, decode, and orientation behavior.

The native API implements these option keys:

`orient`, `rotate`, `flip`, `w`, `h`, `fit`, `enlarge`, `min-w`, `min-h`, `dpr`,
`zoom`, `crop`, `crop-ratio`, `crop-ratio-enlarge`, `region`, `trim-symmetry`,
`anchor-offset`, `extend`, `extend-ratio`, `extend-at`, `extend-offset`,
`anchor`, `focus`, `detect`, `blur`, `sharpen`, `pixelate`, `gray`, `bitonal`,
`monochrome`, `duotone`, `brightness`, `contrast`, `saturation`, `colorize`,
`gradient`, `trim`, `pad`, `bg`, `output`, `format`, `q`, `format-q`,
`autoquality`, `max-bytes`, `jpeg-options`, `png-options`, `webp-options`,
`avif-options`, `jxl-options`, `meta`, `profile`, `hdr`,
`debug`, `expires`, `preset`, `filename`, `attachment`, `cb`.

It also implements `then`, `src`, `src64`, `enc`, and full-length HMAC signing with
key rotation. Presets support nested references and complete `then` pipelines.
Sources are paths, HTTP(S) URLs, S3 objects, or configured custom schemes. Image,
BlurHash, and source-info JSON are implemented terminals. The broader vocabulary in the
[July native design](https://github.com/hlindset/image_pipe/blob/main/docs/superpowers/specs/2026-07-12-native-url-dialect-design.md)
is a proposal, not a record of shipped capabilities; in particular, LQIP
is not an implemented terminal to preserve.

## Capability disposition

Task numbers in this table are children of `image_plug-a0q`. Each port
includes native request tests, documentation, and applicable Fiddle controls.

| Existing capability | Native disposition | Owner |
| --- | --- | --- |
| Native grammar, duplicate/conflict/inert-option validation, canonicalization, presets, signing, expiry | Preserve and promote out of the dialect namespace; reject invalid requests before side effects | `.2` |
| Request lifecycle, conditional GET, negotiation, cache handling, GET/HEAD/OPTIONS, streaming resource ownership | One direct native lifecycle; preserve shared regression coverage | `.2` |
| Generated HTTP cache headers and host-header precedence | Retain `Response.CachePolicy` behavior, including source identity requirements and opt-in policy | `.2` |
| Resize modes: contain, cover, cover-down, stretch, auto; enlargement; minimum dimensions; independent zoom axes | Preserve modes; port missing dimensions and zoom controls | `.4` |
| DPR, canvas extension to box/aspect ratio, canvas gravity and offsets | Port with explicit units and native coordinate semantics | `.4` |
| Guided and explicit-region crops; anchors, focal points, smart crop; crop ratio correction and enlargement | Preserve current native operations; port missing controls | `.4` |
| Trim, padding, background flattening and background alpha | Preserve and complete native parameter coverage | `.4` |
| EXIF policy, user rotation and flips | Expose native controls; preserve orientation/decode correctness | `.4` |
| IIIF arbitrary-angle rotation, grayscale, bitonal | Port these useful operations before removing their only public entry point; native rotation must not be restricted to imgproxy quarter turns | `.3` |
| TwicPics resize/cover/contain/inside, ratio crop/canvas, percentage scaling, crop/focus | Retain their image outcomes through native geometry and `then`; retire expression syntax and implicit ordered focus state | `.3`, `.4` |
| Object/face cropping, class selection, detector configuration, required-detector behavior | Expose through native; retain detector implementations and warmup | `.5` |
| Blur, sharpen, pixelate, monochrome, duotone, brightness, contrast, saturation, colorize, gradient | Expose the full implemented range of each effect; gray/bitonal ports belong to `.3` | `.6` |
| Explicit image formats, Accept negotiation, format preference/capability selection, quality and per-format quality | Preserve existing formats and negotiation; port all quality controls | `.2`, `.7` |
| Maximum output bytes and automatic quality search: size, SSIMULACRA2, Butteraugli | Preserve algorithms and host tuning controls, with explicit native vocabulary | `.7` |
| JPEG, PNG, WebP, AVIF, and JXL encoder options | Preserve all implemented host controls and existing request controls; avoid dropping JXL because the old proposed URL table omitted it | `.7` |
| Metadata stripping, copyright retention, output profile policy/selection, HDR preservation | Expose native policy; preserve input ICC conditioning and encoder carry | `.8` |
| Filesystem, HTTP, S3 and host source adapters; custom scheme translation | Native source model must reach every retained adapter, including object references | `.9` |
| Source URL concealment | Authenticated encrypted source tokens with independent encryption and signing keys, as specified below | `.9` |
| BlurHash and source/info output | Preserve BlurHash; port useful info output with a native response contract | `.10` |
| Cachebuster, filename, attachment, debug headers, clock injection | Port request controls; keep debug opt-in and presentation separate from cached image bytes | `.10` |
| IIIF identifiers/resolver protocol, info.json profile, tile declarations, size grammar and quality aliases | Retire protocol surface; preserve source lookup through host source adapters and useful image operations above | `.3` |
| TwicPics aliases, arithmetic expressions, vendor defaults and ordered command grammar | Retire protocol surface | `.3` |
| Imgproxy aliases, compound resize syntax, implicit units, source suffix formats, truncated/salted signature variants, ignored compatibility options | Retire protocol surface; retain corresponding useful capabilities through native options | `.12` |
| Generic dialect lifecycle, declarative base, renderer behavior and root Plan execution framework | Remove after consumers and regression coverage move; relocate still-used value types by ownership | `.2`, `.3`, `.12` |
| NeutralResolver continuations, SourceShape/State geometry synchronization, separate pipeline drivers | Replace with one native executor, retaining decode planning, orientation, and lazy materialization | `.11` |
| Protocol demo routes/controls, conformance tooling, fixtures, package/docs/CI references | Migrate native controls alongside ports; retain selected test-only reference fixtures and retire orphan tooling | `.3`, `.12`, `.13` |
| Cross-cutting regressions and final capability audit | Check this inventory against native wire coverage and run the complete library/Fiddle gates | `.14` |

Shared host configuration is retained: source/cache adapters,
`max_body_bytes`, `max_input_pixels`, result width/height/pixel limits,
telemetry prefix, automatic format preferences, output capabilities, CORS,
debug-header permission, and storage vary inputs. Source-adapter controls
(including HTTP bounds and S3 credentials/providers) retain their own
validation boundaries. Removing a dialect does not remove those controls.

Core output defaults and configuration also survive: auto-orientation,
metadata/copyright/profile/HDR policy, quality/per-format quality, smart-crop
face detection, all autoquality targets/bounds/errors/iteration and
resolution limits, and each encoder's options. Dialect-specific default
overlays are unnecessary once there is one API. Tasks `.2`, `.5`, `.7`,
and `.8` own these settings according to the capability table.

## Native semantics

The fixed stage order is rotate, flip, trim, source crop, resize/result
crop, effects, canvas, padding, background. Within effects the order is
blur, sharpen, pixelate, gray, bitonal, monochrome, duotone, brightness,
contrast, saturation, colorize, gradient. Units are explicit and `then`
groups are ordered. Rotate accepts arbitrary angles; `flip=h`, `flip=v`, and
`flip=hv` reflect horizontally, vertically, or both after rotation.
For example, `/w=500/then/trim=fff/src/image.jpg` deliberately trims the
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
frame. The request-wide `orient` value also applies to BlurHash. A default
preset can set `orient=none`; an explicit URL value overrides that preset.

Crop and region percentages use their operation's input dimensions, after
rotation, flip, and trim. Trimming a 1000px-wide input to 800px and then
applying `crop=50pct,100pct` requests 400px in width. Decode shrink-on-load
preserves these source-pixel coordinates. Region coordinates are
relative to the trimmed image, with no hidden original-image offset.
Crop and region widths and heights must be positive; invalid sizes fail
during request parsing before source resolution or cache access.

Each `then` group receives the previous group's complete result, including
canvas, padding, and background. Group parameters do not carry forward:
guide, rotation, DPR, and effects must be stated again to apply again.
EXIF is not reapplied. Internal orientation/color/materialization state may
survive a group boundary when doing so is observably equivalent. Decode
happens once, and only the first group may inform shrink-on-load.
BlurHash's terminal reduction contributes a decode hint only for a single
group, sized against its source crop when present so the crop retains enough
detail for the terminal's working frame. Multi-group requests preserve the first
group's input scale unless that group explicitly resizes it.

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

Use the July design's logical-unit model. DPR scales output targets and
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
can scale padding without resizing the source. These options reset at `then`.

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
until a background is requested. Canvas and offset options reset at `then`.

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
Detection and smart guides do not accept anchor offsets. Guides reset at `then`.

Mount options retain `detector: :default | nil | module` and
`detector_required: boolean`. Strict mode checks the requested explicit
detection classes before source resolution or cache access and returns 422
when unavailable. Face-assisted attention remains optional. Missing, empty,
or failed optional detection falls back to attention cropping.

Representation identity includes the detector identities relevant to every
group, including face models used by `smart-face`. Both storage keys and
ETags change when a relevant model changes; unrelated model changes leave
them stable. See [content-aware cropping](content-aware-gravity.md) for host
configuration, weighting, and warmup.

### Sources

All source forms use the same configured source adapters. `src/<source>`
percent-decodes its tail once; `src64/<source>` decodes unpadded base64url.
After this outer decoding:

- A relative path selects the `:path` adapter. Its path segments are not
  percent-decoded again.
- An HTTP(S) URL selects the `:http` or `:https` adapter. Its path components
  are decoded once as URL components and encoded by the adapter when fetching.
  The query stays an opaque encoded string. Userinfo, fragments, malformed
  escapes, and ports outside `1..65535` are rejected.
- `s3://bucket/key?revision` selects the `:s3` adapter with bucket, object key,
  and optional immutable revision. Key and revision are percent-decoded once.
  The entire query is the revision value; it is not a `versionId=` parameter.
  Empty keys, userinfo, fragments, and ports are rejected.

For example, an HTTP source whose filename contains `#` is
`https://images.example/cat%23one.jpg`. Its `src` spelling includes
`cat%2523one.jpg`, preserving the source URL's own escape through the outer
decoding layer. `src64` avoids this extra layer.

Configure custom schemes with
`source_schemes: %{"asset" => {MyApp.AssetSource, options}}`. The module implements
`ImagePipe.Native.SourceScheme`. Its
`translate(source, options)` callback receives the decoded source string and
returns `{:ok, plan_source}` using `ImagePipe.Plan.Source.Path`, `.URL`,
`.Object`, or `.Reference`. It may return `{:error, reason}` to reject the
source. Failures produce a fixed client error without exposing callback
details. Scheme names must be lowercase URI schemes; built-in `http`,
`https`, and `s3` cannot be replaced. Source adapters remain responsible for
filesystem confinement, allowed origins, redirect and body limits, and object
credentials.

### Source concealment

Use `enc/<token>` as an alternative to `src` and `src64`. The token is
unpadded base64url of a version byte (`1`), a 12-byte random nonce,
ciphertext, and a 16-byte authentication tag. Encrypt the UTF-8 source
string with AES-256-GCM and associated data `image-pipe:source:v1`.
Use the OTP AEAD primitive and the standard AES-256-GCM parameters, rather
than implementing a cipher or padding scheme.
See [OTP crypto](https://www.erlang.org/doc/apps/crypto/crypto.html#crypto_one_time_aead/7)
and [RFC 5116 section 5.2](https://www.rfc-editor.org/rfc/rfc5116.html#section-5.2).

Encryption keys are a separate ordered list of 32-byte keys: encrypt with
the first, authenticate/decrypt against the configured list during rotation.
Set `source_encryption_keys: [key, previous_key]` using raw binary keys;
signing `keys` use hex-encoded strings. An empty encryption list disables
concealment. Encryption keys must differ from the signing keys.
The helper generates a fresh nonce; callers do not supply one. Configure
signing keys whenever encryption is enabled, and verify the full native
request signature before decrypting. This binds processing options and
expiry as well as the source token. Reject wrong token lengths/versions,
authentication failures, and invalid UTF-8 through the same external 404
response, before source resolution/fetch or cache access. Check the full
16-byte tag length before calling OTP. Do not emit plaintext, token, or key
material in diagnostics or telemetry.

After decryption, use ordinary native source validation and identity.
Fresh encryptions of the same source and transform share storage/ETag
identity. The public helper accepts validated mount configuration and returns
only the token:

```elixir
opts = ImagePipe.Plug.init(
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}],
  keys: [signing_key_hex],
  source_encryption_keys: [encryption_key]
)

{:ok, token} = ImagePipe.Native.encrypt_source("photos/cat.jpg", opts)
path = "/w=400/enc/" <> token
signature = ImagePipe.Native.Signature.sign(path, opts)
url = "/images/sig=" <> signature <> path
```

The `/images` mount prefix is outside the signed path. The helper generates
a fresh nonce on every call and returns a tagged error for invalid source
text or disabled encryption. Keep both key sets on the host; clients receive
the completed signed URL.

### Pixel effects

Effects work with or without geometry, and run after resize in the fixed
order listed above. Each group starts with its effects disabled. Use `then`
to change their relative order: `contrast=2/then/brightness=30` adjusts
brightness after contrast, while `contrast=2/brightness=30` applies
brightness first.

| Option | Values and defaults | Example |
| --- | --- | --- |
| `blur`, `sharpen` | Non-negative sigma; 0 disables the effect | `sharpen=1.5` |
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

Blur/sharpen sigma and pixelate block size are physical effect parameters,
unaffected by DPR. Pixelate aligns its blocks with the current display axes.
Gradient direction also uses the current display frame, after resizing:
`down` (default) is 0°, `left` is 90°, `up` is 180°, and `right` is 270°.
Signed decimal angles wrap modulo 360. Start and stop are fractions from
0 to 1, defaulting to 0 and 1; reversing them reverses the ramp, and equal
values produce a hard step. Gradient preserves source alpha. Colorize
produces an opaque result unless `keep-alpha` preserves the source alpha;
zero opacity skips the operation and preserves the source unchanged.

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

`profile=strip` converts to the standard working color space and omits the
source ICC profile. `profile=preserve` exports back to the source profile
and retains it. `profile=srgb`, `profile=display-p3`, and `profile=adobe-rgb`
convert to a shipped target profile and embed its bytes. Profile handling
is independent of `meta`: stripping optional metadata preserves a requested
output profile. The default is `strip`; host `strip_color_profile: false`
selects source-profile preservation. Input ICC conditioning happens before
transforms so operations work on interpreted colors.

`hdr=preserve` retains a high-bit-depth working space when the selected
output format supports it. `hdr=tonemap` selects the standard working
space and is the default; host `preserve_hdr: true` changes that default.
JPEG falls back to standard output even under `hdr=preserve`. Named profile
conversion produces 8-bit output and cannot be combined with effective HDR
preservation; use `hdr=tonemap` with a named target. Conflicting URL and host
settings fail before source or cache access.

All three policies are request-scoped and enter effective output identity.
They reject on BlurHash URLs; configured image policies do not change
BlurHash's fixed pixel space or text response.

### Image quality and encoders

`q=80` sets one explicit quality from 1 to 100. `format-q=avif:60,webp:70`
sets per-format qualities, using the same format names as `format`. Explicit
`q` wins over a matching `format-q`. Duplicate formats are invalid. Host
`quality` defaults to 80; `format_quality` defaults to WebP 79, AVIF 63, and
JPEG XL 77. Sparse host and URL format maps preserve other configured formats.
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
JPEG XL uses its native distance encoder for Butteraugli; other supported
formats use the existing iterative search. Large-image SSIMULACRA2 searches
retain crop scoring and its content-dependent correction.

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

Host controls retain `autoquality_method`, `autoquality_target`,
`autoquality_allowed_error`, global `autoquality_min_quality` and
`autoquality_max_quality`, per-format `autoquality_format_min_quality` and
`autoquality_format_max_quality`, `autoquality_max_resolution`, and
`autoquality_max_iterations`. The iteration budget defaults to 6 and bounds
the encoder search, including native JXL attempts to meet a byte budget.
Native JXL Butteraugli without a byte budget uses a single encode. Active
search settings participate in storage and ETag identity; changing an unused
iteration budget leaves identity stable.

Each encoder option is a comma-separated list of bare boolean flags and
`name:value` pairs. Use `flag:false` to override a host-enabled flag. Sparse
URL fields override the corresponding host option struct. Unknown or repeated
fields are invalid, as are options for another explicitly selected format.
Under negotiation, per-format options are conditionally active.

| Native key | Fields |
| --- | --- |
| `jpeg-options` | `progressive`, `subsample:auto\|on\|off`, `trellis-quant`, `overshoot-deringing`, `optimize-scans`, `quant-table:0..8` |
| `png-options` | `interlace`, `palette`, `bitdepth:1\|2\|4\|8\|16`, `filter:none\|sub\|up\|avg\|paeth\|all` |
| `webp-options` | `lossless`, `near-lossless`, `smart-subsample`, `preset:default\|photo\|picture\|drawing\|icon\|text`, `effort:0..6` |
| `avif-options` | `subsample:auto\|on\|off`, `effort:0..9` |
| `jxl-options` | `effort:1..9` |

For example, `format=jpeg/jpeg-options=progressive,quant-table:3` requests a
progressive JPEG. Host keys `jpeg_options`, `png_options`, `webp_options`,
`avif_options`, and `jxl_options` accept their corresponding
`ImagePipe.Plan.Output.*Options` structs. JPEG's host struct calls its
progressive flag `interlace`.

Quality, search, budgets, and encoder URL options apply only to image output.
BlurHash rejects these URL options and ignores configured image output policy.

### Presets and terminals

Presets expand before validation and canonicalization. Precedence is default
preset, named presets in listed order, then explicit URL values. Resolve
nested named presets at initialization and reject cycles/unknown names.
Single-group presets contribute to the first group. A preset containing
`then` supplies the complete group sequence and cannot combine with explicit
URL group options or another multi-group preset; request-scoped options may
still override it. Presets cannot supply a source or signature. Their names
do not participate in representation identity. Task `.2` owns completion.

`output=image` uses negotiated or explicit format. `output=blurhash` retains
its fixed text response. `output=info` describes the source with JSON fields
`format`, `mime_type`, display `width`/`height`, EXIF `orientation`, and
optional byte `size`. It rejects all group options, explicit `orient` values, and
image output options, including metadata, profile, and HDR controls,
uses fixed `application/json`, and does not set `Vary: Accept`. Info retains
source safety limits and can use header inspection without transforming or
encoding pixels. Format names use the library's canonical vocabulary, including
`heif`, `jpeg_xl`, and `jpeg2000`. Host image encoding
policies do not alter info. Preset expansion happens before applicability
validation, so inherited image options also reject. LQIP is
outside this migration's scope.

### Request delivery controls

`filename=photo` supplies a response filename stem. `attachment` (or
`attachment=true`) selects download disposition; `attachment=false` selects
inline disposition and overrides an inherited preset value. Both apply to image,
BlurHash, and info responses. ImagePipe adds the actual response's extension,
including `.txt` for BlurHash and `.json` for info. Filename and attachment
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
the current time; equality remains valid. Expired requests return `404` before
source fetch or cache access. Hosts may configure `clock: fn -> unix_seconds end`
for a controlled time source; the default is `System.os_time(:second)`.

## Architecture and verification constraints

The public Plug should call native configuration/parsing, source resolution,
representation identity, execution, and delivery directly. Parsing produces
a concrete request with groups and output policy. The executor owns fixed
ordering and runtime geometry; `Source`, `Output`, and `Response` own their
respective data and effects. Module moves should follow actual ownership,
not preserve a generic root Plan solely to satisfy old boundaries.

Keep these invariants while changing the structure:

- Signature/expiry/static validation precede source fetch and cache access.
- Conditional responses can complete before fetch, decode, encode, or cache
  reads when a trustworthy source identity is available.
- Cachebuster and vary inputs affect storage identity; they do not change
  a byte-identical representation's ETag. Safety limits gate generation.
- Only successful encoded results are cached; cache failures fail open.
- EXIF, color/HDR, shrink-on-load, and per-operation materialization retain
  pixel tests. Sequential safety is proved with genuinely streamed input.
- Delivery owns stream/resource cleanup on success and failure.
- Telemetry changes update both the default Logger and trace Capture.

Before deleting an old entry point, migrate the shared assertions from its
wire tests. Native coverage must exercise real requests and decoded pixels,
not just parser structs. Selected imgproxy fixtures are reference evidence
for intentionally shared behavior; native semantics govern disagreements.

Keep AGENTS.md, enforcement, and architecture tests aligned with each
implementation step. The capability inventory and native semantics here
take precedence over the July probe design where they differ.
