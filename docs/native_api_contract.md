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

`orient`, `rotate`, `flip`, `w`, `h`, `fit`, `enlarge`, `crop`, `region`,
`anchor`, `focus`, `blur`, `gray`, `bitonal`, `trim`, `pad`, `bg`, `output`, `format`, `q`,
`debug`, `expires`, `preset`.

It also implements `then`, `src`, `src64`, and full-length HMAC signing with
key rotation. Presets support nested references and complete `then` pipelines.
Sources are currently paths or HTTP(S) URLs. Image and
BlurHash are implemented terminals. The broader vocabulary in the
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
group. Multi-group requests preserve the first group's input scale unless
that group explicitly resizes it.

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
identity. Tests in `.9` cover tampering, rotation, nonce generation,
signature-before-decryption, no-fetch failures, and identity equivalence.

### Effects, presets, and terminals

Keep existing effect ranges: brightness is an additive adjustment, contrast
and saturation are factors with 1 as identity. The July proposal's bounded
percentage scale does not constrain these factor controls. Validate the
concrete ranges at the URL boundary and keep native no-op canonicalization.

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
optional byte `size`. It rejects transforms and encoder options as inert,
uses fixed `application/json`, and does not set `Vary: Accept`. Info retains
source safety limits and can use header inspection without transforming or
encoding pixels. Use the library's canonical format names rather than
vendor aliases. Task `.10` owns the info contract and wire tests. LQIP is
outside this migration's scope.

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
