# Performance review 5: image processing

Scope: decode planning, transform operations, materialization, colour
management, watermarks, encoding, and the autoquality search. Library paths
are relative to `image_pipe/`, at `main` fe70ecc. No code was changed on any
branch. Where a finding proposes a different libvips call, the alternative
was timed in a scratch script against the same images, and the outputs were
compared.

## How this was measured

Request numbers come from real `ImagePipe.Plug.call/2` requests against a file
source, with no output cache and the libvips operation cache off (as
`image_pipe_server` sets it). Stage times are summed from the library's own
telemetry stop events. Each figure is the median of 5 to 21 runs; the run
count is given where it matters. The machine has 4 vCPUs (Xeon at 2.8 GHz,
AVX-512) and libvips 8.18.7 built by the cloud setup hook. That is a different
CPU from review 4, so absolute numbers aren't comparable across the two
reviews; every comparison below is within this run.

Fixtures are `priv/static/images/` plus files derived from them:

- `spin_base.jpg`: `spinning_baseline.jpg`, 6000×4000 baseline JPEG. It
  carries the common 3144-byte "sRGB IEC61966-2.1" profile (Hewlett-Packard,
  1998).
- `spin_untagged.jpg`: the same file with only the ICC APP2 segment removed,
  so the pixels and everything else are identical.
- `border_tagged.jpg`, `border_untagged.jpg`: those two with a 200 px white
  border, for trim.
- `spin16.png`: a 16-bit RGB PNG of the same picture; `spin10.avif`: a 10-bit
  AVIF of it.
- `logo.png`: a 1200×600 RGBA crop of `cooking.png`, as a watermark.

## Status of review 4 findings

