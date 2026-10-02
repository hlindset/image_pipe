# Telemetry event reference

[Telemetry setup](telemetry.md) · [Tracing](tracing.md)

## Event names

Events use `:telemetry.span/3` naming conventions. Every span emits a `:start`
event and then either a `:stop` event for normal completion or an `:exception`
event for a raised exception:

```text
telemetry_prefix ++ stage ++ [:start]
telemetry_prefix ++ stage ++ [:stop]
telemetry_prefix ++ stage ++ [:exception]
```

ImagePipe also emits stage spans for meaningful request phases. The exact set
depends on the routing path. Conditional `304` responses and internal cache
hits skip the fetch/decode, transform, and encode generation stages. Response
paths still emit the send span; streamed generation also emits delivery spans.

```text
[:image_pipe, :parse, ...]
[:image_pipe, :preset, :lookup, ...]
[:image_pipe, :source, :resolve, ...]
[:image_pipe, :cache, :lookup, ...]
[:image_pipe, :processing, :admission, ...]
[:image_pipe, :processing, :execute, ...]
[:image_pipe, :output, :negotiate, ...]
[:image_pipe, :output, :terminal, ...]
[:image_pipe, :source, :stage, ...]
[:image_pipe, :source, :fetch, ...]
[:image_pipe, :source, :fetch_decode, ...]
[:image_pipe, :source, :watermark, ...]
[:image_pipe, :transform, :execute, ...]
[:image_pipe, :transform, :input_color_management, ...]
[:image_pipe, :transform, :operation, ...]
[:image_pipe, :transform, :materialize, ...]
[:image_pipe, :encode, ...]
[:image_pipe, :encode, :search, ...]
[:image_pipe, :encode, :classify, ...]
[:image_pipe, :cache, :write, ...]
[:image_pipe, :send, ...]
[:image_pipe, :deliver, ...]
```

### Processing admission and execution

With a configured [processing pool](processing-controls.md), generation misses
emit `[:processing, :admission]` and `[:processing, :execute]` spans. Admission
measures queue wait and reports `:admitted`, `:overloaded`, `:queue_timeout`,
`:cancelled`, `:worker_down`, or `:unavailable`. Execution measures the admitted
lifetime, including streamed demand pauses and cleanup, and reports `:ok`,
`:processing_error`, `:timeout`, `:cancelled`, `:worker_down`, or `:unavailable`.
The pool emits the stop event on worker death as well as ordinary completion.

Start metadata includes `:active` and `:queued` counts before this admission or
execution transition. Cache hits and conditional responses skip both spans.
Execution inherits the request trace and parents the generated stage spans.
Successful admission has trace status `:ok`; rejection and timeout have `:error`.

The default Logger subscribes to both under its `:request` group, renders the
result, and escalates overload, queue/processing timeout, unavailability, worker
failure, and processing errors to `:warning`.

### Request span (`[:request]`)

The request span wraps the whole request, starting before parsing.
Start metadata is empty.
Direct `ImagePipe.run/4` calls also emit this span, enclosing plan preflight
and the shared source/decode/transform/output stages. Their stop metadata has
the same outcome categories, with no HTTP `:status`. Direct calls emit no
parse, send, or HTTP delivery stages. `ImagePipe.write/5` performs its
destination write after the processing request span and source cleanup.

Stop metadata:

