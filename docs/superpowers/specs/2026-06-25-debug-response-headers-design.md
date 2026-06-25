# Debug response headers

**Status:** Design
**Date:** 2026-06-25

## Overview

Add opt-in `X-ImagePipe-*` debug response headers (plus a standard `Server-Timing`
header) that expose internal facts about how a response was produced: source
properties, the negotiated output, autoquality search results, cache status, the
applied pipeline, and per-stage timings.

The primary consumer is the fiddle, which fetches images through a service worker
and can read response headers to surface extra information in the UI. The headers
are also generally useful for debugging negotiation, autoquality, and cache
behavior from browser devtools.

## Goals

- Surface the internal facts listed in the header catalogue below as flat,
  individually-readable response headers.
- Be **off by default** and safe to enable in production behind signed URLs.
- Work consistently across the three response paths: streamed encode, buffered
  encode (autoquality search / JPEG XL / buffered AVIF), and cache hit.
- On a cache hit, replay the stored generation facts and **merge** the original
  per-stage timings with the live cache-serve timing, tagged as a hit.

## Non-goals

- No output byte size or compression ratio headers. Output size is not known up
  front for a streamed encode, so to keep header presence consistent across all
  paths we omit it; the browser obtains it from the fetch and the fiddle derives
  the ratio from `X-ImagePipe-Source-Size` ÷ fetched body length.
- No animated/multi-frame fields (unsupported).
- No echoing of metric-specific request *inputs* (allowed-error band, tolerance,
  max-bytes). Debug headers report outcomes, not inputs.
- No new third-party/telemetry backend wiring. This is a response-surface feature,
  independent of the telemetry contract (though it reuses the same measurement
  points for timings).

## Gate and trigger model

Two independent controls, both required for any header to be **emitted**:

1. **Mount option `allow_debug_headers: false`** (default). The deployment-level
   **output** gate. When `false`, no debug headers are ever rendered. When `true`,
   the deployment permits debug headers to be emitted (subject to the per-request
   trigger). It does **not** gate collection — see *Collection vs. rendering*: facts
   are collected/stored unconditionally so the flag can be flipped on retroactively
   for already-cached items.
2. **Per-request query parameter `_debug=1`.** The trigger. Dialect-neutral
   (works for imgproxy / TwicPics / IIIF / native), parsed and stripped at the
   request entry boundary *before* dialect parsing. Honored only when
   `allow_debug_headers: true`; otherwise ignored (and stripped, so it never
   reaches a dialect parser).

Rationale: with `allow_debug_headers: true` in production, the actual trigger lives
in the URL, so under signed URLs an attacker cannot append `_debug=1` without
invalidating the signature. The mount gate is the emit on/off switch; the query
parameter is the per-request trigger.

### Interaction with cache key and ETag

Neither `_debug=1` **nor** the `allow_debug_headers` mount flag participates in the
cache key or the ETag. Neither changes the produced image *bytes*: a `_debug=1`
request, a normal request, and the same request under either flag setting all
resolve to the **same** cache entry, because the key/ETag rule is byte-identity of
the stored output (debug info is metadata served *alongside* identical bytes, never
a different stored variant). Putting either in the key would fork storage into
byte-identical "debug-on" / "debug-off" copies — pure waste. The `_debug` parameter
is stripped before key/ETag derivation, the same way it is stripped before dialect
parsing.

This exclusion is *why* collection must be unconditional (next section): since the
flag is not in the key, an entry cached while debug was off is reused when debug is
turned on.

### Collection vs. rendering (decoupled)

The two concerns are independent and gated differently:

- **Collection + storage is unconditional.** Debug facts are collected on every
  generation and stored in the cache entry whenever a cacheable entry is written —
  **independent of `allow_debug_headers`**. This is what lets an operator flip
  `allow_debug_headers: true` and immediately get debug headers for items *already*
  in the cache, with **no cache invalidation and no key fork** (the flag isn't in
  the key, so existing entries are reused — and because they already carry the
  stored facts, the hit path can render them). Collection is best-effort and must
  never break decoding.
- **Rendering is gated** on `allow_debug_headers: true` **AND** `_debug=1`. A
  response carries `X-ImagePipe-*` headers only when both hold; otherwise the
  collected/stored facts are simply not emitted.

So `allow_debug_headers` is a pure *output* switch, not a collection switch.

Costs of unconditional collection/storage (deemed acceptable):

- **CPU:** negligible — a few `System.monotonic_time` calls, in-memory struct
  construction, and reads of already-loaded image headers (microseconds against a
  request that spends milliseconds–hundreds of ms decoding/transforming/encoding).
