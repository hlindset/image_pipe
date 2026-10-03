# Telemetry event reference

Every `:telemetry` event ImagePipe emits, grouped by stage. Attaching
handlers is covered in [Monitoring with telemetry](telemetry.md), and how
events become traces in [Request tracing](tracing.md).

## Event names

An event name is the telemetry prefix, then the stage, then a suffix for
spans. The prefix is `[:image_pipe]` unless `telemetry_prefix` sets another
(see `ImagePipe.config/1`). Names on
this page leave out the prefix, so `[:request]` is emitted as
`[:image_pipe, :request, :start]`, `[:image_pipe, :request, :stop]`, and
`[:image_pipe, :request, :exception]`.

There are two kinds of event:

- **Span.** Emitted with `:telemetry.span/3` conventions: a `:start` event,
  then either `:stop` or `:exception`. Stop metadata includes the start
  metadata.
- **One-shot.** A single event with no suffix. Some one-shot names end in
  `:stop`, such as `[:cache, :flush, :stop]`, but have no matching `:start`.

Which events a request emits depends on its path. A conditional `304` or an
output-cache hit emits no fetch, decode, transform, or encode events.

## Measurements

Spans carry the measurements of `:telemetry.span/3`:

- `:start`: `:system_time` and `:monotonic_time`.
- `:stop` and `:exception`: `:duration` and `:monotonic_time`.

Durations use the native time unit. Convert them with
`System.convert_time_unit/3`. One-shot events have no measurements unless
their entry lists some.

## Common metadata

These keys mean the same on every event that carries them. A key whose value
would be `nil` is left out of the metadata.

