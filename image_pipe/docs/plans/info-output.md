# Info output and image-only options on non-image outputs

Beads `image_plug-heh` (decision) and `image_plug-cq7` (implementation).
Draft for agreement; nothing here is implemented.

## Summary

Extend `output=info` to describe both the source and the processed result:
the result's dimensions always, and its BlurHash and LQIP CSS value on
request. Non-image outputs (`info`, `blurhash`, `lqip-css`) accept image-only
output options, validate them as an image request would, and then drop them
before identity. A host can then take any valid image URL, change only
`output=`, and get a placeholder or a JSON description of the image it
would have served.

## Findings

**Use case.** A host stores an image URL per item, e.g.
`w=600/crop=.../format=webp/q=80/src/...`, and needs the final width and
height, a BlurHash, and an LQIP value, usually written once into its own
database. Today that takes three requests, and two of them fail with
`inert_option` unless the caller strips `format` and `q`, including values
inherited from presets it may not control. `info` rejects the transforms
outright, so it cannot report the final dimensions.

**Prior art.** Cloudinary (`fl_getinfo`) and Fastly IO (`format=json`)
return input and output metadata as JSON for a processed request. imgproxy's
info endpoint describes the source only.

**ImagePipe today.**

- `Plan.Spec.Validation.terminal_errors/2` rejects every key in
  `@image_options` for non-image outputs, and every group option and
  explicit `orient` for `info`.
- `Processing.Terminal` renders `info` from the header open and
  `SourceGeometry` alone: it never runs the executor, and `Decode` opens it
  without auto-rotation. BlurHash and LQIP run `Executor.execute/3`, then
  `Executor.reduce_terminal/3`, then compute from the reduced image.
- BlurHash adds a decode hint for single-group requests
  (`@blurhash_terminal_reduction`, 32×32), so shrink-on-load can decode a
  large source almost straight to the hash size. LQIP adds none.
- `Execution.Identity` gives `info` the material
  `[terminal: {:info, 1}] ++ page`, and placeholders their orientation, page,
  groups, terminal identity, and detector identity, with no output policy.

**Cost of each field.**

