# Debug response headers

ImagePipe can attach opt-in `X-ImagePipe-*` response headers and a standard
`Server-Timing` header that expose how a response was produced: source
properties, the negotiated output, autoquality search results, cache status, the
applied pipeline, and per-stage timings. They are **off by default**.

## Enabling

Two independent controls must both be satisfied for any header to be emitted:

1. **Mount option `allow_debug_headers: true`** (default `false`) — the
   deployment-level switch. When `false`, no debug headers are ever rendered.

   ```elixir
   plug ImagePipe.Plug,
     dialect: ImagePipe.Dialect.IIIF,
     resolver: {MyApp.Resolver, []},
     sources: [...],
     allow_debug_headers: true
   ```

   Debug headers are available on every mount — there is one mount shape, and
   the flag means the same thing on all of them. Native currently has no
   per-request trigger in its grammar, so its responses render none until a
   trigger is chosen
   ([#471](https://github.com/hlindset/image_pipe/issues/471)).

2. **Per-request trigger** — opts a single request into debug headers. Honored
   only when `allow_debug_headers: true`; otherwise ignored. The trigger is
   **dialect-specific**:
   - **imgproxy**: the `debug:1` processing option inside the signed path,
     for example `/<signature>/debug:1/rs:fill:400:300/plain/…` (also
     `debug:true`; `debug:0`/`debug:false` opt out).
   - **TwicPics**: a `debug=1` segment in the `twic` manipulation chain, e.g.
     `/images/cat.jpg?twic=v1/resize=400/debug=1`. Order-independent; emits no
     transform.
   - **IIIF**: a `?debug=1` query param, e.g.
     `/iiif/cat/full/400,/0/default.jpg?debug=1`. The IIIF path grammar has no
     free slot, so the trigger is an out-of-band query param (read leniently — a
     malformed value is ignored, never a 400).

   All triggers accept the boolean spellings `1`/`true`; TwicPics and imgproxy
   also accept `0`/`false` to explicitly opt out. Only the imgproxy trigger is
   signature-protected — see below.

A debug trigger does **not** change the produced image bytes: it rides the
dialect's response metadata (`Plan.Response.debug?` on the declarative tier),
which contributes to neither the cache key nor the ETag, so a debug request and
a plain request resolve to the same cache entry. (Facts are collected and stored
on every generation regardless of the flag, so enabling
`allow_debug_headers: true` immediately surfaces headers for already-cached
items, with no cache invalidation.)

## Security and disclosure

> **Signing.** On the imgproxy stack, `debug:1` is part of the signed
> processing-options path, so a configured path signature (HMAC) covers it,
> and covers it as a *disclosing* trigger, which is the point: an attacker
> cannot append `debug:1` to an otherwise-valid signed URL without
> invalidating the signature.
>
> **TwicPics / IIIF** have no request signing at all, so their `debug=1` /
> `?debug=1` triggers are **always unprotected** — anyone who can reach the mount
> can add them. Enable `allow_debug_headers: true` on those mounts only if the
> disclosed facts below are acceptable to expose. (If those dialects gain signing
> later, the trigger should ride the signed material.)

When triggered, a response discloses: internal source dimensions and
format/color/ICC/bit-depth/alpha facts; the negotiated output and its
dimensions/quality/profile; autoquality scores and search internals; the applied
pipeline operations; the cache key; and per-stage timings. None of these are
secrets, but operators who consider any of it sensitive should leave the mount
flag off.

## Header catalogue

All `X-ImagePipe-*` values are flat (one fact per header). `nil`/absent facts are
omitted. Names and units are owned by `ImagePipe.Debug.Headers`.

### Source

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Source-Format` | `jpeg` | Decoded source format |
| `X-ImagePipe-Source-Size` | `184320` | Source byte count |
| `X-ImagePipe-Source-Width` | `4000` | Source pixel width |
| `X-ImagePipe-Source-Height` | `3000` | Source pixel height |
| `X-ImagePipe-Source-Color-Space` | `VIPS_INTERPRETATION_sRGB` | Source interpretation |
| `X-ImagePipe-Source-ICC` | `true` | Embedded ICC profile present |
| `X-ImagePipe-Source-Bit-Depth` | `8` | Bits per sample |
| `X-ImagePipe-Source-Alpha` | `false` | Source has an alpha channel |
| `X-ImagePipe-Source-Orientation` | `6` | EXIF orientation (1–8), pre-auto-orient |
| `X-ImagePipe-Shrink` | `w=2.0;h=2.0` | Shrink-on-load factors applied at decode |

### Output

No output-size header is sent (it is unknown up front for a streamed encode). The
browser obtains the size from the response body; the fiddle derives the
compression ratio from `X-ImagePipe-Source-Size ÷ body length`.

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Output-Format` | `avif` | Concrete encoded format |
| `X-ImagePipe-Output-Negotiated` | `true` | `Accept`-negotiated vs explicitly requested |
| `X-ImagePipe-Output-Accept` | `image/avif,…` | Request `Accept` echoed |
| `X-ImagePipe-Output-Width` | `1200` | Finalized output width |
| `X-ImagePipe-Output-Height` | `900` | Finalized output height |
| `X-ImagePipe-Output-Quality` | `72` | Effective quality (or `default` when the encoder default applied) |
| `X-ImagePipe-Output-Stripped` | `true` | Metadata stripped |
| `X-ImagePipe-Output-Color-Profile` | `srgb` | Output color profile |
| `X-ImagePipe-Output-Distance` | `1.0` | JXL native distance (JXL output only) |

### Autoquality (present only when a quality search ran)

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-AQ-Metric` | `ssimulacra2` | Search metric (`ssimulacra2`/`butteraugli`/`size`) |
| `X-ImagePipe-AQ-Score` | `78.4` | Achieved score (metric units) |
| `X-ImagePipe-AQ-Target` | `78.0` | Search target/threshold (metric units) |
| `X-ImagePipe-AQ-Quality-Min` | `60` | Per-format-clamped search floor |
| `X-ImagePipe-AQ-Quality-Max` | `65` | Per-format-clamped search roof |
| `X-ImagePipe-AQ-Iterations` | `5` | Search iterations |
| `X-ImagePipe-AQ-Outcome` | `hit` | `hit`/`best_effort`/`skipped`/`native` |
| `X-ImagePipe-AQ-Limiting-Factor` | `ceiling` | Why the search stopped |
| `X-ImagePipe-AQ-Scorer` | `crop` | `full`/`crop` |
| `X-ImagePipe-AQ-Tiles` | `9` | Tiles scored (crop mode only) |

### Cache / pipeline

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Cache` | `hit` | Delivery path — `hit`/`miss` |
| `X-ImagePipe-Cache-Key` | `a1b2c3…` | Cache key (64-char sha256 hex) |
| `X-ImagePipe-Pipeline` | `scale,crop,sharpen` | Applied plan operations, in order |

### Timings — `Server-Timing`

Durations are in **milliseconds**. On a miss, the live per-stage durations plus
`total` are emitted; on a hit, the stored origin durations are replayed plus a
live `cache` entry for the cache read.

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, total;dur=181.2
```

On a cache hit:

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, cache;dur=1.5, total;dur=181.2
```

(There is no separate `fetch` stage — source fetch is folded into `decode`.)

## Demo (fiddle)

The bundled demo (`fiddle/`) configures its imgproxy, TwicPics, and IIIF
mounts with `allow_debug_headers: true` and injects each stack's debug
trigger into its preview requests (imgproxy signs a `debug:1`-augmented
preview path; TwicPics `debug=1`; IIIF `?debug=1`). Its service worker reads
these headers off the fetched response and surfaces them in a **Debug headers**
panel under the preview, including the derived output size and compression
ratio.
