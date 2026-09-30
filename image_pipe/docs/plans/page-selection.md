# Page and frame selection

Beads `image_plug-7vl`. Draft for agreement; nothing here is implemented.

## Summary

Add a request option `page=N` that decodes page or frame N of a multi-page or
animated source. The output is still a single image. Without the option,
nothing changes: the source's default image is decoded, as today.

The option passes libvips' `page` load option to both decode opens. The
request fails with `422` when N is out of range, and the pixel limit applies
to what selecting that page actually decodes. Requests without `page` do no
extra work.

## Findings

Measured on libvips 8.18.6 with the test sources from
`ImagePipe.Test.MultiFrameSources` and a 100-frame 400×267 photo animation.

**Every accepted multi-frame loader supports `page`.** WebP, GIF, JPEG XL,
TIFF, and HEIF/AVIF all take it. The header open still reports `n-pages` when
a page is selected, and an out-of-range page fails in libvips with "bad page
number". WebP's `scale` shrink-on-load works together with `page`.

**The default isn't always page 0.** With neither `page` nor `n` set,
libvips' HEIF loader decodes the file's primary image. An explicit `page: 0`
decodes the first image in container order. With a collection whose `pitm`
box was patched so that the third image is primary, the default decode
returned the third image and `page: 0` returned the first. APNG likewise
decodes its default image, and libvips never sees its other frames. So "no
option" and `page=0` are different requests for HEIF.

Current docs say multi-frame sources decode "their first frame or page". For
HEIF that is the primary image; this change corrects the wording.

**Selecting a later frame costs more for WebP and GIF.** Their frames are
composited onto earlier ones, so frame N decodes every frame before it. Render
time to a 200 px PNG:

| Source | Default | Page 0 | Page 50 | Page 99 |
| --- | --- | --- | --- | --- |
| WebP | 7.1 ms | 7.1 ms | 48 ms | 88 ms |
| GIF | 7.9 ms | 7.5 ms | 36 ms | 63 ms |
| JPEG XL | 8.5 ms | 8.2 ms | 8.4 ms | 8.7 ms |
| TIFF | 8.4 ms | 6.2 ms | 5.8 ms | 5.6 ms |

The JPEG XL sample was flat, but it was encoded without frame blending, so it
doesn't prove the general case.

**Pages can differ in size.** TIFF and HEIF pages carry their own dimensions
and EXIF orientation. The header open with `page: N` reports page N's values.

## Design

**Spelling.** `page=N` is a request-scope option, like `orient`: 0-based, in
container order. The builder takes it the same way (`ImagePipe.URL.new(page:
2)`). It is canonical plan material, so it's part of the cache key and ETag.
Absent and `page=0` stay distinct, and aren't canonicalized to one another.

**Decode.**

- `Plan.Spec` gains `page: non_neg_integer() | nil`.
- Decode passes `page` to the random-access header open, and
  `DecodePlanner.open_options_for/5` adds it to the sequential re-open.
- Without it, neither open changes.

**Range check.** After the header open, `page >= n-pages` fails with `422`
before the second open. A still image has one page, so `page=0` succeeds and
anything higher fails. APNG counts as one page, since its frames aren't
visible to libvips. The error is a request-versus-source mismatch; its tag
belongs with the other `422` transform-domain reasons, and the exact name
gets settled in implementation.

**Limits.**

- `max_input_frames` is unchanged. It bounds the declared count, which the
  loader walks regardless of the page.
- Paged sources (TIFF, HEIF collections): check page N's own dimensions
  against `max_input_pixels`.
- Timed frames (sources with `delay` metadata: WebP, GIF, JPEG XL): selecting
  frame N decodes up to N+1 frames, so check `(N + 1) × canvas pixels` against
  `max_input_pixels`. The default request decodes one frame, so its check
  stays as it is today.
- With the 40 MP default, frame 373 of a 400×267 animation is the last one
  allowed, which costs about 0.35 s by the table above. For a 1920×1080
  animation it's frame 18.
- JPEG XL is in the timed group to stay conservative, pending a blended
  sample.

**Info.** `output=info` gains `pages` (the declared count, 1 for a still
image). With `page=N`, `width`, `height`, and `orientation` describe page N.
`page` is allowed with every terminal, since it selects the source, not an
image option.

**Telemetry.**

- `[:source, :fetch_decode]` stop metadata gains `page` when one was
  requested; page numbers aren't sensitive.
- An out-of-range page reports `source_frames` and `page`.
- Logger rendering and the `Capture` allowlist follow AGENTS.md.

**Fiddle.** A numeric page control in the URL state.

**Speed.** Requests without `page` gain nothing: no new option is passed, and
no new header lookup runs. Check it with the same A/B as the earlier decode
changes.

## Tests

- Wire tests, one per family (WebP, GIF, JPEG XL, TIFF, AVIF):
  - `page=2` of a 3-frame source returns frame 2's colour;
  - `page=3` returns `422` after one loader open.
- A HEIF collection with a patched `pitm` (a test-support helper):
  - the default request returns the primary image;
  - `page=0` returns the first.
- A two-page TIFF with a small page 0 and a large page 1. libvips can't write
  mixed page sizes, so the test support builds it.
  - `max_input_pixels` between the two sizes allows `page=0` and rejects
    `page=1` with `413`.
- Timed-frame aggregate:
  - a WebP where `page=N` passes at `(N + 1) × canvas = max_input_pixels`;
  - and fails one frame later.
- Info reports `pages`, and the selected page's dimensions.
- Cache identity:
  - `page=1` and `page=2` get different keys;
  - absent and `page=0` get different keys.
- The grammar round-trips between the builder and the parser. Extend the
  existing property tests.

## Open decisions

1. **Spelling and base.** Recommendation: `page=N`, 0-based, in container
   order. That matches libvips and the "frame 0" wording already in the docs.
2. **Absent versus `page=0`.** Recommendation: keep them distinct. Absent means
   the source's default image (HEIF primary, APNG default, first frame
   otherwise). `page=0` means the first image in container order.
3. **Out of range.** Recommendation: `422`, checked before the decoding
   re-open. It's a valid request that doesn't fit this source, like the other
   source-dependent `422` reasons.
4. **Pixel accounting for timed frames.** Recommendation: `(N + 1) × canvas`
   against `max_input_pixels`, with paged sources checked per page. The
   alternative, per-frame only, lets a single request composite up to
   `max_input_frames` full-canvas frames.
5. **`pages` in info.** Recommendation: yes, always present. It is read from a
   header the info path already opens.
