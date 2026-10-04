# Debug response headers

Debug headers show how one response was produced: what the original was,
which output was chosen, how quality was picked, whether the cache was used,
and how long each stage took. They are `X-ImagePipe-*` headers plus a
standard `Server-Timing` header, and they are off by default.

## Enabling debug headers

Debug headers need a setting in the server's configuration:

<!-- tabs-open -->

### Plug

```elixir
forward "/images", ImagePipe.Plug,
  sources: [...],
  allow_debug_headers: true
```

### image_pipe_server

```toml
[http]
allow_debug_headers = true
```

<!-- tabs-close -->

A request then adds the [`debug`](processing/request.md#debug) option, for
example `/w=400/debug/src/cat.jpg`. Without the setting, `debug` is ignored.

`debug` doesn't change the image, the cache key, or the `ETag`. The details
are recorded on every response that is generated, so a cached response
created before you allowed debug headers has them too.

## Security and disclosure

`debug` is part of the signed path. Sign a new URL to add it to a signed
request.

With debug headers on, a response can reveal the original's size, format,
and color details, the output settings, the quality search results, the
operations applied, the cache key, and timings. Leave
`allow_debug_headers` off if your deployment treats any of that as private.

## Header catalogue

Each header carries one value. A header whose value is unknown is left out.

### Original image

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Source-Format` | `jpeg` | Format of the original |
| `X-ImagePipe-Source-Size` | `184320` | Size of the original in bytes |
| `X-ImagePipe-Source-Width` | `4000` | Width of the original in pixels |
| `X-ImagePipe-Source-Height` | `3000` | Height of the original in pixels |
| `X-ImagePipe-Source-Color-Space` | `VIPS_INTERPRETATION_sRGB` | Color space of the original, as libvips names it: `VIPS_INTERPRETATION_sRGB` for RGB, `VIPS_INTERPRETATION_B_W` for grayscale, `VIPS_INTERPRETATION_CMYK` for CMYK, `VIPS_INTERPRETATION_RGB16` for 16-bit RGB |
| `X-ImagePipe-Source-ICC` | `true` | Whether the original has an embedded color profile |
| `X-ImagePipe-Source-Bit-Depth` | `8` | Bits per channel |
| `X-ImagePipe-Source-Alpha` | `false` | Whether the original has transparency |
| `X-ImagePipe-Source-Orientation` | `6` | EXIF orientation of the original (1 to 8), before it is applied |
| `X-ImagePipe-Shrink` | `w=2.0;h=2.0` | How much the original was scaled down while decoding, per axis. Large originals are decoded at a reduced size when the output is much smaller |

### Output

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Output-Format` | `avif` | Format of the response |
| `X-ImagePipe-Output-Negotiated` | `true` | `true` when the format was chosen from the `Accept` header, `false` when the request set it |
| `X-ImagePipe-Output-Accept` | `image/avif,image/webp,*/*` | The request's `Accept` header |
| `X-ImagePipe-Output-Width` | `1200` | Width of the response image |
| `X-ImagePipe-Output-Height` | `900` | Height of the response image |
| `X-ImagePipe-Output-Quality` | `72` | Encoder quality used, or `default` when the encoder's own default applied |
| `X-ImagePipe-Output-Stripped` | `true` | Whether metadata was removed |
| `X-ImagePipe-Output-Color-Profile` | `strip` | The [`profile`](processing/output.md#profile) the response used: `strip`, `preserve_source` (for `profile=preserve`), `srgb`, `display_p3`, or `adobe_rgb` |

### Automatic quality

Present only when [automatic quality](processing/output.md#autoquality)
searched for a quality.

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-AQ-Score` | `75.4` | SSIMULACRA2 score of the delivered image |
| `X-ImagePipe-AQ-Target` | `75.0` | The target score |
| `X-ImagePipe-AQ-Quality-Min` | `20` | Lowest quality the search could choose |
| `X-ImagePipe-AQ-Quality-Max` | `90` | Highest quality the search could choose |
| `X-ImagePipe-AQ-Iterations` | `3` | Number of encodes the search made |
| `X-ImagePipe-AQ-Outcome` | `hit` | `hit` (target met) or `best_effort` (not met: the highest quality the search tries, or the lowest for `max-bytes`) |
| `X-ImagePipe-AQ-Limiting-Factor` | `ceiling` | With `best_effort`, why: `ceiling` (the target needed a higher quality than the range allows), or `max_bytes` (the byte limit couldn't be met) |
| `X-ImagePipe-AQ-Scorer` | `crop` | `full` when the whole image was scored, `crop` when sample areas of a large image were scored instead |
| `X-ImagePipe-AQ-Tiles` | `9` | Number of sample areas scored, with `crop` |

### Cache and operations

| Header | Example | Meaning |
|---|---|---|
| `X-ImagePipe-Cache` | `hit` | `hit` when the response came from the output cache, otherwise `miss` |
| `X-ImagePipe-Cache-Key` | `a1b2c3…` | The response's cache key, 64 hexadecimal characters. Absent on a generated image that won't be stored, such as when no cache is configured |
| `X-ImagePipe-Pipeline` | `resize,crop,sharpen` | The operations applied, in order |

### Info and placeholder responses

`output=info`, `output=blurhash`, and `output=lqip-css` responses have the
cache and operation headers, but no original-image, output-image, or automatic
quality headers. Their `Server-Timing` has only `total`, plus `cache` on a
cache hit.

### Server-Timing

Durations are in milliseconds:

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, total;dur=181.2
```

- `decode`: fetching and decoding the original.
- `transform`: processing.
- `encode`: encoding.
- `total`: from fetching the original to the first encoded bytes.
- `cache`: reading the response from the output cache. Only on a cache hit.

A cache hit repeats the durations recorded when the response was generated,
and adds `cache`:

```text
Server-Timing: decode;dur=8.123, transform;dur=21.0, encode;dur=140.5, cache;dur=1.5, total;dur=181.2
```