- **I/O:** zero extra for HTTP/buffer sources (`byte_size/1` is O(1)); one
  `File.stat` per generation for *local-file* sources (the `source_bytes` fact).
- **Storage:** ~1–2 KB of serialized facts per cache entry, on every entry. This is
  small relative to the encoded image body the entry already stores (tens to
  hundreds of KB), i.e. low single-digit percent growth, and the data is bounded
  and non-sensitive.

(In **Plan 1** there is no cache storage yet, so collection there only feeds the
immediate miss-path render; the unconditional-storage design applies from **Plan 2**
onward, where the cache entry gains the debug field.)

## Security and disclosure

Documented in the operator-facing docs:

- `allow_debug_headers: true` is safe in production **iff** request URLs are
  signed, because the `_debug=1` trigger is part of the signed URL.
- What gets disclosed when triggered: internal source/output dimensions, formats,
  color/ICC/bit-depth/alpha facts, autoquality scores and search internals, the
  applied pipeline operations, the cache key, and per-stage timings. Operators
  who do not sign URLs, or who consider any of this sensitive, should leave
  `allow_debug_headers: false`.

## Header catalogue

Flat `X-ImagePipe-*` headers, one fact per header. Timings use `Server-Timing`.

### Source (known at decode, before output)

| Header | Example | Code source |
|---|---|---|
| `X-ImagePipe-Source-Format` | `jpeg` | `decoded.source_format` (`request/processor.ex`) |
| `X-ImagePipe-Source-Size` | `184320` | source byte count — **new capture** at fetch |
| `X-ImagePipe-Source-Width` | `4000` | `decoded.original_dims` |
| `X-ImagePipe-Source-Height` | `3000` | `decoded.original_dims` |
| `X-ImagePipe-Source-Color-Space` | `srgb` | VipsImage interpretation |
| `X-ImagePipe-Source-ICC` | `true` | ICC-profile field present on image |
| `X-ImagePipe-Source-Bit-Depth` | `8` | image header |
| `X-ImagePipe-Source-Alpha` | `false` | `Image.has_alpha` |
| `X-ImagePipe-Source-Orientation` | `6` | EXIF orientation (1–8), pre-auto-orient, from `pending_orientation` |
| `X-ImagePipe-Shrink` | `w=2.0;h=2.0` | `decoded.achieved_shrink` (shrink-on-load) |

### Output (no size — browser obtains it from the fetch)

| Header | Example | Code source |
|---|---|---|
| `X-ImagePipe-Output-Format` | `avif` | `resolved_output.format` (concrete encoded format) |
| `X-ImagePipe-Output-Negotiated` | `true` | output policy: `Accept`-negotiated vs explicitly requested |
| `X-ImagePipe-Output-Accept` | `image/avif,...` | request `Accept` echoed (always on; revisit length cap later) |
| `X-ImagePipe-Output-Width` | `1200` | `Image.width` on finalized image (pre-encode) |
| `X-ImagePipe-Output-Height` | `900` | `Image.height` |
| `X-ImagePipe-Output-Quality` | `72` | effective quality: `EncodeSearch.meta.quality` if search ran, else `resolved_output.quality`; renders the `default` sentinel when ImagePipe set no quality and the encoder's own default applied (resolves to a number once #389 lands) |
| `X-ImagePipe-Output-Stripped` | `true` | `resolved_output.strip_metadata` |
| `X-ImagePipe-Output-Color-Profile` | `srgb` | `resolved_output.color_profile` |
| `X-ImagePipe-Output-Distance` | `1.0` | JXL native distance selected (JXL output only) |

### Autoquality (present only when a quality search ran; from `EncodeSearch.meta`)