- `:result` (atom): the outcome. See [result values](#result-values).
- `:error` (atom): the error category from `ImagePipe.Error.tag/1`, on
  failures. Some encode-search failures carry the raw error reason instead.
- `:status` (integer): the HTTP status, on events that know it.
- `:cache` (atom): the cache outcome, on cache events.
- `:pool` (`:input` or `:output`): which cache pool emitted the event.
- `:output_format` (atom): the output format, such as `:webp`.
- `:source_mount` (atom): the source that served the request. Absent for
  `{:file, _}` and `{:binary, _}` inputs.
- `:telemetry_span_context` (reference): added by `:telemetry.span/3` to
  correlate the events of one span.

`:exception` events also carry `:kind`, `:reason`, and `:stacktrace`.

Metadata never includes request paths, source URLs, signatures, or
credentials. [What events contain](telemetry.md#what-events-contain)
explains what to watch for in your own handlers.

## Result values

The request outcome, used by `[:request]`, `[:send]`, `[:source, :watermark]`,
and `[:cache, :refresh]`:

- `:ok`
- `:options`: an `OPTIONS` request answered with `204`.
- `:not_modified`: a conditional request answered with `304`.
- `:method_not_allowed`: a method other than `GET`, `HEAD`, or `OPTIONS`.
- `:parser_error`: the URL, signature, or encrypted source was invalid.
- `:plan_error`: the options can't be served, such as an unavailable detector.
- `:source_error`: the original couldn't be fetched.
- `:processing_error`: decoding, processing, encoding, or streaming failed.

Stages add their own values: `:cache_error` on cache events,
`:materialize_error` on `[:transform, :materialize]`, `:output_error` on
`[:output, :negotiate]`, `:client_closed` on `[:deliver]`, and `:error` for a stage failure with no finer category. Each
entry lists the values its event uses.

## Request events

### `[:request]`

Span. Wraps the whole request, starting before parsing. `ImagePipe.run/4`
emits it too, around plan checks and the shared source, transform, and output
stages. `ImagePipe.write/5` writes its destination after the span closes.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): a request [result value](#result-values). When a
    response fails after streaming has started, it matches the `[:send]`
    result.
  - `:status` (integer): the response status. Plug requests only.
  - `:error` (atom): the error category, on failure. `ImagePipe.run/4`
    leaves it out for `:parser_error` and `:plan_error`.

### `[:parse]`

Span. Plug requests only. Wraps signature verification, source decryption,
preset lookup, and URL parsing. Why a request was rejected is on the
`[:request]` stop.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok` or `:error`.
  - `:sig_key_index` (integer): the position in the key list of the key that
    verified the signature (`0` for the first key), on success. Absent for an unsigned request.

### `[:preset, :lookup]`

Span. Emitted when a request names presets the static preset map doesn't
define, so `ImagePipe.PresetLookup` is called. Nested in `[:parse]`, or in
`[:request]` for `ImagePipe.run/4`.

- Start metadata: `:names` (list of strings), the preset names of the first
  batch.
- Stop metadata:
  - `:result` (atom): `:ok` or `:error`.
  - `:fetched` (integer): definitions the lookup returned.
  - `:batches` (integer): calls to `fetch/2`.
  - `:reason` (atom): `:lookup_unavailable` or `:invalid_definition`, on
    failure.

### `[:processing, :admission]`

Span. Emitted for requests that generate an image under a
[processing pool](processing-controls.md). Measures the wait for a pool slot.

- Start metadata: `:active` and `:queued` (integer), the pool's jobs before
  this request.
- Stop metadata: `:result` (atom), one of `:admitted`, `:overloaded`,
  `:queue_timeout`, `:cancelled`, `:worker_down`, or `:unavailable`.

### `[:processing, :execute]`

Span. Follows a successful admission and measures the admitted job until its
stream is cleaned up, including pauses while the client reads. The pool stops
the span when the worker dies, too. Spans of the generation stages nest in it.

- Start metadata: `:active` and `:queued` (integer).
- Stop metadata: `:result` (atom), one of `:ok`, `:processing_error`,
  `:timeout`, `:cancelled`, `:worker_down`, or `:unavailable`.

### `[:send]`

Span. Plug requests only. Wraps every response the Plug sends: images,
error responses, info and placeholder bodies, `304`, the `OPTIONS` `204`, and
the `405`.

- Start metadata: `:result` (atom), the request result being sent.
- Stop metadata:
  - `:result` (atom): the result after sending. `:processing_error` when a
    streamed response failed partway.
  - `:status` (integer): the sent status.

### `[:deliver]`

Span. Nested in `[:send]` for streamed image responses. Measures sending the
encoded chunks to the client, not encoding them.

- Start metadata:
  - `:output_format` (atom): the format sent.
  - `:skipped` (`true`): the original is sent unchanged under
    `skip_processing_formats`, and `:output_format` is its format.
- Stop metadata:
  - `:result` (atom): `:ok`, `:processing_error` when the stream failed, or
    `:client_closed` when the client disconnected.
  - `:status` (integer): the response status.
  - `:stream_phase` (atom): where a failure happened, such as `:encode` or
    `:client`. On failure only.
  - `:error` (atom): the error category, on failure.

## Source events

### `[:source, :resolve]`

Span. Wraps routing the request to a source and the source adapter's
`resolve/3`.

- Start metadata: `:source_mount` (atom).
- Stop metadata:
  - `:result` (atom): `:ok` or `:source_error`.
  - `:error` (atom): the error category, on failure.

### `[:source, :fetch]`

Span. Wraps the source adapter's `fetch/3`. For HTTP and S3 sources it nests
in `[:source, :stage]`, and for file sources in `[:source, :fetch_decode]`.

- Start metadata: `:source_mount` (atom).
- Stop metadata:
  - `:result` (atom): `:ok`, `:not_modified` when the origin confirmed a
    cached original with `304`, or `:source_error`.
  - `:error` (atom): the error category, on failure. See
    [`[:source, :fetch_decode]`](#source-fetch_decode) for the categories.

### `[:source, :stage]`

Span. Wraps downloading or revalidating an HTTP or S3 original, including
storing it in the input cache. It runs whether or not a cache is configured,
and is skipped when a cached original is still fresh.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok`, `:source_error`, or another request result.
  - `:error` (atom): the error category, on a source error. The categories
    are those of [`[:source, :fetch_decode]`](#source-fetch_decode).

### `[:source, :fetch_decode]`

Span. Wraps opening the original, decoding it, and checking the body, pixel,
and frame limits. It stops before transforms run. libvips decodes lazily, so
decode outcomes are reported here, and pixel work is timed by
`[:transform, :materialize]` and `[:encode]`.

`output=info` with the `blurhash` flag decodes the original twice and emits
this span twice. The second one wraps only the decode.

- Start metadata: none.
- Stop metadata on success:
  - `:result` (atom): `:ok`.
  - `:detected_source_format` (atom): the format read from the file's
    signature, such as `:jpeg`, or `:unknown`.
  - `:source_format_resolution` (atom): `:detected` when the signature named
    the format, or `:libvips_codec` when libvips told AVIF and HEIF apart.
  - `:original_dims` (`{width, height}`): the stored image size.
  - `:loaded_dims` (`{width, height}`): the size actually decoded.
  - `:load_option` (`{:shrink, integer}` or `{:scale, float}`): the
    shrink-on-load option, when one was used.
  - `:achieved_shrink` (`%{w: float, h: float}`): how much smaller the
    decoded image is than the stored one, per axis. `1.0` when the original
    was decoded at full size.
  - `:source_frames` (integer): the frames or pages the original declares.
    Only one is decoded.
  - `:page` (integer): the page selected with `page`, when the request set
    one.
- Stop metadata for an original sent unchanged under
  `skip_processing_formats`: `:result` (`:ok`), `:detected_source_format`,
  and `:skipped` (`true`).
- Stop metadata on failure:
  - `:result` (atom): `:source_error` or `:processing_error`.
  - `:error` (atom): the error category. Source errors include
    `:body_too_large` (the body crossed `max_body_bytes`), `:connect_error`,
    `:receive_timeout`, `:truncated_body`, `:connection_reset`,
    `:connection_closed`, `:transport_error`, `:invalid_body`,
    `:redirect_not_followed`, `:invalid_redirect`, `:too_many_redirects`, and
    `:bad_status` (the origin answered with a non-success status). Processing
    errors include `:decode`, `:input_limit`, `:page_out_of_range`, and
    `:unsupported_source_format`.
  - `:limit` (`:pixels` or `:frames`): with `:input_limit`, the limit that
    rejected the original (`max_input_pixels` or `max_input_frames`).
  - `:page` and `:source_frames` (integer): with `:page_out_of_range`, the
    requested page and the frames the original has. The response is `422`.
  - `:detected_source_format` (atom): with `:unsupported_source_format`, the
    rejected format, such as `:bmp`, `:svg`, or `:unknown`.
  - `:source_loader` (string): with `:unsupported_source_format`, when the
    signature names a supported format but libvips chose a loader for
    another, such as `"dcrawload"`.

### `[:source, :watermark]`

Span. Wraps getting one watermark image, in its own process while the main
original is fetched. That image's source and input-cache spans nest in it.

- Start metadata: `:phase` (atom), `:prepare` when its identity is checked
  before the conditional check, or `:open` when its bytes are read after an
  output-cache miss.
- Stop metadata: `:result` (atom), a request [result value](#result-values).

## Cache events

### `[:cache, :lookup]`

Span. Wraps the output-cache lookup.

- Start metadata: `:pool` (`:output`), and `:cache` (`:disabled`) when no
  output cache is configured.
- Stop metadata:
  - `:result` (atom): `:ok`, or `:cache_error` when the read failed.
  - `:cache` (atom): `:disabled`, `:hit`, `:miss`, or `:read_error`. A read
    error is served as a miss.
  - `:error` (atom): the error category, on a read error.

### `[:cache, :input]`

Span. Wraps opening and checking an original in the input cache. Not emitted
when the output cache hits.

- Start metadata: `:pool` (`:input`).
- Stop metadata:
  - `:result` (atom): `:ok`, or `:cache_error` when the read failed.
  - `:cache` (atom): `:hit`, `:miss`, or `:read_error`. A read error falls
    back to the origin.
  - `:bytes` (integer): the size of the reused original, on a hit.

### `[:cache, :refresh]`

Span. Wraps the background check of a stale original that
[stale-while-revalidate](caching-and-freshness.md#stale-while-revalidate)
starts. It runs outside any request.

- Start metadata: `:pool` (`:input`).
- Stop metadata: `:result` (atom), a request [result value](#result-values).

### `[:cache, :write]`

Span. Wraps committing an entry to either pool.

- Start metadata: `:pool` (atom).
- Stop metadata:
  - `:result` (atom): `:ok` or `:cache_error`.
  - `:cache` (atom): `:write` when stored, or `:write_error`. A cache in
    [bounded mode](cache.md#bounded-mode) that declines the entry reports
    `:admission_rejected` (output pool) or `:stage_skipped` (input pool).
  - `:error` (atom): the error category, on an output-pool write error.
  - `:output_format` (atom): the stored format. Output pool only.

A write error after a streamed response doesn't fail the response, because
the body was already sent.

### `[:cache, :stage]`

One-shot. Emitted when a streamed output-cache miss stops collecting the
entry before committing it.

- Metadata:
  - `:cache` (atom): `:stage_skipped` when the body crossed `max_body_bytes`,
    `:stage_abandoned` when delivery stopped early or the stream failed,
    `:stage_error` when opening or writing the staged entry failed, or
    `:stage_cleanup_error` when discarding it failed.
  - `:result` (atom): `:ok` for skipped and abandoned entries, `:cache_error`
    otherwise.
  - `:reason` (atom): why the entry was skipped or abandoned, such as
    `:too_large`.
  - `:error` (atom): the error category, for `:stage_error` and
    `:stage_cleanup_error`.
  - `:output_format` (atom).

### `[:cache, :coordination]`

One-shot. Emitted when concurrent requests for the same original or image
are coordinated (see [request coalescing](caching-and-freshness.md#request-coalescing)).

- Metadata:
  - `:operation` (atom): `:source` (fetching an original), `:refresh`
    (a background refresh), or `:output` (generating an image).
  - `:pool` (atom): `:input` for `:source` and `:refresh`, `:output` for
    `:output`.
  - `:result` (atom): for `:source` and `:refresh`, one of `:acquired`,
    `:started`, `:coalesced`, `:backoff`, or `:busy`. For `:output`,
    `:acquired` (this request generates), `:waiting` (it waits for another),
    `:ready` (it can check the cache again), `:bypass` (it generates on its
    own), or `:busy` (coordination is at capacity).

### `[:cache, :warm_start]`

Span. Emitted by a bounded `ImagePipe.Cache.FileSystem` cache when it loads
its saved state at startup.

- Start metadata: `:pool` (atom).
- Stop metadata:
  - `:own_state_loaded` (boolean): `true` when this node's state file was
    restored.
  - `:peer_state_files` (integer): state files of other nodes present.

### `[:cache, :admission]`

Span. Emitted by a bounded cache when it decides whether to keep a new entry.

- Start metadata: `:pool` (atom).
- Stop metadata:
  - `:result` (atom): `:admitted` or `:rejected`.
  - `:reason` (atom): why the entry was rejected.
  - `:victim_count` (integer): entries evicted to make room.

### `[:cache, :eviction, :stop]`

One-shot. Emitted when a bounded cache evicts entries in the background to
get back under its size limit.

- Measurements: `:count` (integer), entries evicted, and `:bytes` (integer),
  their total size.
- Metadata: `:trigger` (`:reconcile`) and `:pool` (atom).

### `[:cache, :flush, :stop]`

One-shot. Emitted when a bounded cache writes its state file.

- Measurements: `:bytes` (integer), the file size.
- Metadata: `:result` (`:ok`) and `:pool` (atom).

### `[:cache, :cleanup, :stop]`

One-shot. Emitted when a bounded cache deletes stale state files of other
nodes.

- Measurements: `:removed` (integer), files deleted.
- Metadata: `:pool` (atom).

## Transform events

### `[:transform, :execute]`

Span. Wraps all processing of the image.

- Start metadata:
  - `:operations` (list of atoms): the requested operations, in order.
  - `:operation_count` (integer): their number.
- Stop metadata:
  - `:result` (atom): `:ok` or `:processing_error`.
  - `:error` (atom): the error category, on failure.

Requested and executed operations can differ: `:crop_guided` and
`:crop_region` run as `:crop`, `:canvas` runs as `:extend_canvas`, and one
requested operation can run as several. `:operation_count` can therefore
differ from the number of `[:transform, :operation]` spans.

### `[:transform, :input_color_management]`

Span. Nested in `[:transform, :execute]`. Wraps preparing the decoded image's
colors once before processing, including when nothing needs to change.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok`, or `:processing_error` when an embedded ICC
    profile is corrupt or unsupported (the response is `415`).
  - `:working_space` (atom): the libvips color interpretation processing
    uses, such as `:VIPS_INTERPRETATION_sRGB` or `:VIPS_INTERPRETATION_B_W`
    (grayscale). With `preserve_hdr`, an HDR original keeps
    `:VIPS_INTERPRETATION_RGB16` or `:VIPS_INTERPRETATION_GREY16`.
  - `:imported?` (boolean): `true` when the embedded ICC profile was used to
    convert the image, as for CMYK. RGB and grayscale originals keep their
    values and profile.

### `[:transform, :operation]`

Span. Nested in `[:transform, :execute]`, once per executed operation. libvips
evaluates lazily, so the duration measures building the pipeline, not pixel
work, except for a `[:transform, :materialize]` nested in it.
`[:transform, :materialize]` and `[:encode]` time pixel work.

- Start metadata:
  - `:operation` (atom): the executed operation, such as `:resize`.
  - `:params` (struct): the operation and its parameters.
- Stop metadata:
  - `:result` (atom): `:ok` or `:error`.
  - `:dims` (`{width, height}`): the image size after the operation, on
    success.

### `[:transform, :materialize]`

Span. Wraps computing the image into memory. Every generated image is
computed at least once, at the latest just before encoding.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok`, or `:materialize_error` when the copy failed
    (the response is `415`).
  - `:dims` (`{width, height}`): the size of the computed image, on success.
    After orientation, the size as displayed.

Where the span nests depends on why the image is computed:

- Before an operation that needs the whole image at once (trim, rotation by
  an arbitrary angle, smart or detection crops, or a resize after such a
  rotation): in that `[:transform, :operation]`.
- When EXIF orientation, rotation, or flips are applied: directly in
  `[:transform, :execute]`.
- Just before encoding: in the request span, or in
  `[:processing, :execute]` under a processing pool.

### `[:transform, :detect]`

Span. Wraps running the configured detector for `detect` crops and
`anchor=smart-face`. The duration is the real inference time, including the
first load of a model.

- Start metadata:
  - `:classes` (list of strings, or `:all`): the requested classes.
  - `:weights` (map): the requested weight per class.
- Stop metadata:
  - `:regions` (integer): the regions the detector returned.
  - `:result` (atom): `:detected` (at least one region), `:no_regions` (the
    detector found nothing, and the crop uses attention instead),
    `:unavailable` (the detector reported it is unavailable), or `:error`
    (the detector failed or returned an invalid result).

`:result` describes the detector, not the crop. A `:detected` result whose
regions all lie outside the image still crops by attention.

### `[:transform, :detect, :model]`

Span. Nested in `[:transform, :detect]` when the bundled composite detector
(the default) runs, once per model that ran.

- Start metadata:
  - `:detector` (module): the model's detector module, such as
    `ImagePipe.Transform.Detector.ImageVision.Face`.
  - `:model` (term): the detector's `identity/1` for this request.
  - `:classes` (list of strings, or `:all`): the classes sent to this model.
- Stop metadata:
  - `:result` (atom): `:ok` or `:error`.
  - `:regions` (integer): the regions this model returned. `0` on error.

The union of `:classes` across a request's model spans is the set of classes
actually detected. A requested class that appears in none was unknown to
every model and was dropped.

> #### Keep detector identities free of secrets {: .warning}
>
> A custom detector's `identity/1` appears in `:model`, which every attached
> handler receives, including exporters to third parties.

### `[:transform, :detect, :skipped]`

One-shot. Emitted instead of `[:transform, :detect]` when a request asks for
detection but no detector is configured. The crop uses attention instead.

- Metadata: `:classes` (list of strings, or `:all`) and `:result`
  (`:no_detector`).

### `[:transform, :detect, :blend]`

One-shot. Emitted for `anchor=smart-face` when a face was found and blended
with the attention point. Coordinates are normalized to `0..1`.

- Metadata:
  - `:attention` (`{x, y}`): the libvips attention point.
  - `:face` (`{x, y}`): the area-weighted center of the faces.
  - `:blended` (`{x, y}`): the point used, `(1 - weight) * attention +
    weight * face`.
  - `:weight` (float): the face weight.

The difference between `:attention` and `:blended` is how far the faces moved
the crop.

## Output events

### `[:output, :negotiate]`

Span. Wraps choosing the output format from the request, the original's
format, and whether the final image has alpha.

- Start metadata: `:output_mode` (atom), `:explicit` when the request set a
  format, or `:automatic` when it is negotiated from `Accept`.
- Stop metadata:
  - `:result` (atom): `:ok`, or `:output_error` when no acceptable format
    exists.
  - `:output_format` (atom): the chosen format, on success.
  - `:error` (atom): the error category, on failure.

### `[:output, :terminal]`

Span. Wraps producing an `output=info`, `output=blurhash`, or
`output=lqip-css` body. Not emitted for a cache hit or a `304`.

- Start metadata:
  - `:terminal` (atom): `:info`, `:blurhash`, or `:lqip_css`.
  - `:placeholders` (list of atoms): for `:info`, the placeholders the body
    includes (`:blurhash`, `:lqip_css`), possibly none.
- Stop metadata: `:result` (atom), `:ok` or a request
  [result value](#result-values).

### `[:output, :clamp]`

One-shot. Emitted when the final image is larger than the result limits or
the format allows, and is scaled down before encoding. WebP allows 16383
pixels per side, AVIF 16384, and JPEG 65535. The default result limit of
8192 pixels per side is usually lower.

- Measurements: `:scale` (float), the scale factor applied, below `1.0`.
- Metadata:
  - `:format` (atom): the output format.
  - `:source_dimensions` (`{width, height}`): the size before scaling.
  - `:dimensions` (`{width, height}`): the size after scaling.
  - `:limits` (map): the limits applied, `%{max_width, max_height,
    max_pixels}`, each an integer or `:infinity`.

## Encode events

### `[:encode]`

Span. Wraps building the encoder and producing the first encoded chunk, which
forces the image's pixel work. Nested in the request span, or in
`[:processing, :execute]` under a processing pool.

- Start metadata: `:output_format` (atom).
- Stop metadata:
  - `:result` (atom): `:ok`, or `:processing_error` when encoding failed
    before the first chunk (the response is `500`).
  - `:output_format` (atom).
  - `:error` (atom): the error category, such as `:empty_stream`, on failure.

### `[:encode, :classify]`

Span. Nested in `[:encode]`, before `[:encode, :search]`. Emitted when an
`ssimulacra2` quality search scores crops of a large image. Classifies the
image as a photo or a graphic, which sets the correction applied to the crop
scores.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): always `:ok`.
  - `:content_class` (atom): `:photo`, or `:graphic` (screenshots, text,
    charts, line art).
  - `:applied_offset` (float): the score correction for this format and
    class.
  - `:palette_ent` (float): the brightness-histogram entropy feature, divided
    by 8.
  - `:nat_var` (float): the mid-band gradient feature.

### `[:encode, :search]`

Span. Nested in `[:encode]`. Wraps the search for an encoder quality, run for
a `size`, `ssimulacra2`, or `butteraugli` autoquality method, or for a
`max_bytes` limit on a format with a quality setting. The search encodes the
image at several qualities and delivers one of those encodes.

- Start metadata:
  - `:objective` (atom): `:size`, `:ssimulacra2`, `:butteraugli`, or `:none`
    (only a `max_bytes` limit).
  - `:min_quality` and `:max_quality` (integer): the quality range searched,
    after per-format limits. Absent for `:none`.
  - `:target` (number): the target, in bytes for `:size` and in score units
    otherwise. Absent for `:none`.
  - `:max_bytes` (integer): the byte limit, when set.
- Stop metadata:
  - `:result` (atom): `:ok` or `:processing_error`.
  - `:chosen_quality` (integer): the delivered quality.
  - `:chosen_bytes` (integer): the delivered size.
  - `:iterations` (integer): encodes performed.
  - `:outcome` (atom): `:hit` (the target or limit was met), `:best_effort`
    (it wasn't, and the closest quality in range was used).
  - `:limiting_factor` (atom): with `:best_effort`, why. `:ceiling` or
    `:floor` (the target was out of range), or `:max_bytes` (the limit
    couldn't be met even at the lowest quality).
  - `:final_score` (float): the delivered quality's score, for `ssimulacra2`
    and `butteraugli`.
  - `:scorer` (atom): `:full` when the whole image was scored, or `:crop`
    when crops of a large image were scored instead.
  - `:tiles_scored` (integer): crops scored, at most 16. `:crop` only.
  - `:confirm_passes` (integer): always `0`.

### `[:encode, :search, :probe]`

Span. Nested in `[:encode, :search]`, once for each new encode. A quality
the search already encoded emits nothing again.

- Start metadata:
  - `:quality` (integer): the quality tried.
  - `:phase` (atom): `:objective` (searching for the target) or `:cap`
    (lowering quality to meet `max_bytes`).
- Stop metadata:
  - `:bytes` (integer): the encoded size.
  - `:index` (integer): which encode this is, from 1.
  - `:score` (float): the score computed. Absent for `:size` and `:none`.
  - `:scorer` (atom): `:full` or `:crop`.
  - `:tiles_scored` (integer): crops scored. `:crop` only.
  - `:result` and `:error`: on failure, `:processing_error` and the raw
    error reason.

### Probe cost spans

Spans nested in `[:encode, :search, :probe]` that split its time. They time
real work, unlike `[:transform, :operation]`. The default Logger doesn't log
them.

- `[:encode, :search, :probe, :encode]`: the encode, for every objective.
  Start metadata `:quality`, stop metadata `:result` and `:bytes`.
- `[:encode, :search, :probe, metric, :decode]`: decoding the encoded
  candidate. `metric` is `:ssimulacra2` or `:butteraugli`. Start metadata
  `:bytes`, stop metadata `:result`.
- `[:encode, :search, :probe, metric, :metric]`: computing one score, over
  the whole image or over the crops. Start metadata `:tiles_scored` for crop
  scoring, stop metadata `:result` and `:score`.

### `[:encode, :search, :probe, :chosen]`

One-shot. Emitted once when the search finishes, naming the probe whose
encode is delivered.

- Metadata:
  - `:quality` (integer): equals `:chosen_quality`.
  - `:bytes` (integer): equals `:chosen_bytes`.
  - `:phase` (atom): the phase that encoded it, `:objective` or `:cap`.
  - `:index` (integer): that encode's index.
  - `:score` (float): its score. Absent for `:size` and `:none`.
  - `:scorer` (atom) and `:tiles_scored` (integer): as on the probe.

## HTTP cache events

One-shot events about the `Cache-Control` and `ETag` headers of a response
(see [HTTP caching](cdn-http-cache.md)). None carries a path, source
identity, cache key, or ETag value.

### `[:http_cache, :prepare]`

One-shot. Emitted when the response's cache headers are built.

- Metadata:
  - `:effective_mode` (atom): the `http_cache` mode in use, `:validators`,
    `:auto`, `:public`, or `:private`.
  - `:byte_identity` (atom): `:strong`.
  - `:etag` (boolean): whether the response has an `ETag`.

### `[:http_cache, :conditional, :match]`

One-shot. Emitted when a conditional request matches before the
output-cache lookup and is answered with `304`. A `304` answered after an
output-cache hit doesn't emit it.

- Metadata: `:method` (atom), `:get` or `:head`.

### `[:http_cache, :fallback, :no_store]`

One-shot. Emitted when a response is marked `no-store` because it is a
fallback.

- Metadata:
  - `:reason` (atom): `:detection_failed`, when a crop used attention because
    detection failed.
  - `:source_mount` (atom).

### `[:http_cache, :cache_hit, :headers]`

One-shot. Emitted when an output-cache hit is sent.

- Metadata:
  - `:etag` (boolean): whether the response has an `ETag`.
  - `:generated_cache_headers` (boolean): whether ImagePipe generated
    `Cache-Control` headers.
  - `:representation_headers` (boolean): whether it added headers such as
    `Vary`.

## Debug events

### `[:debug, :collect, :error]`

One-shot. Emitted when reading the original's details for
[debug headers](debug_headers.md) fails. The details are collected on every
generation, whether or not debug headers are on. The request continues
without them.

- Metadata: `:error` (atom), the error category.
