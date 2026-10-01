# Output DPI

Beads `image_plug-154`. Draft for agreement; nothing here is implemented.

## Summary

Add a request option `dpi=N` that writes N pixels per inch as the output's
physical density, and a host setting `stripped_dpi` (default `72`) that is
written whenever metadata is stripped and the request names no DPI. Density
is a header value only: it never changes pixels, dimensions, or DPR.

## Findings

Measured on libvips 8.18.7.

**imgproxy.** OSS `vips_strip` (`vips/vips.c`) resets `xres`/`yres` to 72 DPI
whenever it strips metadata. Pro adds `dpi:%dpi`, which replaces density
whether or not metadata is stripped (`0` means "leave it"), and
`IMGPROXY_STRIP_METADATA_DPI` (default `72.0`), the value written on strip.

**ImagePipe today leaks source density.** `Encoder.strip_metadata/2` removes
EXIF/XMP/IPTC fields but not the `xres`/`yres` header. A 300 DPI source
stripped with `meta=strip` still comes out at 300 DPI in JPEG, PNG, WebP, and
AVIF. A source with no density gets libvips' default of 1 px/mm, written as
about 25 DPI.

**One header drives every carrier.** On save, libvips rebuilds EXIF
`XResolution`/`YResolution` from `xres`/`yres`, and synthesizes an EXIF block
when none exists. Setting `xres`/`yres` before encode therefore covers each
format:

| Format | Where density is written |
| --- | --- |
| JPEG | JFIF APP0 and EXIF |
| PNG | `pHYs` and EXIF |
| JPEG XL | EXIF |
| WebP, AVIF | EXIF only |

Under `meta=keep`, a source EXIF block's `XResolution` is rewritten to match
the new header, so the two never disagree.

## Design

**Spelling.** `dpi=N` is a request-scope option, next to `meta` and `profile`.
N is an integer from 1 to 65535: the JFIF density field is 16-bit, and PNG
and EXIF store integers or rationals that integers fill exactly. One value
sets both axes. The URL builder takes `dpi:`.

**Host default.** `stripped_dpi` is a positive integer, default `72`, matching
imgproxy and replacing today's leaked or 25 DPI value. It applies only when
the resolved metadata policy strips (`strip` or `copyright`). Under
`meta=keep` with no `dpi`, source density is preserved, like the other source
metadata.

**Resolution.** `Output.RequestPolicy` resolves one effective value into a new
`Policy.dpi` field:

| Request | Metadata | `Policy.dpi` |
| --- | --- | --- |
| `dpi=N` | any | `N` |
| none | stripped | `stripped_dpi` |
| none | kept | `nil` (source density unchanged) |

`Policy.identity_material/1` includes `dpi`, so the cache key and the ETag
both change when the written bytes do. `Resolved` carries it to the encoder.

**Encode.** After `strip_metadata/2`, when `dpi` is set, the encoder sets
`xres`/`yres` to `dpi / 25.4` with a lazy `copy`. This is a header change: no
materialization and no pixel work, and every autoquality probe encodes the
same header.

**Out of scope.** The `blurhash`, `lqip-css`, and `info` terminals reject
`dpi` as inert, the same way they reject `meta`. DPR and resize do
not scale density: a `dpr=2` image keeps the requested DPI. Separate X and Y
densities and units other than inches are not offered.

## Tests

- `image_pipe_url`: parse and build `dpi`, range errors, order-insensitivity.
- `RequestPolicy`: the resolution table above, including host `stripped_dpi`.
- Representation: different `dpi` values give different keys and ETags;
  absent `dpi` under `keep` keys the same as today.
- Wire tests decoding JPEG, PNG, and WebP responses and asserting `xres` and
  EXIF `XResolution`: `dpi=300` under each `meta` value, the 72 DPI default on
  strip, and a 300 DPI source preserved under `meta=keep`.

## Other changes

- `Processing.Config` and `image_pipe_server` configuration: `stripped_dpi`.
- `docs/api_contract.md`: the `dpi` option and its interaction with `meta`.
- Fiddle: a DPI control in the output panel, wired into URL state.