- **#2, score the two alpha backgrounds concurrently:** fixed on main
  (vy09, PR #955, d249084).
- **#4, composite an untiled watermark only where it lands:** closed as
  won't-fix (r89a). A partial composite reads the base twice, which the
  sequential-access gate forbids. Not repeated.
- **#1, build the detector tensor in libvips:** deferred upstream (acyo).
- **#3, threading inside the SSIMULACRA2 compare:** deferred upstream (ett1).
  See the note under "Checked" about the NIF's CPU features.

## Findings, ranked by payoff against risk

### 1. An embedded sRGB profile costs a LittleCMS transform, about 5 ms of setup each, on every request

**Severity: High. New angle on a review 1 note. Measured. Output unchanged
for the common profile. Low to medium risk.**

Most web JPEGs carry an sRGB profile. ImagePipe keeps it on the working frame
(`InputColorManagement`, `lib/image_pipe/transform/input_color_management.ex:88`)
and converts through it wherever a step needs sRGB values:

- the output conversion, `to_standard/1`
  (`lib/image_pipe/output/encoder.ex:396`, reached from `:389`), on every
  request that doesn't preserve the profile;
- `WorkingColor.values/2` (`lib/image_pipe/transform/working_color.ex:28`), an
  ICC import and export of a 1×1 image, called once or twice by duotone and
  monochrome (`duotone.ex:51-52`), background (`background.ex:41,56`),
  colorize (`colorize.ex:46,55`), and gradient (`gradient.ex:67`);
- `WorkingColor.to_srgb/1` (`working_color.ex:61`) on the whole frame, for gray
  and bitonal (`gray.ex:20`, `bitonal.ex:22`), watermarks (`executor.ex:775`),
  and trim (`trim.ex:167-175`). Several of these also buffer the frame first
  (`materialize_tagged_frame/1`, `executor.ex:914`).

Each `icc_transform` builds a new LittleCMS transform. On a 1×1 image that
takes 4.6–4.9 ms; at 300×200 the transform takes 6 ms against a 1.4–2 ms JPEG
encode. Review 1 measured this output transform and found it within noise,
but the libvips operation cache was on then, and it caches the transform:
with the cache at 100 the same call takes 0.8 ms. Since review 3 the server
turns the cache off, so every request now pays the setup.

The same request on `spin_base.jpg` and `spin_untagged.jpg` (JPEG out, 9 to
21 runs; the response bytes are identical in every row):

| request | tagged | untagged | difference |
|---|---:|---:|---:|
| `w=300` (encode span alone) | 10 ms | 3 ms | 7 ms |
| `w=300/gray` | 94 ms | 82 ms | 12 ms |
| `w=300/gradient=0.8,black` | 119 ms | 100 ms | 19 ms |
| `w=300/wm=logo/wm-scale=0.2` | 129 ms | 95 ms | 34 ms |
| `w=300/pad=10/bg=ff0000` | 125 ms | 88 ms | 36 ms |
| `w=300/monochrome=0.8` | 132 ms | 83 ms | **49 ms** |
| `w=800` | 148 ms | 131 ms | 17 ms |
| `w=800`, WebP out | 202 ms | 193 ms | 9 ms |
| `w=3000` | 191 ms | 165 ms | 26 ms |
| `trim=auto/w=800` (bordered) | 717 ms | 591 ms | **126 ms** |
| `trim=auto/w=3000` (bordered) | 805 ms | 587 ms | **218 ms** |

I also compared PNG, WebP, and AVIF output at `w=800`, and duotone with WebP
output: byte-identical responses in every case. Trim pays most because it
converts the full-resolution frame before its preview shrink, then again
under every refinement strip.

The conversion isn't an exact identity for every colour. Over all 16.7 million
8-bit colours, both the HP profile and Facebook's 524-byte "c2" profile
(`woman.jpg`) map to libvips' sRGB with at most 1 level of difference, in
0.28% of channel values. The test photo happens to hit none of them.

**Suggested fix:** recognise an sRGB-equivalent profile once per request and
treat the frame as untagged: skip `to_standard/1`, take the untagged branches
in `WorkingColor`, `Trim`, and the watermark path, and let the encoder's
metadata strip drop the profile. Removing the profile at input conditioning
would buffer the whole lazy decode (the Vix mutable copy), so carry the
decision as state instead, for example as the stored `source_color_profile`.

Ways to recognise the profile:

- a digest allowlist of the common sRGB profiles (the HP one, Apple's, the
  compact "c2" ones), each checked offline over all 16.7 million colours;
- or memoize per profile digest: transform a small colour lattice once,
  compare it to identity, and cache the answer (for example in
  `:persistent_term`).

Questions for Håvard:

- Is a difference of at most 1 level in 0.28% of channel values acceptable?
  That's the libvips round trip for these profiles. If not, only profiles
  that round-trip exactly can be skipped.
- Golden images and imgproxy references made from tagged sources could move by
  that 1 level. Is re-baking them acceptable?

### 2. Padding and extend add an alpha band that a JPEG encode then flattens

**Severity: Low–Medium. New. Measured. Output unchanged for JPEG. Medium
risk: the executor needs one fact about the output format.**

`ExtendCanvas.embed_image/4` (`lib/image_pipe/transform/operation/extend_canvas.ex:79-80`)
always adds an alpha band and pads with transparent black. For a format
without alpha, the encoder then flattens the whole frame onto white in float
(`flatten_onto_white/1`, `lib/image_pipe/output/encoder.ex:328`): a cast to
float, a flatten, a round, and a cast back, over every pixel.

On an in-memory 3000×2000 frame padded to 3040×2040 and encoded as JPEG:

| approach | time |
|---|---:|
| current: alpha, transparent pad, float flatten, encode | 98 ms |
| pad with opaque white and no alpha band, encode | 49 ms |

The JPEG bytes are identical. At request level, `w=3000/pad=20` costs 246 ms
against 213 ms without padding (7 runs).

**Suggested fix:** when the group's frame has no alpha band and the final
format can't hold alpha, embed with the colour the encoder would flatten to
(white, or the group's opaque `bg`), and skip `Alpha.ensure/1`. The executor
would need "can the output hold alpha?" from `Output.Policy`. That's known
for explicit formats, but not for `Accept` negotiation before the transform
runs.

Question for Håvard: is that input to the executor worth adding for
padding? Review 3 #4 wanted the same fact for arbitrary rotation and was
solved another way (PR #783). If the format isn't known before the
transform, this finding only applies to explicit `format=jpeg`.

### 3. A gradient blends the whole frame in float with five full-frame operations

**Severity: Low. New. Measured. Output within 1 level. Low risk.**

`Gradient.blend/3` (`lib/image_pipe/transform/operation/gradient.ex:66`)
joins the float mask three times, builds an inverse mask, multiplies the frame
by it, builds a full-frame constant colour image, multiplies that by the mask,
adds the two, then rounds and casts (`:60`).

On an in-memory 3000×2000 frame, `gradient=0.8,black`:

| approach | time |
|---|---:|
| current | 152 ms |
| same mask scaled to uchar, then `ifthenelse(mask, colour, frame, blend: true)` | 71 ms |

The outputs differ by at most 1 level (mean 0.095). That comes from
quantizing the mask to 255 steps. At request level the gradient adds about
60 ms at `w=3000` (7 runs).

**Suggested fix:** keep `DirectionalMask.build/6`, cast its result to a uchar
mask (×255, rounded), and use `ifthenelse` with `blend: true` against a
constant colour image. libvips then blends in one pass in the frame's own
format. A 16-bit frame would need a ushort mask, or the current path.

### 4. A 16-bit downscale converts the full-resolution frame to float before shrinking

**Severity: Low. New (a cost of d82db2d, fjwd). Measured. Output changes
slightly. Low risk.**

To keep 16-bit white at 65535, `resample_bands/4`
(`lib/image_pipe/transform/operation/resize.ex:83-86`) casts a ushort frame to
float before `resize`. libvips then does its integer box shrink in float on
the full-resolution frame too, although only the kernel reduce loses
precision. In this run, a ushort `shrink` by 3 kept white at 65535 and was
within 1 level of the same shrink done in float.

A 6000×4000 16-bit PNG resized to 800 px wide (this only happens when the
working space stays 16-bit, so with `hdr=preserve` and a 16-bit-capable
output):

| path | streamed from the PNG | from memory |
|---|---:|---:|
| current (float before resize) | 1584 ms | 188 ms |
| plain ushort resize (white becomes 65455) | 1335 ms | 100 ms |
| ushort `shrink` by 3, then float reduce | 1286 ms | 101 ms |

At request level, `w=800/format=png` on `spin16.png` takes 1215 ms with the
working space narrowed to 8 bits, and 1736 ms with `hdr=preserve`. Part of
that gap is the 16-bit PNG encode.

**Suggested fix:** do the integer part of the shrink in ushort
(`Operation.shrink` by `floor(1 / scale / 2)`, which is libvips' own split
with the default gap), then cast the smaller image to float for the reduce.
My two-step version kept white white but didn't reproduce `resize`'s
internal split exactly: it differed from the current output by a mean of
212/65535, with a maximum of 3409. Matching libvips' shrink factor and centre
convention needs a closer look before the goldens could stay put.

Question for Håvard: is it worth it for `hdr=preserve` and 16-bit sources?
They're rare in web traffic.

## Checked and not worth changing

- **Blur precision.** Below sigma 4, blur runs at float precision
  (`gaussian_blur.ex:32-33`) and costs 159 ms at sigma 3 on 6 MP, against
  30 ms at integer precision. Integer precision shifts a flat 200 to 202
  at sigma 2.5, 3, and 3.9. I tried a hand-built integer mask: weights summing
  to 256 keep flat areas exact for most sigmas but not 0.7 or 1.1–1.5, and a
  sum of 64 is always flat-exact but up to 8 levels off elsewhere. Blurring
  in ushort is exact but slower than float (195–257 ms). Approximate
  precision is slower than float below sigma 4, and wrong at sigma 0.5. I
  found no exact, faster path; the current threshold is right.
- **Streamed resize of an RGBA PNG.** `w=800` from `cooking.png` takes 705 ms
  streamed, against 424 ms when the decode is copied to memory first. With
  `VIPS_CONCURRENCY=1` the two are equal (731 against 760 ms), so the gain is
  idle cores working in parallel with the single-threaded PNG decode. The
  server sets the concurrency to its CPU quota, so under load this would
  only cost memory.
- **SSIMULACRA2 build flags.** A compare takes 430 ms on 1200×800 here. A
  local build of the NIF with `target-cpu=x86-64-v3`, and a default local
  build, both time the same as the precompiled one (`fast-ssim2` dispatches
  on CPU features at runtime). ett1 still covers threading.
- **Autoquality**, for the record in this run (JPEG out, `spin_base.jpg`):
  `w=1200` 1597 ms, `w=2400` 6421 ms, `w=3010` (crop scoring) 1904 ms. All
  three made 3 probes, and the metric is 98% of the search. The crossover
  decision (e4a.6.10) stands, and ett1 is the remaining lever.
- **Saturation** adds about 60 ms at `w=3000` (LCh round trip in
  `Image.saturation/2`, already noted in review 3).
- **JPEG shrink cliff.** `w=3040/h=2027` takes 334 ms against 213 ms for
  `w=3000`, because a target just over half the source can't use shrink 2.
  Shrinking below the target would mean upscaling afterwards, so this is
  correct.
- **`kernel=nearest`** decodes at full size (271 ms against 184 ms at
  `w=3000`). That's by design, since the load shrink averages pixels.
- **Quarter turns and flips.** `w=2000/rotate=90` (6 MP out) takes 226 ms
  against 204 ms for `w=3000`. Horizontal and vertical flips are within
  noise.
- **Progressive JPEG, AVIF, and JPEG XL decodes** are 3.1×, 11×, and 11× a
  baseline JPEG at `w=800`, all inside the decoder. The cloud build decodes
  AVIF with aom rather than the server's dav1d, so those numbers don't apply
  to the server. Embedded HEIF thumbnails are already bead brh.
- **Placeholders.** `output=info` answers in 2 ms; `blurhash` and `lqip-css`
  on the 24 MP JPEG take 87 and 99 ms, mostly the shrink-8 decode.

## Suggested order

1. Recognise sRGB-equivalent profiles and skip their transforms (#1). This is
   the largest and most common saving: about 5–7 ms on every tagged request,
   12–49 ms with colour effects, watermarks, or padding, and 126–218 ms for
   trim.
2. Blend gradients with `ifthenelse` (#3). Small, local, and within 1 level.
3. Decide whether the executor should know the output can't hold alpha (#2).
4. The 16-bit shrink split (#4), only if 16-bit traffic matters.