| Header | Example | Code source |
|---|---|---|
| `X-ImagePipe-AQ-Metric` | `ssimulacra2` | `quality_search` type — `ssimulacra2`/`butteraugli`/`size` |
| `X-ImagePipe-AQ-Score` | `78.4` | `meta.score` (achieved, in the metric's units) |
| `X-ImagePipe-AQ-Target` | `78.0` | search target/threshold (metric's units) |
| `X-ImagePipe-AQ-Quality-Min` | `60` | `resolved.quality_search.min_quality` — per-format-clamped search floor for the selected format |
| `X-ImagePipe-AQ-Quality-Max` | `65` | `resolved.quality_search.max_quality` — per-format-clamped search roof for the selected format |
| `X-ImagePipe-AQ-Iterations` | `5` | `meta.iterations` |
| `X-ImagePipe-AQ-Outcome` | `hit` | `meta.outcome` — `hit`/`best_effort`/`skipped`/`native` |
| `X-ImagePipe-AQ-Limiting-Factor` | `ceiling` | `meta.limiting_factor` |
| `X-ImagePipe-AQ-Scorer` | `crop` | `meta.scorer` — `full`/`crop` |
| `X-ImagePipe-AQ-Tiles` | `9` | `meta.tiles_scored` (crop mode only) |

The metric name carries the interpretation (ssimulacra2 → higher-better 0–100;
butteraugli → lower-better distance). `Outcome` + `Limiting-Factor` explain why the
search stopped. `Quality-Min`/`Quality-Max` are the effective quality bounds the
search was allowed to pick within for the *selected* format, after the global
per-format clamp (`autoquality_format_min_quality`/`_max_quality`, falling back to
the base bracket) is applied in `output/policy.ex resolve_search/2` — i.e. the
quality floor/roof, and what `Limiting-Factor: floor`/`ceiling` refers to hitting.
No per-metric input knobs are echoed.

### Cache / pipeline

| Header | Example | Code source |
|---|---|---|
| `X-ImagePipe-Cache` | `hit` | delivery path — `hit`/`miss` |
| `X-ImagePipe-Cache-Key` | `a1b2c3…` | `Cache.Key` (telemetry-approved as non-sensitive) |
| `X-ImagePipe-Pipeline` | `scale,crop,sharpen` | plan operations, in order |

### Timings — `Server-Timing`

```
Server-Timing: fetch;dur=12, decode;dur=8, transform;dur=21, encode;dur=140, total;dur=181
```

- **On miss:** live per-stage durations + `total` (the existing `cost_us`,
  generalized to per-stage).
- **On hit:** the stored origin per-stage durations replayed, **plus** a live
  `cache;dur=N` entry for the cache read, with `X-ImagePipe-Cache: hit` denoting
  it. Origin and cache-serve timings are thereby merged and tagged.

## Architecture

### New boundary: `ImagePipe.Debug`

A neutral boundary that owns the debug fact model and rendering, so the producing
(`request`), storing (`cache`), and rendering (`response`) boundaries can all
reference one type without depending on each other.

- `ImagePipe.Debug.Info` — the collected facts struct. Fields cover source,
  output, autoquality, pipeline, and per-stage timings. Autoquality and
  JXL-distance fields are optional (absent unless applicable). Designed to
  serialize cleanly via `:erlang.term_to_binary` for cache storage.
- `ImagePipe.Debug.Timing` — a small per-request accumulator of per-stage
  durations (microseconds), recorded at the existing stage boundaries.
- `ImagePipe.Debug.Headers` — pure rendering: `Info` (+ live cache status and
  live cache-serve duration on a hit) → the flat `X-ImagePipe-*` header list and
  the `Server-Timing` value. This is where header names live.

Boundary `deps`: `debug → plan`. Add `debug` to the `deps` of `request`, `cache`,
and `response`. (`output` and `source` do not depend on `debug`; the `request`
orchestration assembles `Info` from the values they already return.)

### Collection and plumbing

1. **Request entry:** parse and strip `_debug` from the query before dialect
   parsing and before cache-key/ETag derivation. Compute a *render* flag
   (`allow_debug_headers AND _debug`) in the request context — this gates emission
   only. Collection/timing on the generation path runs unconditionally (see
   *Collection vs. rendering*), not behind this flag.
2. **Source fetch / decode (`request/processor.ex`):** capture source byte size
   (new), and read source format, original dims, color space, ICC presence, bit
   depth, alpha, EXIF orientation, and achieved shrink into `Info`. Record the
   `fetch` and `decode` stage durations.
3. **Transform:** record the applied operation names (in order) and the
   `transform` stage duration. Read finalized output dims before encode.
4. **Output negotiation / encode (`request/source_session/producer.ex`):** capture
   `resolved_output` facts (format, negotiated vs explicit, quality, stripped,
   color profile) and, when a search ran, the `EncodeSearch.meta` (currently
   discarded at the `{:ok, binary, _meta}` site — stop discarding it). Capture the
   JXL distance for JXL output. Record the `encode` stage duration.
5. **Assemble `Info`** in the producer and carry it on
   `Request.SourceSession.Prepared` (new field), thence onto
   `Response.PreparedStream` (new field).
6. **Render (`response/sender.ex`):** only when the render flag is set
   (`allow_debug_headers AND _debug`), call `Debug.Headers` to merge the `Info`
   into the response header list. Set `X-ImagePipe-Cache: miss` on the freshly
   produced path.

### Cache storage (hybrid behavior)

- Add a `debug` field to `ImagePipe.Cache.Entry.Metadata` holding the `Debug.Info`
  (generation-only facts). Populated in `cache/sink.ex` from the same `Info`,
  **unconditionally** — every written entry carries the debug blob regardless of
  `allow_debug_headers`, so toggling the flag on later renders debug headers for
  already-cached items without invalidating the cache (the flag is not in the key,
  so existing entries are reused and already carry the facts).
- Reshape the `Entry.Metadata` serialize/deserialize and `validate_metadata`
  paths in `cache/file_system.ex` **in place** to carry/validate the `debug`
  field. No `@metadata_version` bump — this is greenfield with nothing in
  production, so we reshape the canonical metadata shape and update tests rather
  than versioning for backward compatibility. (Any stale dev-disk entry lacking
  the field simply fails validation and is treated as a miss → regenerate.)
- The existing `cost_us` is generalized into / replaced by the per-stage timings
  in `Info`.
- On a cache **hit** (`response/sender.ex` `send_cache_entry`), when debug headers
  are requested: render the stored `Info`, set `X-ImagePipe-Cache: hit`, add a live
  `cache;dur=N` Server-Timing entry, and recompute the request-derivable headers
  (see split below) from the current request rather than from storage.

### Stored vs. re-derived on a hit

- **Re-derived from the current request (not stored):** `Output-Format` (also
  already present as `Metadata.output_format`), `Output-Negotiated`,
  `Output-Accept`, `Pipeline`, `Cache-Key`, `Cache` status.
- **Stored in `Metadata.debug` (generation-only):** all `Source-*`, `Shrink`,
  `Output-Width`/`Height`/`Quality`/`Stripped`/`Color-Profile`, all `AQ-*`
  (including `Quality-Min`/`Quality-Max`), `Output-Distance`, and the origin
  per-stage `Server-Timing` durations.

### Data availability by path

| Fact | Streamed miss | Buffered miss | Hit |
|---|---|---|---|
| Source-* | live | live | stored |
| Shrink | live | live | stored |
| Output dims / quality / stripped / color-profile | live | live | stored |
| Output-Format / Negotiated / Accept | live | live | re-derived |
| AQ-* / Output-Distance | live (if search) | live (if search) | stored |
| Pipeline / Cache-Key / Cache | live | live | re-derived |
| Server-Timing stages | live | live | stored origin + live `cache` |

## Edge cases

- **304 Not Modified:** the conditional path returns before generation and has no
  `Info`. No debug headers (no body anyway). Acceptable.
- **Error responses:** debug headers are a success-path feature; error responses
  carry none.
- **Streamed output size unknown:** by design, no output-size header on any path.
- **Large `Output-Accept`:** always emitted as-is for now; revisit a length cap if
  it bites (header budget is ~1.5–2 KB total, well under the ~8 KB proxy ceiling).
- **`allow_debug_headers: false`:** `_debug=1` is ignored and no debug headers are
  rendered. Facts are still collected and stored in the cache entry (unconditional,
  so the flag can be flipped on retroactively) — `false` gates *output*, not
  collection/storage.

## Fiddle consumption

The fiddle service worker reads the `X-ImagePipe-*` headers and `Server-Timing`
from the fetch response and surfaces them in the UI. Output byte size comes from
the fetched body length; compression ratio is derived from `X-ImagePipe-Source-Size`
÷ that length. The fiddle adds `_debug=1` to its image requests so it always gets
the headers (against a debug-enabled mount).

## Test plan

- **Wire-level (`call/2`):** with `allow_debug_headers: true` + `_debug=1`, assert
  representative headers and `Server-Timing` are present with correct values on a
  miss; assert they are absent without `_debug=1`; assert they are absent when
  `allow_debug_headers: false` even with `_debug=1`.
- **Cache hybrid:** miss then hit for the same request; assert the hit replays the
  stored facts, sets `X-ImagePipe-Cache: hit`, includes a live `cache;dur` entry,
  and re-derives the request-derived headers. Assert `_debug=1` and a plain request
  share the same cache entry (same key, no extra generation).
- **Buffered path:** a JXL/AVIF or autoquality-search request emits the `AQ-*`
  (and `Output-Distance` for JXL) headers with the real `EncodeSearch.meta`.
- **Negotiation:** `Output-Negotiated`/`Output-Format`/`Output-Accept` reflect
  auto-negotiated vs explicitly-requested formats.
- **Cache-key/ETag invariance:** `_debug=1` does not change the cache key or ETag
  (conditional GET still `304`s).
- **Metadata round-trip:** `Entry.Metadata` with a `debug` blob serializes and
  deserializes correctly.

## Docs updates

- Operator docs: the `allow_debug_headers` option, the `_debug=1` trigger, the
  signed-URL safety note, and the disclosure list.
- The header catalogue itself (a reference table of every header and its meaning).
- Fiddle: note that it requests against a debug-enabled mount.
