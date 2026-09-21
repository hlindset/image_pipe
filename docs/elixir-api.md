# Elixir API

Use the `ImagePipe` builder API to construct an immutable processing plan with
typed Elixir values. The resulting builder is reusable across sources and keeps
its plan separate from host configuration:

```elixir
alias ImagePipe, as: IP

thumbnail =
  IP.new()
  |> IP.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
  |> IP.output(format: :webp, quality: 82)

:ok = IP.validate(thumbnail)
```

Execute the plan directly with `IP.run/3`, or write its result with
`IP.write/4`. Generate an equivalent API URL with `IP.url/3` or `IP.url!/3`.

## Shared configuration

Configure sources, caches, processing defaults, limits, and storage partitions
once for both the Plug mount and direct Elixir calls:

```elixir
config = IP.config(
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media", stable: :trusted}],
  cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/output"},
  input_cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/input"},
  quality: 82,
  storage_inputs: [{:header, "x-tenant"}]
)

ip_client = IP.new(config)

thumbnail =
  ip_client
  |> IP.group(resize: [width: 400])
  |> IP.output(format: :webp)

{:ok, result} =
  IP.run(thumbnail, {:source, "photos/original-v1.jpg"},
    request_inputs: [headers: [{"x-tenant", "one"}]]
  )

mount = IP.Plug.init(config: config, http_cache: [mode: :enabled])
# Pass mount to IP.Plug.call(conn, mount), or configure the router with:
# plug ImagePipe.Plug, config: config, http_cache: [mode: :enabled]
```

`IP.new()` uses default configuration. `IP.new(config, expires: unix_seconds)`
combines reusable configuration with request controls. Builder calls return
new values, so `ip_client` stays empty and reusable. Configuration is validated
when constructed and hidden by `Inspect`; it performs no source or cache I/O.
Per-call host options remain available and override the builder's settings.

Signing/encryption keys, IV policy, and `base_url` also belong in this shared
configuration. The builder uses them automatically when generating URLs; the
Plug uses the same keys to verify and decrypt them. HTTP controls such as CORS,
presets, and `http_cache` belong on the Plug mount.

The file example assumes immutable source paths: `stable: :trusted` enables
caching based on that promise. Give changed files a new identifier. With the
default `stable: :auto`, configured files remain uncached unless caching is
explicitly enabled. HTTP sources use origin freshness and validators.

## URL generation

```elixir
config = IP.config(base_url: "/images")
thumbnail = IP.new(config) |> IP.group(resize: [width: 400])
url = IP.url!(thumbnail, "photos/original.jpg")

{:ok, url} = IP.url(thumbnail, "photos/original.jpg")
```

The source is the mount's source identifier, supplied separately from the
plan: a configured path, HTTP(S) URL, S3 identifier, or custom scheme. Pass
its original UTF-8 bytes, including any query parameters. The builder escapes
them once. File and binary input tuples have no URL representation; store the
bytes somewhere the mount can resolve first.

Build configuration once and reuse it. `base_url` accepts an absolute HTTP(S)
URL, a root-relative mount such as `/images`, or a relative prefix such as
`images`. Mount segments use unescaped ASCII letters, digits, `-`, `.`, `_`,
or `~`. Credentials, query strings, fragments, and dot segments are rejected
in the base URL. An omitted base produces a mount-relative path.

### Signed URLs

Configure signing keys once for the builder and mount. They are hex strings;
the first key signs new URLs and the mount can retain older keys for rotation.

```elixir
config = IP.config(
  base_url: "https://cdn.example.com/images",
  keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
)

thumbnail = IP.new(config) |> IP.group(resize: [width: 400])
url = IP.url!(thumbnail, "photos/original.jpg")
mount = IP.Plug.init(config: config)
```

Only the mount-relative path is signed. The base URL and mount prefix are
prepended afterward. Configuration inspection excludes credentials. Keep it
server-side; in a Phoenix template, render only the generated URL:

```heex
<img src={ImagePipe.url!(@thumbnail, @photo.source)} />
```

Equivalent normalized plans, source bytes, and configuration produce the
same URL. Option order does not affect serialization; explicit groups remain
separate. Set expiry explicitly with `IP.new(config, expires: unix_seconds)` when
needed. Reusing that timestamp preserves the URL; calculating a fresh
`now + duration` changes it. URL generation does not check the current time
or perform source, cache, or image I/O.

