# Output and encoding

[All processing options](../processing.md)

Output settings apply once to the final result. Pass the Elixir options in
this page to `ImagePipe.URL.output/2`.

## Formats

| URL | Elixir | Result |
| --- | --- | --- |
| `format=jpeg` | `format: :jpeg` | JPEG |
| `format=png` | `format: :png` | PNG |
| `format=webp` | `format: :webp` | WebP |
| `format=avif` | `format: :avif` | AVIF |

Omit `format` to negotiate AVIF or WebP from `Accept`, enabled encoders, and host
preference order. `image/avif`, `image/webp`, and `image/*` advertise modern
format support; a missing header or `*/*` alone does not. `q=0` excludes a
candidate, but relative q-values do not change host preference order.

With no enabled modern candidate, ImagePipe keeps the source format if it has
an encoder. Otherwise it uses PNG for a final image with alpha, JPEG for one
without. Negotiated image responses use `Vary: Accept`; configure your CDN
accordingly. An explicit format bypasses negotiation.

Codec availability depends on the installed libvips build. An explicit
unavailable format fails; it does not silently substitute another format.
See [native format support](../installation.md#native-format-support) and
[HTTP negotiation](../cdn-http-cache.md).

## Quality and byte budgets

| URL | Elixir | Values / behavior |
| --- | --- | --- |
| `q=82` | `quality: 82` | Integer `1..100`; overrides per-format quality and inherited search |
| `format-q=avif:60,webp:75` | `format_qualities: [avif: 60, webp: 75]` | Per-format quality map |
| `autoquality=none` | `autoquality: :none` | Disable inherited search |
| `autoquality=size,target:30000,min:40,max:95` | `autoquality: {:size, target: 30_000, min_quality: 40, max_quality: 95}` | Search toward a byte target |
| `autoquality=ssimulacra2,target:80,error:3` | `autoquality: {:ssimulacra2, target: 80, allowed_error: 3}` | Perceptual score, `0..100`; default target 78 |
| `autoquality=butteraugli,target:1,error:0.1` | `autoquality: {:butteraugli, target: 1, allowed_error: 0.1}` | Perceptual distance, `0..25`; default target 1 |
| `max-bytes=30000` | `max_bytes: 30_000` | Positive best-effort byte budget |

Search methods accept `min`/`max` (`min_quality`/`max_quality`) in `1..100`.
Perceptual methods accept nonnegative `error`/`allowed_error`. Size needs a
target from the request or host and does not accept an error tolerance.
Request bounds override per-format host bounds, then global bounds.

Explicit quality and enabled request autoquality conflict. PNG and lossless
WebP reject explicit search or byte budgets; inherited search is inactive for
these encoders. Under negotiation, budgets/search apply where supported.
PNG ignores implicit global quality; explicit quality can request quantization.

A byte budget is not a guaranteed maximum response size: if the lowest-quality
candidate cannot fit, ImagePipe returns the best available image. Search can
encode multiple candidates; configure its [iteration and resolution limits](../configuration.md#automatic-quality-search).

```text
/w=800/format=webp/q=82/max-bytes=60000/src/photos/beach.jpg
```

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 800])
|> ImagePipe.URL.output(format: :webp, quality: 82, max_bytes: 60_000)
```

## Encoder options

URL encoder fields are comma-separated flags or `name:value` pairs.
Use `flag:false` to disable an inherited flag. Elixir accepts a keyword list
under the corresponding output option.

| URL option | URL fields | Elixir option / field differences |
| --- | --- | --- |
| `jpeg-options` | `progressive`, `subsample:auto\|on\|off`, `trellis-quant`, `overshoot-deringing`, `optimize-scans`, `quant-table:0..8` | `jpeg_options`; `interlace`, `subsample_mode`, `trellis_quant`, `overshoot_deringing`, `optimize_scans`, `quant_table` |
| `png-options` | `interlace`, `palette`, `bitdepth:1\|2\|4\|8\|16`, `filter:none\|sub\|up\|avg\|paeth\|all` | `png_options`; same field names, enum values are atoms |
| `webp-options` | `lossless`, `near-lossless`, `smart-subsample`, `preset:default\|photo\|picture\|drawing\|icon\|text`, `effort:0..6` | `webp_options`; `near_lossless`, `smart_subsample`, preset atom |
| `avif-options` | `subsample:auto\|on\|off`, `effort:0..9` | `avif_options`; `subsample_mode` atom |

```text
/format=jpeg/jpeg-options=progressive,quant-table:3/src/photos/beach.jpg
```

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.output(format: :jpeg, jpeg_options: [interlace: true, quant_table: 3])
```