- `:result` — the request outcome category (see [result values](#result-values)).
- `:status` — the response status.
- `:error` — a stable error category on failures.

When a committed `200` fails mid-stream, the stop `:result` agrees with the
`[:send]` stop rather than the pre-delivery outcome.

### Parse span (`[:parse]`)

The `[:image_pipe, :parse]` span wraps the Plug's signature verification,
source decryption, and URL parsing. Its
**start metadata is empty**. Stop metadata contains `:result` (`:ok` or
`:error`); successful parsing also includes `:sig_key_index`, or `nil` for
an unsigned request. Rejection reasons appear on the enclosing request span.

### Preset lookup span (`[:preset, :lookup]`)

Emitted only when a request selects names the static preset map does not
define, inside `[:parse]` for Plug requests and `[:request]` for direct
execution. Start metadata contains `:names`, the names of the first batch.
Stop metadata contains `:result` (`:ok` or `:error`), `:fetched` (definitions
returned by the lookup), and `:batches` (calls to `fetch/2`); failures add
`:reason` (`:lookup_unavailable` or `:invalid_definition`). The default Logger
logs failures at `:warning`.

### Source fetch + decode (`[:source, :fetch_decode]`)

This span wraps source fetch, decode, and body/pixel/frame limits. It closes
when decoded state is built, before transforms and encoding run. HTTP and S3
originals are downloaded earlier, in `[:source, :stage]`, so their fetch and
body failures stop that span instead.

`output=info` with the `blurhash` flag decodes the fetched source twice: once for
the result facts and once with BlurHash's own decode plan. It emits two
`[:source, :fetch_decode]` spans inside one source fetch; the second wraps decode
only.

libvips is lazy, so a separate decode span would time loader construction rather
than pixel work. Decode and guard outcomes therefore appear on this span's stop
metadata; real pixel work is timed by materialization and encode spans.

For file sources, the nested `[:source, :fetch]` span (source side effects
only) lives inside it.

Success stop metadata:

- `:result` — `:ok`.
- `:load_option` — the shrink-on-load option chosen, `{:shrink, n}`, `{:scale, f}`, or absent when none.
- `:achieved_shrink` — `%{w: float, h: float}` realized shrink, when shrink-on-load fired.
- `:original_dims` — `{w, h}` of the stored image before decode.
- `:loaded_dims` — `{w, h}` actually decoded.
- `:detected_source_format` — the format the up-front detector returned from the
  header peek (`:jpeg`, `:png`, …, or `:unknown`).
- `:source_format_resolution` — how the final `source_format` was decided:
  `:detected` (the signature named the family) or `:libvips_codec` (the
  AVIF-vs-HEIF split read from libvips).
- `:source_frames` — the number of frames or pages the source declares (libvips
  `n-pages`, `1` for a still image). Only one is decoded.
- `:page` — the page or frame the request selected with `page=N`; absent when
  the request decodes the source's default image.

A source delivered unchanged under `skip_processing_formats` stops the span
with only `:result` (`:ok`), `:detected_source_format`, and `skipped: true`:
no libvips call, image guard, transform, or encode runs for it.

Failure stop metadata:

- Source-side failure — `:result` is `:source_error`; `:error` is a stable
  category atom (e.g. `:body_too_large` when the source body crosses
  `:max_body_bytes`). HTTP fetch failures are classified rather than collapsed
  so an observer can tell them apart: `:connect_error` (DNS/TLS/refused/connect
  or pool timeout/startup failure), `:receive_timeout` (origin stalled mid-body),
  `:truncated_body` (closed before a framed response completed),
  `:connection_reset`, `:connection_closed`, or `:transport_error` (transport
  failures after response headers), `:invalid_body` (unparseable HTTP framing),
  `:redirect_not_followed` /
  `:invalid_redirect` / `:too_many_redirects` (redirect handling), and
  `:bad_status` for a non-success origin status (the underlying error tuple
  carries the numeric status as `{:bad_status, status}`; the metadata atom is
  the `:bad_status` category).

- Decode / input-validation failure — `:result` is `:processing_error`; `:error`
  is a stable category atom (e.g. `:input_limit` when the decoded image exceeds
  `:max_input_pixels` or declares more frames than `:max_input_frames`,
  `:decode` for an undecodable body). An `:input_limit` failure also carries
  `:limit`, `:pixels` or `:frames`, naming the limit that rejected the source.
- Page out of range — `:result` is `:processing_error`; `:error` is
  `:page_out_of_range`. It carries the requested `:page` and the source's
  `:source_frames`. The response status is `422`.
- Unsupported-format reject — a sub-case of `:processing_error`; `:error` is
  `:unsupported_source_format`. It also carries `:detected_source_format`, so an
  observer can distinguish a format gate from a corrupt-body decode failure
  without parsing `:error`. Two shapes:
  - Rejected before any libvips call: `:detected_source_format` is the rejected
    family (`:bmp`, `:ico`, `:svg`, `:avif_sequence`) or `:unknown` for
    an unrecognised signature.
  - Loader-family mismatch: the source has an accepted family's signature, but
    libvips chose a loader outside that family. `:detected_source_format` is the
    detected family and `:source_loader` names the loader (e.g. `"dcrawload"`).

The default Logger appends the detected format, a skipped source, a rejected
loader, a selected page, a frame count above one, and the rejecting limit
after the error category, e.g. `source fetch_decode: ok (detected webp, 3
frames)`, `source fetch_decode: ok (detected gif, skipped processing)`,
`source fetch_decode: processing_error (unsupported_source_format, detected
tiff, loader dcrawload)`, `source fetch_decode: processing_error
(page_out_of_range, page 3, 3 frames)`, or `source fetch_decode:
processing_error (input_limit, frames limit)`. Input-limit and page rejections log at the base level, like
decode failures. The trace exporter keeps `:source_frames`, `:page`, `:limit`,
`:source_loader`, and `:skipped` as span attributes.

An upstream `304` produces `result: :not_modified` on the source fetch span.
The default Logger renders this outcome, and the trace exporter records it as
a successful span. Origin validators, URLs, and request credentials are not
included in the event.

### Remote source staging span (`[:source, :stage]`)

`[:image_pipe, :source, :stage]` wraps the download or conditional
revalidation of an HTTP or S3 original, including complete-body staging and
input-cache publication. It runs for every fetched remote original, with or
without a configured cache, and the `[:source, :fetch]` span nests inside it.
A fresh cached original skips it.

Stop metadata carries `result: :ok | :source_error`. A source error also
carries `:error`, with the same categories as `[:source, :fetch_decode]`. The
default Logger renders `source stage: source_error (receive_timeout)` and
escalates failures to a warning.

### Watermark acquisition span (`[:source, :watermark]`)

`[:image_pipe, :source, :watermark]` wraps one watermark asset's acquisition.
Each runs in its own task while the main source is acquired, and the tracer
parents it to the request across that process hop. Start metadata carries
`:phase`: `:prepare` establishes the asset's byte identity before the
conditional gate (reusing a fresh input-cache record, or fetching), and `:open`
reads the asset's bytes after an output-cache miss. The asset's
`[:source, :resolve]`, `[:source, :stage]`, `[:source, :fetch]`, and
input-cache spans nest inside it. Stop metadata carries `:result` in the request vocabulary. Asset sources
and names are not included.

The default Logger renders `source watermark prepare: ok` or `source watermark
open: source_error`, escalating failures to a warning; the trace exporter
records `:phase` and `:result` as span attributes.

### Transform execute span (`[:transform, :execute]`)

This span wraps execution of all request groups. Start metadata describes the
requested operations:

- `:operation_count` — number of requested semantic operations.
- `:operations` — the ordered list of requested semantic operation-name atoms.

Request names can differ from executed names: `:crop_guided` and `:crop_region`
both run as `:crop`, and `:canvas` runs as `:extend_canvas`. One requested
operation can expand into several executed operations, so `:operation_count`
can differ from the number of per-operation spans.

Stop metadata: `:result` (`:ok` or `:processing_error`).

### Input color management span (`[:transform, :input_color_management]`)

This span measures input color conditioning, once before group execution,
nested inside `[:transform, :execute]`.

Stop metadata:

- `:result` — `:ok` on success, or `:processing_error` when a corrupt or
  unsupported embedded ICC profile prevents conditioning (maps to a `415`
  response). The default Logger escalates `:processing_error` to `:warning`.
- `:working_space` — the VIPS interpretation atom of the resolved working
  colorspace (e.g. `:VIPS_INTERPRETATION_sRGB`/`:VIPS_INTERPRETATION_B_W` for
  tone-mapped SDR, or `:VIPS_INTERPRETATION_RGB16`/`:VIPS_INTERPRETATION_GREY16`
  when an HDR source is preserved under `preserve_hdr`).
- `:imported?` — `true` when the source's embedded ICC profile was imported
  into the working space (CMYK and other spaces that aren't RGB or gray);
  `false` otherwise, including RGB-family and gray sources, which keep their
  values and profile.

The span also fires when conditioning is a no-op, with `imported?: false`.

The default Logger renders it as:

```text
image_pipe transform input_color_management: ok (VIPS_INTERPRETATION_sRGB)
image_pipe transform input_color_management: ok imported (VIPS_INTERPRETATION_sRGB)
```

### Per-operation transform spans (`[:transform, :operation]`)

Each executed operation is wrapped in a nested
`[:image_pipe, :transform, :operation]` span, inside `[:transform, :execute]`.
Its duration measures pipeline construction; libvips defers pixel work to
materialization and encoding. Use these spans to inspect operation order,
and materialize/encode spans to measure pixel work.

Start metadata:

- `:operation` — the executed operation name atom (e.g. `:resize`, `:crop`).
- `:params` — the full operation struct (product-neutral, derived from the
  public request).

Stop metadata: `:result` (`:ok` or `:error`). A successful stop also carries
`:dims` — the post-operation image dimensions `{width, height}`.

The default Logger includes the operation name and outcome, for example
`image_pipe transform: resize ok` or `image_pipe transform: crop error`.

### Materialization barrier span (`[:transform, :materialize]`)

This span measures evaluation and copying of lazy libvips state into RAM,
including orientation flushes.

The executor's orientation boundary prepares random access before orientation that
reorders rows, applies the orientation, and buffers its display frame. Each flush
evaluates its result for downstream consumers, including horizontal-only flips
and later rotation groups.

Stop metadata: `:result` (`:ok` or `:materialize_error`). A successful stop also
carries `:dims` — the allocated buffer dimensions `{width, height}`. Orientation
flushes report the display frame after rotation. A failed copy surfaces
as a `:stop` carrying `result: :materialize_error` (the callers map it to a decode
error → `415`); a raise inside the copy surfaces as a `[:transform, :materialize,
:exception]` event.

Parenting depends on where the materialization happens — there are three cases:

- **during execution**, before an operation that needs random access (trim,
  arbitrary-angle rotate, smart/object-detect crop), or inside resize when
  buffering a preceding lazy arbitrary rotation: nested under that
  operation's `[:transform, :operation]` span;
- **orientation flush**, when the executor applies pending orientation and
  buffers the display frame: nested directly under `[:transform, :execute]`;
- **delivery backstop**, when the pipeline streamed without materializing
  and the late delivery copy runs after the transform pipeline has closed
  (after `[:transform, :execute]`): nested under the request root.

Every generated image materializes at least once, using the post-clamp,
pre-encode delivery barrier if needed. Cache hits and conditional `304`s skip
transform spans.

### Output negotiate span (`[:output, :negotiate]`)

This span measures output-format selection from the request policy, decoded
source format, and final alpha channel.

Start metadata: `:output_mode` — `:explicit` when the request pinned a format, or
`:automatic` when the format is `Accept`-negotiated from the source.

Stop metadata:

- `:result` — `:ok`, or `:output_error` when negotiation fails (e.g. a
  source-only format with no acceptable target).
- `:output_format` — the negotiated output format atom, on success.
- `:error` — a stable error category (`ImagePipe.Error.tag/1`), on failure.

### Output terminal span (`[:output, :terminal]`)

The `[:image_pipe, :output, :terminal]` span wraps info JSON, BlurHash, and LQIP CSS
generation. A complete-body cache hit and a conditional `304` perform
no terminal computation and therefore emit no terminal span.

Start metadata:

- `:terminal` — `:info`, `:blurhash`, or `:lqip_css`.
- `:placeholders` — for `:info` only, the sorted placeholders the response
  includes (`:blurhash`, `:lqip_css`), possibly empty.

Stop metadata:

- `:result` — `:ok` on success, or the request outcome category for a decode or
  transform failure.
- `:terminal` and `:placeholders` — repeated from start metadata.

The default Logger renders the terminal and any placeholders, e.g.
`output terminal: ok (info with blurhash, lqip_css)`. The OpenTelemetry exporter
copies both keys onto the span.

### Output encode span (`[:encode]`)

This span measures encoder construction and the first encoded chunk, forcing
pixel work. It runs in the producer process under the request root. First-chunk
failures occur before response headers and return `500`.

Start metadata: `:output_format` — the negotiated output format atom.

Stop metadata:

- `:result` — `:ok`, or `:processing_error` when the encode fails before the first
  chunk (the failure maps to a `500`). The default Logger escalates an encode
  `:processing_error` to `:warning`.
- `:output_format` — the negotiated output format atom.
- `:error` — a stable error category when the encode failed (e.g. `:empty_stream`).

### Encode-quality search span (`[:encode, :search]`)

When quality search runs (a `:size`, `:ssimulacra2`, or `:butteraugli` objective,
or a `max_bytes` budget on a quality-bearing format), ImagePipe wraps the
search over encoder quality in a `[:image_pipe, :encode, :search]` span, emitted
from inside the encode stage (nested under `[:encode]`). The search probes
candidate qualities, re-encoding the finalized image at each one, and returns the
winning buffer.

Start metadata (product-neutral search descriptor):

- `:objective` — `:size`, `:ssimulacra2`, `:butteraugli`, or `:none` (a
  `max_bytes`-alone search).
- `:min_quality` / `:max_quality` — the per-format-clamped quality bracket
  (absent for a `:none` search).
- `:target` — the objective target (byte target for `:size`, score band centre for
  `:ssimulacra2`, butteraugli distance band centre for `:butteraugli`; absent for
  `:none`).
- `:max_bytes` — the requested byte budget when set.

Stop metadata:

- `:result` — `:ok`, or `:processing_error` when the search failed (e.g. an
  encode/score error).
- `:objective` — the objective above.
- `:chosen_quality` — the delivered quality.
- `:chosen_bytes` — the encoded byte size of the delivered buffer.
- `:iterations` — the number of distinct encodes performed.
- `:outcome` — `:hit` (objective/budget met), `:best_effort` (fell back to the
  bracket floor/ceiling because the target was unreachable), or `:skipped`.
- `:final_score` — the perceptual score of the delivered quality for a
  SSIMULACRA2 or Butteraugli search, otherwise absent.
- `:scorer` — `:full` (whole-frame SSIMULACRA2) or `:crop` (K p10-tiles above the
  internal ~6 MP crossover).
- `:tiles_scored` — tiles actually scored on the crop path (sub-sampled, `<= 16`);
  absent on the full-frame path.
- `:confirm_passes` — full-frame confirm/bump passes on the crop path (1 = confirm
  only; up to 3 with the bump cap). `0` on the full-frame path.
- `:limiting_factor` — why a `:best_effort` result fell short, absent on a `:hit`:
  `:ceiling`/`:floor` (the objective never cleared its band/target and pinned to
  the bracket ceiling/floor), `:max_bytes` (the hard budget could not be met even
  at the floor), or `:bump_exhausted` (the crop confirm undershot through every
  bump pass).

The default Logger escalates an `outcome: :best_effort` stop (and an exception) to
`:warning`; other outcomes log at the base level. It renders the stop with the
scorer token (`full`/`crop`):

```text
image_pipe encode search: ok (full hit q62 12345b score 90.42)
image_pipe encode search: ok (crop hit q72 12345b score 90.42)
```

### Content-class classify span (`[:encode, :classify]`)

On the crop-scoring path (an `:ssim2` search above the internal ~6 MP crossover),
ImagePipe classifies the finalized image as `:photo` (continuous-tone) or
`:graphic` (discrete-tone: screenshots, text, charts, line art) to select the
per-`{format, content-class}` crop offset. The
classification is wrapped in a `[:image_pipe, :encode, :classify]` span. It is
emitted from the search setup, **before** the `[:encode, :search]` span opens, so
it is a sibling of the search under `[:encode]` — not nested under it. The span
emits start/stop only (the classifier is total — it never raises — so no
`:exception` leg fires).

Stop metadata (all product-neutral — a class atom, a constant offset, two image
statistics; nothing sensitive):

- `:result` — `:ok` (the classifier is total, so this is always `:ok`; it gives the
  Logger/exporters the standard outcome key).
- `:content_class` — `:photo` or `:graphic` (the safe fallback).
- `:applied_offset` — the offset subtracted from the crop estimate for this
  `{format, content-class}` cell.
- `:palette_ent` — the luminance-histogram entropy feature (÷ 8).
- `:nat_var` — the mid-band gradient-fraction feature.

The default Logger renders the stop at the base level (it never escalates):

```text
image_pipe encode classify: ok (graphic offset 6.0)
```

The OTel exporter captures it as `image_pipe.encode.classify` with the four
attributes above on the span.

### Encode-quality search probe (`[:encode, :search, :probe]`)

Each unit of probe work the search performs is a `[:image_pipe, :encode, :search,
:probe]` **span**, nested under `[:encode, :search]`. A probe span is created for
every NEW distinct encode (objective/cap search and the floor/ceiling fallbacks)
and every NEW authoritative confirm score (the crop path's confirm/bump). Re-using
an already-memoized quality (or confirm score) emits **nothing**. The span
duration is the total probe time; its child legs (below) give the cost split.

Start metadata:

- `:quality` — the probed quality.
- `:phase` — `:objective` (the objective binary search), `:cap` (the `max_bytes`
  cap descent), `:confirm` (the first crop→full re-validation), or `:bump` (a
  linear bump pass after a confirm undershoot).

Stop metadata:

- `:bytes` — the encoded byte size at that quality.
- `:index` — the distinct-encode ordinal (1-based). A confirm probe whose encode
  was a memo hit carries the same `:index` as the objective probe that produced
  the buffer, tying the estimate and confirm legs of one buffer together.
- `:score` — the score this phase computed: the (offset-corrected) crop estimate
  on an objective probe in crop mode, the authoritative full-frame score on a
  confirm/bump probe, the whole-frame score on a full-frame objective probe;
  absent for a `:size`/`:none` search.
- `:scorer` — `:full` or `:crop` (the configured scorer).
- `:tiles_scored` — tiles scored on the crop path; absent on the full-frame path.

Confirm/bump probes also carry the crop-to-full residual, which measures the
accuracy of the internal crop-correction offset:

- `:crop_estimate` — the offset-corrected crop estimate for the same buffer.
- `:full_frame_score` — the authoritative whole-frame score (equals `:score`).
- `:passed?` — whether `:full_frame_score` cleared the confirm band.

#### Per-probe cost legs

Each probe span nests child spans splitting the probe's cost. These are eager
NIF/op calls, so their durations are honest compute timing (unlike the
libvips-lazy per-operation transform spans):

- `[:encode, :search, :probe, :encode]` — the codec encode
  (`ImagePipe.Output.Encoder.encode_to_buffer`). Method-neutral: it fires for
  every objective (`:size`/`:ssimulacra2`/`:butteraugli`/`:none`), so it carries no
  metric segment. Stop metadata: `:bytes`. Absent on a confirm probe whose encode
  was a memo hit.
- `[:encode, :search, :probe, <metric>, :decode]` — the candidate decode
  (`Image.from_binary`). Stop metadata: `:bytes` (the input buffer size).
- `[:encode, :search, :probe, <metric>, :metric]` — one aggregate perceptual score
  (whole-frame, or K crop tiles for SSIMULACRA2). Stop metadata: `:score`, and
  `:tiles_scored` on the crop-estimate path (absent on the whole-frame confirm /
  butteraugli full-frame). No per-tile span is emitted — that detail lives in `mix
  autoquality.bench`.

The scoring legs carry a **per-metric** segment derived from the metric's
`leg_name/0` — `:ssimulacra2` or `:butteraugli` — so each metric gets distinct span
names a backend can group by.

All values are product-neutral numbers/atoms (no URLs, secrets, or PII).

**Logger vs. OTel asymmetry.** The default Logger renders the **probe span**
(`image_pipe encode search probe: …`, base level; an exception escalates to
`:warning`) but deliberately does **not** subscribe to the cost legs — ~15–27 leg
lines per request would drown the human log. The legs are traced by the OTel
exporter only (`ImagePipe.Telemetry.Trace.Capture`), where per-probe cost detail
belongs. This is the one intentional place the Logger and the tracer cover
different event sets.

#### Delivered-probe marker (`[:encode, :search, :probe, :chosen]`)

The delivered bytes are the **winning probe's** encode — produced during the
search and reused via memoization, with no separate post-search re-encode. Because
probe spans close before the search resolves its final quality, the winner cannot
be tagged on its own (already-closed) span. Instead a single **one-shot** event,
`[:image_pipe, :encode, :search, :probe, :chosen]`, is emitted once when the search
resolves, naming the delivered probe so it is directly filterable. In a trace it
folds as an annotation onto the enclosing `[:encode, :search]` span.

Metadata (a subset of the winning probe's, plus the encode phase):

- `:quality` — the delivered quality (equals the search's `:chosen_quality`).
- `:bytes` — the delivered byte size (equals `:chosen_bytes`).
- `:phase` — the phase that actually **encoded** the delivered bytes: `:objective`
  or `:cap`, or `:bump` when the winner was first encoded during a confirm bump.
  (A confirm only re-scores already-encoded bytes, so it never names the winner.)
- `:index` — the distinct-encode ordinal of that encode.
- `:score` — the delivered quality's score; absent for a `:size`/`:none` search.
- `:scorer` — `:full` or `:crop`.
- `:tiles_scored` — tiles scored on the crop path; absent on the full-frame path.

Both surfaces subscribe to it: the default Logger renders one line
(`image_pipe encode search chosen: q64 12345b (objective score 90.42)`, base
level), and the OTel exporter folds it onto the search span.

### Send span (`[:send]`)

The `[:image_pipe, :send]` span wraps the terminal response send — every path a
request can exit through: the streamed/cached image sends, error responses,
rendered/complete bodies (info, BlurHash, LQIP CSS), 304s, the OPTIONS 204, and the
method-405 reject. `ImagePipe.Plug.Runner` emits it around every
terminal send, so all exits share the same shapes. It runs in the
connection-owner process.

Start metadata: `:result` — the request's classified result (same vocabulary as
`[:request]`'s stop `:result`).

Stop metadata: `:result` (re-read after the send, so a mid-stream delivery
failure surfaces as `:processing_error`) and `:status` — the sent HTTP status.

### Delivery streaming span (`[:deliver]`)

The `[:image_pipe, :deliver]` span wraps streaming the already-produced encoded
chunks back over the connection. It measures connection delivery, **not**
encoding. It is emitted from the request process (`ImagePipe.Response.Sender`),
nested under `[:send]`.

Stop metadata:

- `:result` — `:ok`; `:processing_error` for a mid-stream failure; or
  `:client_closed` when the client disconnects mid-stream (a normal outcome, not
  escalated).
- `:status`, `:output_format`, and, on failure, `:stream_phase` (the streaming
  phase the error occurred in, e.g. `:encode`) and `:error`.
- `skipped: true` when the response streams an unchanged source, whose
  `:output_format` is then the source format.

## Measurements

ImagePipe uses the measurements provided by `:telemetry.span/3`:

- `:start` events include `:system_time` and `:monotonic_time`.
- `:stop` events include `:duration` and `:monotonic_time`.
- `:exception` events include `:duration` and `:monotonic_time`.

Durations use the native time unit from `System.monotonic_time/0`. Handlers can
convert them with `System.convert_time_unit/3` for a specific display unit.

HTTP cache decision events are one-shot events with empty measurements.

## Metadata

Metadata excludes secrets, credentials, private content, and source-derived
paths that may contain them. Cardinality is a consumer concern; handlers choose
which emitted fields become metrics tags. Common fields are:

- `:result` - the stable outcome category.
- `:status` - the response status when known.
- `:cache` - cache status when relevant.
- `:output_mode` - `:automatic` or `:explicit` when known.
- `:output_format` - the resolved output format when known.
- `:terminal` - the complete-body terminal name (`:info`, `:blurhash`, or `:lqip_css`).
- `:source_mount` - the name of the source mount that served the source, on
  source spans; `nil` for direct `{:file, _}` and `{:binary, _}` inputs. The
  default Logger adds it to source resolve and fetch lines, for example
  `image_pipe source fetch: ok (mount media)`.
- `:source_kind` - `:path`, `:url`, `:object`, or `:input` on source spans.
- `:source_adapter_kind` - `:file`, `:http`, `:s3`, or `:custom` on source spans.
- `:error` - a stable error category when known. The default Logger appends it
  to the outcome, for example `output negotiate: output_error (unsupported)`.
- `:sig_key_index` - the matched signing-key index (`ImagePipe.Security.verify/3`'s
  return value) on the path parser's `[:parse]` stop metadata; `nil` when the
  request is legitimately unsigned.

Exception events include the metadata added by `:telemetry.span/3`, including
`:kind`, `:reason`, and `:stacktrace`.

All span events also include `:telemetry_span_context`, which
`:telemetry.span/3` injects for correlating the events from the same span. Treat
it as correlation data, not as a metrics dimension.

ImagePipe does not emit full request paths. They can contain signatures, source
URLs, tokens, and private identifiers. Hosts that add paths in their own
handlers must apply suitable privacy controls; they should separately decide
which high-cardinality values are appropriate as metrics dimensions.

## Result values

Request and stage spans use narrow result atoms:

- `:ok`
- `:options` - an `OPTIONS` request answered with `204` (CORS preflight /
  capability discovery). A success outcome (OTel span status `:ok`).
- `:parser_error`
- `:plan_error`
- `:source_error`
- `:cache_error`
- `:materialize_error`
- `:processing_error`
- `:error`

Use `:error` for stage-local failures that aren't otherwise classified at that
stage. The request span maps returned failures into the more specific request
outcome categories in this list.

Representative stage → result mappings:

- `[:source, :fetch_decode]` → `:ok`, `:source_error` (e.g. `error: :body_too_large`),
  or `:processing_error` (e.g. `error: :input_limit`, `:decode`). An
  unsupported-format reject (a rejected or unrecognised family before any libvips
  call, or a loader-family mismatch) reports `:result` `:processing_error` and
  carries `:detected_source_format`, plus `:source_loader` for a mismatch, so an
  observer sees why the request was rejected.
- `[:transform, :execute]` → `:ok` or `:processing_error`.
- `[:transform, :materialize]` → `:ok` or `:materialize_error`.
- `[:output, :negotiate]` → `:ok` or a negotiation failure category.
- `[:output, :terminal]` → `:ok` or a terminal computation failure category.
- `[:encode]` → `:ok` or `:processing_error`.
- `[:deliver]` → `:ok`, `:processing_error`, or `:client_closed`.

The `:error` field is a stable category atom (`ImagePipe.Error.tag/1`), never a
raw message or source-derived path.

## Content-aware crop detection

`detect=face`, `detect=car,dog`, and `detect=all,face:3` guides on crop or
cover requests, plus `anchor=smart-face`, report detection according to whether
a detector ran.

When a detector is configured, ImagePipe wraps the detector invocation in a
`[:image_pipe, :transform, :detect]` span whose duration reflects real inference
work (useful for spotting model cold-start cost). Stop metadata:

- `:classes` - the requested detection classes, e.g. `["face"]` or `:all`.
- `:regions` - the total number of regions the detector returned.
- `:result` - the detector outcome, one of:
  - `:detected` - the detector returned at least one region.
  - `:no_regions` - the detector ran but found nothing (no matching object in the
    frame). This is a normal result, **not** a failure; the crop falls back to
    libvips attention saliency.
  - `:unavailable` - the configured detector reported it is unavailable.
  - `:error` - the detector raised, errored, or returned a malformed result.

`:result` reflects the *detector* outcome, not the final crop decision: a
`:detected` result whose boxes all fall outside the image still degrades to
attention downstream.

### Per-model spans (Composite detector)

When using the bundled Composite detector (the default), ImagePipe also emits a
nested `[:image_pipe, :transform, :detect, :model]` span **per child detector
that ran**. These spans are emitted inside the outer `[:transform, :detect]`
span. Stop metadata:

- `:detector` - the child detector module that ran (e.g.
  `ImagePipe.Transform.Detector.ImageVision.Face`).
- `:model` - the child's `identity/1` result for this request (e.g.
  `{ImagePipe.Transform.Detector.ImageVision.Face, {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"}}`).
- `:classes` - the class subset routed to this child for the request (a list of
  class name strings, or `:all`).
- `:regions` - the number of regions this child returned.
- `:result` - `:ok` or `:error`; failed children report zero regions. The raw
  detector error is omitted.

To determine the **effective detected class set** from per-model spans: take the
union of all `:classes` values across all `:stop` events for a given request. A
class that was requested but does not appear in any per-model span was unknown to
all configured detectors and was silently dropped (best-effort).

> **Custom-detector authors:** keep your `identity/1` return value free of
> secrets — it appears in these per-model spans, which fan out to every attached
> handler including third-party exporters.

The opt-in default Logger renders successful per-model spans at the base level
and failed children at warning level. Trace capture marks failed children as
error spans even when another child succeeds. For example:

```text
image_pipe transform detect model: ok (2 regions, ImagePipe.Transform.Detector.ImageVision.Face)
```

When **no** detector is configured, no detection runs, so there is no span.
Instead ImagePipe emits a one-shot (non-span) marker:

```text
[:image_pipe, :transform, :detect, :skipped]
```

with empty measurements and metadata `%{classes: [...], result: :no_detector}`.

The two unfulfillable-but-configured span results (`:unavailable`, `:error`) and
the `:skipped` one-shot (`:no_detector`) all mark a face-aware request that fell
back to attention saliency; the opt-in default Logger escalates all three to
`:warning`. The normal `:no_regions` and `:detected` span results log at the
base level.

For `anchor=smart-face`, a detected face is blended with the attention point.
ImagePipe emits a one-shot marker recording the skew:

```text
[:image_pipe, :transform, :detect, :blend]
```

with empty measurements and metadata:

- `:attention` - the pure libvips saliency point `{x, y}` (normalized 0..1).
- `:face` - the area-weighted face centroid `{x, y}` (normalized 0..1).
- `:blended` - the point actually used: `(1 - weight)·attention + weight·face`.
- `:weight` - the face-assist blend weight (ImagePipe's approximation).

Subtract `:attention` from `:blended` for how far the face pulled the crop. The
coordinates are product-neutral and derived from the public request, so they are
safe to emit. This marker fires only when a face is detected; no face means a
plain attention crop and no blend event. The default Logger renders it at the
base level.

## Cache events

Cache-related metadata may include:

- `cache: :disabled`
- `cache: :hit`
- `cache: :miss`
- `cache: :read_error`
- `cache: :write`
- `cache: :stage_skipped`
- `cache: :stage_error`
- `cache: :write_error`
- `cache: :stage_abandoned`
- `cache: :stage_cleanup_error`

Streamed cache misses may also emit the one-shot `[:cache, :stage]` event (sent
with `Telemetry.execute/4`, not a span) with:

- `cache: :stage_skipped` and `reason: :too_large` when the staging sink crosses
  `:max_body_bytes`.
- `cache: :stage_abandoned` when ImagePipe aborts a staged entry
  because delivery stopped early, the owner process exited, or the stream failed.
- `cache: :stage_error` when opening or writing the staging sink fails before
  commit.
- `cache: :stage_cleanup_error` when abort cleanup fails after the response path
  has already failed open.

Input caching adds two spans (each has `:start`, `:stop`, and `:exception`
events):

- `[:cache, :input]` measures opening and verifying a cached original. Stop
  metadata has `pool: :input` and `cache: :hit | :miss | :read_error`. A hit
  includes `:bytes`, the original bytes reused without downloading a body;
  read failures report `result: :cache_error` and fall back to origin access.
- `[:cache, :refresh]` measures supervised stale-while-revalidate work. It
  retains the request outcome, so failed refreshes remain visible.

The default Logger and trace Capture subscribe to both. Trace attributes
include the safe `:pool` field; credentials, source URLs, and origin headers are
not included. Output-only hits do not emit an input-pool hit.
Filesystem admission, warm-start, eviction, flush, and cleanup events carry
the supervisor's `:pool` label too. The Logger appends `(input pool)` or
`(output pool)` when a pool label is present.
The `[:cache, :warm_start, :stop]` metadata reports `own_state_loaded: true`
only when local state was restored successfully. `peer_state_files` counts
present peer state files. Trace Capture retains both fields.
The one-shot `[:cache, :coordination]` event reports `operation: :source | :refresh | :output`.
Source acquisition and refresh report
`result: :acquired | :started | :coalesced | :backoff | :busy`.
Output coalescing carries `pool: :output` and reports `:acquired` for the leader,
`:waiting` for a follower, `:ready` when it can recheck the cache, `:bypass` when
it must generate independently, and `:busy` when coordinator capacity is full.
The Logger preserves the outcome and pool label, warning on `:busy` and `:bypass`.
Trace Capture records these events under the requesting span, including across
the output coordinator process hop. Cache keys and cache configuration are not
included in coordination events.

Both pools use `[:cache, :write, ...]` with their `:pool` label. A
successful commit stop event includes `cache: :write`. A commit error after
successful streamed delivery includes `cache: :write_error` and
`result: :cache_error`, but the response still fails open because the body was
already delivered.

## HTTP cache events

HTTP cache handling emits one-shot events:

- `[:image_pipe, :http_cache, :prepare]` with `:effective_mode` (the resolved
  `http_cache` value: `:validators`, `:auto`, `:public`, or `:private`),
  `:byte_identity`, and `:etag`.
- `[:image_pipe, :http_cache, :conditional, :match]` with `method: :get` or
  `method: :head`.
- `[:image_pipe, :http_cache, :fallback, :no_store]` with `:source_mount`,
  `:source_kind`, and `:reason`.
- `[:image_pipe, :http_cache, :cache_hit, :headers]` with booleans for `:etag`,
  `:generated_cache_headers`, and `:representation_headers`.

These events don't include request paths, source identities, cache keys, or ETag
values.

The opt-in default Logger renders all four at the base level under its own
`:http_cache` event group (so a host can include or exclude them via the
`:events` option independently of the storage `:cache` group), e.g.:

```text
image_pipe http_cache prepare: auto (byte_identity strong, etag true)
image_pipe http_cache conditional match: get
image_pipe http_cache fallback no_store: missing_byte_identity (url, mount web)
image_pipe http_cache cache_hit headers: etag true (generated true, representation false)
```

## Output dimension clamp (`[:output, :clamp]`)

When the final image exceeds the tighter of the host result caps and encoder
limits, ImagePipe uniformly downscales it before encoding and emits a one-shot
marker. WebP caps each axis at 16383, AVIF at 16384, JPEG at 65535, and PNG is
effectively unbounded. The host's default 8192-axis cap is usually tighter.

```text
[:image_pipe, :output, :clamp]
```

Measurements:

- `:scale` — the uniform downscale factor applied (a float `< 1.0`).

Metadata:

- `:format` — the negotiated output format atom (e.g. `:webp`, `:avif`).
- `:source_dimensions` — `{w, h}` before the clamp.
- `:dimensions` — `{w, h}` after the clamp.
- `:limits` — the effective caps applied: `%{max_width, max_height, max_pixels}` (each a `pos_integer` or `:infinity`).

The event fires only when the clamp downscales the image.

The opt-in default Logger attaches to this event and renders it at `:warning`,
for example:

```text
image_pipe output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)
```

## Debug fact collection (`[:debug, :collect, :error]`)

Debug-fact collection (the source/output facts behind the opt-in `X-ImagePipe-*`
debug headers) is best-effort and runs unconditionally on every generation. If
reading the decoded image's headers raises, ImagePipe degrades that fact set to
empty rather than failing the decode, and emits a one-shot (non-span) marker so the
loss is observable.

```text
[:image_pipe, :debug, :collect, :error]
```

Measurements: none.

Metadata:

- `:error` — the classified exception category atom (`ImagePipe.Error.tag/1`).
  Product-neutral and non-sensitive.

The default Logger renders a `:warning` line
(`image_pipe debug collect: error (<tag>)`), and the OTel exporter folds it as an
annotation onto the enclosing span (typically `[:source, :fetch_decode]`).
