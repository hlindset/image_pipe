# Animation frame limits and aggregate pixel accounting

Beads `image_plug-0t4` (GitHub #45). Coordinates with `image_plug-3b8` (#123,
multi-page and animation handling). Draft for agreement; nothing here is
implemented.

## Summary

Every accepted multi-frame family already decodes only its first frame or page,
and every output is a single frame. `max_input_pixels` is therefore a per-frame
limit today, and that is safe. The gap is the libvips header open, not frame
decode. libvips walks the whole container to count frames before ImagePipe sees
`n-pages`, and for animated WebP that walk is quadratic. A crafted 9.4 MB WebP
(inside the default 10 MB `max_body_bytes`) with 180,000 one-pixel frames costs
about 22 s of CPU in one header open. A 100,000-frame request took 19.6 s
end to end with default limits and returned `200`.

Proposal: keep first-frame flattening as the documented default. Add a
host-level `max_input_frames` gate that rejects with `413` before any libvips
open for animated WebP, and before the sequential re-open for other families.
Keep `max_input_pixels` per frame until sequence processing (3b8) exists.

## Current behavior

Evidence comes from code reading plus scratch experiments against the
workspace build (libvips 8.18.6 on this Mac). The CI and server images use
8.18.7 built from source. Test sources were generated with libvips, `heif-enc`
1.23.4, and `magick`, and one APNG and one crafted WebP were built by hand.

### Accepted families that can carry several frames

`ImagePipe.Decode` rejects `:gif`, `:bmp`, `:ico`, and `:svg` by magic bytes.
It trusts detection for JPEG, PNG, WebP, TIFF, JPEG 2000, and JPEG XL. It
resolves AVIF/HEIF through `heif-compression`, and sends `:unknown` to libvips'
own loader sniffing, then classifies the loader name.

| Source | Detected | Loader | `n-pages` on header open | Today |
| --- | --- | --- | --- | --- |
| Animated WebP | `:webp` | webpload | frame count | frame 0, accepted |
| Multi-page TIFF | `:tiff` | tiffload | page count | page 0, accepted; pages may differ in size |
| HEIC/AVIF image collection | `:heif`/`:avif` | heifload | top-level item count | page 0, accepted; libheif rejects over 256 `iloc` items (`415`) |
| HEIF image sequence (`msf1`, `heif-enc -S`) | `:heif` | heifload | 1 | still item only; sequence track is invisible |
| AVIF image sequence (`avis`) | `:unknown` | **magickload** on this host | 4 | ImageMagick parses it (383 ms), then rejected as unsupported `:unknown` (`415`) |
| Animated JPEG XL | `:jpeg_xl` | jxlload | frame count | frame 0, accepted |
| APNG | `:png` | pngload | absent | default image only; libvips ignores `acTL`/`fdAT` |
| GIF | `:gif` | none (gifload if admitted) | frame count | rejected before libvips (`415`); see GIF input below |
| PDF | `:unknown` | pdfload | page count | parsed (12 ms), then rejected (`415`) |

JPEG 2000 is single-image in libvips. MPO (multi-picture JPEG) was not tested.

### What decode passes to libvips

Decode never passes `n`, `page`, or `pages`. Both opens use the loader default
of one page from page 0: the random-access header open and the sequential
re-open with shrink-on-load `shrink`/`scale`. Streaming decode (`Decode.Streaming`)
accepts only JPEG and PNG, so animated WebP/JXL/HEIF/TIFF always arrive as a
buffer or file. Opening the same sources with `pages: :all` returns
`64×144` strips with `page-height=48`. ImagePipe's opens return `64×48`.
The existing regression test `shrink_on_load_test.exs:297` already pins this for
animated WebP: `max_input_pixels` is set between one frame's pixels and two
frames' pixels.

The first-frame image still carries `n-pages`, `delay`, and `loop` metadata, but
not `page-height`. No encoder writes animation from it. Every accepted
multi-frame source above, encoded to WebP and PNG, produced a single-frame
`32×24` output without `n-pages`.

