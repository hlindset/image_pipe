# Telemetry

ImagePipe emits telemetry spans for the request lifecycle and its major runtime
stages. Host applications can attach their own logging, metrics, or tracing
integration to those events. ImagePipe doesn't *hard*-depend on
AppSignal, OpenTelemetry, or any other tracing system; it ships an optional,
opt-in OTel exporter (API-only at compile time) — see
[OpenTelemetry export](#opentelemetry-export) below.

## Configuration

Set the telemetry prefix as a Plug option:

```elixir
forward "/",
  to: ImagePipe.Plug,
  init_opts: [
    dialect: ImagePipe.Dialect.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    telemetry_prefix: [:my_app, :image_pipe]
  ]
```

The default prefix is `[:image_pipe]`. Prefixes must be non-empty lists of
atoms.

## Event names

Events use `:telemetry.span/3` naming conventions. Every span emits a `:start`
event and then either a `:stop` event for normal completion or an `:exception`
event for a raised exception:

```text
telemetry_prefix ++ stage ++ [:start]
telemetry_prefix ++ stage ++ [:stop]
telemetry_prefix ++ stage ++ [:exception]
```

The top-level request span is:

```text
[:image_pipe, :request, :start]
[:image_pipe, :request, :stop]
[:image_pipe, :request, :exception]
```

ImagePipe also emits stage spans for meaningful request phases. The exact set
depends on the routing path. For example, cache hits skip source fetch,
transform execution, output negotiation, the encode span, and the send/deliver
streaming spans.

```text
[:image_pipe, :parse, ...]
[:image_pipe, :source, :resolve, ...]
[:image_pipe, :cache, :lookup, ...]
[:image_pipe, :output, :negotiate, ...]
[:image_pipe, :source, :fetch, ...]
[:image_pipe, :source, :fetch_decode, ...]
[:image_pipe, :transform, :execute, ...]
[:image_pipe, :transform, :input_color_management, ...]
[:image_pipe, :transform, :operation, ...]
[:image_pipe, :transform, :materialize, ...]
[:image_pipe, :encode, ...]
[:image_pipe, :encode, :search, ...]
[:image_pipe, :encode, :classify, ...]
[:image_pipe, :cache, :write, ...]
[:image_pipe, :render, ...]
[:image_pipe, :send, ...]
[:image_pipe, :deliver, ...]
```

For example, the cache lookup stop event with the default prefix is:

```text
[:image_pipe, :cache, :lookup, :stop]
```

### Request span (`[:request]`)

The `[:image_pipe, :request]` span wraps the whole request, opened by
`ImagePipe.Plug.DialectRunner` before any dialect callback runs. Its **start
metadata is empty** — nothing about the request is known yet, and the runner
does not name the mounted dialect.

Stop metadata:

- `:result` — the request outcome category (see "Result values"). A dialect may
  refine an error into its own vocabulary through the optional
  `c:ImagePipe.Dialect.classify_error/1` callback; otherwise the neutral
  `ImagePipe.Telemetry.request_result/1` mapping applies.
- `:status` — the response status.
- `:error` — a stable error category on failures.

When a committed `200` fails mid-stream, the stop `:result` agrees with the
`[:send]` stop rather than the pre-delivery outcome.

### Parse span (`[:parse]`)

The `[:image_pipe, :parse]` span wraps `c:ImagePipe.Dialect.parse/2`. Its
**start metadata is empty**; the stop metadata is **dialect-owned** — the
callback returns it alongside its parse result, for both outcomes. Every in-tree
dialect reports at least `:result` (`:ok`, `:redirect`, or `:error`), an
`:error` tag from `ImagePipe.Error.tag/1` on rejection, and `:status` on a
redirect. Individual dialects add their own fields, such as the native dialect's
`:sig_key_index`.

### Source fetch + decode (`[:source, :fetch_decode]`)

`[:image_pipe, :source, :fetch_decode]` wraps source fetch **and** image decode
as one span. By deliberate design it also folds in the two input guards that run
during decode — input-pixel-count validation and source body-size limiting —
rather than emitting separate spans for them.

It is emitted from one place: the `ImagePipe.Decode.with_image/4` bracket every
dialect routes through. The span closes immediately after the decoded state is
built, *before* the transform/encode continuation runs (even though that
continuation stays inside the source bracket), so a transform or encode failure
is never misattributed to fetch/decode.

This fold is intentional. libvips is lazy: a standalone `[:decode]` span would
time loader *construction*, not pixel work (real decode cost is realized later,
during transform materialization and encode). A separate timing span for it
would mislead, the same way per-operation durations would (see below). The
guards are likewise checks, not durationful stages. So their *outcomes* are
reported as stop metadata on this span instead of as their own spans.

The nested `[:source, :fetch]` span (source side effects only) lives inside it.

Success stop metadata:

- `:result` — `:ok`.
- `:load_option` — the shrink-on-load option chosen, `{:shrink, n}`, `{:scale, f}`, or absent when none.
- `:achieved_shrink` — `%{w: float, h: float}` realized shrink, when shrink-on-load fired.
- `:original_dims` — `{w, h}` of the stored image before decode.
- `:loaded_dims` — `{w, h}` actually decoded.
- `:detected_source_format` — the format the up-front detector returned from the
  header peek (`:jpeg`, `:png`, …, or `:unknown`). Product-neutral, non-sensitive.
- `:source_format_resolution` — how the final `source_format` was decided:
  `:detected` (authoritative magic), `:libvips_codec` (ISOBMFF avif-vs-heif split
  from libvips), or `:libvips_fallback` (detector returned `:unknown`; libvips
  classified).

Failure stop metadata (one of two shapes, by failure mode):

- Source-side failure — `:result` is `:source_error`; `:error` is a stable
  category atom (e.g. `:body_too_large` when the source body crosses
  `:max_body_bytes`). HTTP fetch failures are classified rather than collapsed
  so an observer can tell them apart: `:connect_error` (DNS/TLS/refused/connect
  or pool timeout), `:receive_timeout` (origin stalled mid-body),
  `:invalid_body` (unparseable chunked framing), `:redirect_not_followed` /
  `:invalid_redirect` / `:too_many_redirects` (redirect handling), and
  `:bad_status` for a non-success origin status (the underlying error tuple
  carries the numeric status as `{:bad_status, status}`; the metadata atom is
  the `:bad_status` category).
- Decode / input-validation failure — `:result` is `:processing_error`; `:error`
  is a stable category atom (e.g. `:input_limit` when the decoded image exceeds
  `:max_input_pixels`, `:decode` for an undecodable body).
- Unsupported-format reject — a sub-case of `:processing_error` (before the
  libvips open): also carries `:detected_source_format` set to the rejected family
  atom (e.g. `:gif`, `:svg`), so an observer can distinguish a format gate from a
  corrupt-body decode failure without parsing `:error`.

### Transform execute span (`[:transform, :execute]`)

The `[:image_pipe, :transform, :execute]` span wraps the full transform chain.
It is opened by the runner (`ImagePipe.Plug.DialectRunner`) around
`c:ImagePipe.Dialect.execute/4`, so it has the same start/stop shape whichever
tier owns the stage — the fixed neutral driver for a declarative dialect, the
dialect's own `Pipeline.run/4` for an ordered one. Its start metadata carries
the aggregate request view:

- `:operation_count` — number of **plan** operations.
- `:operations` — the ordered list of **plan** (semantic) operation-name atoms.

**These two aggregate fields use a deliberately different vocabulary from the
per-operation spans below.** The aggregate `:operations` is the *semantic plan*
view (`:crop_guided`, `:crop_region`, `:canvas`, …). The per-op span's
`:operation` is the *executed-transform* view (`Transform.transform_name/1`),
where e.g. both crop variants execute as `:crop` and a canvas executes as
`:extend_canvas`. A single plan operation can also expand into several executed
transform ops, so `:operation_count` (plan ops) is **not** guaranteed to equal
the number of `[:transform, :operation]` spans. Treat the aggregate as "what
the request asked for" and the per-op spans as "what actually ran".

Stop metadata: `:result` (`:ok` or `:processing_error`).

### Input color management span (`[:transform, :input_color_management]`)

The `[:image_pipe, :transform, :input_color_management]` span wraps the
data-determined input-color preamble, which runs once at the start of transform
execution to condition the decoded image into a working colorspace before any plan
operation. It is emitted from the shared seam
`ImagePipe.Transform.InputColorManagement.condition/2` itself (via
`State.telemetry_opts`), so every dialect that runs the preamble emits it with
identical metadata — the declarative tier through
`ImagePipe.Transform.Executor`, each ordered dialect through its own
`Pipeline.run/4` — nested inside `[:transform, :execute]` either way.

Stop metadata:

- `:result` — `:ok` on success, or `:processing_error` when a corrupt or
  unsupported embedded ICC profile prevents conditioning (maps to a `415`
  response). The default Logger escalates `:processing_error` to `:warning`.
- `:working_space` — the VIPS interpretation atom of the resolved working
  colorspace (e.g. `:VIPS_INTERPRETATION_sRGB`/`:VIPS_INTERPRETATION_B_W` for
  tone-mapped SDR, or `:VIPS_INTERPRETATION_RGB16`/`:VIPS_INTERPRETATION_GREY16`
  when an HDR source is preserved under `preserve_hdr`).
- `:imported?` — `true` when the source had an importable embedded ICC profile
  that was imported into the working space; `false` otherwise (no profile, or a
  profile that was recognized and skipped — e.g. the canonical sRGB IEC61966
  profile on an sRGB source).

This span fires even when the preamble is a no-op (e.g. a source with no
embedded profile, or one already in a standard colour space); `imported?:
false` covers that case.

The default Logger renders it as:

```text
image_pipe transform input_color_management: ok (VIPS_INTERPRETATION_sRGB)
image_pipe transform input_color_management: ok imported (VIPS_INTERPRETATION_sRGB)
```

### Per-operation transform spans (`[:transform, :operation]`)

Each executed operation is wrapped in a nested
`[:image_pipe, :transform, :operation]` span, inside `[:transform, :execute]`.
Its **duration reflects pipeline construction, not pixel compute** — libvips
defers and fuses work to materialization/encode — so use it for tracing
execution *structure* (which operations ran, in what order), never as
per-operation timing. Honest aggregate timing lives on `[:transform, :execute]`.

Start metadata:

- `:operation` — the operation name atom (e.g. `:resize`, `:crop_region`).
  Includes the neutral bookkeeping operation the resolver emits: `:flush`
  (applies a pending orientation).
- `:index` — zero-based position within its executed batch (a staged resolve
  may execute one plan operation's executables across more than one batch).
- `:params` — the full operation struct (product-neutral, derived from the
  public request).

Stop metadata: `:result` (`:ok` or `:error`). A successful stop also carries
`:dims` — the realized post-operation image dimensions `{width, height}` (an
O(1) header read).

### Materialization barrier span (`[:transform, :materialize]`)

Each time the pipeline flushes the lazy libvips state to a RAM-resident buffer it
emits a `[:image_pipe, :transform, :materialize]` span from
`ImagePipe.Transform.Materializer` (`materialize/1`, the plain `copy_memory`, or
`flush/1`, the explicit orientation flush run by the `Flush` operation). This is
the **honest per-barrier timing the per-operation spans deliberately lack**:
libvips defers and fuses pixel work until materialization, so a materialize
span's duration is real flush cost (orientation pixels written, `copy_memory`),
not construction time.

The `flush/1` form also applies the deferred EXIF/user orientation before
copying, so its materialize span marks where the displayed frame changes, not
only where pixels reach RAM.

Stop metadata: `:result` (`:ok` or `:materialize_error`). A successful stop also
carries `:dims` — the post-materialize image dimensions `{width, height}`, which
surface the display-frame swap when the flush applied a pending quarter turn. A
failed flush surfaces
as a `:stop` carrying `result: :materialize_error` (the callers map it to a decode
error → `415`); a raise inside the flush surfaces as a `[:transform, :materialize,
:exception]` event.

Parenting depends on where the materialization happens — there are three cases:

- **mid-chain**, before an operation that needs random access (trim,
  arbitrary-angle rotate, smart/object-detect crop): nested under that
  operation's `[:transform, :operation]` span;
- **explicit flush**, when a pending EXIF/user orientation is applied by the
  `Flush` operation (emitted by the resolver mid-pipeline or at the pipeline
  boundary): nested under that `Flush` op's `[:transform, :operation]` span,
  inside `[:transform, :execute]`;
- **delivery backstop**, when a chain streamed through without ever materializing
  and the late delivery copy runs after the transform pipeline has closed
  (after `[:transform, :execute]`): nested under the request root.

The delivery backstop lives in the runner's post-clamp, pre-encode
`Materializer.materialize/2` barrier, so every dialect emits it with identical
metadata. Every
request that decodes and runs the transform pipeline (a cache miss)
materializes at least once: a chain that never materializes mid-pipeline hits the
delivery backstop. Requests served from cache (cache hits, conditional `304`s) skip
decode and transform entirely, so they emit no `[:transform, :materialize]` span
(nor any other transform span).

### Output negotiate span (`[:output, :negotiate]`)

The `[:image_pipe, :output, :negotiate]` span wraps output-format negotiation —
resolving the request's `Output.Policy` against the decoded source format into a
concrete `Output.Resolved`. It is emitted from the shared seam
`ImagePipe.Output.Negotiate.negotiate_output/4`, called once from the runner's
producer-side build, so every dialect emits it with identical metadata. The
single span encloses **both** resolution legs —
`Policy.resolve/2` and, when the format depends on the final image's alpha, the
second `resolve_final_image_alpha` pass — so exactly one span is emitted per
request regardless of which legs run.

Start metadata: `:output_mode` — `:explicit` when the request pinned a format, or
`:automatic` when the format is `Accept`-negotiated from the source.

Stop metadata:

- `:result` — `:ok`, or `:output_error` when negotiation fails (e.g. a
  source-only format with no acceptable target).
- `:output_format` — the negotiated output format atom, on success.
- `:error` — a stable error category (`ImagePipe.Error.tag/1`), on failure.

### Output encode span (`[:encode]`)

The `[:image_pipe, :encode]` span wraps the **forced output encode** — building
the encoder pipeline (`ImagePipe.Output.Encoder.stream_output/3`) and pulling the
first encoded chunk, which forces libvips to actually encode. This is the heaviest
stage of most requests, and unlike the per-operation transform spans (which time
*construction*), this span measures real pixel/encode compute: libvips is lazy, so
the work happens here when the first chunk is pulled.

It is emitted from the **producer** process and parents to the request root
(sibling of the delivery-backstop `[:transform, :materialize]`), not to `[:send]`.
The runner's producer-side build forces the first chunk *inside* the span, so a
first-chunk encode failure surfaces before any response header is written (a
pre-header 500), never as a mid-stream abort of an already-committed 200.

Start metadata: `:output_format` — the negotiated output format atom.

Stop metadata:

- `:result` — `:ok`, or `:processing_error` when the encode fails before the first
  chunk (the failure maps to a `500`). The default Logger escalates an encode
  `:processing_error` to `:warning`.
- `:output_format` — the negotiated output format atom.
- `:error` — a stable error category when the encode failed (e.g. `:empty_stream`).

### Encode-quality search span (`[:encode, :search]`)

When automatic encode-quality search runs (a `:size`/`:ssim2` objective and/or a
hard `max_bytes` budget on a quality-bearing format), ImagePipe wraps the binary
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
- `:max_bytes` — the hard byte budget when set.

Stop metadata (the search verdict; keys deliberately differ from the internal
result `meta`):

- `:result` — `:ok`, or `:processing_error` when the search failed (e.g. an
  encode/score error).
- `:objective` — the objective above.
- `:chosen_quality` — the delivered quality.
- `:chosen_bytes` — the encoded byte size of the delivered buffer.
- `:iterations` — the number of distinct encodes performed.
- `:outcome` — `:hit` (objective/budget met), `:best_effort` (fell back to the
  bracket floor/ceiling because the target was unreachable), `:skipped`, or
  `:native` (the butteraugli + JPEG XL single-encode path drove libvips' `distance`
  knob directly — `:iterations` is `0`, `:chosen_quality` is `0` since no Q was
  chosen, and no external metric ran).
- `:final_score` — the SSIMULACRA2 score of the delivered quality for an
  `:ssimulacra2` search, otherwise absent (`nil` on the native path).
- `:scorer` — `:full` (whole-frame SSIMULACRA2) or `:crop` (K p10-tiles above the
  internal ~6 MP crossover, #354).
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
per-`{format, content-class}` confirm-skipped crop offset (#380). The
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

Confirm/bump probes additionally carry the crop→full residual — the real-world
accuracy of the internal crop-correction offset, a shadow signal for any future
per-content offset calibration:

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
names a backend can group by. (The native-JXL butteraugli path emits no cost legs:
it is a single `distance`-driven encode with no decode/score loop.)

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
rendered/complete bodies (`/info`, blurhash), 304s, the OPTIONS 204, and the
method-405 reject. `ImagePipe.Plug.DialectRunner` emits it around every
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

### Render span (`[:render]`)

The `[:image_pipe, :render]` span wraps alternative (non-image) response
rendering — for example the IIIF `info.json` document. It is emitted by
`ImagePipe.Renderer.run/3`, so it covers **only** the render call itself, with
the preceding source fetch and header decode timed separately by
`[:source, :fetch_decode]`. It sits
as a **sibling** of `[:source, :fetch_decode]` under the request root, and it is
**absent** when the fetch or the decode fails, because the renderer never runs.

Only a renderer dispatched through that entry point emits it. An ordered dialect
that drives its own render terminal — the `ImagePipe.Dialect.Imgproxy` `/info`
endpoint, the `ImagePipe.Dialect.Native` blur-hash terminal — bypasses it and
emits no `[:render]` span.

Start metadata:

- `:renderer` — the renderer module (e.g. `ImagePipe.Dialect.IIIF.InfoRenderer`).
  The response content-type is not known until the renderer runs; it is reported
  in the stop metadata.

Stop metadata:

- `:result` — `:ok` on success, or `:render_error` on failure. The default
  Logger escalates `:render_error` to `:warning`.
- `:content_type` — the response content-type string on success (e.g.
  `"application/json"`).
- `:error` — a stable error category atom on failure.

The default Logger renders it as:

```text
image_pipe render: ok (application/json)
```

## Measurements

ImagePipe uses the measurements provided by `:telemetry.span/3`:

- `:start` events include `:system_time` and `:monotonic_time`.
- `:stop` events include `:duration` and `:monotonic_time`.
- `:exception` events include `:duration` and `:monotonic_time`.

Durations use the native time unit from `System.monotonic_time/0`. Handlers can
convert them with `System.convert_time_unit/3` for a specific display unit.

HTTP cache decision events aren't spans. ImagePipe emits them with
`Telemetry.execute/4`, and they're sent with empty measurements:

```text
[:image_pipe, :http_cache, :prepare]
[:image_pipe, :http_cache, :conditional, :match]
[:image_pipe, :http_cache, :fallback, :no_store]
[:image_pipe, :http_cache, :cache_hit, :headers]
```

## Metadata

Metadata is product-neutral and free of sensitive data (no secrets, credentials,
or source-derived paths). Cardinality is a consumer concern — handlers may safely
accept high-cardinality fields and project or aggregate them as needed. Common
fields are:

- `:result` - the stable outcome category.
- `:status` - the response status when known.
- `:cache` - cache status when relevant.
- `:output_mode` - `:automatic` or `:explicit` when known.
- `:output_format` - the resolved output format when known.
- `:source_kind` - `:path`, `:url`, `:object`, or `:reference` on source spans.
- `:source_adapter_kind` - `:file`, `:http`, `:s3`, or `:custom` on source spans.
- `:error` - a stable error category when known.
- `:sig_key_index` - the matched signing-key index (`ImagePipe.Dialect.Native.Signature.verify/3`'s
  return value) on the native URL dialect's `[:parse]` stop metadata; `nil` when the
  request is legitimately unsigned.

Exception events include the metadata added by `:telemetry.span/3`, including
`:kind`, `:reason`, and `:stacktrace`.

All span events also include `:telemetry_span_context`, which
`:telemetry.span/3` injects for correlating the events from the same span. Treat
it as correlation data, not as a metrics dimension.

ImagePipe doesn't emit full request paths by default. Imgproxy-style paths can
contain signatures, filenames, and source-shaped user data, and often have high
cardinality. Host applications that need path-level observability should add
that data in their own handlers with the relevant privacy and cardinality
controls.

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
- `:render_error`
- `:error`

Use `:error` for stage-local failures that aren't otherwise classified at that
stage. The request span maps returned failures into the more specific request
outcome categories in this list.

Representative stage → result mappings:

- `[:source, :fetch_decode]` → `:ok`, `:source_error` (e.g. `error: :body_too_large`),
  or `:processing_error` (e.g. `error: :input_limit`, `:decode`). An
  unsupported-format reject (gif/bmp/ico/svg, rejected before the libvips open)
  reports `:result` `:processing_error` and carries `:detected_source_format` set
  to the rejected family, so an observer sees why the request was rejected.
- `[:transform, :execute]` → `:ok` or `:processing_error`.
- `[:transform, :materialize]` → `:ok` or `:materialize_error`.
- `[:output, :negotiate]` → `:ok` or a negotiation failure category.
- `[:encode]` → `:ok` or `:processing_error`.
- `[:render]` → `:ok` or `:render_error`.
- `[:deliver]` → `:ok`, `:processing_error`, or `:client_closed`.

The `:error` field is a stable category atom (`ImagePipe.Error.tag/1`), never a
raw message or source-derived path.

## Content-aware crop detection

Detection-aware crops (`g:obj:face`, `g:obj:car`, `g:obj`, `c:W:H:obj:…`, and
face-assisted `g:sm`) report detection two ways, depending on whether any
detection actually ran.

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

To determine the **effective detected class set** from per-model spans: take the
union of all `:classes` values across all `:stop` events for a given request. A
class that was requested but does not appear in any per-model span was unknown to
all configured detectors and was silently dropped (best-effort).

> **Custom-detector authors:** keep your `identity/1` return value free of
> secrets — it appears in these per-model spans, which fan out to every attached
> handler including third-party exporters.

The opt-in default Logger renders the per-model span at the base level, e.g.:

```text
image_pipe transform detect model: 2 regions (ImagePipe.Transform.Detector.ImageVision.Face)
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

For face-assisted smart crop (`g:sm` with `smart_crop_face_detection`), when a
face is found ImagePipe blends the attention point with the face centroid. It
emits a one-shot (non-span) marker recording the skew:

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

Cache-related metadata may also include:

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

Cache sink commits use the existing `[:cache, :write, ...]` span. A
successful commit stop event includes `cache: :write`. A commit error after
successful streamed delivery includes `cache: :write_error` and
`result: :cache_error`, but the response still fails open because the body was
already delivered.

Generated CDN HTTP cache handling emits non-span events. The first three come
from `ImagePipe.Response.CachePolicy` and fire **only** on a mount whose
`%ImagePipe.Dialect.Resolved{}` carries `http_cache: :generated` — the
declarative tier today. An ordered dialect is `http_cache: :dialect_owned`, so
the policy is skipped and none of the three fire:

- `[:image_pipe, :http_cache, :prepare]` with `:effective_mode`,
  `:byte_identity`, and `:etag`.
- `[:image_pipe, :http_cache, :conditional, :match]` with `method: :get` or
  `method: :head`.
- `[:image_pipe, :http_cache, :fallback, :no_store]` with `:adapter`,
  `:source_kind`, and `:reason`.

The fourth is emitted by `ImagePipe.Response.Sender` on every mount:

- `[:image_pipe, :http_cache, :cache_hit, :headers]` with booleans for `:etag`,
  `:generated_cache_headers`, and `:representation_headers`.

These events don't include request paths, source identities, cache keys, or ETag
values.

The opt-in default Logger renders all four at the base level under its own
`:http_cache` event group (so a host can include or exclude them via the
`:events` option independently of the storage `:cache` group), e.g.:

```text
image_pipe http_cache prepare: generate (byte_identity strong, etag true)
image_pipe http_cache conditional match: get
image_pipe http_cache fallback no_store: missing_byte_identity (url)
image_pipe http_cache cache_hit headers: etag true (generated true, representation false)
```

## Output dimension clamp (`[:output, :clamp]`)

When the realized final image exceeds the effective result caps — the tighter of
the host `max_result_width`/`max_result_height`/`max_result_pixels` config and the
negotiated output encoder's hard limit (`min(host, encoder)`) — ImagePipe
uniformly downscales it to fit before encoding and emits a one-shot (non-span)
marker. This both keeps encoding from failing (WebP caps each dimension at 16383,
AVIF at 16384, JPEG at 65535; PNG effectively unbounded) and serves the host result cap as a
downscale rather than an error (imgproxy `limitScale` parity). The common trigger
is the host cap (default 8192 per axis), which is below the encoder limits.

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

This metadata is product-neutral and non-sensitive (no URLs, secrets, or PII).

The event is emitted from a single site — the shared clamp seam
`ImagePipe.Output.Clamp.clamp_with_telemetry/4`, called once from the runner's
producer-side build — so every dialect produces identical `[:output, :clamp]`
metadata. It fires only when the
clamp actually downscaled the image; a within-caps result is a silent no-op.

The opt-in default Logger attaches to this event and renders it at `:warning`,
matching imgproxy's `slog.Warn` for the same condition, e.g.:

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

Both surfaces see it: the opt-in default Logger renders one `:warning` line
(`image_pipe debug collect: error (<tag>)`), and the OTel exporter folds it as an
annotation onto the enclosing span (typically `[:source, :fetch_decode]`).

## Attaching handlers

A host application can attach to all ImagePipe span events with
`:telemetry.attach_many/4`:

```elixir
defmodule MyApp.ImagePipeTelemetry do
  require Logger

  @stages [
    [:request],
    [:parse],
    [:source, :resolve],
    [:cache, :lookup],
    [:output, :negotiate],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:transform, :input_color_management],
    [:transform, :operation],
    [:transform, :materialize],
    [:encode],
    [:encode, :search],
    [:encode, :search, :probe],
    [:render],
    [:cache, :stage],
    [:cache, :write],
    [:send],
    [:deliver]
  ]

  def attach do
    events =
      for stage <- @stages,
          suffix <- [:start, :stop, :exception] do
        [:image_pipe | stage] ++ [suffix]
      end

    :telemetry.attach_many(
      "my-app-image-pipe",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.debug(
      "image_pipe event=#{inspect(event)} " <>
        "measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
```

When customizing `telemetry_prefix`, attach to that same prefix instead of
`[:image_pipe]`.

## Tracing (opt-in)

The events above are raw `:telemetry` events. ImagePipe also ships an **opt-in
span tracer** that consumes those events, reconstructs correctly-nested
distributed-trace-shaped spans (one `trace_id` per request, parent/child
relationships preserved across the `[:transform, :execute]` /
`[:transform, :operation]` / `[:transform, :materialize]` nesting and across the
request → `ImagePipe.Delivery` coordinator → producer process seams — the
producer-emitted `[:encode]` span parents to the request root, and `[:deliver]`
nests under `[:send]` in the request process), and hands each finished span to
a pluggable exporter as an `ImagePipe.Telemetry.Trace.Span`.

The tracer is **not** attached automatically. A host opts in with
`ImagePipe.Telemetry.attach_tracer/1` and removes it with
`ImagePipe.Telemetry.detach_tracer/0`. Both are host-startup configuration, so
`attach_tracer/1` **raises** `ArgumentError` on invalid options rather than
returning a tagged error.

```elixir
# Attach the bundled stdlib-Logger exporter:
ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter)

# ... later ...
ImagePipe.Telemetry.detach_tracer()
```

### Options

| Option            | Type            | Default                   | Meaning                                                                 |
| ----------------- | --------------- | ------------------------- | ----------------------------------------------------------------------- |
| `:exporter`       | module (atom)   | — (required)              | Module implementing the `ImagePipe.Telemetry.Trace.Exporter` behaviour. |
| `:prefix`         | list of atoms   | `[:image_pipe]`           | Telemetry event prefix to subscribe to. Reuses `ImagePipe.Telemetry.default_prefix()`; match your configured `telemetry_prefix`. |
| `:extract_inbound`| boolean         | `false`                   | Extract an inbound W3C `traceparent` header so the root span continues an upstream trace. Off by default — only enable behind a trusted edge. |
| `:finch_spans`    | boolean         | `true`                    | Also capture physical Finch wire spans for outbound source fetches.     |

`attach_tracer/1` raises `ArgumentError` when an option is unknown, has the wrong
type, `:exporter` is missing, or the exporter module is not loaded / does not
export `export/1`.

### The exporter contract

A host implements `ImagePipe.Telemetry.Trace.Exporter`:

```elixir
@callback export(ImagePipe.Telemetry.Trace.Span.t()) :: :ok
```

- `export/1` is called **synchronously** in the process that emitted the span's
  `:stop` / `:exception`. Keep it cheap and non-blocking — hand real I/O off to a
  batch processor. It must return `:ok` and should not raise.
- Span **attributes are pre-filtered for sensitivity** by the capture layer
  (allowlist only — source URLs, request paths, signatures, and tokens are never
  copied in). Exporters that fan out to third parties remain responsible for
  their own egress policy.
- Attributes carry **both the start metadata and the allowlisted stop
  metadata** — the per-result verdict (e.g. the encode-search `chosen_quality` /
  `final_score` / `scorer`, the HTTP `status`, the classified `error` tag, the
  decoded shape). Stop keys win on collision. Exporters need not read the
  telemetry events separately to recover the outcome.
- The allowlist covers **attributes only**. A span's `status_message` and the
  `reason` on a folded `exception` event carry the raw exception reason
  (`inspect/1`, standard tracing behavior) and are **not** allowlist-filtered,
  so an exporter that renders them to third parties should be aware they may
  embed an exception message. (The bundled `LogExporter` renders neither.)

### `LogExporter`

`ImagePipe.Telemetry.Trace.LogExporter` is the bundled default. It is
**stateless and flat by design**: it logs one structured `Logger.info` line per
completed span as that span closes, in the process that emitted it. It does
**not** buffer spans into a tree or wait for a root to close — parentage is
carried in the `parent=` field so a downstream log pipeline can reconstruct
nesting.

```
image_pipe.trace trace=<trace_id> span=<span_id> parent=<parent_span_id|-> <name> dur=<duration_native|-> status=<ok|error|unset>
```

### Inbound extraction and sampling

Inbound `traceparent` extraction is **opt-in** (`extract_inbound: true`) because
trusting an inbound trace header from an untrusted client lets a caller pin your
`trace_id`; enable it only behind a gateway you control. When enabled and a valid
W3C `traceparent` is present, the request root span continues that trace and
parents to the inbound span; otherwise it mints a fresh root.

**Sampling is deferred to the host.** ImagePipe propagates `trace_flags` but does
not implement a sampler. A host that wants head- or tail-based sampling does it in
its exporter (e.g. drop spans whose `trace_flags` indicate "not sampled", or
batch and sample in the downstream collector).

### OpenTelemetry export

`ImagePipe.Telemetry.Trace.OpenTelemetryExporter` replays captured spans into a
host-running OpenTelemetry SDK via the public OTel API. Optional dependency: ImagePipe
compiles against `:opentelemetry_api` only (declared `optional: true`); the **host**
adds `:opentelemetry` (+ an OTLP exporter) and starts the SDK.

```elixir
# host deps: {:opentelemetry, "~> 1.7"}, {:opentelemetry_exporter, "~> 1.8"}
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

**Hierarchy and correlation:** spans are buffered per trace and replayed into the
SDK top-down when the request's root span finishes, so every child is parented
onto its parent's OTel-minted span context — the full span tree survives into
Jaeger/Tempo. (The replay buffer is a GenServer supervised by ImagePipe's
application; it is inert unless this exporter is attached, and best-effort:
buffered traces are dropped on crash/shutdown, and under extreme load spans for
new traces are shed rather than growing without bound.) Correlation with logs
is trace-level: logs and OTel spans share the `trace_id`; OTel mints its own
span ids, so the `span=` ids in `LogExporter` lines will not match OTel span
ids. When ImagePipe is *not* the originating tracer (`extract_inbound: true`
behind a traced caller), the root span is a real child of the caller. As the
originator, only the root carries a synthetic "remote parent" (it forces
ImagePipe's `trace_id` onto the OTel trace) — at most one out-of-trace parent
reference per trace, on the root. Traces whose root never finishes (the
emitting process died) are flushed flat after ~10 s, each span keeping its
recorded parent id; spans finishing shortly after the root (cross-process
stages) still parent correctly within the same window, except a late span
whose own parent is also late and not yet replayed, which falls back to a
dangling parent. One cosmetic side effect of forcing the `trace_id`: every
replayed span is marked as having a *remote* parent (`parent_span_is_remote`),
because the OTel SDK propagates the root's synthetic remote-parent flag down
the tree. Hierarchy and trace identity are unaffected, but a `parent_based`
sampler that treats remote and local parents differently will take its
remote-parent branch for all ImagePipe spans — keep both branches on the same
policy. If `:opentelemetry_api` is absent, `attach_tracer/1` raises;
if present but the SDK isn't started, spans are silently dropped by the noop
tracer (start the SDK). See `docs/cookbook/opentelemetry-jaeger.md`.

**Forced sampled flag:** the OTel exporter always emits spans with the W3C `-01`
sampled flag set — trace-level correlation requires every span to reach the SDK.
Host-side `trace_flags` sampling does not apply on this path; do sampling in your
downstream OTel collector instead.

**Span attributes:** the `[:output, :clamp]` one-shot's `source_dimensions` /
`dimensions` / `limits` and the `[:transform, :input_color_management]` span's
`working_space` / `imported?` are on the capture allowlist, so they surface as
OTel span attributes on every dialect (all product-neutral geometry, a
colorspace atom, and a boolean; no secrets).
