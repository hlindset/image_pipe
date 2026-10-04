# Design note: shrink-on-load for trim requests

Status: proposal, not implemented. Source: perf review item 2
(`/mnt/project-files/perf-review/image-processing.md`).

## Problem

`DecodePlanner.compute_load_shrink_for_request/3` returns `1.0` whenever the
request trims, because the trimmed extent is unknown when the decode is
planned. A request such as `trim/w=600` on a large JPEG therefore decodes the
whole source at full size, materializes it (`Trim.requires_materialization?/1`),
and runs `find_trim` over every pixel before resizing.

The review measured a 24 MP baseline JPEG with a white border, `trim` then
`w=600` (pyvips, libvips 8.15, 4 cores):

| decode shrink | 1 (today) | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| request time | 1315 ms | 475 ms | 186 ms | 103 ms |

The same request without trim runs in 73 ms at shrink 8.

Only JPEG (DCT shrink) and WebP (`scale`) have shrink-on-load, and progressive
JPEGs gain little from it, so the win is limited to large baseline JPEGs and
WebPs. Those are common camera and CMS outputs.

## Proposal: plan the shrink from a preview trim

Trim detection is input conditioning: its result comes from the decoded
pixels, which no operation struct can see. So the extra pass belongs in
decode planning, next to `crop_extent`, not in a new transform operation.

1. **Preview.** When the first group trims and the planner would shrink by 2
   or more without trim, `ImagePipe.Decode` opens a cheap preview at the
   largest load shrink the format offers (JPEG `shrink: 8`, WebP `scale`),
   orients it the way the executor does before trim, and runs the same trim
   detection (`Trim` prepare, background, threshold, symmetry) on it.
2. **Plan.** The preview box, grown by one preview pixel on each side and
   clamped to the source, scaled back to source pixels, becomes a new
   `trim_extent` on `DecodePlanner.Request`. The planner treats it like
   `crop_extent`: the shrink ratio is computed from the trimmed extent
   against the resize or terminal target. `DecodePlanner` stays pure.
3. **Decode and trim.** The real decode opens at that shrink. The executor's
   trim runs unchanged on the shrunk image, so the box is found again at
   decode resolution rather than reused from the preview. Later crops and
   resizes already rescale through `state.decode_shrink`.

Running `find_trim` again in step 3 keeps one trim implementation and keeps
the preview's only job to choose a shrink. The preview can be wrong without
corrupting the output: it can only make the shrink too large or too small.

## What changes in the output

- Trim edges land on decode-shrink pixel boundaries. The shrink never exceeds
  the resize ratio, so the error is under one output pixel. Region crops
  already accept the same tradeoff.
- `find_trim` runs on DCT-downscaled pixels. Near the threshold, a soft edge
  can trim one pixel differently from full resolution.
- Trim goldens and imgproxy reference comparisons that trim a shrinkable
  source move. They need re-baking with this change listed in their
  `changes_with`.

Requests without a resize or terminal target, sources without shrink-on-load,
and trims in later groups decode exactly as today.

## Risks and open questions

1. **Preview misses detail.** A thin line visible at full size can vanish at
   shrink 8, so the preview trims more than the real decode. The one-pixel
   margin covers 8 source pixels. Beyond that, the real decode keeps the
   larger box and the planned shrink is slightly too large, which means a
   small upscale. Options: accept it, plan with one step of headroom (shrink
   4 where the ratio allows 8), or re-decode at full size when the step-3 box
   is larger than planned. Recommendation: headroom, because it never costs
   a second decode.
2. **Preview cost.** A shrink-8 preview of a 24 MP baseline JPEG costs about
   70 ms. Skip the preview when the planned shrink without trim is under 2,
   where it can't pay for itself.
3. **Orientation.** The preview runs in the storage frame. The box must be
   mapped through the pending EXIF orientation the same way
   `Geometry.orient_decode_shrink/2` maps shrink axes.
4. **Telemetry.** The preview is a new stage. It needs a span (for example
   `[:decode, :trim_preview]`) added to the default Logger and to
   `Trace.Capture`'s stage lists, with `docs/telemetry-events.md` and
   `docs/tracing.md` updated.

## Tests

- Planner unit and property tests: `trim_extent` sizes the shrink like
  `crop_extent`, and never shrinks below the target.
- A request-boundary test on a bordered baseline JPEG: trimmed output
  dimensions match today's to within one output pixel, and pixels match
  within a small tolerance.
- The sequential-safety gate for the preview open (streamed source,
  `fail_on: :error`).
- A latency benchmark on a baseline JPEG fixture. Every JPEG in
  `priv/static/images/` is progressive, so it needs a baseline copy.

## Decision needed

Accept shrink-precision trim edges and re-baked trim goldens in exchange for
roughly 5 to 12 times faster trim-and-resize on large baseline JPEGs, and pick
the answer to open question 1.
