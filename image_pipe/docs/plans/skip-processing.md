# Skip processing

Beads `image_plug-0f2`. Draft for agreement; nothing here is implemented.

## Summary

Add a host setting `skip_processing_formats`. When a source's signature
names a listed format and the request would deliver that same format,
ImagePipe streams the source bytes unchanged instead of decoding,
transforming, and encoding. Other requests are processed as usual.

## Findings

**imgproxy.** `skip_processing:%ext...` (request) and
`IMGPROXY_SKIP_PROCESSING_FORMATS` (host) skip processing when the source
format is listed and the output format is either unset or equal to the
source format (`processing/processing.go`, `shouldSkipStandardProcessing`).
Skipping is decided before Accept-based WebP/AVIF preference, so a skipped
GIF stays a GIF for a client that accepts AVIF. imgproxy still checks source
resolution before skipping, to avoid sending an image bomb to the client.

**ImagePipe today.** Decode reads a bounded peek of the source and
classifies it with `Format.Detector` before any libvips call
(`Decode.decode/4`). The peek is available for every input form: a file
path (input cache or spooled download), a buffer, or an overlapped download
prefix.

Output formats are `jpeg`, `png`, `webp`, and `avif`. `gif`, `tiff`, `heif`,
`jpeg_xl`, and `jpeg2000` are source-only, so they can only be skipped when
the request names no `format`.

## Design

**Configuration.** `skip_processing_formats` is a list of source formats
from `Format.source_formats/0`, default `[]`. It is a server option next to
the output defaults. It has no URL spelling: a request cannot opt itself out
of the host's metadata or watermark policy.

**Eligibility.** A request is skipped when all of these hold:

1. The terminal is `image`.
2. The request draws no watermark. A watermark protects the image, so a
   request that asks for one is always processed.
3. The format detected from the source signature is in
   `skip_processing_formats`.
4. The request has no explicit `format`, or its explicit `format` equals the
   detected format. Accept negotiation does not block a skip, as in
   imgproxy: an AVIF-capable client gets a skipped GIF as `image/gif`.

Otherwise the request is processed normally. A skip never produces an error
of its own.

**No image validation.** A skipped source is not opened by libvips, so the
loader check, `max_input_pixels`, frame limits, and result limits do not
apply. Those limits bound ImagePipe's own decode and encode work, and
skipping does none. A corrupt or oversized file in a listed format is
served as the origin has it. Source fetching keeps its own bounds: adapter
timeouts, redirect limits, origin and root restrictions, and
`max_body_bytes`.

**Ignored options.** A skipped request ignores every group option, `orient`,
`page`, and every output option, including `meta`, `profile`, `hdr`, `dpi`,
and quality. The response carries the source's metadata. This is the reason
the setting is host-only, and the docs say so plainly. Parsing still
validates all options before any source access, so a malformed request fails
the same way whether or not its source would be skipped.

**Where it runs.** `Output.Policy` decides eligibility from the detected
format (`Policy.skip?/2`), since it already owns explicit-versus-negotiated
format selection. `Decode` checks it right after classifying the peek and,
when it passes, returns the input without opening it. `Processing` then
streams the source bytes in chunks through the usual pump. `[:transform,
:execute]` and `[:encode]` do not run. Overlapped preparation returns the
same skipped result, and the resumed build streams the completed spool
file.

**Response headers.** `Content-Type` is the detected format's MIME type.
Skipped responses carry `X-Content-Type-Options: nosniff`, so a file whose
signature merely looks like a listed format is still treated only as that
image type. `Response.Disposition` gains extensions for the source-only
image types.

**Identity.** `skip_processing_formats` enters `Policy.identity_material/1`,
so the cache key and ETag change when the host changes the list. The ETag is
still computed before fetch from the request, the negotiated selection, and
the source identity. Skipped responses keep the same `Vary: Accept` as
processed ones, because eligibility is unknown before the fetch.

**Caching.** Skipped responses are not written to the output cache. The
bytes are exactly the source bytes, which the input cache already stores
when the source is cacheable. The output-cache lookup still runs, because
eligibility is known only after the fetch. Conditional requests still
return `304` before fetch when the source identity is trustworthy.

**Native API.** `ImagePipe.run/4` returns a skipped result as
`%Result{terminal: :image}` with the source bytes and detected format. Its
`width` and `height` come from a header read of the returned bytes, as for
any result without debug dimensions.

**Telemetry.** The `[:source, :fetch_decode]` and `[:deliver]` stop
metadata gain `skipped: true` when a request is skipped. The default Logger
shows it, and `Telemetry.Trace.Capture` adds it to `@safe_keys`. No new
events.

## Out of scope

- A request-level `skip` option. Add it if a host needs per-request control,
  bounded by the host list.
- Raw output of arbitrary source files. A host app can serve originals
  itself; revisit for `image_pipe_server` if a concrete need appears.
- Stripping metadata from skipped responses. That needs an encoder pass,
  which skipping exists to avoid.

## Tests

- `Policy.skip?/2`: the eligibility table above, including explicit format
  and negotiation.
- Wire tests: a listed GIF with `w=100` returns the source bytes exactly as
  `image/gif` with `nosniff`, under an AVIF `Accept`; `format=png` on a
  listed GIF processes; a watermarked request processes; an unlisted format
  processes; a corrupt listed GIF and one above `max_input_pixels` are
  served unchanged; `max_body_bytes` still rejects an oversized source;
  decode and encode telemetry spans do not fire for a skip; `304` on a
  matching ETag.
- Representation: changing `skip_processing_formats` changes the key and
  ETag.
- A skipped response stores no output-cache entry.

## Other changes

- `docs/api_contract.md`: `skip_processing_formats` and what a skip
  ignores. `docs/configuration.md` and `docs/telemetry.md` to match.
- `image_pipe_server`: `skip_processing_formats`.
- Fiddle: no URL option changes. The fiddle host may list a format to
  demonstrate skipping.
