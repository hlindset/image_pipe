# Bug hunt 7: image processing and output

Scope: transform geometry and decode, pixel operations and colour, watermarks, output policy and encoding, in `image_pipe/` at `6a87579`. The hunt concentrated on code changed since bug hunt 6 (mostly its fixes) and on two areas earlier hunts touched lightly: what metadata each output carries, and how colour effects behave on tagged (non-sRGB) sources. Findings already in `bug-hunt/` through `bug-hunt-6/`, and open or deferred beads, are left out.

**How this was checked:** every finding was reproduced with real `ImagePipe.Plug.call/2` requests in a cloud session (`MIX_ENV=test mix run`, File source, response decoded and pixels or headers read back), libvips 8.18.7 built as CI builds it. Numbers are actual output. Pixel differences are mean / max absolute difference per 8-bit channel after converting both images to sRGB.

**Bug hunt 6 status:** all 6 findings are fixed on main and were re-run here.

| # | finding | fix | re-run |
|---|---|---|---|
| 1 | `kernel=nearest` downscale of oriented sources | e8ed9de | `flip=h/kernel=nearest/w=16` vs pre-flipped twin: 0.0; EXIF 3: 0.03 |
| 2 | blur budget per group | ccd23d5 | one `blur` group 200 (2.7 s), two groups 200 (5.7 s), four groups 422 |
| 3 | WebP shrink-on-load | 9653759 | `w=16` 1.45, `w=50` 1.18 from the ideal (was 7.58 / 4.40) |
| 4 | 16→8-bit rounding | dd91a5c | 16-bit gray ramp: 0 values off |
| 5 | clamp drops alpha | ce3f80a | `[200,120,37,100]` exact |
| 6 | not-ready detector floor | 0b1f3b2 | code read |

---

## 1. Every output carries a libvips-made EXIF block, even with `meta=strip` and EXIF-less sources

**Severity:** Medium (180–190 bytes on every response, which is 20–55% of a small thumbnail; it also rewrites a kept sRGB `ColorSpace` tag to "Uncalibrated")