Among output formats, only libvips `webpsave` writes animation (it needs
`page-height`). `heifsave` writes a multi-image collection, not an animation.
PNG output is not APNG, and JPEG is single-frame. Animated output would
realistically be WebP only (GIF output is `image_plug-ysj`).

### Where the existing limits fire

- `max_body_bytes` is enforced while fetching (`Source.WrappedStream` raises
  `:body_too_large`), before decode.
- `max_input_pixels` is checked twice: on the 32 KiB peek for PNG IHDR, JPEG
  SOF, and WebP VP8X/VP8/VP8L (for animated WebP, the VP8X canvas), and on the
  libvips header open's page-0 dimensions. Both are per-frame values. Failures
  are `{:input_limit, _}` → `413`.
- Result limits clamp by uniform downscale after transforms. They are not a
  frame concern, and imgproxy `mrd` stays out of this design.

### Cost of counting frames

`n-pages` is available after the header open for every family that has it, as
one `header_value` lookup. The header open itself pays for the count, and
Decode opens twice. Best-of-five header opens with 16×16 frames:

| Frames | WebP | TIFF | JPEG XL | HEIC |
| --- | --- | --- | --- | --- |
| 1 | 0.14 ms | 0.14 ms | 0.29 ms | 0.17 ms |
| 100 | 0.17 ms | 0.95 ms | 0.47 ms | 0.72 ms (120 items) |
| 1,000 | 0.67 ms | 8.0 ms | 1.9 ms | over libheif limit |
| 10,000 | 69 ms | 63 ms (10 MB) | 17 ms | — |
| 40,000 | — | — | 72 ms | — |

TIFF and JPEG XL grow linearly and are bounded by `max_body_bytes`. HEIF is
capped by libheif. WebP grows quadratically. With 52 bytes per frame (one
shared 1×1 VP8L frame in each `ANMF` chunk):

| Frames | Bytes | Header open |
| --- | --- | --- |
| 1,000 | 52 KB | 2 ms |
| 10,000 | 520 KB | 103 ms |
| 40,000 | 2.1 MB | 1.2 s |
| 100,000 | 5.2 MB | 6.6 s |
| 180,000 | 9.4 MB | 21.8 s |

GIF is rejected today, but it was measured the same way for the GIF decision
below: 23 bytes per frame (a 1×1 frame with a graphic control extension), so
10 MB holds about 430,000 frames. libvips' GIF loader counts them linearly:

| Frames | Bytes | Header open | Sequential open |
| --- | --- | --- | --- |
| 1,000 | 23 KB | 3 ms | <1 ms |
| 100,000 | 2.3 MB | 5 ms | 4 ms |
| 400,000 | 9.2 MB | 39 ms | 37 ms |

`ImagePipe.run` on the 100,000-frame file (`resize: [width: 1]`, PNG, default
config) returned `:ok` in 19.6 s. That is about three header-open costs:
Decode's two opens plus, presumably, the loader re-reading the container during
the pixel load. The cause appears to be libvips iterating frames through
libwebp's demux, whose frame lookup walks a linked list. That is an upstream
cost, and it happens before ImagePipe can look at `n-pages`. A processing pool
deadline can abandon such a request, but it can't preempt a libvips call
that is already running.

## Options

### Family policy

1. **Flatten to the first frame (status quo, documented).** No semantic change
   for any source. Zero cost for single-frame requests.
2. **Reject multi-frame sources by default.** This breaks every animated WebP,
   multi-page TIFF, and HEIF collection that works today, and the page-0 output
   is already bounded, so there is little safety gain.
3. **Process sequences.** Only WebP-to-WebP is realistic. It needs 3b8's frame
   model, timing and disposal semantics, and per-group transform rules. It is
   not a prerequisite for closing the DoS.

Recommendation: 1 now, with 3 left to 3b8. Frame selection (`page=N`) also
belongs to 3b8.