`url/3` returns `{:ok, url}`, `{:error, {:invalid_request, issues}}`,
`{:error, :invalid_source}`, or `{:error, :too_many_options}`. The last error
means the plan exceeds the HTTP parser's 64 option/separator limit.
`url!/3` raises `ArgumentError` on failure without including the source or
credentials. Malformed URL configuration raises during `config/1`.

### Encrypted sources

Put independent signing and source-encryption keys in shared configuration.
Encryption keys are raw 32-byte binaries; signing
keys are hex strings. Generate secrets once and store them in server-side
configuration. The first encryption key generates tokens; the mount accepts
older keys in the list during rotation.

```elixir
config = IP.config(
  base_url: "/images",
  keys: [signing_key_hex],
  source_encryption_keys: [encryption_key],
  encrypt_source: true,
  iv_mode: :deterministic
)

thumbnail = IP.new(config) |> IP.group(resize: [width: 400])
mount = IP.Plug.init(config: config)
url = IP.url!(thumbnail, "photos/original.jpg")
random_url = IP.url!(thumbnail, "photos/original.jpg", iv: :random)

iv = :crypto.strong_rand_bytes(16)
explicit_url = IP.url!(thumbnail, "photos/original.jpg", iv: iv)
```

`:deterministic` is the default. Identical source bytes and active key produce
identical tokens, independent of transforms, process, or configuration instance.
Stable signing and expiry inputs also preserve the complete URL for browser/CDN
caching. Set `iv_mode: :random` for fresh tokens by default; a per-call
`iv: :deterministic` or `iv: :random` overrides it. All modes share the same
decoder, internal cache identity, and ETag semantics.

An explicit IV must be exactly 16 bytes. The caller must provide an
unpredictable random IV or a secret-keyed derivation over the complete source,
and must not reuse it for different sources under the same key. Reusing it
with the same source produces the same token. Prefer the built-in modes;
constant IVs and public source hashes are unsuitable. Fixed IVs cannot be
stored as the reusable `iv_mode` setting.

