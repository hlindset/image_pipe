# Resize kernel selection

Beads `image_plug-al7`. Draft for agreement; nothing here is implemented.

## Summary

Add a group option `kernel=NAME` that picks the libvips kernel the group's
resize uses. Without the option, nothing changes: resize uses `lanczos3`, as
today. `kernel=nearest` also turns off shrink-on-load, because the JPEG and
WebP load shrinks filter the image and would defeat a nearest-neighbour
request.

## Findings

Measured on libvips 8.18.7, downscaling `high_freq.jpg` (1600×1200) to 300 px
wide with `vips_resize`.

**All eight libvips kernels are reachable through Vix.** `Image.resize/3`
accepts only six (`Image.Kernel` lacks `mks2013` and `mks2021`), but
`Vix.Vips.Operation.resize/3` takes every `VipsKernel` value.

**The kernels differ visibly; cost doesn't.** Mean absolute difference from
`lanczos3`, and time per sequential decode-plus-resize:

| Kernel | Mean \|Δ\| | Time |
| --- | --- | --- |
| nearest | 13.9 | 15 ms |
| linear | 14.5 | 9 ms |
| cubic | 4.6 | 9 ms |
| mitchell | 11.7 | 10 ms |
| lanczos2 | 4.5 | 9 ms |
| lanczos3 | 0 | 13 ms |
| mks2013 | 5.8 | 10 ms |
| mks2021 | 2.3 | 10 ms |

Every kernel is within the noise of the current default, so the option adds
no speed risk.

**Shrink-on-load breaks `nearest`, not the others.** Comparing a resize from
the full decode with one from a `shrink=4` JPEG decode:

| Kernel | Mean \|Δ\| full vs shrink=4 |
| --- | --- |
| nearest | 20.9 |
| lanczos3 | 3.3 |

The JPEG DCT shrink and WebP `scale` load both average source pixels, so a
`nearest` result from a shrunk decode has blended colours. That defeats the
usual reason to ask for `nearest`: pixel art and hard-edged graphics. For the
filtering kernels the shrink costs about what it costs `lanczos3` today.

**imgproxy** exposes `resizing_algorithm` (Pro) with `nearest`, `linear`,
`cubic`, `lanczos2`, and `lanczos3`, default `lanczos3`, as a request option
only.

## Design

**Spelling.** `kernel=NAME` is a group option, next to `fit` and `enlarge`.
NAME is one of `nearest`, `linear`, `cubic`, `mitchell`, `lanczos2`,
`lanczos3`, `mks2013`, `mks2021`. The builder takes it with the resize options
(`ImagePipe.URL.group(resize: [width: 400, kernel: :nearest])`).

**Plan.**

- The group's `resize` map gains `kernel`.
- `lanczos3` is the identity and canonicalizes to absent, the way the other
  default-valued options do, so `kernel=lanczos3` and no option share a cache
  key and ETag.
- Without resize intent, `kernel` is an inert option (`422`), like `fit`.

**Execution.**

- `Transform.Operation.Resize` gains `kernel` and calls
  `Vix.Vips.Operation.resize/3` with it, so all eight kernels work.
- Only the group's resize uses it. Rotation, pixelate, terminal reductions
  (blurhash, LQIP), and the content classifier keep their own resampling.

**Shrink-on-load.** `DecodePlanner.Request` gains `nearest?`, set when the
first group's resize asks for `kernel=nearest`; the planner then returns no
shrink, as it does for trim. Other kernels keep shrink-on-load.

**Cache and ETag.** The kernel is canonical plan material, so it changes the
key and the ETag with no extra work. There's no host default, so no host
setting joins the key.

**Telemetry.** The `[:transform, :operation]` span already carries the
operation struct, which now includes `kernel`. No new event.

**Fiddle.** A kernel select beside the resize controls, in the URL state.

**Speed.** Requests without `kernel` call the same libvips operation with the
same kernel as today. Switching from `Image.resize/3` to
`Operation.resize/3` drops the wrapper's option validation and nothing else;
check it with the usual A/B.

## Tests

- Wire tests, decoding the response:
  - `kernel=nearest` and `kernel=linear` downscales each differ from the
    default in pixels;
  - a `kernel=nearest` downscale of a JPEG returns only colours present in
    the source (proves shrink-on-load is off);
  - a `kernel=nearest` upscale of a 2×2 checkerboard stays hard-edged.
- Decode planner: `nearest?` gives no shrink; other kernels keep it.
- Cache identity: `kernel=nearest` and `kernel=linear` get different keys;
  `kernel=lanczos3` and absent share one.
- `kernel` without resize fails with `422` before source fetch.
- The grammar round-trips between the builder and the parser. Extend the
  existing property tests.

## Open decisions

1. **Request option or host default.** Recommendation: request option only.
   A host default would join the cache key and ETag and change every request's
   output; no host has asked for one. Add it when one does.
2. **Spelling.** Recommendation: `kernel=NAME`, using libvips' names. imgproxy's
   `resizing_algorithm` is long and omits three kernels.
3. **Kernel set.** Recommendation: all eight. The MKS kernels cost nothing
   extra, and `mks2021` is the closest to `lanczos3` with less ringing.
4. **Shrink-on-load.** Recommendation: off for `nearest` only. Turning it off
   for every non-default kernel would slow those requests to keep a 3-level
   difference that `lanczos3` already accepts.
5. **Groups.** Recommendation: per group, like `fit`. Only the first group's
   kernel affects shrink-on-load, because only the first group's resize
   drives the decode.
