# Requesting images

You get a resized, cropped, or converted image by requesting a URL that lists
the processing options before the image's path:

```text
https://img.example.com/w=400/h=300/fit=cover/src/photos/beach.jpg
```

Requesting images from an ImagePipe server takes a few details from its
configuration:

- The base URL, such as `https://img.example.com` or `https://example.com/images`.
- What an image path looks like: a path such as `photos/beach.jpg`, or a full
  URL when the images come from another website.
- The names of any presets defined in the server's configuration, and what
  each one does.
- Whether URLs must be signed, and how you get signed URLs.

## URL structure

```text
https://img.example.com/w=400/h=300/fit=cover/src/photos/beach.jpg
└───── base URL ──────┘└────── options ──────┘    └─ image path ─┘
```

Each option is one path segment, written `name=value`, such as `w=400`.
An on/off option is written by its name alone, such as `enlarge`. Values are
described under [option values](#option-values).

The options end at `src/`, and everything after it is the image path. A URL
with no options, such as `https://img.example.com/src/photos/beach.jpg`, is
valid too. ImagePipe then only chooses the [output format](#output-formats).

ImagePipe rejects a URL with `400` when it has an unknown option, the same
option twice in one group, options that conflict, or an option that has no
effect, such as `fit=cover` without a width or height (`w`, `h`, `min-w`, or
`min-h`). It also rejects:

- A query string, such as `?v=2`. To get a fresh copy after an image
  changes, use the [`cb` option](processing/request.md) instead.
- Percent escapes, such as `%20`, anywhere in the options.
- Empty segments (`//`) and the segments `.` and `..` in the options.
- More than 64 option segments.

## Image paths

URL-encode the image path, keeping its slashes:
`summer photos/beach #1.jpg` becomes `src/summer%20photos/beach%20%231.jpg`,
and the full URL `https://assets.example.com/a.jpg?v=2` becomes
`src/https://assets.example.com/a.jpg%3Fv=2`.

Two other markers can take the place of `src/`:

- `src64/` followed by the image path in unpadded base64url, for example
  `src64/cGhvdG9zL2JlYWNoLmpwZw` for `photos/beach.jpg`. Leave out the
  trailing `=` characters.
- `enc/` followed by an encrypted token that hides the image path. These
  tokens need the server's encryption key, so they are created server-side,
  for example by the application that builds your URLs. A token that no server key decrypts answers `404`.
  A server without source encryption keys answers `400` for every `enc/` path.

## Processing groups

The options between two `-` segments form a group. Within a group, the order
you write options in doesn't matter: ImagePipe always applies them in a
[fixed order](processing.md#processing-order), so `w=500/trim=fff` and
`trim=fff/w=500` both trim first, then resize.

A `-` starts a new group, which processes the result of the previous one.
This URL resizes the image to 500 pixels wide, then trims the white border
from the smaller image:

<!-- tabs-open -->

### URL

```text
/w=500/-/trim=fff/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 500])
|> ImagePipe.URL.group(trim: "fff")
```

<!-- tabs-close -->

Each group starts with fresh settings. A `dpr=2` in the first group doesn't
apply to the second.

Request-wide options apply to the whole request rather than to one group:
the [output and encoding options](processing/output.md), the
[request controls](processing/request.md), `orient`, and `page`. You can write
each one anywhere in the URL, but only once. A group that holds only
request-wide options adds no group, so `/w=800/-/format=webp` is the same request as
`/w=800/format=webp`.

A URL must not start or end with `-`, or contain two `-` segments in a row.
[Processing order and groups](processing-order.md) explains the order and
when a new group helps.

## Option values

### Numbers

Plain decimals: `2`, `1.5`, `-10`. Write at least one digit before and after
the point (`0.5`, not `.5`), and no `+` or exponent. Each option states its
range.

### Pixel lengths

A plain number is a length in pixels: `w=400`. Don't add a unit, since
`400px` is rejected. Widths and heights (`w`, `h`, `min-w`, `min-h`) take
whole numbers, and `w` and `h` also accept `auto`. Crop sizes, regions, and
offsets accept decimals, and offsets may be negative.

<!-- tabs-open -->

### URL

```text
crop=400,300
```

### Elixir

```elixir
ImagePipe.URL.group(builder, crop: {400, 300})
```

<!-- tabs-close -->

### Percentages

A number followed by `pct` is a percentage: `50pct`. The `%` sign can't be
used. Crop sizes, regions, and offsets accept percentages. Each option page
says what the percentage is of.

<!-- tabs-open -->

### URL

```text
crop=50pct,100pct
```

### Elixir

```elixir
ImagePipe.URL.group(builder, crop: {{:pct, 50}, {:pct, 100}})
```

<!-- tabs-close -->

### Fractions

A decimal from `0` to `1`, inclusive. Focus points, opacity, and alpha use
fractions: `focus=0.3,0.6` sets a crop target 30% from the left and 60% from
the top.

### Colors

A color is three or six hex digits without `#`, such as `fff` or `ff8800`,
or a lowercase CSS color name, such as `white` or `rebeccapurple`. Some
options take an alpha [fraction](#fractions) after the color: `bg=fff,0.5`
is half-transparent white.

<!-- tabs-open -->

### URL

```text
bg=ff8800
bg=fff,0.5
```

### Elixir

```elixir
ImagePipe.URL.group(builder, background: "ff8800")
ImagePipe.URL.group(builder, background: {"fff", 0.5})
```

<!-- tabs-close -->

### Anchors

A position in the image: `center`, `top`, `bottom`, `left`, `right`,
`top-left`, `top-right`, `bottom-left`, or `bottom-right`. The `anchor`
option also accepts `smart` and `smart-face`, described under
[crop guides](processing/crop.md#crop-guides).

### Booleans

Write the option's name alone for true and `=false` for false: `enlarge`
or `enlarge=false`. `enlarge=true` is rejected. `=false` turns off something
a [preset](#named-presets) turned on.

<!-- tabs-open -->

### URL

```text
enlarge
enlarge=false
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [enlarge: true])
ImagePipe.URL.group(builder, resize: [enlarge: false])
```

<!-- tabs-close -->

### Named values

Lowercase names, with hyphens between words: `anchor=top-left`, `flip=hv`,
`format=webp`. Each option page lists the names it accepts.

<!-- tabs-open -->

### URL

```text
anchor=top-left
```

### Elixir

```elixir
ImagePipe.URL.group(builder, anchor: :top_left)
```

<!-- tabs-close -->

### Pairs and lists

Several values in one option are separated by commas, without spaces:
`crop=400,300` is a width and a height, `zoom=2,1` an x and a y factor.
Each option page says how many values it takes. Ratios use a colon or a
decimal: `crop-ratio=16:9` or `crop-ratio=1.5`.

## Named presets

A preset is a named set of options defined in the server's configuration.
Write `preset=` and the name where you would write the options:

```text
/preset=card/src/photos/beach.jpg
```

You can combine a preset with your own options. Options you write yourself
win over the preset's options in the same group, so with a `card` preset of
`w=400/h=300/fit=cover`, this URL is 600 pixels wide:

```text
/preset=card/w=600/src/photos/beach.jpg
```

- `preset=card,dark` applies both presets. When they set the same option,
  the later one wins.
- A preset applies to the group you write it in. `/w=800/-/preset=frame`
  applies `frame` to the resized image.
- A preset's request-wide options, such as `format`, apply to the whole
  request. A `format` you write yourself wins over every preset.
- Some options replace a related set rather than one value. Writing
  `anchor`, `focus`, or `detect` replaces the preset's whole crop target,
  `region` replaces its `crop`, `q` replaces its `autoquality`, and `wm`
  replaces its watermark.
- `unset` removes a preset's value as if it had never been set:
  `/preset=brand/wm=unset` removes the watermark. Every option except
  `preset` accepts `unset`.

The server's configuration can also set defaults for the first group of every
request. Presets and your own options win over them, and `unset` removes them
too.

A preset can also define several groups of its own. You can add only
request-wide options to such a preset, such as `/preset=framed/format=png`,
either directly or through another preset. Adding any other option answers
`400`. The server's configuration defines which presets work this way, as
described in [single-group and pipeline presets](presets.md#single-group-and-pipeline-presets).

A preset name that doesn't exist answers `400`.

## Signed URLs

When ImagePipe requires signed URLs, each URL starts with a `sig=` segment
that covers everything after it:

```text
https://img.example.com/sig=<signature>/w=400/src/photos/beach.jpg
```

Signing needs the server's secret key, so URLs are signed server-side. The
application that builds your URLs signs them, or an endpoint in it creates
signed URLs. Signing is set up as described in
[signing URLs and rotating keys](signing-urls.md).

- Changing any option or the image path invalidates the signature.
- A missing or wrong signature answers `403` with the body `invalid signature`.
- A signed URL may carry `expires=` with a Unix time in seconds. After that
  second, the URL answers `410` with the body `expired`.
- When ImagePipe doesn't require signatures, a URL with a `sig=` segment
  answers `400`.

## Output formats

Without a `format` option, ImagePipe picks AVIF or WebP when the browser's
`Accept` header lists it. Otherwise JPEG and PNG originals keep their format,
and any other format becomes PNG if the image has transparency, JPEG if not. With
`format=webp` (or `avif`, `jpeg`, `png`) you always get that format. See
[formats](processing/output.md#formats) for the details.

## Request errors

A request that fails answers with a status and a short plain-text body. For a
`400`, the body points at each problem in the URL:

```text
invalid transformation options

/w=400/fit=fill/src/photos/beach.jpg
           ^^^^
           |
           invalid value: expected contain, cover, stretch, or auto
```

| Status | Meaning |
| --- | --- |
| `400` | The URL doesn't parse, or its options don't fit together. |
| `403` | The signature is missing or wrong. |
| `404` | The image doesn't exist, or an `enc/` token can't be decrypted. |
| `410` | The URL's `expires` time has passed. |

[Error responses](errors.md) lists every status, including those for images
that are too large or can't be processed.

## Next steps

- [Processing options](processing.md): every option, grouped by category.
- [Resize and layout](processing/resize.md): width, height, fit, and
  pixel density, the options most requests start with.
- [Request controls](processing/request.md): downloads, file names, and
  cache busting.