| Field | Work |
|---|---|
| Source facts (today's fields) | Header open only |
| Result width and height | Executor pipeline build. libvips is lazy, so geometric operations report their size without pixel work. Trim, smart crop, and detection materialize, as they already do. The orientation flush buffers for EXIF orientations 3–8. |
| BlurHash, LQIP CSS | The same work as the standalone outputs, including BlurHash's decode hint |
| Encoded format and byte size | A full encode and `Accept` negotiation. Out of scope. |

## Design

### Image-only options on non-image outputs

`blurhash`, `lqip-css`, and `info` accept every key in `@image_options`.
Validation runs as if the terminal were `image`, so `output_errors/1` still
reports `q` with `autoquality`, encoder options that disagree with `format`,
and `max-bytes`/`autoquality` with PNG. Malformed values still fail parsing.
Canonicalization then removes these keys, so they never reach the executor or
representation identity: `…/q=80/output=blurhash` and `…/output=blurhash`
share a cache entry and an ETag.

The rule hosts can rely on: a URL is valid with `output=blurhash`,
`output=lqip-css`, or `output=info` exactly when it is valid with
`output=image`, apart from the placeholder flags that only `output=info`
accepts (below).

Presets need nothing new: they expand before validation. The builder
(`ImagePipe.URL`) keeps emitting the options it is given. Its validation
shares `Plan.Spec.Validation`, so it accepts the same URLs the server does.

### Info accepts the full request

`info` accepts every group option, `orient`, and `page`. Groups apply as
they would for an image request, including watermarks, which matter for
placeholders.

### Response

```json
{
  "source": {
    "format": "jpeg",
    "mime_type": "image/jpeg",
    "width": 4000,
    "height": 3000,
    "orientation": 6,
    "pages": 1,
    "size": 2481920
  },
  "result": {
    "width": 600,
    "height": 450,
    "dpr": 1.0,
    "blurhash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
    "lqip_css": "#22333091"
  }
}
```

`source` carries today's fields unchanged: display dimensions from the EXIF
orientation, ignoring the request's `orient`. `result` is always present.
`result.width`/`height` are the dimensions of the executed display frame:
the size an image request for the same URL would encode, including DPR
scaling. With no groups, they equal the source display dimensions under the
request's `orient`. `blurhash` and `lqip_css` appear only when requested, and
equal what `output=blurhash` and `output=lqip-css` return for the same URL.

`result.dpr` is the effective DPR of the last group, after the enlargement
clamp. A caller cannot derive it from its URL: without `enlarge`,
`w=100/dpr=2` on a 150px source yields a 150px image at effective DPR 1.5,
so the CSS width is 150 / 1.5 = 100. With no resize it is the last group's
requested DPR (1 by default). Reporting the
DPR rather than CSS dimensions keeps the value exact and leaves rounding to
the caller.

DPR is a group parameter that does not carry forward, so the last group's
DPR is the scale its own lengths were written in: `w=100/dpr=2/-/pad=10`
reports 220px at DPR 1, and `w=100/dpr=2/-/pad=10/dpr=2` reports 240px at
DPR 2 (CSS 120). The value is exact for single-group requests and for
multi-group requests whose earlier groups were not clamped. An earlier
group's enlargement clamp is not reflected: `w=100/dpr=2/-/pad=10/dpr=2` on
a 150px source reports 190px at DPR 2, although the intended CSS width is
120. The contract states this limitation.

### Requesting placeholders

`output` takes trailing flags after `info`, following the leading-mode
comma lists used by `autoquality` and `colorize`:
`output=info,blurhash,lqip-css`. The flags are the placeholder output
names; duplicates are rejected and the list is canonicalized to a sorted
set. Other outputs take no flags, so the grammar rejects a misplaced flag as
an invalid `output` value rather than an inert option. The builder spells it
`terminal: {:info, [:blurhash, :lqip_css]}`; `Plan.Spec.Output` carries the
list next to `terminal`.

Placeholders are opt-in because each one forces decode and reduction work,
while result dimensions alone usually do not.

### Execution

- **No operations and no LQIP CSS:** today's header-only path. `result`
  copies the source display dimensions under the request's `orient`. A request
  without transform options still has one empty group, so the test is
  `Executor.operation_names/1 == []`, not an empty group list.
- **Otherwise:** decode with the request's orientation and no terminal
  decode hint, then `Executor.execute/3`. `result` dimensions and DPR are
  read from the executed state; libvips is lazy, so this usually computes no
  pixels. LQIP CSS has no decode hint, so it reduces this executed state with
  `reduce_terminal/3` and matches `output=lqip-css` exactly.
- **BlurHash:** a second decode of the same fetched input, planned as
  `output=blurhash` plans it (including the 32×32 decode hint for
  single-group requests), then `execute/3` and `reduce_terminal/3`. The hash
  is identical to `output=blurhash`. The hint cannot share the first decode:
  it shrinks the decode toward 32×32, which would make the result
  dimensions wrong.

A stream-backed source body can be drained only once, so `info` fetches
through `Decode.with_seekable/3`, which drains the body once into a path or
buffer, and passes that to each `Decode.with_image` call. Both decodes run
inside one `Source.with_fetched/3` bracket, and each emits its own
`[:source, :fetch_decode]` span. The groups run twice, which
costs real pixel work only for operations that materialize (trim, smart crop,
detection, EXIF orientations 3–8). Detection running twice is the worst
case, and only when a BlurHash is requested.

Source safety limits apply as for the placeholder outputs. Static result
dimension limits apply as they do for placeholders today.

### Identity

`info` representation material becomes `orient`, `page`, canonical groups,
`terminal: :info`, the canonicalized placeholder list, and detector identity,
following the placeholder clause in `Execution.Identity`. No output policy
and no `Vary: Accept`; the content type stays `application/json`.
Greenfield: reshape the material in place without bumping a version.

### Telemetry

The `[:output, :terminal]` span gains `placeholders` (the canonical
placeholder list) for `info`. Update the default Logger rendering, add the key
to `Capture`'s `@safe_keys`, and keep `docs/telemetry.md` in step.

### Demo app

The fiddle's info preview renders the `source`/`result` shape, and its
controls stop disabling group and output options for non-image outputs. Add
the placeholder flags.

## Contract changes

- Validation row in the summary table: inert options are rejected, except
  image-only output options on non-image outputs, which are validated and
  ignored.
- The paragraph saying BlurHash and LQIP CSS reject quality, search, budget,
  and encoder options: they now accept and ignore them.
- The `output=info` paragraph: rewritten around `source`/`result`, the
  placeholder flags, `result.dpr` and its multi-group limitation, and the
  cost of each field.
- The skip-processing paragraph already processes every `info` request; no
  change.

## Tests

- Parser and builder: image-only options accepted for each non-image output;
  output-option conflicts still rejected for them; placeholder flag
  validation and canonicalization; flags after any other output rejected. Replace the
  existing `inert_option` assertions for these cases, including
  `preset_composition_test.exs` (`output=blurhash/format=png`).
- Identity: requests differing only in image-only options share material;
  `info` requests differing in groups, `orient`, `page`, or flags do not.
- Wire: `info` with a resize/crop returns the decoded dimensions of the
  matching `output=image` response; EXIF orientation 6 with and without
  `orient`; `output=info,blurhash,lqip-css` returns the same strings as
  `output=blurhash` and `output=lqip-css` for the same URL, with one source
  fetch; `result.dpr` under the enlargement clamp and for a multi-group
  request that restates `dpr`; a header-only request
  makes no executor call; parse errors still fail before source fetch.

## Open questions

- Encoded `format`/`size` in `result`: a later opt-in that would add
  negotiation and `Vary: Accept`.
