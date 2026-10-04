# Bug hunt: image processing and output

Scope: resize/fit/crop, effects, content-aware crop and detection, encoders, auto quality, colour, and the `ImagePipe.run` API in `image_pipe/` at `84eeac2`.

**How this was checked:** static review only. The cloud environment blocks `repo.hex.pm`, so `mise`/`mix` and the deps can't be installed and no test was run. "Code-checked" below means I re-read the cited lines myself and the reasoning holds; the others are from a reviewer pass and I checked them less closely.

## High confidence

### 1. Odd-sized `region` crops start 1px too far right/down
`lib/image_pipe/transform/operation/crop.ex:196-200` (code-checked)

The coordinate branch converts the origin to a centre and back: `center_x = round(left + w/2)`, then `left = round(center_x - w/2)`. `Kernel.round` rounds halves away from zero, so any odd width or height moves the origin by +1. `region=0,0,3,3` on a 10x10 image crops from (1,1). The contract says region origins are exact. All pixel-compared region tests use even sizes.
Fix: `left = clamp(left_px, 0, image_width - crop_width)` (same for top).

### 2. Single-axis `fit=stretch` is shrunk on load, then upscaled back
`lib/image_pipe/transform/executor.ex:747-755` → `decode_planner.ex:102-103` (code-checked)

The decode target ignores `fit`. For stretch, `executor/geometry.ex:78-81` keeps the `:auto` axis at full source size, but the planner shrinks by the one given axis. `w=500/fit=stretch` on a 4000x3000 JPEG decodes at 500x375 and stretches 375 rows back up to 3000: right size, badly blurred.
Fix: no decode target (or no shrink on the auto axis) for single-axis stretch.

### 3. Watermark failure leaks the staged source temp file
`lib/image_pipe/execution.ex:69-77` (code-checked)

When the main source is staged (`prepare_remote`) and `Watermarks.await/1` returns an error, the `else` branch cancels tasks and drops the context, including `acquisition.lease`. Callers only `Execution.close/1` after a successful prepare, so the temp file (up to `max_body_bytes`) and its `Resources` entry stay until the owner process exits, which for a keep-alive connection or a long-lived caller of `run/4` can be a long time. Trigger: HTTP source plus `watermark_source` pointing at a 404.
Fix: `SourceCache.release(context.acquisition.lease)` in that branch.

### 4. Bundled detectors get boxes in the wrong frame with `orient=none`
`lib/image_pipe/transform/detector/image_vision/face.ex:61-65`, `objects.ex:156-163`

With `orient=none` the detect crop runs on storage-frame pixels that still carry the EXIF `orientation` tag. `Image.FaceDetection.detect/2` autorotates and `Image.Detection.detect/2` thumbnails (which also autorotates), so boxes come back in the display frame. On an orientation-6 photo `orient=none/crop=1000,1000/detect=face` gets an x/y-swapped focal point, or the box fails the bounds filter and silently falls back to attention.
Fix: remove `orientation` before calling the library, as `terminal/lqip_css.ex:72` already does.

### 5. `info` reports unclamped result dimensions
`lib/image_pipe/processing/terminal.ex:171-196`

The image path applies `Output.Clamp` (`processing.ex:223`); info never does. `docs/processing/output.md:501` promises `result` matches "the image the same URL would return". A 9000x3000 JPEG with default limits reports 9000x3000; the image response is 8192x2731.

## Medium confidence

### 6. JPEG encoder limit is 65,535; libjpeg's maximum is 65,500
`lib/image_pipe/output/encoder.ex:29` (code-checked). Only reachable when a host raises `max_result_width/height` above 65,500: an axis of 65,501-65,535 passes the clamp and `jpegsave` fails with a 500.

### 7. `processing_timeout` above 60 s is ignored for image output
`lib/image_pipe/delivery/coordinator.ex:32,77` (code-checked). `Delivery.stream` waits for the first chunk with a hard-coded 60 s call, returning `{:session, :timeout}` (not the documented `{:processing, :timeout}`). Non-image terminals honour the configured timeout, so the same config behaves differently by terminal.

### 8. `bitonal` on 16-bit RGBA gives near-black output
`lib/image_pipe/transform/operation/bitonal.ex:34-41`. Colour bands become 8-bit 0/255 and are bandjoined back with the ushort alpha without rescaling. `gray.ex` and `brightness.ex` handle USHORT; bitonal doesn't. Trigger: `hdr=preserve/bitonal/format=png` on a 16-bit RGBA PNG.

### 9. `pixelate` averages alpha without premultiplying
`lib/image_pipe/transform/operation/pixelate.ex:47`. Blocks straddling a transparent edge pick up the colour of transparent pixels (usually black). Blur, sharpen and progressive blur all use `AlphaPremultiply.with_alpha_premultiplied`.

### 10. `output=blurhash` shrink-on-load changes fixed-pixel effects
`lib/image_pipe/transform/executor.ex:770-774`. A single-group blurhash decodes at up to 1/8. Crop coordinates are rescaled, but padding, watermark size, pixelate block size and blur/sharpen sigma are not, so `pad=200/output=blurhash` on a 4000x3000 photo pads ~45% of the frame instead of ~5%.

### 11. `ImagePipe.validate/2` misses watermark-source errors
`lib/image_pipe/run.ex:105-112` (code-checked). `validate/2` skips `Execution.watermark_sources/2`, a pure parse `run/4` does before reading. `watermark_source: "ftp://x/y.png"` validates `:ok` but `run/4` returns `{:invalid_source, {:unsupported_scheme, "ftp"}}`.

## Low impact

### 12. `Accept: image/webp;q=0.` is treated as q=1
`lib/image_pipe/output/negotiation.ex:100-104` (code-checked). `Float.parse("0.")` returns `{0.0, "."}`, which misses the `{q, ""}` clause and falls back to 1.0. RFC 9110 allows `0.`; WebP gets served to a client that refused it.

### 13. Byte-budget phase mislabels its result when the iteration budget is spent
`lib/image_pipe/output/encode_search.ex:299-310`. With a small `autoquality_max_iterations` plus `max-bytes`, the first cap probe returns `:capped` and the search jumps to the floor, labelling it `:best_effort`/`:max_bytes` even if a higher quality would fit. Metadata and telemetry only.

## Not confirmed
- Whether the SSIMULACRA2/Butteraugli NIFs accept 4-band CMYK (CMYK JPEG + `profile=preserve` + perceptual autoquality could fail). Needs the NIF source.
- A 1px tie-rounding mismatch for focus-point crops under mirrored deferred orientation. Real but very narrow.
