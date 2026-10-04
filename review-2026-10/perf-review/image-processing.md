# Performance review: image processing and encoding

Scope: libvips pipeline use (shrink-on-load, sequential access, materialization),
operation ordering, detection and content-aware crop, encoders, and auto-quality
search. Paths are relative to `image_pipe/`. No code was changed.

## How this was measured

The Elixir toolchain can't be installed in this container (hex.pm and mise are
blocked by the network policy), so the request path wasn't run end to end. Instead
the same libvips operations were timed from Python (`pyvips`) against system
libvips 8.15.1 with libheif/libaom, on 4 cores, with the operation cache off.
Medians of 3 to 7 runs. Vix ships libvips 8.18, so the absolute numbers will be
different. The ratios are what matter. Quality parity was checked with
SSIMULACRA2 (the `ssimulacra2` Python package). Anything marked *inferred* comes
from reading the code or from the repo's own `bench/autoquality.md` numbers, not
from a new measurement.

## Candidates, ranked by expected payoff

### 1. AVIF and WebP encode at libvips' default effort (4), and that cost dominates AVIF requests

`lib/image_pipe/processing/config.ex:36-37` default to `%WebpOptions{}` and
`%AvifOptions{}` with `effort: nil`, so `Output.Encoder` (`encoder.ex:205`, or
`Image.stream!` with no options) uses libvips' default effort of 4. With
`auto_avif: true` and `format_order: [:avif, :webp]`, every browser that sends
`Accept: image/avif` gets this encoder.

AVIF encode time at the same Q=63 (wall ms / bytes):

| frame | e0 | e2 | e4 (current) | e6 |
|---|---:|---:|---:|---:|
| beach 600 px | 12 / 16K | 29 / 15K | 162 / 16K | 504 / 15K |
| beach 1600 px | 36 / 69K | 128 / 65K | **704** / 67K | 1999 / 67K |
| cooking.png 1600 px | 47 / 110K | 181 / 71K | **814** / 73K | 2223 / 71K |

At the same Q, effort 4 also gives 3 to 5 SSIMULACRA2 points more quality, so
it isn't free to drop. At **matched quality** (the lowest Q whose score reaches
e4 Q63's score, 1200 px frames):

| image | e4 Q63 | e3 | e2 |
|---|---|---|---|
| beach | 560 ms, 44K | 117 ms, +15% bytes | 100 ms, +21% bytes |
| mountain | 505 ms, 41K | 161 ms, +13% | 140 ms, +19% |
| cooking.png | 624 ms, 53K | 142 ms, +12% | 108 ms, +17% |
| flower | 1244 ms, 161K | 245 ms, +12% | 204 ms, +12% |

So effort 3 makes AVIF encoding about 4× faster for about 12–15% more bytes at
equal quality. WebP shows the same pattern, but smaller: e2 is about 2.5× faster
than e4 (beach 1600 px: 52 vs 136 ms) for 4–6% more bytes, with an equal
SSIMULACRA2 score.

This is a product tradeoff, not a bug. Two things make it worth deciding on
purpose:

- With an auto-quality search, AVIF pays the encode on every probe. The default
  AVIF bracket of 60–65 takes about 3 probes, so roughly 1.5–2.5 s of encoding for
  a 1200–1600 px frame at effort 4. `bench/autoquality.md` Part A found the metric
  to be ~80% of search cost, but that was measured with a cheap encoder. For AVIF,
  the encode is the larger cost.
- A possible follow-up: run the search probes at a low effort to pick the
  quality, then encode the winner once at the configured effort. That needs a
  per-effort quality offset (the same idea as the existing
  `quality_search_offsets`), so it's a design question, not a quick change.

Options: lower the default AVIF effort to 2 or 3 (and WebP to 2 or 3), or keep 4
and document the latency cost next to `avif_options`/`webp_options`.

### 2. Trim turns off shrink-on-load completely

`lib/image_pipe/transform/decode_planner.ex:62` returns shrink 1.0 whenever a
group trims, so `trim + w=600` decodes the whole source at full size, buffers it
(`Trim.requires_materialization?/1`), and runs `find_trim` over every pixel.

A 24 MP baseline JPEG with a white border, trim then `w=600`:

| decode shrink | 1 (current) | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| request time | **1315 ms** | 475 ms | 186 ms | 103 ms |

The same request without trim, at shrink 8: 73 ms.

The planner can't pick a safe shrink up front, because the trimmed extent is
unknown, and a shrink based on the full source over-shrinks a heavily trimmed
image. A two-pass plan would fix that:

1. Open a cheap shrink-on-load preview (shrink 8) and run `find_trim` on it.
2. Plan the real decode's shrink from the trimmed extent (with a margin of one
   preview pixel).