Pages and animation frames differ, and only one of them matters here. libvips
reports both as `n-pages`: a multi-page TIFF or a HEIF collection has pages
with no timing, and an animated WebP, JPEG XL, or GIF has frames with `delay`
and `loop` metadata. imgproxy treats a source as animated only when `delay`,
`loop`, and `n-pages > 1` are all present (`vips_image_is_animated` in
`vips/vips.c`), so a multi-page TIFF is never animated there. ImagePipe should
draw the same line when 3b8 designs sequence output: only timed frames can
become an animation, and pages are selectable stills. The frame gate in this
note ignores the distinction. It counts every `n-pages` entry, because the cost
it bounds is the container walk, and libvips walks pages and frames alike.

### GIF input

GIF is rejected by the magic-byte gate. No recorded decision explains why.
Before #170 (June 2026), GIF was never in `Format.source_formats/0`, and the
loader classifier treated `gifload` as unsupported `:unknown`. The #170 spec
added the named `:gif` reject so errors say which family was refused. It left
support explicitly out of scope ("gif/bmp/ico stay rejected; detection just
names them"). `image_plug-ysj` covers GIF *output* only.

Under the first-frame policy, GIF input fits like animated WebP and JPEG XL.
Frame 0 is decoded and served as AVIF, WebP, JPEG, or PNG through the normal
negotiation, with no animated output needed. It is also the common real-world
case: a GIF avatar or thumbnail requested as a modern static format.

What enabling it takes:

- Move `:gif` from `@reject_families` into `Format.source_formats/0` and
  `source_only_formats/0`, add `"image/gif"` to the MIME table, add a
  `gifload` clause to `Decode.SourceFormat.classify_loader/2`, and add `:gif` to
  Decode's authoritative formats.
- Count GIF frames through `n-pages` with the other libvips-counted families.
  The gate needs no GIF-specific pre-count, because the header walk is linear
  (about 39 ms per open at the 10 MB body limit, see above).
- Check the pixel limit against the logical screen size, which is the canvas
  libvips reports for page 0. A GIF's logical screen size, like a VP8X canvas,
  can exceed its frames' own sizes, so the check stays conservative. The peek
  could read the screen descriptor (bytes 6–9) for an early reject; that is
  optional, since the header open is cheap.
- Decide shrink-on-load: libvips' GIF loader has no shrink option, so GIF
  decodes at full size like PNG.
- Update `Format` docs, the Fiddle only if it lists source formats, and
  `docs/telemetry.md`, which uses `:gif` as the example rejected family.

Unmeasured: rendering a late frame composites every earlier one. That doesn't
matter while only frame 0 is decoded, but it bounds any frame-selection option
in 3b8.

### Frame-count limit

Add a host option `max_input_frames` (positive integer) to
`ImagePipe.Processing.Config`. It flows into the server's `[processing]` TOML
table through the existing schema projection. A source whose container
declares more frames or pages than the limit is rejected, even though only
frame 0 would be decoded, because counting the frames is the cost. Truncation
isn't possible: libvips reads the whole container regardless.

How to count:

- **Animated WebP:** use a pure Elixir RIFF chunk walk that counts `ANMF`
  chunks and stops at `limit + 1`. It runs only when the peek shows VP8X with
  the animation flag (`0x02`), before any libvips open. The input is always
  `{:buffer, _}` or `{:path, _}` for WebP; a path needs a file read that stays
  bounded by `max_body_bytes`. The walk is linear, reads 8-byte chunk headers,
  and never touches frame payloads. A plain lossy/lossless WebP or a
  non-animated VP8X WebP skips it.
- **TIFF, JPEG XL, HEIF/AVIF (and GIF, if admitted):** read `n-pages` from the
  header image Decode already opens, and check it before the sequential
  re-open. The header open is linear or capped for these families, and the gate
  saves the second open and all pixel work.
- **APNG:** don't count it. libvips decodes the default image and never walks
  the frames, so extra frames cost only bytes, which `max_body_bytes` already
  bounds.

With a default of 1,000 frames, the worst WebP header open is about 2 ms. At
10,000 frames it is about 100 ms per open.

`max_input_frames` is a reject gate on frames *declared*, not a cap on frames
*processed*. imgproxy's `IMGPROXY_MAX_ANIMATION_FRAMES` (default 1) is the
second kind. imgproxy loads `min(n-pages, max)` frames, drops the rest, and
never rejects on frame count (`processing/processing.go`,
`reloadImageForProcessing`). A processing cap can't bound the header cost
measured above, because libvips counts every frame before any cap applies. If
3b8 adds sequence processing, its frames-processed cap is a separate setting.
The two must not share a name or a default.

### Pixel accounting

- **Flatten mode (all of today):** `max_input_pixels` applies to one frame: the
  WebP canvas or page 0 of TIFF/HEIF/JXL. This matches the pixels actually
  decoded. Aggregate accounting (width × height × frames) would reject
  legitimate animations to protect work that never happens.
- **When 3b8 adds sequence processing or page selection:** check the frames
  actually decoded: frame pixels × frames processed against `max_input_pixels`
  (imgproxy likewise uses `min(pages, max_frames)`). A selected TIFF page is
  checked against that page's own dimensions, since pages can differ. The
  mixed fixture below has a 16×16 page 0 and a 4000×4000 page 1.

A separate per-frame limit (imgproxy's `MAX_ANIMATION_FRAME_RESOLUTION`) only
becomes meaningful with sequences, so it waits for 3b8.

### Host controls and request options

- Host: `max_input_frames` only. It is a safety gate, so it stays out of cache
  key and ETag material, like the other generation limits. A cached success
  may still be served under a stricter limit.
- Request: none. Flattening is deterministic from source bytes, which source
  identity already covers. A future frame-selection or animation-output option
  from 3b8 changes bytes and belongs in `Plan.Spec` identity.

### Where enforcement happens

The order inside `Decode.decode/4`:

1. Peek, detect, family gate (existing).
2. Peek pixel check (existing).
3. **New:** WebP animation pre-count when VP8X has the animation flag. On
   failure, no libvips open happens.
4. Random-access header open (existing).
5. **New:** `n-pages` against `max_input_frames`, for families that report it.
6. Stored-dimension pixel check (existing), then the sequential re-open.

Both new gates run before source-format-dependent planning, the second open,
transforms, encode, and output cache writes. On the common single-frame path
they add one pattern match on the peek and one `header_value` lookup. Per the
speed-first rule, this still gets a before/after latency measurement of
single-frame JPEG and WebP requests (`bench/materialization_latency.py
--preload` style) before merging.

### Errors, status, and telemetry

- The error is `{:input_limit, {:too_many_input_frames, count, max}}`. The
  existing classifier maps it to `413` and the message "source image is too
  large". It's deterministic: the count comes from the container, not timing.
  For the WebP pre-count, the reported count is `max + 1` because the walk
  stops early; the error means "exceeds max".
- `Error.tag/1` reduces both pixel and frame failures to `:input_limit`. Add
  a `limit: :pixels | :frames` key to the `[:source, :fetch_decode]` stop
  metadata so operators can tell them apart. Add `source_frames` (integer,
  non-sensitive) to successful stops.
- Keep the telemetry surfaces in sync, per AGENTS.md: render the new keys in
  `Telemetry.Logger`, add them to `Capture`'s `@safe_keys`, cover both in
  tests, and update `docs/telemetry.md`. The span stays the same.
- Update `docs/operational_notes.md`, which currently says "Animation frame
  limits are not implemented", plus `docs/configuration.md` and the server
  configuration reference.

## Fixtures and tests

`SourceInventory` has no multi-frame sources, and the only multi-frame test
input is the in-test animated WebP in `shrink_on_load_test.exs`. Add a small
generated set (distinct frame colors, so a pixel probe proves which frame was
decoded), produced by `mix fixtures.gen_sources` and recorded in
`SourceInventory`:

- `anim_3.webp`, `anim_3.jxl`: 3 frames.
- `multi_3.tif`: 3 equal pages. `mixed_pages.tif`: 16×16 page 0 and a large
  page 1, generated in-test rather than committed if size matters.
- `multi_3.heic`, `multi_3.avif`: 3-item collections. `seq.heics`: a sequence
  via `heif-enc -S`, if the generator may depend on it.
- `anim_2.apng`: built by hand (chunk assembly; neither libvips nor this
  machine's `magick` writes APNG without ffmpeg).
- If GIF is admitted: `anim_3.gif` (libvips writes GIF through cgif) and a
  crafted many-frame GIF generated in-test at `limit + 1` frames (23 bytes per
  frame).
- A crafted `ANMF`-repeat WebP generated in-test at `limit + 1` frames (52 bytes
  per frame), never committed.

Tests:

- Wire (`ImagePipe.Plug.call/2`): each family returns `200`, a single-frame
  output, and frame 0's pixel color. Include an animated WebP with WebP output
  to prove no animation leaks.
- Frame limit: `max_input_frames: 2` against each 3-frame fixture returns `413`
  with no transform or encode telemetry and no output cache write. The WebP
  pre-count rejects before any libvips open, proven with a recording
  `:buffer_loader`/`:image_open_module` (see
  `test/support/image_pipe/test/header_dimensions/recording_open.ex`).
- Pixel limit: `mixed_pages.tif` passes with `max_input_pixels` between page
  0's and page 1's pixel counts. Keep the existing WebP per-frame test.
- Body limit: a multi-frame source over `max_body_bytes` fails as a source
  error before decode.
- Cache: a success under a high frame limit is served from cache under a lower
  one, so the limit is not in the key.
- Property: the RIFF `ANMF` counter agrees with libvips `n-pages` across
  generated chunk layouts (frame counts, padding, unknown chunks, truncation),
  and never reads past a declared chunk size.
- Telemetry: `limit` and `source_frames` metadata, asserted under a private
  `telemetry_prefix`.

## Open decisions

1. **Default family policy.** Recommendation: flatten to frame 0 for every
   accepted family (today's behavior) and document it. Leave sequence output to
   3b8.
2. **`max_input_frames` default.** Recommendation: 1,000. That costs about 2 ms
   per WebP header open and covers normal animated WebP/JXL. Hosts serving long
   animations can raise it knowing the WebP cost is quadratic.
3. **Pixel accounting.** Recommendation: per frame while flattening. Frames
   processed × frame pixels against `max_input_pixels` once 3b8 decodes more
   than one frame. No separate per-frame knob yet.
4. **APNG.** Recommendation: don't count APNG frames. Document that ImagePipe
   decodes the default image, as libvips does.
5. **Request option.** Recommendation: none in this issue. Frame and page
   selection is 3b8's, as identity-bearing `Plan.Spec` material.
6. **GIF input (`image_plug-qfe`).** Recommendation: admit GIF as a source, flattened to frame 0
   and counted by `max_input_frames` like the other families. Ship it as its
   own change after the frame gate, so GIF never arrives without the gate.
   Frame-count cost is linear (39 ms per open at 10 MB). Nothing recorded
   argues against it, and it serves the common "static modern format from a
   GIF" request without animated output.
7. **`:unknown` loader fallback (outside this issue's scope, found here).**
   Undetected sources reach libvips' generic loader sniffing. On a
   Homebrew-style libvips, that includes untrusted loaders: ImageMagick parsed
   an AVIF sequence, and poppler parsed a PDF, before ImagePipe rejected them.
   The server image builds libvips without magick or poppler, which narrows
   this but doesn't remove it for library hosts. imgproxy's open-source version
   never sniffs: `Image.Load` in `vips/vips.go` calls the loader for the
   detected type and errors otherwise. Filed as `image_plug-8ly` (P1): open
   with the detected family's loader, reject `:unknown` before libvips, and
   recognize the `avis` brand.
8. **Upstream report.** Recommendation: report the quadratic animated-WebP
   header cost to libvips/libwebp with the crafted-file reproduction, but keep
   the ImagePipe pre-count regardless.
