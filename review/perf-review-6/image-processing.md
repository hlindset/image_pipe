# Performance review 6: image processing

Scope: decode planning, input colour conditioning, transform operations,
materialization, the encoder's finalize step (flatten, colour, metadata), and
the quality search. Library paths are relative to `image_pipe/`, at `main`
6a87579. No code was changed on any branch; the two request-level comparisons
that needed a patched build used a local edit that was reverted afterwards.

## How this was measured

Request numbers come from real `ImagePipe.Plug.call/2` requests against a file
source, with no output cache and the libvips operation cache off (as
`image_pipe_server` sets it). Stage times are summed from the library's own
telemetry stop events. Each figure is the median of 7 to 11 runs. The machine
has 4 vCPUs (Xeon at 2.1 GHz) and libvips 8.18.7 built by the cloud setup hook.
That is a different CPU from review 5, so absolute numbers aren't comparable
across the two reviews; every comparison below is within this run.

Fixtures, all derived from `priv/static/images/`:

- `spin_plain.jpg`: `spinning_baseline.jpg` (6000×4000) re-saved at Q92 with its
  sRGB profile and no EXIF.
- `spin_exif.jpg`: the same with a realistic camera EXIF block (make, model,
  dates, exposure, GPS, copyright, artist, a 40 KB maker note): 41.6 KB of EXIF.
  `e_4k.jpg`, `e_iphone.jpg`, `e_40k.jpg`, `e_thumb.jpg`: 1200×800 variants
  with 4, 14, 40 and 52 KB of EXIF. None of the repository's fixtures carry
  camera EXIF; they've all been stripped.
- `var0.jpg` … `var12.jpg`: 3000×2000 copies whose sRGB profile differs only in
  four reserved header bytes, so each has a new digest but is still sRGB.
- `spin16.png`: a 4000×2667 16-bit RGB PNG of the same picture with light
  noise, so the low bits vary.
- `spin.webp`: the 6000×4000 picture as WebP Q80.
- `logo.png`: a 1200×600 crop of `cooking.png`, as a watermark.

## Status of review 5 findings

