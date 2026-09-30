# Loader allowlist for source decode

Beads `image_plug-8ly`. Draft for agreement; nothing here is implemented.

## Summary

Decode lets libvips choose a loader by sniffing, and checks the choice only
afterwards, if at all. Any loader compiled into the host's libvips can therefore
parse untrusted bytes before ImagePipe rejects them: ImageMagick, poppler,
librsvg, libraw, and libvips' own untrusted loaders.

Proposal:

- Reject sources the detector doesn't recognise before any libvips call.
- Verify that the loader libvips picks belongs to the detected family.
- For TIFF file inputs only, check the loader before opening, because
  libraw's loader outranks `tiffload` there.
- Extend the detector for the legitimate formats that reach the fallback today
  (BigTIFF).

The common path gains one header lookup. Only TIFF from a file pays for a
loader sniff.

## Current behavior

In `ImagePipe.Decode.decode/4`, the magic-byte detector names a family. GIF,
BMP, ICO, and recognisable SVG are rejected. Everything else, including
`:unknown`, goes to the random-access header open, where libvips picks a loader
by priority-ordered `is_a` sniffing. The loader is checked afterwards only for
AVIF/HEIF (codec split) and `:unknown` (`resolve_source_format/2`). The
authoritative families (JPEG, PNG, WebP, TIFF, JPEG 2000, JPEG XL) never look
at the loader.

Measured on Homebrew libvips 8.18.6 (built with ImageMagick, poppler, librsvg,
and libraw):

| Input | Detected | libvips picks | Today |
| --- | --- | --- | --- |
| AVIF sequence (`avis` brand) | `:unknown` | magickload | ImageMagick's `is_a` alone takes 364 ms, then it loads; `415` |
| PDF | `:unknown` | pdfload (poppler) | parsed, then `415` |
| gzip-compressed SVG (svgz) | `:unknown` | svgload (librsvg) | parsed, then `415`; the SVG gate can't see through gzip |
| SVG with a prolog over 32 KiB | `:unknown` | svgload | same; the root is beyond the peek |
| PPM | `:unknown` | ppmload (untrusted) | parsed, then `415` |
| BigTIFF | `:unknown` | tiffload | accepted through `:libvips_fallback` |
| UltraHDR JPEG | `:jpeg` | uhdrload | accepted as `:jpeg`; same size, bands, and format as `jpegload` in the test sample |
| TIFF-magic RAW (a crafted DNG), from a file named `.dng` | `:tiff` | dcrawload (libraw, untrusted) | reaches libraw; would be accepted as `:tiff` if it decodes |
| The same DNG, from a file named `.tif` | `:tiff` | tiffload | decoded as a TIFF |
| The same DNG, from a buffer | `:tiff` | tiffload | decoded as a TIFF |

File inputs matter: file sources and the input cache hand Decode a path, and
libvips' file sniffing reaches loaders its buffer sniffing doesn't. The RAW
loader claims TIFF-signature files by file name, so the exposure is a file
source serving RAW-named files.

The server image builds libvips from source with auto-detected dependencies.
Its apt packages include `librsvg2-dev` and `libgif-dev` but no ImageMagick,
poppler, libraw, or OpenEXR. So the server exposes librsvg (both SVG bypasses
above), plus the built-in untrusted loaders (ppm, rad, vips, analyze).
ImagePipe never renders SVG itself, so librsvg serves no purpose there. The
image also lacks OpenJPEG, so JPEG 2000 sources fail there even though
`Format` accepts them.

Two libvips facts shape the options:

- libvips marks `jxlload` and `jp2kload` untrusted. `VIPS_BLOCK_UNTRUSTED`
  would therefore drop JPEG XL and JPEG 2000, which ImagePipe accepts, so it
  can't be the fix as-is.
- `Vix.Vips.Foreign.find_load_buffer/1`, `find_load/1`, and
  `find_load_source/1` run the `is_a` sniffers and return the loader name
  without loading. Best of 200: 13–32 µs from a buffer and 52–239 µs from a
  file (JPEG is the slow one), against a 130–154 µs header open. For unknown
  input the sniff falls through to ImageMagick's `is_a`, which is itself the
  364 ms cost above.

imgproxy's open-source version never sniffs. `Image.Load` in `vips/vips.go`
calls the loader for the detected type, and any other type is an error.

## Options

