# Output and encoding

These options choose what a request returns: the image format, its quality
and file size, encoder settings, metadata and color handling, or a
placeholder or JSON description instead of an image. Each one applies once to
the whole request, wherever it appears in the URL.

## Formats

### format

Accepts `jpeg`, `png`, `webp`, or `avif`, a
[named value](../requesting-images.md#named-values). No default: without
`format`, the format is chosen for each request.

With `format`, the response is always that format. Without it:

- AVIF or WebP is used when the browser's `Accept` header names `image/avif`
  or `image/webp`. Wildcards such as `image/*` and `*/*` don't count, and a
  type listed with `q=0` is excluded. When both are accepted, AVIF wins
  unless the server's configuration changes the order or turns either
  format off, or the server can't encode it.
- Otherwise JPEG and PNG originals keep their format, and any other original
  becomes PNG if the result has transparency, JPEG if not.
- The response carries `Vary: Accept`, because the same URL can return
  different formats.

The server's configuration can list source formats, such as GIF, that are
delivered unprocessed. An image request for such an original without
`format`, or with the original's own format, and without a watermark returns
the original file and ignores every other option. Placeholder and `info`
requests are always processed.

A format the server can't encode fails with `501` and the body
`requested output format is not supported by this server`.

<!-- tabs-open -->

### URL

```text
/w=800/format=webp/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(format: :webp)
```

<!-- tabs-close -->

## Quality and byte budgets

### q

Accepts a whole [number](../requesting-images.md#numbers) from `1` to `100`.
Default: the quality set in the server's configuration, 80 unless changed (see
[Plug configuration](`ImagePipe.config/1`) and
[server configuration](../../../image_pipe_server/docs/server-configuration.md#processing)).

`q` sets the encoder quality for every format, overriding `format-q` and
any automatic quality search the host turns on. Combining `q` with an
`autoquality` method in the same request fails with `400`.

PNG has no default quality and ignores `q` unless `palette` is on in
[`png-options`](#png-options), where `q` sets the quantization quality. For
lossless WebP, `q` sets compression effort rather than image quality.

<!-- tabs-open -->

### URL

```text
/w=800/q=70/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(quality: 70)
```

<!-- tabs-close -->

### format-q

Accepts a [list](../requesting-images.md#pairs-and-lists) of `format:quality`
pairs, such as `avif:60,webp:75`, using the format names from `format` and
qualities from `1` to `100`. Each format may appear once. Default: per-format
qualities set in the server's configuration.

Only the entry for the format the response uses applies, so one URL can set
qualities for every format the browser might get. Formats you leave out keep
their host quality. `q`, when present, wins.

<!-- tabs-open -->

### URL

```text
/w=800/format-q=avif:60,webp:75/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(format_qualities: [avif: 60, webp: 75])
```

<!-- tabs-close -->

### autoquality

Accepts `none`, or a method name followed by optional `name:value` fields, as
a list. Default: no search, unless the server's configuration turns one on
for every request.

`autoquality` encodes the image at several qualities and picks one that meets
the target. The method sets what the target measures:

| Method | `target` | Default target (unless changed) |
| --- | --- | --- |
| `size` | File size in bytes, a positive whole number | None |
| `ssimulacra2` | Visual similarity score from `0` to `100`, higher is better | `78` |
| `butteraugli` | Visual difference from `0` to `25`, lower is better | `1` |

The other fields are:

- `min` and `max`: the lowest and highest quality to try, from `1` to `100`.
- `error`: how far from the target a result may land, a number of `0` or
  more. Only `ssimulacra2` and `butteraugli` accept it.

`autoquality=none` turns off a search the host turns on. The request fails
with `400` when:

- It also sets `q`.
- A field is unknown, repeated, or out of range, or `min` is greater than
  `max`.
- `min` is above the host's `max` for the chosen format, or `max` is below
  the host's `min`. The body is `invalid output`.
- `size` has no `target` and the host sets none. The body is
  `invalid output`.
- It sets `format=png`, or `format=webp` while WebP is lossless (through
  `webp-options` or the host's defaults). PNG and lossless WebP have no
  quality to search. Without `format`, the search applies only when the
  chosen format has a quality setting.

<!-- tabs-open -->

### URL

```text
/w=800/autoquality=ssimulacra2,target:80,min:50/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(autoquality: {:ssimulacra2, target: 80, min_quality: 50})
```

<!-- tabs-close -->

### max-bytes

Accepts a positive whole number of bytes. Default: no budget.

When the encoded image is larger than `max-bytes`, ImagePipe lowers the
quality to the highest one that fits. The budget is best effort. The lowest
quality tried is the search's `min`, or `10` without `autoquality` (lower if
`q` is lower). If the image is still too large at that quality, the response
is larger than the budget.

`max-bytes` fails with `400` under the same format rules as `autoquality`:
with `format=png`, or with `format=webp` while WebP is lossless.

<!-- tabs-open -->

### URL

```text
/w=800/format=webp/max-bytes=60000/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(format: :webp, max_bytes: 60_000)
```

<!-- tabs-close -->

## Encoder options

Each encoder option takes a list of fields. A field is either a flag that
turns a setting on, such as `progressive`, or a `name:value` pair, such as
`effort:6`. Write `flag:false` to turn off a flag that the host
or a [preset](../requesting-images.md#named-presets) turned on. Each field may
appear once. Fields you leave out keep the encoder defaults set by whoever
runs ImagePipe.

With an explicit `format`, options for any other encoder fail with `400`.
Without `format`, each encoder's options apply only when the response uses
that format, so one URL can carry options for several encoders.

### jpeg-options

Accepts these fields. Default: the host's JPEG encoder settings.

| Field | Values | Effect |
| --- | --- | --- |
| `progressive` | flag | Progressive JPEG |
| `subsample` | `auto`, `on`, `off` | Chroma subsampling |
| `trellis-quant` | flag | Trellis quantization |
| `overshoot-deringing` | flag | Reduces ringing around hard edges |
| `optimize-scans` | flag | Optimizes progressive scans |
| `quant-table` | `0` to `8` | Quantization table |

<!-- tabs-open -->

### URL

```text
/format=jpeg/jpeg-options=progressive,quant-table:3/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.output(format: :jpeg, jpeg_options: [interlace: true, quant_table: 3])
```

<!-- tabs-close -->

### png-options

Accepts these fields. Default: the host's PNG encoder settings.

| Field | Values | Effect |
| --- | --- | --- |
| `interlace` | flag | Interlaced PNG |
| `palette` | flag | Palette (indexed color) PNG |
| `bitdepth` | `1`, `2`, `4`, `8`, `16` | Bits per channel |
| `filter` | `none`, `sub`, `up`, `avg`, `paeth`, `all` | Row filter |

<!-- tabs-open -->

### URL

```text
/format=png/png-options=palette,filter:paeth/src/logos/brand.png
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.output(format: :png, png_options: [palette: true, filter: :paeth])
```

<!-- tabs-close -->

### webp-options

Accepts these fields. Default: the host's WebP encoder settings.

| Field | Values | Effect |
| --- | --- | --- |
| `lossless` | flag | Lossless WebP |
| `near-lossless` | flag | Near-lossless WebP |
| `smart-subsample` | flag | Sharper chroma subsampling |
| `preset` | `default`, `photo`, `picture`, `drawing`, `icon`, `text` | Encoder tuning for the image type |
| `effort` | `0` to `6` | Higher is slower and smaller |

<!-- tabs-open -->

### URL

```text
/format=webp/webp-options=near-lossless,effort:6/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.output(format: :webp, webp_options: [near_lossless: true, effort: 6])
```

<!-- tabs-close -->

### avif-options

Accepts these fields. Default: the host's AVIF encoder settings.

| Field | Values | Effect |
| --- | --- | --- |
| `subsample` | `auto`, `on`, `off` | Chroma subsampling |
| `effort` | `0` to `9` | Higher is slower and smaller |

<!-- tabs-open -->

### URL

```text
/format=avif/avif-options=subsample:off,effort:6/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.output(format: :avif, avif_options: [subsample_mode: :off, effort: 6])
```

<!-- tabs-close -->

## Metadata, color profiles, and HDR

### meta

Accepts `copyright`, `strip`, or `keep`, a named value. Default: `copyright`,
unless the server's configuration changes it.

| Value | Result |
| --- | --- |
| `copyright` | Keeps copyright and artist, removes other optional metadata |
| `strip` | Removes all optional metadata, including copyright and artist |
| `keep` | Keeps the original's metadata |

Metadata the format requires, such as JPEG dimensions, is always written.
Orientation metadata always matches the delivered pixels, so a viewer never
rotates the result a second time.

<!-- tabs-open -->

### URL

```text
/w=800/meta=strip/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(metadata: :strip)
```

<!-- tabs-close -->

### dpi

Accepts a whole number from `1` to `65535`. Default: with `meta=copyright`
or `meta=strip`, the density set in the server's configuration, 72
unless changed. With `meta=keep`, the original's density.

`dpi` writes the image's density in pixels per inch, under any `meta`
value. It changes only the stored density value, never the pixels, the
dimensions, or `dpr` scaling.

<!-- tabs-open -->

### URL

```text
/w=2400/dpi=300/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 2400])
|> ImagePipe.URL.output(dpi: 300)
```

<!-- tabs-close -->

### profile

Accepts `strip`, `preserve`, `srgb`, `display-p3`, or `adobe-rgb`, a named
value. Default: `strip`, unless the server's configuration changes it
to `preserve`.

| Value | Result |
| --- | --- |
| `strip` | Converts the result to sRGB (or grayscale) and embeds no profile |
| `preserve` | Keeps the original's color profile, so wide-gamut colors survive |
| `srgb`, `display-p3`, `adobe-rgb` | Converts to that profile and embeds it |

Only JPEG can hold CMYK, so a CMYK original with `profile=preserve` keeps its
profile in JPEG and becomes sRGB without a profile in other formats. `profile`
works independently of `meta`: `meta=strip` doesn't remove a requested
profile.

A named profile produces 8-bit output, so it can't be combined with HDR
preservation. A request for `srgb`, `display-p3`, or `adobe-rgb` that also
has `hdr=preserve`, or that runs on a host that preserves HDR by default,
fails with `400` and the body `invalid output`. Add `hdr=tonemap` to use a
named profile there.

<!-- tabs-open -->

### URL

```text
/w=800/profile=display-p3/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(color_profile: {:convert, :display_p3})
```

<!-- tabs-close -->

### hdr

Accepts `tonemap` or `preserve`, a named value. Default: `tonemap`, unless
the server's configuration changes it to `preserve`.

`hdr=preserve` keeps high bit depth through processing and into the output
when the response is AVIF or PNG. JPEG and WebP output are always standard
8-bit, even with `hdr=preserve`.

<!-- tabs-open -->

### URL

```text
/w=800/format=avif/hdr=preserve/src/photos/sunset.avif
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(format: :avif, hdr: :preserve)
```

<!-- tabs-close -->

## Placeholders and image information

### output

Accepts `image`, `blurhash`, `lqip-css`, or `info`, a named value. `info` may
be followed by `blurhash`, `lqip-css`, or both, each at most once:
`output=info,blurhash,lqip-css`. Default: `image`.

| Value | Response |
| --- | --- |
| `image` | The encoded image |
| `blurhash` | A [BlurHash](https://blurha.sh) string, `text/plain` |
| `lqip-css` | An 8-digit `#rrggbbaa` CSS placeholder value, `text/plain` |
| `info` | JSON describing the original and the result, `application/json` |

Placeholders and info apply every group and the orientation, so they match
the image the same URL returns. Use the `lqip-css` value as
`style="--lqip: #22333091"` together with the stylesheet from
[Image's LQIP CSS guide](https://hexdocs.pm/image/lqip_css.html).

`info` returns:

```json
{
  "source": {"format": "jpeg", "mime_type": "image/jpeg", "width": 4000,
             "height": 3000, "orientation": 6, "pages": 1, "size": 2481920},
  "result": {"width": 600, "height": 450, "dpr": 1.0,
             "blurhash": "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "lqip_css": "#22333091"}
}
```

- `source` describes the original: its format, MIME type, width and height
  as displayed under its EXIF orientation, EXIF `orientation`, number of
  `pages` or frames, and `size` in bytes when known. With
  [`page`](request.md#page), it describes that page.
- `result` has the width and height of the image the same URL would return,
  and the `dpr` of the last group. Divide the width and height by `dpr` to get
  CSS pixels. `dpr` can be lower than requested: without `enlarge`,
  `w=100/dpr=2` on a 150-pixel-wide image reports width 150 at `dpr` 1.5.
- `blurhash` and `lqip_css` appear when named after `info`, with the same
  values `output=blurhash` and `output=lqip-css` return.

Placeholders and info ignore the image options (`format`, `q`, `profile`,
and the rest of this page), so a URL that works for an image keeps working
when you switch it to a placeholder or `info`. These responses have a fixed
content type and no `Vary: Accept`.

<!-- tabs-open -->

### URL

```text
/w=600/output=info,blurhash,lqip-css/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 600])
|> ImagePipe.URL.output(terminal: {:info, [:blurhash, :lqip_css]})
```

<!-- tabs-close -->