- **#1, sRGB-equivalent profiles cost a LittleCMS transform:** fixed on main
  (cy3p, PR #1022, c12f2bf). Finding 2 below is about the cost of the new
  equivalence check itself.
- **#2, padding adds alpha that a JPEG encode flattens:** fixed for explicit
  formats (PR #1047, f5ed8b1). Negotiated output keeps the transparent path by
  design; `w=800/pad=20` still spends 7.7 ms in encode against 2.8 ms with
  `format=jpeg`, for the same bytes. Not repeated.
- **#3, gradient blend in float:** fixed on main (PR #1051, 85b24e4).
- **#4, 16-bit downscale in float:** still open as m907 (P4). Not repeated.

Older open items seen again in this run and not repeated: the watermark asset
is still decoded on every request (review 3 #8), progressive blur still costs
about 150 ms at 800 px (review 2 #8), and autoquality is still dominated by the
metric (`w=2400/autoquality=80`: 4.5 s, ett1).

## Findings, ranked by payoff against risk

### 1. Stripping metadata parses the whole EXIF block in Elixir, up to 17 ms per request, to keep nothing

**Severity: Medium. New. Measured. Output unchanged. Low risk.**

With the default `strip_metadata`, `strip_metadata/2`
(`lib/image_pipe/output/encoder.ex:519`) calls `Image.minimize_metadata/2`
(`:549-550`) with `keep: []` unless the request keeps copyright. In `image`
0.72, `minimize_metadata/2` always runs `Image.exif/1` first
(`deps/image/lib/image.ex:7486`), which decodes the whole EXIF blob in Elixir,
and only then calls `remove_metadata/1`. With `keep: []` the parsed map is
thrown away.

The parse time grows with the EXIF size, and camera photos carry maker notes
of 10 to 60 KB:

| EXIF block | `Image.exif/1` |
|---|---:|
| 440 B (no maker note) | 0.01 ms |
| 4.5 KB | 0.9 ms |
| 14 KB | 3.2 ms |
| 40 KB | 13 ms |
| 52 KB | 14 ms |
| 41.6 KB (`spin_exif.jpg`) | 16–17 ms |

At request level (JPEG out), the encode span goes from 2.3 ms to 22–25 ms:

| request | no EXIF | 41.6 KB EXIF |
|---|---:|---:|
| `w=300` | 72 ms | 96 ms |
| `w=800` | 99 ms | 119 ms |

That's 20–35% of a thumbnail request, and it runs on a BEAM scheduler, not
in libvips. `Image.remove_metadata/1` alone on the same image takes 0.2 ms
and leaves exactly the same header fields; the encoded bytes are identical.

**Suggested fix:** when nothing is kept, call `Image.remove_metadata/1`
directly instead of `minimize_metadata/2`. When copyright and artist are
kept, read `exif-ifd0-Copyright` and `exif-ifd0-Artist` from the libvips
header (they're already parsed by libexif) and write them back, rather than
decoding the blob in Elixir. That would also make the date-parsing workaround
at `:541-548` (1pr7) unnecessary on the default path.

This is also an `image` gap: `minimize_metadata(image, keep: [])` needn't parse
anything. It should be filed with `-l image-upstream -s deferred`
(`image` 0.72, `lib/image.ex:7483-7497`); I didn't file beads, as asked.

**Side note, not performance (for the bug hunt):** Vix's `MutableImage`
copies with `vips_image_copy_memory`, which returns the same `VipsImage` when
the image is already in memory. So `Image.mutate/2` on a memory image edits
the original's header in place. Measured: after
`Image.minimize_metadata(mem, keep: [])`, `mem` itself had no `exif-data`. In
the encoder, `finalize/3` copies to memory and then `maybe_drop_profile/2`,
`strip_metadata/2` and `set_icc/2` mutate, so they change the delivery state's
image in place. Nothing seems to read that image afterwards today, but any
future reuse (a second encode, a retry) would see stripped metadata.

### 2. The sRGB-equivalence check costs about 20 ms, and past its 256-profile cap it runs on every call, up to 3 times per request

**Severity: Medium. New (a cost of PR #1022). Measured. Output unchanged.
Low risk.**

`SrgbProfile.equivalent?/1` (`lib/image_pipe/srgb_profile.ex:26`) checks an
unseen RGB profile with four libvips colour operations on a 4913-pixel lattice
(`check/1`, `:74`). Timed separately:

| step | time |
|---|---:|
| `icc_transform` profile → sRGB | 4.7 ms |
| `icc_import` of the lattice from built-in sRGB | **9.2 ms** |
| `icc_export` sRGB → profile | 5.3 ms |
| whole check (median of 15 unseen profiles) | 19.5 ms |
| cached lookup | 2 µs |

The answer is cached in `:persistent_term` for the first 256 distinct
profiles. After that, by design (the cy3p close note: "past-cap check now
uncached for determinism"), every call checks again. `WorkingColor.profile/1`
(`working_color.ex:139`) and the encoder's `to_standard/1` call it more than
once per request:

| request | `equivalent?/1` calls |
|---|---:|
| `w=800` | 1 |
| `w=800/pad=10/bg=ff0000`, `gradient`, `trim=auto` | 2 |
| `w=800/gray`, `w=800/monochrome=0.8` | 3 |

Requests on a 3000×2000 JPEG (JPEG out):

| request | cached profile | unseen profile, cap full |
|---|---:|---:|
| `w=800` | 60 ms | 86 ms (+26) |
| `w=800/gray` | 66 ms | 129 ms (+64) |
| `w=800/monochrome=0.8` | 69 ms | 142 ms (+73) |

Below the cap, the first request with a new profile pays about 20–25 ms once
(78–86 ms against 60 ms). Past the cap, a request with an uncached profile
pays more than the ~5 ms per transform that PR #1022 removed. The cap is
per node and never resets, so a long-running public server fills it with
profiles it sees once (anything that embeds a per-file profile), and a
client can fill it on purpose with 256 requests.

**Suggested fix**, in order of payoff:

1. Import the lattice from sRGB once, at first use (it doesn't depend on the
   profile), and reuse the PCS image. That removes 9 of the 19.5 ms from every
   check.
2. Decide once per request: memoize the answer for the frame's profile digest
   in `State` (or check once in `InputColorManagement` and carry the result),
   so the gray and monochrome paths don't check three times.
3. Past the cap, evict instead of re-checking: an ETS table with a bounded
   size and least-recently-used eviction keeps the common profiles hot. The
   answer for a given profile is the same whether it's cached or not, so this
   doesn't make output depend on what the node saw first.

Question for Håvard: was "uncached for determinism" about the answer, or about
`:persistent_term` updates (each put of a new key copies the table)? If it's
the latter, an ETS LRU avoids both.

### 3. Every request buffers the whole result before encoding, so JPEG and PNG encodes can't overlap the pipeline

**Severity: Medium. New. Measured outside the request path. Output unchanged.
Medium to high risk: it trades away the 415 for corrupt sources.**

`prepare_pixels/7` materializes the clamped result
(`materialize_for_delivery/1`, `lib/image_pipe/processing.ex:235`, `:388-390`),
and `Encoder.finalize/3` copies to memory again (`encoder.ex:212`, a no-op
then). Decode, transforms, and resize run on all libvips threads into memory,
and only then does the encoder start. libvips' JPEG and PNG savers stream
scanlines through `sink_disc`, which computes the pipeline while the encoder
compresses earlier rows, so buffering first turns overlap into a sequence.
WebP and AVIF build a whole picture before encoding and gain nothing.

Shrink-on-load decode of the 6000×4000 JPEG, lanczos3 resize, then encode, in
a scratch script (median of 9):

| output | copy to memory, then encode | encode the lazy image |
|---|---:|---:|
| JPEG, 800 px | 83 ms | 83 ms |
| JPEG, 3000 px | 128–131 ms | 100–102 ms (−22%) |
| PNG, 800 px | 146 ms | 100–104 ms (−30%) |
| PNG, 3000 px | 800–805 ms | 727–746 ms (−8%) |
| WebP, 800 / 3000 px | 147 / 769 ms | 144 / 765 ms |

Streaming would also drop the result buffer (18 MB at 3000×2000).

The copy is there on purpose: the comment at `encoder.ex:208-210` says it makes
a corrupt source fail as a 415 before the first byte, rather than mid-stream.
The metadata and profile edits in `finalize/3` also go through
`Image.mutate/2`, which needs a memory image (or copies one in a linked
process, the a7v9 workaround).

**Suggested fix, if the trade is acceptable:** for single-encode JPEG and PNG
output, stop buffering and move the metadata edits to the save options
(libvips 8.15+ `keep`, for example `keep=icc` or `keep=none`, plus the
`profile` option), so nothing needs `mutate`. The quality search still needs
the buffer and keeps it.

Questions for Håvard:

- Is a mid-stream failure (truncated 200, not cached) acceptable for a corrupt
  JPEG or PNG source, in exchange for 20–30% on large JPEG and PNG results?
- A narrower version: stream only when the source is already known to decode
  cleanly, such as a source served from the input cache that decoded before.
  Is that worth the extra state?

### 4. Narrowing 16-bit input to 8 bits runs three float operations over the full-resolution frame

**Severity: Low–Medium. New (a cost of dd91a5c, p7pl). Measured, also at
request level. Output identical. Low risk.**

For 16-bit sources with 8-bit output, `InputColorManagement.to_colorspace/2`
(`lib/image_pipe/transform/input_color_management.ex:135`) narrows with
`BitDepth.narrow_to_8_bits/1` (`lib/image_pipe/bit_depth.ex:26-28`): `linear`
to float, `round`, and `cast`, on every pixel of the full-resolution decode
(PNG and TIFF can't shrink on load). A single `maplut` with a 65536-entry table
of `div(v + 128, 257)` gives exactly the same bytes over the whole frame (that
expression equals `round(v / 257)` for every 16-bit value; checked
exhaustively). `linear` with `uchar: true` and a +0.5 offset is also exact,
but measured slower.

`spin16.png` (4000×2667), decode, narrow, resize to 800, copy (median of 9,
interleaved):

| narrowing | time |
|---|---:|
| current (linear, round, cast) | 497–503 ms |
| `maplut` | 438 ms |
| `colourspace` (the old truncating shift) | 416–435 ms |

At request level, with `BitDepth` patched locally to use the table (byte-
identical responses, 9 runs):

| request | main | `maplut` |
|---|---:|---:|
| `w=800/format=jpeg` | 543–565 ms | 462 ms (−15%) |
| `w=800/format=png` | 573–586 ms | 536 ms |
| `w=300/gray/format=jpeg` | 436–454 ms | 468 ms (no gain) |

I don't know why the gray request doesn't gain; its decode dominates.

**Suggested fix:** build the table once (a `copy_memory`'d 65536×1 uchar image
in `:persistent_term`) and narrow with `Operation.maplut/2`. The encoder's
`fit_png_depth/2` uses the same helper on the (small) output frame and would
get it for free.

### 5. WebP sources now decode at a power of two and resample, which costs 11–36% at common sizes

**Severity: Low. New (a cost of 9653759, 4qw6). Measured. A quality
trade-off, not a bug.**

Since 9653759, `DecodePlanner.append_load_option/3`
(`lib/image_pipe/transform/decode_planner.ex:103`) asks libwebp for the power
of two at or below the ratio (capped at 8) and lets lanczos3 do the rest,
instead of scaling straight to the target. That fixed visibly coarse
thumbnails. The cost, decoding the 6000×4000 WebP and resizing (median of 7;
"difference" is the mean and maximum absolute difference from a full-size
decode plus lanczos3):

| target | main (power of two) | before 9653759 (scale to target) |
|---|---|---|
| `w=100` | 184 ms, 0.96 / 8 | 157 ms, 3.7 / 31 |
| `w=300` | 171 ms, 0.49 / 8 | 155 ms, 2.1 / 34 |
| `w=800` | 182 ms, 0.83 / 8 | 155 ms, 1.9 / 44 |
| `w=1600` | 255 ms, 0.78 / 13 | 188 ms, 1.3 / 35 |

A full-size decode takes about 390 ms, so the change still keeps most of
the shrink-on-load win. Scaling libwebp to twice the target, as a middle
ground, wasn't faster and wasn't consistently closer.

No change suggested. Question for Håvard: is +17–67 ms per WebP request the
cost you expected for 4qw6? If the server sees mostly large WebP originals
resized to 1000–2000 px, the `w=1600` row is the one that matters.

## Checked and not worth changing

- **Effects at 800 px** (`spin_plain.jpg`, JPEG out, base 92–103 ms): smart
  cover crop 107 ms, quarter turn 101 ms, arbitrary rotate 177 ms, blur=3 114
  ms, sharpen=1 122 ms, pixelate=10 100 ms, watermark at 0.2 scale 115 ms,
  padding 104–106 ms, saturation 103 ms, BlurHash 89 ms. Nothing stands out
  that earlier reviews haven't covered.
- **Integer fusing of brightness, contrast, colorize, and duotone.** These do
  `linear`, `round`, `cast` like `BitDepth`, but on the already-resized frame;
  at 800 px they're within noise.
- **Crop-mode tiles** already score concurrently (`each_tile/2`,
  `crop_score.ex:146`).
- **`Image.autorotate/1`** uses libvips' `autorot` and doesn't parse EXIF in
  Elixir.

## Suggested order

1. Skip the EXIF parse when nothing is kept (#1). Small, local, byte-identical,
   and it saves 1–17 ms on every camera photo.
2. Cache the sRGB lattice import and decide equivalence once per request (#2,
   fixes 1 and 2). Then decide on the past-cap behaviour.
3. Narrow 16-bit input with a lookup table (#4). Small and byte-identical.
4. Decide whether a mid-stream failure for corrupt sources is acceptable (#3).
5. #5 only if WebP traffic is large.