Encryption conceals source contents, including private hostname, path, and
query credentials. Deterministic mode reveals equality; all modes reveal
length rounded to CBC padding blocks. Keep generation trusted and server-side;
an arbitrary-source encryption endpoint permits guessing by token comparison.
The [source concealment contract](api_contract.md#source-concealment) specifies
the authenticated CBC construction, key derivation, and token format.

`url/3` returns `{:error, :invalid_encryption_options}` for malformed or unknown
IV options. Passing IV options to a configuration with `encrypt_source: false`
returns `{:error, :source_encryption_disabled}`. `url!/3` raises without echoing
the source or credentials. Enabling encryption requires both key sets.

The mount supplies source adapters, processing defaults, detector, and output
negotiation. Match those settings and source contents with direct execution
when you need equivalent output. Plans contain explicit options; they do
not reference mount presets.

## Direct execution

```elixir
{:ok, result} = IP.run(thumbnail, {:file, "photos/original.jpg"})
result.content_type # "image/webp"
result.width        # 400, when the source is large enough
result.data         # complete encoded bytes

{:ok, result} = IP.run(thumbnail, {:binary, uploaded_bytes})
{:ok, result} = IP.write(thumbnail, {:file, "photos/original.jpg"}, "thumb.webp")
```

`{:file, path}` reads an explicit local path, relative to the current working
directory or absolute. It follows symlinks and requires a regular file. Use
configured `Source.File` input when a path needs confinement to a root.
`{:binary, bytes}` takes encoded image bytes, such as an upload.
Both obey `max_body_bytes` and `max_input_pixels`.

`{:source, string}` uses the same source translation and configured adapters as
HTTP. Supply the source string directly, without a `src` marker or outer URL
encoding:

```elixir
{:ok, result} =
  IP.run(thumbnail, {:source, "photos/original.jpg"},
    sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}]
  )

{:ok, result} =
  IP.run(thumbnail, {:source, "https://assets.example.com/original.jpg"},
    sources: [url: {ImagePipe.Source.HTTP, allowed_hosts: ["assets.example.com"]}]
  )
```

S3 adapters and custom `ImagePipe.Source.Scheme` translators work through this
same input. Adapter-specific network, redirect, timeout, and content-type
policies remain in effect. Configured path responses keep their adapter's file
policy; stream responses have a bounded body read.

### Options and equivalence

Pass processing options as the last argument to `run` or `write`. They share
the mount's validated defaults for output quality, per-format quality,
metadata, color profiles, HDR, quality search, encoder options, detector,
`max_body_bytes`, `max_input_pixels`, `max_result_width`, `max_result_height`,
`max_result_pixels`, and `telemetry_prefix`. Source configuration uses the
same `sources` and `source_schemes` options. Output limits clamp dimensions
using the same encoder limits as HTTP.

`accept: "image/webp"` supplies optional format preferences when the plan
does not specify a format. It defaults to an empty Accept value, following
the source format and the usual fallback policy. `auto_avif`, `auto_webp`,
`auto_jpeg_xl`, `format_order`, and `output_capabilities` apply as on a mount.
`clock` supplies Unix seconds for the plan's expiry check; a plan remains
valid at its exact expiry timestamp.

Matching source bytes, plans, host settings, detector behavior, and Accept
preferences produce the same processing result through direct execution and
HTTP. Mount presets apply only when interpreting URLs; incorporate those
settings into a plan explicitly when comparing the two entry points.

Configured `{:source, identifier}` inputs participate in the same input and
output caches as HTTP. Either entry point can warm entries for the other.
Remote source freshness, revalidation, stale-while-revalidate, storage
permission, and generation limits apply equally. File-backed configured sources
use their adapter's identity for output caching. Raw `{:file, path}` and
`{:binary, bytes}` inputs bypass both caches.

`request_inputs` supplies the values named by `storage_inputs`:

```elixir
IP.run(thumbnail, {:source, "photos/original.jpg"},
  accept: "image/webp",
  request_inputs: [
    headers: [{"x-tenant", "one"}],
    cookies: %{"session" => "abc"}
  ]
)
```

Header names are case-insensitive; cookie names are case-sensitive. Missing
values match an HTTP request that omits them. These inputs partition storage;
they do not change the ETag or get forwarded to the source. Source credentials
and outbound headers remain source-adapter configuration. `accept` controls
output negotiation separately. Supply equivalent values on both entry points
when they should share a cache entry.

`cachebuster` partitions storage for native calls too. Presentation controls
(`filename`, `attachment`, `debug`) do not change the direct result; `write`
uses its explicit destination. Direct calls return data without HTTP headers
or conditional responses.

### Results, errors, and resource ownership

Every successful call returns `{:ok, %ImagePipe.Result{}}`:

| Terminal | `data` | Additional result fields |
| --- | --- | --- |
| `:image` | Complete encoded binary | `format`, `content_type`, `width`, `height` |
| `:info` | Map with string keys: format, MIME type, displayed width/height, EXIF orientation, and available source size | `content_type: "application/json"` |
| `:blurhash` | BlurHash string | `content_type: "text/plain"` |
| `:lqip_css` | Packed CSS color string | `content_type: "text/plain"` |

`write` returns the same result after writing its data, serializing info maps
as JSON. It overwrites an existing destination, and it does not infer an
output format from the filename. Select the format in the plan.

Expected runtime failures return tagged errors:

| Error | Meaning |
| --- | --- |
| `{:invalid_request, issues}` | Plan dependencies, conflicts, or terminal applicability |
| `{:invalid_source, reason}` | Malformed input or source string |
| `:expired` | Plan expiry precedes the current time |
| `{:invalid_output, reason}`, `{:unsupported_output_format, format}` | Output policy or encoder capability |
| `{:detector, :unavailable}` | Required detector unavailable |
| `{:source, reason}` | Source access, stream, or body-size failure |
| `{:input_limit, reason}` | Decoded input pixel limit |
| `{:decode, reason}`, `{:transform, reason}` | Image decode or processing failure |
| `{:encode, reason, stacktrace}` | Encoder creation or lazy stream failure |
| `{:destination, reason}` | File-writing failure |

Malformed host configuration raises `ArgumentError`, just as mount
initialization does. Plan and output preflight finish before resolving or
fetching a source. Programming errors in trusted transform code propagate.

Image processing is lazy internally, but all encoded chunks are consumed
inside the source lifetime. A successful result owns no open resource. Source
close callbacks run on success and on decode, transform, and encode failures;
destination writes happen after source cleanup. Results are buffered in memory,
so concurrent large outputs require enough memory for their complete binaries.
No public stream ownership protocol is involved.

## Builder API: composition and validation

`IP.group/2` appends a complete group. All options in that call follow the
[fixed stage order](api_contract.md#processing-semantics), regardless of keyword
order. A second call starts a new group over the first group's result, just
like `then` in a URL. DPR, zoom, and other group settings start fresh.
An empty plan is valid; an explicitly appended group must contain an option.

```elixir
def thumbnail(plan) do
  IP.group(plan, resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
end

plan =
  IP.new()
  |> thumbnail()
  |> IP.group(padding: 12, background: "white")
  |> IP.output(format: :webp)

lower_quality = IP.output(plan, quality: 60)
```

Ordinary functions provide reusable plans. Every call returns a new value;
`plan` remains reusable after deriving `lower_quality`.

`IP.output/2` merges explicitly supplied options. Repeating an option replaces
its entire value, including nested encoder keywords or per-format quality
settings. Omitted options keep their previous value. Host-dependent output
defaults remain unspecified until execution or URL interpretation supplies
configuration. Plan construction does not apply a mount's default preset.

Unknown options, duplicate keys, invalid types, and out-of-range values raise
`ArgumentError` during construction. `IP.validate/1` checks dependencies,
conflicts, and terminal applicability, returning `:ok` or `{:error, issues}`.
Each `ImagePipe.Plan.Request.Issue` has a `reason`, `detail`, and `locations`:
`{:group, zero_based_index, option_name}` or `{:request, option_name}`. Resize
locations use the individual names such as `:width` and `:fit`.

```elixir
{:error, issues} = IP.new() |> IP.group(resize: [fit: :cover]) |> IP.validate()
# fit requires a concrete resize dimension
```

Validation preserves explicit choices: `blur: 0` is still inapplicable to
`terminal: :info`. It checks the plan before canonical no-op normalization.
It never fetches a source, opens an image, or accesses a cache. Source,
credentials, host configuration, and image-dependent geometry belong to the
terminal lifecycle.

## Request controls

`IP.new/1` accepts these optional controls:

| Option | Value |
| --- | --- |
| `orient` | `:auto` (default) or `:none` |
| `filename`, `cachebuster` | Nonempty strings containing letters, digits, `.`, `_`, or `-` |
| `attachment`, `debug` | Boolean |
| `expires` | Positive Unix timestamp in seconds |

## Group options

Numbers in crop, region, and offset coordinates mean pixels. `{:px, number}`
is also accepted; `{:pct, 50}` means 50 percent. Crop percentages resolve in
the display frame after trim. Resize dimensions are positive integers or
`:auto`; minimum dimensions are positive integers.

Colors accept `{red, green, blue}` integers in `0..255`, CSS color names,
or three/six-digit hex strings with an optional `#`.

| Option | Value |
| --- | --- |
| `resize` | Keywords: `width`, `height`, `min_width`, `min_height`, `fit`, `enlarge`, `zoom` |
| `resize[:fit]` | `:contain`, `:cover`, `:cover_down`, `:stretch`, `:auto` |
| `resize[:enlarge]` | Boolean |
| `resize[:zoom]` | Positive number or `{x, y}` positive factors |
| `dpr` | Positive number |
| `rotate` | Degrees from 0 through 360 |
| `flip`, `trim_symmetry` | `:horizontal`, `:vertical`, `:both` |
| `trim` | `:auto`, color, or `{color, nonnegative_tolerance}` |
| `crop` | `{width, height}`, positive lengths |
| `region` | `{x, y, width, height}`, positive width/height |
| `crop_ratio` | `{positive_integer, positive_integer}`, e.g. `{16, 9}` |
| `crop_ratio_enlarge` | Boolean |
| `anchor` | Named anchor, `:smart`, or `:smart_face` |
| `focus` | `{x, y}`, each in `0..1` |
| `detect` | `:all` or a nonempty list of class names and `{class, weight}` pairs |
| `anchor_offset`, `extend_offset` | `{x, y}` signed lengths |
| `extend`, `extend_ratio` | Boolean; mutually exclusive when enabled |
| `extend_at` | Named anchor |
| `padding` | Nonnegative integer or CSS-order tuple of two, three, or four integers |
| `background` | Color or `{color, alpha}` with alpha in `0..1` |

Named anchors are `:center`, `:top`, `:bottom`, `:left`, `:right`,
`:top_left`, `:top_right`, `:bottom_left`, and `:bottom_right`.
Detection names are strings; `:all` can also appear in the list.
For example, `detect: [{:all, 2}, {"face", 3}]` assigns weight 3 to faces
and weight 2 to other detections. Weights must be positive and at most 1,000,000.

The same [geometry constraints](api_contract.md) apply as in URLs: guides need
a crop or cover-family resize, offsets need an explicit named anchor, and
canvas extension needs concrete width and height.

| Effect | Value |
| --- | --- |
| `blur`, `sharpen` | Nonnegative sigma |
| `pixelate` | Positive integer block size |
| `gray`, `bitonal` | Boolean |
| `brightness` | Integer from -255 to 255 |
| `contrast`, `saturation` | Positive factor; 1 is identity |
| `monochrome` | `[intensity: fraction, color: color]`; color defaults to `{179, 179, 179}` |
| `duotone` | `[intensity: fraction, shadow: color, highlight: color]`; colors default to black and white |
| `colorize` | `[opacity: fraction, color: color, keep_alpha: boolean]`; `keep_alpha` defaults to false |
| `gradient` | `[opacity: fraction, color: color, angle: degrees, start: fraction, stop: fraction]` |

Fractions are numbers in `0..1`. Gradient angle defaults to 0 degrees (down),
start to 0, and stop to 1. Angles wrap modulo 360.

## Output options

| Option | Value |
| --- | --- |
| `terminal` | `:image` (default), `:info`, `:blurhash`, `:lqip_css` |
| `format` | `:jpeg`, `:png`, `:webp`, `:avif`, `:jpeg_xl` |
| `quality` | Integer in `1..100` |
| `format_qualities` | Format keywords, e.g. `[webp: 80, jpeg: 85]` |
| `metadata` | `:strip`, `:copyright`, `:keep` |
| `color_profile` | `:strip`, `:preserve_source`, or `{:convert, profile}` with `:srgb`, `:display_p3`, or `:adobe_rgb` |
| `hdr` | `:tone_map`, `:preserve` |
| `autoquality` | `:none` or `{method, keywords}` |
| `max_bytes` | Positive integer byte limit |

Autoquality methods are `:size`, `:ssimulacra2`, and `:butteraugli`.
All accept optional `target`, `min_quality`, and `max_quality`. Perceptual
methods also accept nonnegative `allowed_error`. Size targets are positive
integer bytes; SSIMULACRA2 targets range from 0 to 100 and Butteraugli from
0 to 25. Omitted settings inherit host policy. Enabled autoquality conflicts
with explicit `quality`; PNG cannot use quality search or byte limits.

Encoder options are keyword lists. Omitted encoder fields remain unspecified.

| Option | Accepted fields |
| --- | --- |
| `jpeg_options` | Boolean `interlace`, `trellis_quant`, `overshoot_deringing`, `optimize_scans`; `subsample_mode: :auto \| :on \| :off`; `quant_table: 0..8` |
| `png_options` | Boolean `interlace`, `palette`; `bitdepth: 1 \| 2 \| 4 \| 8 \| 16`; `filter: :none \| :sub \| :up \| :avg \| :paeth \| :all` |
| `webp_options` | Boolean `lossless`, `near_lossless`, `smart_subsample`; `preset: :default \| :photo \| :picture \| :drawing \| :icon \| :text`; `effort: 0..6` |
| `avif_options` | `subsample_mode: :auto \| :on \| :off`; `effort: 0..9` |
| `jxl_options` | `effort: 1..9` |

An explicit format rejects options for other encoders. Without an explicit
format, encoder settings remain available for negotiation. `:info` accepts
no group transforms or image output policy; `:blurhash` and `:lqip_css`
accept transforms but no image encoding policy.