An explicit format rejects settings for another encoder. With negotiation,
per-format settings are conditionally active. Sparse fields override host
defaults. Host configuration takes [typed encoder structs](../configuration.md#encoder-defaults).

## Metadata, color profiles, and HDR

| URL | Elixir | Behavior |
| --- | --- | --- |
| `meta=copyright` | `metadata: :copyright` | Retain attribution, strip other optional metadata; default |
| `meta=strip` | `metadata: :strip` | Strip optional metadata including attribution |
| `meta=keep` | `metadata: :keep` | Retain source metadata |
| `dpi=300` | `dpi: 300` | Write 300 pixels per inch, 1-65535, under any `meta` |
| `profile=strip` | `color_profile: :strip` | Convert to sRGB (or gray) at the end, omit source ICC; default |
| `profile=preserve` | `color_profile: :preserve_source` | Keep the source profile; RGB and gray sources keep their values, so wide-gamut colors survive |
| `profile=srgb` | `color_profile: {:convert, :srgb}` | Convert to and embed the named target profile |
| `profile=display-p3` | `color_profile: {:convert, :display_p3}` | Display P3 target |
| `profile=adobe-rgb` | `color_profile: {:convert, :adobe_rgb}` | Adobe RGB target |
| `hdr=tonemap` | `hdr: :tone_map` | Standard working space; default |
| `hdr=preserve` | `hdr: :preserve` | Preserve high bit depth where supported |

Without `dpi`, stripping writes the host `stripped_dpi` (default 72) and
`meta=keep` retains the source density. Density is a header value only: it
never changes pixels, dimensions, or DPR scaling.

Profile handling is independent of metadata policy. Named profile conversion
produces 8-bit output and cannot combine with effective HDR preservation.
JPEG uses standard output even with `hdr=preserve`. Required codec metadata
may still appear under `meta=strip`. See the
[color contract](../api_contract.md#metadata-color-profiles-and-hdr).

## Placeholders and image information

| URL | Elixir | HTTP result |
| --- | --- | --- |
| `output=image` | `terminal: :image` | Encoded image; default |
| `output=blurhash` | `terminal: :blurhash` | BlurHash string, `text/plain` |
| `output=lqip-css` | `terminal: :lqip_css` | Packed `#rrggbbaa` CSS value, `text/plain` |
| `output=info` | `terminal: :info` | Source and result information, `application/json` |
| `output=info,blurhash,lqip-css` | `terminal: {:info, [:blurhash, :lqip_css]}` | Info with placeholders |

Placeholders apply transforms and orientation, then use a fixed pixel space.
Non-image outputs check image encoding settings such as format, quality,
profile, and HDR as an image request would, then ignore them, so switching a
valid image URL to a placeholder or info keeps it valid. LQIP CSS values work
with Image's shared LQIP stylesheet; see the
[terminal contract](../api_contract.md#presets-and-terminals).

Info applies the request's groups and orientation. Its `source` object has the
source format, MIME type, display width/height, EXIF orientation, page count,
and available byte size. Its `result` object has the width and height the same
URL's image would have and the last group's effective `dpr`, plus any
placeholders named after `info`, each equal to its standalone output:

```elixir
plan =
  ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 600])
  |> ImagePipe.URL.output(terminal: {:info, [:blurhash, :lqip_css]})

{:ok, result} = ImagePipe.run(ImagePipe.config(), plan, {:file, "photos/beach.jpg"})
result.data["result"] # %{"width" => 600, "height" => ..., "dpr" => 1.0, "blurhash" => ..., ...}
```

These terminals retain source safety limits. Text and JSON have fixed content
types and do not vary by `Accept`. See [Elixir result types](../elixir-api.md#results-errors-and-resource-ownership).