**Where:** `lib/image_pipe/output/encoder.ex:132-140` (`buffer_for`, which never passes libvips' `keep` option), `:517-545` (`strip_metadata`), `:549` (`minimize_metadata`), `:557` (`set_density`), `:485-505` (`@icc_remove_fields`, `maybe_drop_profile`).

The encoder strips metadata by removing header fields, then saves without `keep`. libvips' savers default to `keep=all`, and with the resolution fields still on the image (libvips always has `xres`/`yres`) they build a fresh EXIF block from the image: resolution, `ResolutionUnit`, and `ColorSpace=65535` (Uncalibrated). JPEG gets an APP1 EXIF segment, WebP and AVIF an `EXIF` chunk/item, PNG an `eXIf` chunk. This happens on sources with no EXIF at all and under `meta=strip`.

**Evidence:**

- `noexif.png` (no metadata), `w=32`: JPEG 889 B with a 186 B EXIF segment, WebP 372 B with an EXIF chunk, PNG with a 180 B `eXIf` chunk. Each decodes with `ColorSpace = 65535`, `XResolution = 72`.
- Re-saving the same output images with `keep: [:icc]` (or none) and the same quality: JPEG 871 → 681 B, WebP 356 → 144 B, AVIF 568 → 313 B, PNG 919 → 727 B. `keep: [:icc]` keeps the density in JPEG and PNG (JFIF / `pHYs`), so those lose nothing.
- `cs1.jpg` (EXIF `ColorSpace = 1`, sRGB) with default `meta` and with `meta=keep`: output `ColorSpace = 65535`. 98800fb (bead z9ek) fixed this only for hosts with `strip_metadata: false`; the default path and `meta=keep` with copyright kept still rewrite it, because `minimize_metadata` drops `exif-ifd2-ColorSpace` and libvips writes its default.
- `max-bytes` counts the block, and the docs say it counts metadata, so this is mostly size, but `docs/processing/output.md` and the `strip_metadata` doc in `config.ex` ("Remove EXIF, XMP, and other optional metadata") promise there is no EXIF left.

**Suggested fix:** when nothing is kept (strip, or keep with no EXIF field left), save with `keep: [:icc]` when a profile is kept and `keep: []` otherwise (Vix exposes `keep` on every saver used here). When EXIF is kept (copyright, `meta=keep`), set `exif-ifd2-ColorSpace` to 1 after `minimize_metadata` when the output is sRGB. When `dpi=` is set, JPEG and PNG carry it in JFIF / `pHYs`; WebP and AVIF have only EXIF, so keep the EXIF block there. Add a wire test that a `meta=strip` response of each format has no EXIF segment/chunk.

**Question for Håvard:** without EXIF, WebP and AVIF outputs carry no density at all. Viewers assume 72 dpi anyway, so dropping a 72-dpi block looks safe; is anything relying on it?

---

## 2. `profile=display-p3` / `adobe-rgb` with `meta=keep` keeps the source's `ColorSpace = sRGB` tag

**Severity:** Low (wrong colour-space claim in EXIF next to a correct embedded profile; most viewers follow the ICC profile, some older ones follow EXIF)

**Where:** `lib/image_pipe/output/encoder.ex:338` (the convert clause of `color_result`), `:416` (`convert_to_target`), `:485-505`.

When the output is converted to a non-sRGB target, the encoder embeds the target profile but leaves the EXIF colour fields from the source. A source tagged `ColorSpace = 1` keeps `ColorSpace = 1` and its `WhitePoint` / `PrimaryChromaticities`, which now describe the wrong primaries.

**Evidence:** `cs1.jpg`, `meta=keep/profile=display-p3/format=jpeg`: output embeds Display P3 and EXIF says `ColorSpace = 1` (sRGB). Same with `profile=adobe-rgb`. With `profile=srgb` the tag is right.

**Suggested fix:** when the target is not sRGB, set `exif-ifd2-ColorSpace` to 65535 and remove `WhitePoint` and `PrimaryChromaticities` (the fields `@icc_remove_fields` already lists for dropped profiles). Can share code with finding 1's `ColorSpace` handling.

---

## 3. Colour effects blend in the tagged source's encoding, so the same request gives different colours on a P3 source and its sRGB twin

**Severity:** Medium (visible colour shift on wide-gamut phone photos, which are the common tagged source; breaks "request colours are sRGB")

**Where:** `lib/image_pipe/transform/executor.ex:946-955` (`run_color_optional`, `run_display_color_optional`), `:826` (`srgb_frame`, used only for watermarks).

On a tagged source the executor keeps the pixels in the source's encoding until output. Request colours are converted into that space (the `bg` and watermark tests in `colour_conversion_wire_test.exs` cover this), but the blend itself runs on P3-encoded values. A 30% blend toward red in P3 code values, then converted to sRGB, is not a 30% blend in sRGB, so `colorize`, `gradient`, `duotone` and `monochrome` come out differently than on the same picture delivered as sRGB. Watermarks avoid this because `srgb_frame` converts the frame to sRGB first when the output is sRGB.

**Evidence:** a photo-like sRGB PNG and its Display P3 twin (same colours, `icc_transform` to P3, profile embedded). Default output (sRGB), PNG, difference between the two responses:

| request | mean | max |
|---|---:|---:|
| `colorize=0.3,ff0000` | **9.36** | 65 |
| `gradient=0.8,ff0000,down,0,1` | **10.7** | 34 |
| `duotone=1,000080,ffff00` | **14.35** | 45 |
| `monochrome` | 2.62 | 31 |
| `colorize=0.3,0000ff` | 1.21 | 20 |
| `bg=ff000080` on alpha source | 0.05 | 1 |
| `wm=mark` | 0.0 | 0 |
| no effect | 0.0 | 0 |

**Suggested fix:** when the output is sRGB (`srgb_output?`), convert the frame with `srgb_frame` before the first colour effect, as watermarks already do; the later output conversion then sees sRGB and does nothing. Add a twin test (P3 vs sRGB source, each colour effect) to `colour_conversion_wire_test.exs`.

**Question for Håvard:** with `profile=preserve` the output stays in P3, so converting to sRGB for the effect and back would clip wide-gamut colours. Should preserve keep blending in the source encoding (today's behaviour), or blend in linear/sRGB and accept the round trip?

---

## 4. `SrgbProfile` cache keys on the full profile bytes, so after 256 distinct profiles every tagged request re-runs the lattice check

**Severity:** Low–Medium (performance: up to ~50 ms extra per request on servers that see many camera/phone profiles)

**Where:** `lib/image_pipe/srgb_profile.ex:21` (`@cap 256`), `:26` (`equivalent?`, keyed `{module, sha256(profile)}`), `:37` (`check_and_store`), `:74` (`check`).

The cache key hashes the whole profile, including the creation date (bytes 24–35) and profile ID (84–99), which differ between otherwise identical sRGB profiles written by different apps and devices. Once 256 distinct digests are stored the cache stops storing, and each later lookup runs the full check (~13–18 ms). A request can look up a profile up to three times (input conditioning, `srgb_frame` for watermarks/gray, output).

**Evidence:** cache filled with 256 synthetic profiles, then requests on a tagged JPEG: `w=300` 15 → 33–37 ms; with `wm=mark` 44 → 77–89 ms; `gray/colorize/wm` 40 → 77–89 ms (1, 4 and 7 checks counted via a counter on `check/2`).

**Suggested fix:** memoize the answer per request (it is the same profile each time), hash the profile with bytes 24–35 and 84–99 zeroed so app/date variants share a key, and replace the hard cap with a bounded LRU (or evict the oldest) so a long-running server keeps caching new profiles.

---

## 5. `png-options=palette` is ignored on 16-bit results, and `palette,bitdepth:4` narrows 16-bit by truncation

**Severity:** Low–Medium (PNG 2.8–4.3× larger than asked for under `hdr=preserve` or a `preserve_hdr` host; small colour error at low bit depths)

**Where:** `lib/image_pipe/output/encoder.ex:227-264` (`fit_png_depth`). The 1/2/4-bit clause has a guard on `palette != true`, the 16-bit clause widens, and the 8-bit clause narrows with `BitDepth.narrow_to_8_bits`. A 16-bit image with `palette` and no `bitdepth` falls through to no narrowing, and libpng can't palettize 16-bit, so it saves full 16-bit RGB. `docs/processing/output.md` says palette applies "except at bitdepth 16", which reads as an explicit `bitdepth:16`.

**Evidence:** `hdr=preserve/png-options=palette`: `rgb16.png` 1,230 B (8-bit source equivalent) → 3,422 B; `rgba16.png` 1,244 → 3,744 B; 16-bit P3 photo 65,465 → 281,817 B. With `palette,bitdepth:4` the 16-bit values `[65400,128,129,32896,300,65280]` come out `[255,0,0,128,1,255]` (shift), where `BitDepth` rounding gives `[254,0,1,128,1,254]`.

**Suggested fix:** when `palette` is set without `bitdepth:16`, narrow a 16-bit image with `BitDepth.narrow_to_8_bits` first, as the 8-bit clause does, and route the 1/2/4-bit palette case through the same narrowing.

**Question for Håvard:** or should `palette` on a 16-bit result be a `400`/ignored-with-docs instead, so `hdr=preserve` always means 16-bit out?

---

## 6. `progressive-blur` is charged like one blur but costs 2–7× as much

**Severity:** Low (a request can do almost twice the blur work `max_blur_work` is meant to allow)

**Where:** `lib/image_pipe/transform/executor/step.ex:129` (progressive blur charged as one `convolution`), `lib/image_pipe/transform/work_limits.ex:29-38`.

Progressive blur runs several blurs and blends them, so it does more work than a single blur at the same sigma, but `max_blur_work` charges it the same.

**Evidence:** a 1200×1600 PNG (1.9 megapixels), JPEG output: `blur=60` 146 ms vs `progressive-blur=60,…` 627–1,087 ms; `blur=150` 241 ms vs 1,175 ms; `blur=1000` 4,708 ms vs `progressive-blur=1000,down,0,1` 7,841 ms. `blur=1000/-/blur=1000` is allowed (9.3 s, just under the default budget), so the same with two progressive groups is allowed too and should take about 15.7 s (estimated from the single-group time, not run).

**Suggested fix:** charge progressive blur about twice a plain blur (measure the factor at the large sigmas the budget is about, where it is ~1.7×), and keep the deployment guide's numbers in step.

---

## 7. JPEG shrink-on-load drops the last `width mod n` columns, but the executor maps the decoded image to the full source width

**Severity:** Low (less than one output pixel of drift; visible as a sharpness/alignment difference on fine detail, and the same as libvips' own `thumbnail`)

**Where:** `lib/image_pipe/transform/decode_planner.ex:96` (`append_load_option :jpeg`, `jpeg_shrink_n`), `lib/image_pipe/decode.ex:~413` (`decode_shrink`).

libjpeg's DCT scaling at shrink n produces `floor(width / n)` columns that cover the first `n × floor(width / n)` source columns. The executor treats the decoded image as covering the full width and scales the residual by `decoded / target`, so for widths that aren't a multiple of n the content is stretched by up to `(n − 1)` source columns. WebP's shrink rounds instead and doesn't have this.

**Evidence:** 1199×1599 block-noise JPEG (shrink 8 → 149×199, which is a box filter of the first 1192×1592), `w=67`, compared with an ideal Lanczos reduce of the full source: JPEG source 8.74 mean, PNG twin 1.05. At width 1193: 1.70 vs 1.04; at 1200 (a multiple of 8): 1.08 vs 1.06. libvips `thumbnail` on the same file also gives 8.74, so this is parity with libvips, not a regression.

**Suggested fix:** compute the coverage as `n × decoded` source pixels and scale the residual from that, cropping or extending the last partial block, so the result lines up with the full-resolution path.

**Question for Håvard:** worth fixing given it matches libvips, or note it and move on?

---

## Checked and clean

- EXIF copyright is kept across 22 operations × JPEG/PNG/WebP/AVIF under the default `meta`.
- Display P3 source vs sRGB twin across 26 operations × default options, `meta=keep` and `hdr=preserve`: equal apart from finding 3's colour effects.
- Explicit-JPEG white fill equals the transparent path flattened on white (9 alpha sources × 5 operations).
- 2,600 random requests over the option vocabulary: no 5xx and no unexpected 400.
- 300 random geometry requests on smooth 2003×1501, 1601×2399 and 4001×1203 JPEG/WebP sources vs their PNG twins: none over threshold (finding 7 needs high-frequency content to show).
- 16-bit and gray-with-alpha sources to JPEG flatten on white; gradient on 8-bit sources stays 8-bit.

**Harness:** `/tmp/claude-0/hunt/h.exs` in the session (not kept); it is the bug hunt 3 harness with a `D.norm/1` that converts any response to flattened 8-bit sRGB before comparing.