**A. Reject unknown up front and verify the loader after the header open.**
`gate_detected/1` rejects `:unknown` along with the named families. After the
header open, the `vips-loader` header must map to the detected family (extend
`SourceFormat.classify_loader/2`, with AVIF/HEIF treated as one family). This
adds one `header_value` lookup. Residual gap: a higher-priority competing
loader still runs its header parse before the check. Two exist:
uhdrload for JPEG, which we'd allow anyway, and dcrawload for TIFF-magic files
from a path.

**B. A, plus a pre-open sniff for TIFF file inputs.** Call `find_load/1`
before the open when the family is `:tiff` and the input is a path, and reject
anything but tiffload. That closes libraw and costs about 50–240 µs on TIFF
file inputs only.

**C. Call each family's loader directly** (`Vix.Vips.Operation.jpegload_buffer/2`
and so on). This forces `tiffload` for RAW-in-TIFF and can open `avis` through
heifload; `heifload_buffer` opened the test sequence at 64×48. But Vix
generates these functions from the linked libvips at compile time, so a family
missing from a host's build becomes an `UndefinedFunctionError` rather than a
`415`. It would need a boot capability probe, and it covers 7 families × 3
input kinds, including the streaming source variant. It means more code for no
speed gain.

Recommendation: B. C only if AVIF sequences or RAW become wanted inputs.

Measured after implementing B (A/B in one VM, 300 samples each, three runs):
JPEG and PNG requests moved −0.3% to +1.9% with no consistent sign. TIFF from a
file gained 136–265 µs (+1.4% to +2.8% on a ~10 ms request), which is the
pre-open sniff.

## Detector and allowlist

- Add BigTIFF signatures (`II+\0`, `MM\0+`) to `:tiff`.
- Name the AVIF sequence brand `avis` as a rejected family (like `:gif`), so it
  fails before libvips with a precise `detected_source_format`.
- Before shipping, check what real traffic takes the fallback: the
  `[:source, :fetch_decode]` stop already reports
  `source_format_resolution: :libvips_fallback`. Formats that show up there
  become detector entries, not fallback cases.
- The allowlist per family:

  | Family | Loaders |
  | --- | --- |
  | JPEG | jpegload, uhdrload |
  | PNG | pngload |
  | WebP | webpload |
  | TIFF | tiffload |
  | HEIF/AVIF | heifload |
  | JPEG XL | jxlload |
  | JPEG 2000 | jp2kload |

  GIF adds gifload when `image_plug-qfe` lands.
- Streaming decode already requires the sniffed loader to match the detected
  JPEG or PNG (`Decode.Streaming.eligible?/1`), so it needs no change.

## Errors and telemetry

- Unknown input keeps its current result, `{:decode, {:unsupported_source_format,
  :unknown}}` → `415`, but now with no libvips call.
- A loader mismatch is `{:decode, {:unsupported_source_format, family}}` with
  `detected_source_format` set, plus a new `source_loader` stop-metadata key.
  The key holds the libvips loader name, which is non-sensitive. It is needed
  so operators can see, for example, "tiff, rejected: dcrawload". Add it to the
  Logger rendering and the `Capture` allowlist, per AGENTS.md.
- `source_format_resolution: :libvips_fallback` disappears. `docs/telemetry.md`
  changes accordingly.

## Tests

The wire tests use a recording `:buffer_loader` / `:image_open_module`, so a
rejection can assert that no libvips open happened:

- svgz, SVG with a long prolog, PPM, PDF bytes, `avis`, and random bytes return
  `415` with no loader open.
- BigTIFF returns `200` as `:tiff`.
- The crafted DNG from a file source returns `415` without reaching dcrawload.
  The sniff is observable through the recorder, and the test runs only where
  libvips has dcrawload; elsewhere it still asserts `415` or `200` as a TIFF,
  depending on the build.
- An UltraHDR JPEG returns `200` as `:jpeg`, where the host libvips has
  uhdrsave to build the fixture.
- Add a latency A/B for TIFF file inputs (the only path that gains a sniff), in
  the same style as the frame-gate PR.

## Decisions

Agreed 2026-09-30:

1. Scope: B.
2. UltraHDR: accept uhdrload for JPEG.
3. AVIF sequences: reject `avis` as a named family before libvips.
4. RAW in TIFF: reject.
5. No global loader allowlist.
6. Server image: drop `librsvg2-dev` and explicitly disable unused loaders in
   the libvips build. JPEG 2000 support in the server image stays a separate
   question.
