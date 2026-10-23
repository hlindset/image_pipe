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
  `:stop`, such as `[:cache, :eviction, :stop]`, but have no matching `:start`.

Which events a request emits depends on its path. A conditional `304` or an
output-cache hit emits no fetch, decode, transform, or encode events.

## Default Logger lines

`ImagePipe.Telemetry.attach_default_logger/1` logs a line for these events
only:

- [`[:request, :summary]`](#request-summary), one line per request.
- [`[:request, :exception]`](#request), for a request that raised, which
  has no summary.
- [`[:cache, :sweep]`](#cache-sweep) and
  [`[:cache, :eviction, :stop]`](#cache-eviction-stop), which belong to no
  request.
- Failures of [`[:cache, :write]`](#cache-write) and
  [`[:cache, :stage]`](#cache-stage), at `:warning`, since a write can end
  after its request's line.

With `stages: true`, every other event logs a line too. Any other Logger
line an entry below describes appears only with `stages: true`.

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
  failures.
- `:status` (integer): the HTTP status, on events that know it.
- `:cache` (atom): the cache outcome, on cache events.
- `:pool` (atom): which pool emitted the event, such as `:input` or
  `:output`.
- `:output_format` (atom): the output format, such as `:webp`.
- `:source_name` (atom): the source that served the request. Absent for
  `{:file, _}` and `{:binary, _}` inputs.
- `:telemetry_span_context` (reference): added by `:telemetry.span/3` to
  correlate the events of one span.

`:exception` events also carry `:kind`, `:reason`, and `:stacktrace`.

Metadata never includes signing or encryption keys. In source URLs, each
query value and any user name and password are replaced with `REDACTED`. [What events contain](telemetry.md#what-events-contain) lists
the paths and source URLs metadata includes.

## Result values

The request outcome, used by `[:request]`, `[:send]`, `[:source, :watermark]`,
and `[:cache, :refresh]`:

- `:ok`
- `:options`: an `OPTIONS` request answered with `204`.
- `:not_modified`: a conditional request answered with `304`.
- `:method_not_allowed`: a method other than `GET`, `HEAD`, or `OPTIONS`.
- `:parser_error`: the URL, signature, source, or encrypted source was
  invalid.
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

- Start metadata, Plug requests only:
  - `:method` (string): the HTTP method, such as `"GET"`.
  - `:path` (string): the request path, with the path the Plug is mounted
    at, cut at the source:
    - The first `src`, `src64`, or `enc` segment that has a source after it
      is followed by `REDACTED`, and the rest of the path and the query string
      are left out, as in `/w=200/src/REDACTED`. Once the request parses,
      the source is in `:source_url` on the `[:request]` stop.
    - Each `wm-src64=` value is replaced with `REDACTED`. A value in
      standard base64 can hold `/`, so the segments after it made only of
      base64 characters are dropped too.
    - Without a source segment, the query string is kept with each value
      replaced with `REDACTED`, as in `?v=REDACTED`.
    - Bytes that aren't valid UTF-8 become `U+FFFD`.
    - Other segments are kept as sent, including the URL signature (`sig=`)
      and `wm-enc=` values.
- Stop metadata:
  - `:result` (atom): a request [result value](#result-values). When a
    response fails after streaming has started, it matches the `[:send]`
    result.
  - `:status` (integer): the response status. Plug requests only.
  - `:error` (atom): the error category, on failure. `ImagePipe.run/4`
    leaves it out for `:parser_error` and `:plan_error`.
  - `:source_url` and `:watermark_source_urls`: as on the
    [`[:parse]`](#parse) stop. Plug requests that parsed only.

### `[:request, :summary]`

One-shot. Emitted once per request, right after the `[:request]` stop, with
what the request did and how long its parts took, gathered from the events
of every process that served it. It is emitted only if a handler is
attached to it when the request starts. Work that runs after the response,
such as the output cache write, isn't in it. The default Logger writes it as
one line, and the tracer doesn't use it.

- Measurements: `:duration` (integer, native time units), as on the
  `[:request]` stop.
- Metadata. Each field is present only when the request reached the stage
  that produces it:
  - `:method` and `:path`: as on the `[:request]` start.
  - `:status`, `:result`, and `:error`: as on the `[:request]` stop.
  - `:source_url` and `:watermark_source_urls`: as on the
    [`[:parse]`](#parse) stop. The default Logger writes them first among
    the `key=value` fields, as `source_url=` and one
    `watermark_source_url=` for each watermark source.
  - `:duration_ms` (integer): the request's duration in milliseconds.
  - `:reason` (string): the message the error response's body gives, on
    failure. Plug requests only.
  - `:bytes` (integer): the body bytes sent. Plug requests only.
  - `:sig_key` (integer): the position in the key list of the key that
    verified the URL signature, counting from `0`. Absent for an unsigned
    request.
  - `:cache` (atom): the output cache's answer, as on
    [`[:cache, :lookup]`](#cache-lookup), or `:coalesced` when the response
    came from another request's work, or `:not_modified` for a `304`.
  - `:download` (atom): for a request that waited for another request's
    download of a new original, `:coalesced` when it waited until the other
    request had the original, or `:bypass` when it stopped waiting for any
    other reason (see [`[:cache, :coordination]`](#cache-coordination)).
  - `:staging` (`:memory`) and `:staging_reason` (atom): the original was
    held in memory instead of a temporary file, as on
    [`[:source, :stage]`](#source-stage).
  - `:source` (atom): the source name, from `[:source, :resolve]`.
  - `:source_fetch` (atom) and `:fetch_ms` (integer): the result and
    duration of [`[:source, :fetch]`](#source-fetch).
  - `:input` (atom), `:input_size` (`{width, height}`), and `:decode_ms`
    (integer): the original's format and stored size, and the duration of
    [`[:source, :fetch_decode]`](#source-fetch_decode).
  - `:ops` (list of atoms): the operations that ran, in order.
  - `:output_size` (`{width, height}`): the image size after the last
    operation.
  - `:clamped` (`{width, height}`): the size the result was scaled down to,
    when it was larger than the result limits or the format allows, as on
    [`[:output, :clamp]`](#output-clamp).
  - `:output` (atom): the output format, or the terminal (`:info`,
    `:blurhash`, `:lqip_css`).
  - `:encode_ms` (integer): the duration of [`[:encode]`](#encode).
  - `:quality` (integer) and `:quality_search` (atom), from a search for
    `autoquality` or `max-bytes`, as on [`[:encode, :search]`](#encode-search).
    `:quality` is the quality the search chose, and `:quality_search` is its
    outcome, `:hit` or `:best_effort`.
  - `:admission` (atom) and `:queue_ms` (integer): the result and duration
    of [`[:processing, :admission]`](#processing-admission).
  - `:priority` (`:low`): the request had
    [low priority](processing/request.md#priority).
  - `:detect` (atom): the result of
    [`[:transform, :detect]`](#transform-detect), or of
    [`[:transform, :detect, :skipped]`](#transform-detect-skipped) when
    detection didn't run.
  - `:degraded` (`true`): the response is a fallback that isn't stored, as
    on [`[:http_cache, :fallback, :no_store]`](#http_cache-fallback-no_store).
  - `:ignored` (list of strings): the URL keys of options that had no
    effect, as on [`[:request, :ignored_options]`](#request-ignored_options).
  - `:skipped` (`true`): the original was sent unchanged under
    `skip_processing_formats`.
  - `:client_closed` (`true`): the client disconnected before the response
    was sent in full.

### `[:parse]`

Span. Plug requests only. Wraps signature verification, source decryption,
preset lookup, and URL parsing. Why a request was rejected is on the
`[:request]` stop.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok` or `:error`.
  - `:sig_key_index` (integer): the position in the key list of the key that
    verified the signature (`0` for the first key), on success. Absent for an unsigned request.
    With `stages: true`, the default Logger shows it as `(signing key 1)`.
  - `:source_url` (string): the request's source as ImagePipe parsed it, on
    success: a `src` source percent-decoded, a `src64` source decoded from
    base64, or an `enc` source decrypted. It's a URL or a path, such as
    `photos/cat.jpg`. Each value in its query string is replaced with
    `REDACTED`, as in `?X-Amz-Signature=REDACTED`, and so is a user name and
    password, as in `https://REDACTED@origin.example/cat.jpg`. Bytes that
    aren't valid UTF-8 become `U+FFFD`, and control characters, such as a
    line break, are percent-encoded (`%0A`).
  - `:watermark_source_urls` (list of strings): the watermark source of each
    group that has one, set with `wm-src64=` or `wm-enc=` or by a preset, in
    group order, with credentials replaced the same way. Absent when no
    group has a watermark source.

### `[:request, :ignored_options]`

One-shot. Emitted after parsing when the URL wrote options that have no
effect, which the request [ignores](requesting-images.md#ignored-options).
`ImagePipe.run/4` emits it too, for options the plan sets. Options that a
preset or the request defaults supply aren't reported. The request summary
lists them as `:ignored`. With `stages: true`, the default Logger also logs
the event at its base level, as
`image_pipe request ignored options: ok (fit, enlarge)`.

- Metadata:
  - `:options` (list of strings): the URL keys of the ignored options, such
    as `["fit", "enlarge"]`. Never their values.
  - `:locations` (list): where each option is, as in
    `ImagePipe.Plan.Spec.Issue`. Not copied to trace spans.

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
  this request, and `:priority` (atom), `:normal` or `:low`, the request's
  [priority](processing/request.md#priority). `:continuation` (boolean) is
  `true` for the second turn of a request whose original was decoded while
  it downloaded (see [deadlines](processing-controls.md#deadlines)).
- Stop metadata: `:result` (atom), one of `:admitted`, `:overloaded`,
  `:queue_timeout`, `:cancelled`, `:worker_down`, or `:unavailable`, or
  `:timeout` when a second turn's deadline passes while it waits.

### `[:processing, :execute]`

Span. Follows a successful admission and measures the admitted job until its
stream is cleaned up, including pauses while the client reads. The pool stops
the span when the worker dies, too. Spans of the generation stages nest in it.
After a timeout or cancellation, the span remains open until the worker
finishes, matching the lifetime of its processing slot.

- Start metadata: `:active` and `:queued` (integer), and `:priority` (atom).
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

- Start metadata: `:source_name` (atom).
- Stop metadata:
  - `:result` (atom): `:ok` or `:source_error`.
  - `:error` (atom): the error category, on failure.

### `[:source, :fetch]`

Span. Wraps the source adapter's `fetch/3`. For HTTP and S3 sources it nests
in `[:source, :stage]`, and for file sources in `[:source, :fetch_decode]`.

- Start metadata: `:source_name` (atom).
- Stop metadata:
  - `:result` (atom): `:ok`, `:not_modified` when the origin confirmed a
    cached original with `304`, or `:source_error`.
  - `:error` (atom): the error category, on failure. See
    [`[:source, :fetch_decode]`](#source-fetch_decode) for the categories.

### `[:source, :stage]`

Span. Wraps downloading or revalidating an HTTP or S3 original. It runs
whether or not a cache is configured. A request whose original is still
fresh runs it only when it needs the original's bytes.

- Start metadata: none.
- Stop metadata:
  - `:result` (atom): `:ok`, `:source_error`, or another request result.
  - `:error` (atom): the error category, on a source error. The categories
    are those of [`[:source, :fetch_decode]`](#source-fetch_decode).
  - `:staging` (`:memory`): the original was held in memory because it
    couldn't be written to a temporary file. Absent when it was written to
    one.
  - `:staging_reason` (atom), with `:staging`: `:dir` when the `image_pipe`
    directory in the system's temporary directory can't be created or isn't
    a directory only this user can access, `:open` when the temporary file
    couldn't be created, or `:write` when writing to it failed.

### `[:source, :fetch_decode]`

Span. Wraps opening the original, decoding it, and checking the body, pixel,
and frame limits. It stops before transforms run. libvips decodes lazily, so
decode outcomes are reported here, and pixel work is timed by
`[:transform, :materialize]` and `[:encode]`.

`output=info` decodes the original a second time, and emits this span twice,
when it has the `blurhash` flag. It does the same for the `lqip-css` flag when
the request has one group, no resize, and no effects sized in pixels, because
that placeholder can then use a smaller decode. Both flags share the second
decode, and its span wraps only the decode.

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
    rejected format, such as `:bmp` or `:unknown`, or `:svg` without the
    `image_pipe_svg` package.
  - `:source_loader` (string): with `:unsupported_source_format`, when the
    signature names a supported format but libvips chose a loader for
    another, such as `"dcrawload"`.

### `[:source, :decode_open]`

Span. Wraps one libvips open of an image, during
[`[:source, :fetch_decode]`](#source-fetch_decode) or while a watermark image
is decoded. A request opens the original once to read its header, once more
to read a page selected with `page`, and again when decoding needs other
options than the header read, such as a streamed download or a smaller decode
size. The default Logger doesn't log it.

- Start metadata:
  - `:access` (atom): `:sequential` or `:random`.
  - `:page` (integer): the page selected with `page`, when the open selects
    one.
- Stop metadata: `:result` (atom), `:ok` or `:processing_error`.

### `[:source, :svg_render]`

Span. Wraps rendering an SVG: parsing it, estimating the rendering cost, and
rendering it at the size the request needs. An SVG original renders during
[`[:source, :fetch_decode]`](#source-fetch_decode), and an SVG watermark
during [`[:transform, :execute]`](#transform-execute).

- Start metadata: `:asset` (atom), `:original` or `:watermark`.
- Stop metadata on success:
  - `:result` (atom): `:ok`.
  - `:intrinsic_dims` (`{width, height}`): the SVG's own size in pixels.
  - `:rendered_dims` (`{width, height}`): the size it rendered at.
  - `:work` (integer): the estimated rendering work, which `:svg`'s
    `:max_render_work` limits.
  - `:peak` (integer): the estimated pixels of intermediate images held at
    once, which `:svg`'s `:max_render_pixels` limits.
  - `:images` (integer): embedded raster images drawn, counting each draw.
  - `:image_pixels` (integer): the pixels those draws decode.
- Stop metadata on failure:
  - `:result` (atom): `:processing_error`.
  - `:error` (atom): `:decode` for an SVG that doesn't parse, or
    `:input_limit`.
  - `:limit` (atom): with `:input_limit`, the limit that rejected the SVG:
    `:svg_bytes`, `:svg_elements` (too many elements once reused content,
    such as `<use>` copies and markers, is counted at each use),
    `:svg_entities` (entity references that would expand past 1,000,000
    characters), `:svg_text` (more than 10,000 bytes of text in one
    `<text>` element, or 1,000,000 in all), `:svg_nesting` (embedded SVGs
    nested too deep), `:pixels` (an original's render, or an embedded image,
    is over `max_input_pixels`), `:svg_render_work`, `:svg_render_pixels`,
    or `:svg_render_extent` (drawn geometry reaches more than 32,767 pixels
    from the canvas, which the renderer can't draw).

### `[:source, :watermark]`

Span. Wraps getting one watermark image, in its own process while the main
original is fetched. That image's source spans nest in it.

- Start metadata: `:phase` (atom), `:prepare` when its identity is checked
  before the conditional check, or `:open` when its bytes are read after an
  output-cache miss.
- Stop metadata: `:result` (atom), a request [result value](#result-values).

## Cache events

### `[:cache, :lookup]`

Span. Wraps a lookup in the output cache or in the instance's memory.

- Start metadata: `:pool` (`:output` or `:memory`), `:cache_key` (string,
  the hash of the cache key looked up), `:entry` (atom), and `:cache`
  (`:disabled`) when no output cache is configured and the pool is
  `:output`. `:entry` is `:response` for a processed response, or
  `:source_record` for the record of the original that responses were made
  from. `:pool` is `:memory` for a source record looked up on an instance,
  and `:output` with `cache: :disabled` without one.
- Stop metadata:
  - `:result` (atom): `:ok`, or `:cache_error` when the read failed.
  - `:cache` (atom): `:disabled`, `:hit`, `:miss`, or `:read_error`. A read
    error is served as a miss.
  - `:bytes` (integer): the size of the cached body, on a hit for a processed
    response. The span ends before the body is read, so its duration doesn't
    include reading it.
  - `:cache_key` and `:entry`: as on start.
  - `:error` (atom): the error category, on a read error.

### `[:cache, :refresh]`

Span. Wraps the background check of a stale original that
[stale-while-revalidate](caching-and-freshness.md#stale-while-revalidate)
starts. It runs outside any request.

- Start metadata: `:pool` (`:input`).
- Stop metadata: `:result` (atom), a request [result value](#result-values).

### `[:cache, :write]`

Span. Wraps committing an entry to the cache. Writes run after the response
is sent. A write nests under the request's span and can end after it.

- Start metadata: `:pool` (atom), and `:cache_key` (string, the hash of the
  entry's cache key).
- Stop metadata:
  - `:result` (atom): `:ok` or `:cache_error`.
  - `:cache` (atom): `:write` when stored, or `:write_error`. A cache that
    declines the entry to stay under its [size limit](cache.md#size-limit)
    reports `:admission_rejected`.
  - `:error` (atom): the error category, on a write error.
  - `:output_format` (atom): the stored format.
  - `:estimated_cost_us` (integer): the estimated
    [work to make the entry](cache.md#work-to-make-an-entry), in
    microseconds, comparable only with other entries' estimates. The cache
    scores entries by it.
  - `:bytes` (integer): the size of the entry's body. On `:write`, the span's
    duration includes syncing the body to disk, so `:bytes` divided by the
    duration gives a rough write speed. The duration also includes waiting for
    the admission decision.
  - `:cache_key` (string): as on start.

A write error after a streamed response doesn't fail the response, because
the body was already sent. The default Logger logs write errors and
exceptions at `:warning`, with or without `stages: true`.

### `[:cache, :stage]`

One-shot. Emitted when a cache write stops before committing the entry.
The default Logger logs `:stage_dropped` and `:stage_error` at `:warning`,
with or without `stages: true`.

- Metadata:
  - `:pool` (atom): `:output`.
  - `:cache` (atom): `:stage_skipped` when the body crossed `max_body_bytes`,
    `:stage_abandoned` when delivery stopped early or the stream failed,
    `:stage_dropped` when the cache dropped the write to keep up with its
    storage (see [writing entries](cache.md#writing-entries)), or
    `:stage_error` when opening or writing the staged entry failed.
  - `:result` (atom): `:ok` for skipped, abandoned and dropped entries,
    `:cache_error` otherwise.
  - `:reason` (atom): why the entry was skipped, abandoned or dropped, such
    as `:too_large`. A dropped write has `:writer_limit` (the cache already
    runs its maximum number of writes), `:pending_limit` (its unfinished
    writes hold too many bytes), `:lagging` (the client got too far ahead of
    the write), or `:deadline` (a response's write was unfinished 30 seconds
    after it started).
  - `:error` (atom): the error category, for `:stage_error`.
  - `:output_format` (atom), or `nil` for a body that isn't an image, such
    as a BlurHash.
  - `:cache_key` (string): the hash of the entry's cache key.

### `[:cache, :coordination]`

One-shot. Emitted when concurrent requests for the same original or image
are coordinated (see [request coalescing](caching-and-freshness.md#request-coalescing)).
Which requests emit it:

- `:source`: none for a source with `internal_cache: :disabled`. For a
  local file, only a request that checks a file read earlier, when a
  processed-image cache is configured.
- `:download`: only a request for an original that no cache has fetched yet,
  or whose details were evicted, when a processed-image cache is configured
  and caching is on for the source, and
  [storage](caching-and-freshness.md#storage-permission) isn't denied for it
  in its configuration. An immutable source with
  `storage: :allow` doesn't emit it, nor does a low-priority request when no
  other request is downloading the original.
- `:refresh`: a request that serves a stale processed image and starts or
  joins its background check.
- `:output`: none when no processed-image cache is configured, when the image
  may not be stored, or for a
  [low-priority request](processing/request.md#priority) when no other request
  is making the image.

The default Logger logs `:busy`, `:bypass`, and `:timeout` results at
`:warning`, except a `:bypass` with reason `:not_stored` or
`:watermark_not_stored`, and a `:download` `:busy`, which it logs at its base
level. It shows the reason, when there is one, after the result, as in
`bypass (deadline)`.

- Metadata:
  - `:operation` (atom): `:source` (fetching an original), `:refresh`
    (a background refresh), `:download` (identical requests sharing a new
    original's download), or `:output` (generating an image).
  - `:pool` (atom): `:input` for `:source` and `:refresh`, `:download` for
    `:download`, and `:output` for `:output`.
  - `:result` (atom), by `:operation`:
    - `:source`: `:acquired` (this request fetches or checks the original),
      `:coalesced` (it waited for another request's download or check),
      `:timeout` (it stopped waiting for one), `:bypass` (the original may
      not be stored, so it downloads it itself), or `:busy` (coordination is
      at capacity, or the coordinating process isn't running).
    - `:refresh`: `:started` (this request starts one), `:coalesced` (one is
      already running), `:backoff` (a refresh of the same image finished
      less than a second ago), or `:busy` (coordination is at capacity, or
      the coordinating process isn't running).
    - `:download`: `:acquired` (this request downloads the original),
      `:waiting` (it waits for an identical request's download), `:ready`
      (the other request has the original, so this one waits for its image
      instead of downloading), `:bypass` (it stops waiting for that request,
      because the other request failed, the wait ran out, the coordinating
      process isn't running, or for a `:reason` below, and then gets the
      original as a request for another size would), or `:busy` (coordination is at capacity). A request that waited
      can then emit `:output` events while it waits for the image.
    - `:output`: `:acquired` (this request generates), `:waiting` (it
      waits for another), `:ready` (it can check the cache again), `:bypass`
      (it generates on its own), or `:busy` (coordination is at capacity).
  - `:reason` (atom), on a `:bypass`:
    - `:deadline` (`:output`): the image wasn't stored within 2 seconds of
      being sent (see [coordination limits](cache.md#coordination-limits)).
    - `:not_stored` (`:source` or `:download`): the original may not be
      stored, so the waiting request downloads it itself.
    - `:watermark_not_stored` (`:download`): a watermark asset may not be
      stored, so the image may not be stored either. The waiting request
      makes the image itself.

### `[:cache, :sweep]`

Span. Emitted each time ImagePipe checks for
[leftover files](cache.md#leftover-files), whether or not it finds any:

- For the cache, after its startup scan and then every 24 hours.
- For staged originals, when the `:image_pipe` application starts and every
  24 hours after.

The default Logger logs a check that deleted nothing at `:debug`.

- Start metadata: `:pool` (atom): `:output` for the cache, `:staging` for
  staged originals.
- Stop metadata:
  - `:result` (atom): `:ok`.
  - `:bytes` (integer): total size of the deleted files.
  - For the cache, `:temps` and `:bodies` (integer): how many temporary
    writes and bodies no metadata named were deleted.
  - For the cache, `:unreadable` (integer): how many metadata files the cache
    can't read were deleted. Their bodies are counted in `:bodies`.
  - For `:staging`, `:staged` (integer): how many staged originals were
    deleted.

### `[:cache, :admission]`

Span. Emitted when a cache keeps or rejects a new entry, after its body is
written and before it's synced to disk.

- Start metadata: `:pool` (atom).
- Stop metadata:
  - `:result` (atom): `:admitted` or `:rejected`.
  - `:reason` (atom): why the entry was rejected.
  - `:victim_count` (integer): entries the new one was compared with.

An `:admitted` entry can still go unstored: when other writes fill the cache
during its sync and it loses a second comparison, or when the write fails
after the decision. A decision the write stopped waiting for isn't made, so
it emits no event.
Its [`[:cache, :write]`](#cache-write) event has the outcome, and
[`[:cache, :eviction, :stop]`](#cache-eviction-stop) counts the entries
actually evicted.

### `[:cache, :eviction, :stop]`

One-shot. Emitted each time a cache evicts entries to stay under its size
limit.

- Measurements: `:count` (integer), entries evicted, and `:bytes`
  (integer), their total size.
- Metadata: `:pool` (atom), and `:trigger` (atom): `:admission` for the
  entries a write evicts to make room, or `:startup` for each batch the
  startup scan evicts to get under a lowered cap.

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
  - `:weights` (map): the weight per class, leaving out weights that don't
    change the crop.
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
  - `:result` (atom): `:ok`, `:unavailable` (the model can't run, such as a
    face model without `image_vision`), or `:error`.
  - `:regions` (integer): the regions this model returned. `0` unless the
    result is `:ok`.

The union of `:classes` across a request's model spans is the set of classes
actually detected. A requested class that appears in none was unknown to
every model and was dropped.

> #### Keep detector identities free of secrets {: .warning}
>
> A custom detector's `identity/1` appears in `:model`, which every attached
> handler receives, including exporters to third parties.

### `[:transform, :detect, :skipped]`

One-shot. Emitted instead of `[:transform, :detect]` when a request asks for
detection that can't run. The crop uses attention instead.

- Metadata: `:classes` (list of strings, or `:all`) and `:result`:
  - `:no_detector`: no detector is configured.
  - `:not_ready`: with `detector_required`, the face model for
    `anchor=smart-face` isn't loaded yet. The response isn't stored.
  - `:unavailable`: with `detector_required`, the detector has no face
    model for `anchor=smart-face`. The response is stored.

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
pixels per side, AVIF 16384, and JPEG 65500. The default result limit of
8192 pixels per side is usually lower.

- Measurements: `:scale` (float), the long side's scale factor, below `1.0`.
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

### `[:encode, :search]`

Span. Nested in `[:encode]`. Wraps the search for an encoder quality, run for
`autoquality` or for a `max_bytes` limit on a format with a quality setting.
The search encodes the image at several qualities and delivers one of those
encodes.

- Start metadata:
  - `:objective` (atom): `:ssimulacra2` for `autoquality`, or `:none` (only a
    `max_bytes` limit).
  - `:min_quality` and `:max_quality` (integer): the quality range searched
    for the format. Absent for `:none`.
  - `:target` (number): the SSIMULACRA2 target. Absent for `:none`.
  - `:max_bytes` (integer): the byte limit, when set.
- Stop metadata:
  - `:result` (atom): `:ok` or `:processing_error`.
  - `:error` (atom): the error category, on failure.
  - `:chosen_quality` (integer): the delivered quality.
  - `:chosen_bytes` (integer): the delivered size.
  - `:iterations` (integer): encodes performed.
  - `:outcome` (atom): `:hit` (the target or limit was met), `:best_effort`
    (it wasn't, and the highest quality in range was used, or the lowest
    for `max_bytes`).
  - `:limiting_factor` (atom): with `:best_effort`, why. `:ceiling` (the
    target needed a higher quality than the range allows), `:search_pixels`
    (`max_search_pixels` stopped the search before a quality met the target),
    or `:max_bytes` (the limit couldn't be met even at the lowest quality).
  - `:pixel_limited` (boolean): whether `max_search_pixels` stopped the search
    before it would have finished. The Logger logs such a search at
    `:warning`.
  - `:final_score` (float): the delivered quality's SSIMULACRA2 score, for
    `:ssimulacra2`.
  - `:scorer` (atom): `:full` when the whole image was scored, or `:crop`
    when crops of a large image were scored instead.
  - `:tiles_scored` (integer): crops scored, at most 16. `:crop` only.

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
  - `:score` (float): the score computed. Absent for `:none` and in the
    `:cap` phase.
  - `:scorer` (atom): `:full` or `:crop`.
  - `:tiles_scored` (integer): crops scored. `:crop` only.
  - `:result` (atom): `:processing_error`, on failure.
  - `:error` (atom): the error category, on failure.

### Probe cost spans

Spans that split the time of `[:encode, :search, :probe]` and nest in it.
When the search delivers a quality that only the `:cap` phase encoded, the
`:ssimulacra2` spans that score it nest in `[:encode, :search]` instead.
They time real work, unlike `[:transform, :operation]`. The default Logger
doesn't log them.

- `[:encode, :search, :probe, :encode]`: the encode, for every objective.
  Start metadata `:quality`, stop metadata `:result` and `:bytes`, or
  `:result` and `:error` on failure.
- `[:encode, :search, :probe, :ssimulacra2, :decode]`: decoding the encoded
  candidate. Start metadata `:bytes`, stop metadata `:result`.
- `[:encode, :search, :probe, :ssimulacra2, :metric]`: computing one score, over
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
  - `:score` (float): its score. Absent for `:none`.
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

One-shot. Emitted when a conditional request is answered with `304`, whether
it matched before the output-cache lookup or after an output-cache hit.

- Metadata: `:method` (atom), `:get` or `:head`.

### `[:http_cache, :fallback, :no_store]`

One-shot. Emitted when a response is marked `no-store` because it is a
fallback.

- Metadata:
  - `:reason` (atom): `:detection_failed`, when a crop used attention because
    detection failed.
  - `:source_name` (atom).

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
generation, whether or not the request has `debug`. The request continues
without them.

- Metadata: `:error` (atom), the module of the exception raised, such as
  `RuntimeError`.