3. Decode at that shrink, trim there, and rescale the box the way region crops
   already do (`Geometry.rescale_crop`, `executor.ex:227,235`).

The cost is that trim edges get shrink-pixel precision, which works out to under
one output pixel. That is the same tradeoff region crops already accept. Edge
detection on a DCT-downscaled image can also differ slightly from full
resolution near the threshold. This changes output pixels, so it needs a design
decision and re-baked goldens for trim.

### 3. Crop-mode quality search rebuilds each tile's SSIMULACRA2 reference on every probe

`lib/image_pipe/output/ssim2_metric/crop_score.ex:101-105`: `tile_score/3` calls
`Ssim2Metric.reference(bt)` on the **base** tile for every candidate. The base
image and the 16 tile coordinates are the same for the whole search, so the 16
references could be built once in `EncodeSearch.score_opts/4` (crop path,
`encode_search.ex:626`) and reused by every probe.

*Inferred* from `bench/autoquality.md` Part A: building a reference costs about
31 ms/MP and a compare costs about 43 ms/MP, so the reference is roughly 40% of
each tile's cost. The crop-mode probe budget of about 265 ms should drop to
about 155 ms. Over the 4–6 probes of a search on a >6 MP image, that saves about
0.4–0.6 s, with **identical scores and output**. This is the cheapest change on
the list and needs no design discussion. Re-running Part E/L confirms it.

### 4. Detection runs the face and object models one after the other

`lib/image_pipe/transform/detector/composite.ex:84` maps over the routed
children in sequence, and each child (`image_vision`'s `preprocess/1`) flattens,
converts, and thumbnails the frame on its own. When a request routes to both
(`detect` with faces and objects, or face assist plus objects), detection takes
face time plus RT-DETR time. Running the children concurrently (each is
independent and returns its own regions) would cut it to the slower of the two.

*Inferred*, not measured: the models can't be loaded here. YuNet is small, so the
gain is about the face model's time per request, probably tens of ms. A smaller
change is to give both children one shared, pre-shrunk frame instead of letting
each thumbnail the full frame. Both thumbnail to their model's input size anyway.

### 5. Production keeps libvips' operation cache at its defaults, but every benchmark turns it off

Nothing in `lib/` or `image_pipe_server/` calls `Vix.Vips.cache_set_max*`, so
production runs with libvips' default cache (100 operations, 100 MB, 100 files).
`test/test_helper.exs:21` and every `bench/*.exs` script disable it. For
mostly-unique image traffic the cache seldom hits, and it keeps recent
intermediate buffers alive after their requests end. This mostly affects
resident memory, not speed. It also means the committed memory and latency
studies don't describe production exactly. *Inferred*. A short A/B run of
`bench/pre_clamp_materialization.exs` with the cache on would settle it, before
deciding whether the server should disable it or the docs should recommend that.

## Checked and not worth changing

- **Full copy to memory before every encode** (`encoder.ex:224`) and the
  **sRGB→sRGB ICC transform** on output for sRGB-tagged sources (`to_standard`,
  `encoder.ex:300-307`; every fiddle fixture carries an sRGB profile and the
  default strips it). Removing either changed 600–1600 px requests by 0–5%,
  within run-to-run noise. The copy also keeps corrupt-source failures as 415s.
- **The second copy in the orientation flush** (`orientation_flush.ex`): the
  repo's own fd8 study (`bench/pre_clamp_materialization.md`) already measured
  this and chose speed over memory.
- **Smart and detect crops before a resize**: these buffer only the
  decode-shrunk frame, because the planner already sizes shrink-on-load from
  `crop_extent`. The cover-resize smart crop runs on the resized frame.
- **Shrink-on-load for HEIF/AVIF/PNG/TIFF**: libvips offers only an embedded
  thumbnail (HEIF) or pyramid levels for these, nothing general.

## Note for future benchmarks

Every JPEG in `priv/static/images/` is progressive. libjpeg's DCT shrink helps
progressive files very little: spinning.jpg (24 MP) decodes in 344 ms at shrink 1
and still 276 ms at shrink 8. A baseline JPEG gets a far larger speedup. Benches
built on these fixtures understate shrink-on-load gains and overstate decode
cost. A baseline copy of one large fixture would make them more representative.

## Suggested order

1. Cache the tile references in crop scoring (#3): no output change, small diff.
2. Decide the AVIF/WebP default effort (#1): a one-line default plus docs, but a
   bytes-versus-latency call only you can make.
3. Run the operation-cache A/B (#5) before changing anything there.
4. Design note for two-pass trim decode (#2), then concurrent detector children
   (#4).
