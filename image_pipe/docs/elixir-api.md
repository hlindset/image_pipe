# Elixir API

Start with [installation](installation.md) if ImagePipe is not in your application.
For a shared HTTP endpoint and background jobs, see [combined usage](combined-usage.md).
The [processing reference](processing.md) pairs URL and Elixir options by task.

The Elixir API has two parts:

- `ImagePipe.URL` builds immutable processing plans with typed Elixir values
  and turns them into signed URLs. It performs no I/O and needs no image
  libraries.
- `ImagePipe` holds the server configuration (sources, caches, processing
  defaults) and executes plans in-process with `run/4` and `write/5`.

```elixir
thumbnail =
  ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
  |> ImagePipe.URL.output(format: :webp, quality: 82)

:ok = ImagePipe.URL.validate(thumbnail)
```

For a first local result, run:

```elixir
config = ImagePipe.config()
input = {:file, "photos/original.jpg"}
{:ok, result} = ImagePipe.write(config, thumbnail, input, "thumbnail.webp")
```

The input is an existing file relative to your working directory. The output
format comes from the plan; `write` overwrites an existing destination.

## Shared configuration

Build URL and server configuration once, then share them between the Plug mount
and direct calls. See [configuration](configuration.md#where-settings-belong)
for which settings belong in each:

```elixir
config = ImagePipe.config(
  presets: %{"card" => "w=400/h=400/fit=cover"},
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media", stable: :immutable]
    ]
  ],
  cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/output"},
  input_cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/input"},
  quality: 82,
  storage_inputs: [{:header, "x-tenant"}]
)

ip_client = ImagePipe.URL.new(ImagePipe.url_config(config))

thumbnail =
  ip_client
  |> ImagePipe.URL.group(resize: [width: 400])
  |> ImagePipe.URL.output(format: :webp)

{:ok, result} =
  ImagePipe.run(config, thumbnail, {:source, "photos/original-v1.jpg"},
    request_inputs: [headers: [{"x-tenant", "one"}]]
  )

mount = ImagePipe.Plug.init(config: config, http_cache: :auto)
# Pass mount to ImagePipe.Plug.call(conn, mount), or configure the router with:
# forward "/images", ImagePipe.Plug, instance: MyApp.Images, http_cache: :auto
```

Builder calls return new values, so `ip_client` remains reusable. Per-call host
options passed to `run` and `write` override server configuration.

A bounded cache must be configured on an instance (see
`ImagePipe.child_spec/1`). Pass the instance's configuration to `run` and
`write`:

```elixir
config = ImagePipe.config!(MyApp.Images)
```

Per-call options work with it as usual. A per-call bounded `:cache` or
`:input_cache` raises `ArgumentError` unless it is one of the instance's own
caches.

The builder uses its URL configuration when generating URLs. The Plug and
direct execution use the server configuration: its URL settings verify and
decrypt URLs, and its presets and request defaults expand plans. `run` resolves
presets from the server configuration, not from the builder.
`ImagePipe.url_config(config)` returns the URL settings with the server's
presets attached, so the builder checks plans against them. HTTP controls
such as CORS and `http_cache` belong on the Plug mount.

The file example assumes immutable source paths: `stable: :immutable` lets
ImagePipe serve cached results without reading the file. Give changed files a
new identifier. With the default `stable: :auto`, ImagePipe checks each file
for changes and still reuses cached results while it's unchanged. HTTP sources
use origin freshness and validators.

## URL generation

```elixir
url_config = ImagePipe.URL.config(base_url: "/images")
thumbnail = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 400])
url = ImagePipe.URL.url!(thumbnail, "photos/original.jpg")

{:ok, url} = ImagePipe.URL.url(thumbnail, "photos/original.jpg")
```

The source is the mount's source identifier, supplied separately from the
plan: a configured path, HTTP(S) URL, S3 identifier, or custom scheme. Pass
its original UTF-8 bytes, including any query parameters. The builder escapes
them once. File and binary input tuples have no URL representation; store the
bytes somewhere the mount can resolve first.

`base_url` accepts an absolute HTTP(S)
URL, a root-relative mount such as `/images`, or a relative prefix such as
`images`. Mount segments use unescaped ASCII letters, digits, `-`, `.`, `_`,
or `~`. Credentials, query strings, fragments, and dot segments are rejected
in the base URL. An omitted base produces a mount-relative path.

### Signed URLs

Configure signing keys once for the builder and mount. They are hex strings;
the first key signs new URLs and the mount can retain older keys for rotation.

```elixir
url_config = ImagePipe.URL.config(
  base_url: "https://cdn.example.com/images",
  keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
)

thumbnail = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 400])
url = ImagePipe.URL.url!(thumbnail, "photos/original.jpg")
mount = ImagePipe.Plug.init(url: url_config, sources: sources)
```

Only the mount-relative path is signed. The base URL and mount prefix are
prepended afterward. Keep keys server-side; render only the generated URL:

```heex
<img src={ImagePipe.URL.url!(@thumbnail, @photo.source)} />
```

Equivalent normalized plans, source bytes, and configuration produce the same
URL. Option order does not affect serialization; explicit groups remain
separate. Set expiry explicitly with
`ImagePipe.URL.new(url_config, expires: unix_seconds)` when needed. Reusing that
timestamp preserves the URL; calculating a fresh `now + duration` changes it.
URL generation does not check the current time.

`url/3` returns `{:ok, url}`, `{:error, {:invalid_request, issues}}`,
`{:error, :invalid_source}`, or `{:error, :too_many_options}`. The last error
means the plan exceeds the HTTP parser's 64 option/separator limit.
`url!/3` raises `ArgumentError` on failure without including the source or
credentials. Malformed URL configuration raises during `ImagePipe.URL.config/1`.

### Encrypted sources

Put independent signing and source-encryption keys in the URL configuration.
Encryption keys are raw 32-byte binaries; signing
keys are hex strings. Generate secrets once and store them in server-side
configuration. The first encryption key generates tokens; the mount accepts
older keys in the list during rotation.

```elixir
url_config = ImagePipe.URL.config(
  base_url: "/images",
  keys: [signing_key_hex],
  source_encryption_keys: [encryption_key],
  encrypt_source: true,
  iv_mode: :deterministic
)

thumbnail = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 400])
mount = ImagePipe.Plug.init(url: url_config, sources: sources)
url = ImagePipe.URL.url!(thumbnail, "photos/original.jpg")
random_url = ImagePipe.URL.url!(thumbnail, "photos/original.jpg", iv: :random)

iv = :crypto.strong_rand_bytes(16)
explicit_url = ImagePipe.URL.url!(thumbnail, "photos/original.jpg", iv: iv)
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

`ImagePipe.URL.encrypt_source/3` returns the token alone, for hosts that
assemble and sign paths themselves with `ImagePipe.URL.sign_path/2`.

`url/3` returns `{:error, :invalid_encryption_options}` for malformed or unknown
IV options. Passing IV options to a configuration with `encrypt_source: false`
returns `{:error, :source_encryption_disabled}`. `url!/3` raises without echoing
the source or credentials. Enabling encryption requires both key sets.

### Named presets

```elixir
config = ImagePipe.config(
  request_defaults: "format=webp",
  presets: %{"poster-320" => "w=320/h=480/fit=cover"}
)

poster =
  ImagePipe.URL.new(ImagePipe.url_config(config))
  |> ImagePipe.URL.group(presets: ["poster-320"])
url = ImagePipe.URL.url!(poster, "photos/poster.jpg")
# /preset=poster-320/src/photos%2Fposter.jpg
{:ok, result} = ImagePipe.run(config, poster, {:file, "photos/poster.jpg"})
```

Plug and direct execution share expansion. A group's presets apply to that
group: `request_defaults` first (first group only), its names in order, then
the group's explicit builder or URL options. Nested presets resolve when the
config is built. Validation and execution reject unknown names and conflicting
pipeline composition before source or cache access.

URL generation preserves named references and explicit overrides, including
false and identity values. Changing a preset definition leaves the URL stable;
the serving mount resolves its current definition. A builder without the
mount's presets can reference any name; the mount then validates the combined
request. See [validating URLs before serving](urls.md#validating-urls-before-serving).
`ImagePipe.validate(config, builder)` runs the serving check, including any
preset lookup, without reading a source.

Pass `:unset` as any option's value, including a resize setting, to clear what
the group's presets or the request defaults set:
`group(presets: ["brand"], watermark: :unset)` or `output(format: :unset)`.
The URL writes it as `key=unset`. Encoder options and format qualities need at
least one entry; use `:unset` to clear them.

### Split deployments

An application that only builds URLs can send them to a separate image
service using `image_pipe_url` alone. See
[URL builder with an external server](external-server.md) for server setup,
builder configuration, and shared settings.

### Fetching results from the service

`image_pipe_url` has no fetch function; the signed URL is the interface. To use
a result on the builder side, request that URL from the service with any HTTP
client. Only sources the service can resolve work this way: `{:file, path}` and
`{:binary, bytes}` inputs need the processing runtime, and the service has no
upload endpoint.

The signature covers only the mount-relative path, so server-side fetches can
skip the CDN. Build a second URL configuration with the same keys and the
service's internal address as `base_url`:

```elixir
internal = ImagePipe.URL.config(
  base_url: "http://image-service:4000/images",
  keys: signing_keys
)

url =
  ImagePipe.URL.new(internal)
  |> ImagePipe.URL.output(terminal: :lqip_css)
  |> ImagePipe.URL.url!(source)
```

The examples below use [Req](https://hexdocs.pm/req). `decode_body: false`
keeps every body as raw bytes, including info JSON. Req returns non-2xx
responses as `{:ok, response}`, so check the status: 4xx means the request was
rejected (an invalid option, a bad signature, an expired URL, or a missing
source) and retrying won't help. Req retries transient failures such as 503
by default. Set `receive_timeout` above your slowest first render; cached
results return quickly.

Responses vary on `Accept` when the plan doesn't select a format. Send the
formats you can use, or set `format:` in the plan, so the result's format is
predictable.

Buffer small results such as placeholders, info JSON, and thumbnails:

```elixir
case Req.get(url,
       decode_body: false,
       receive_timeout: 30_000,
       headers: [accept: "image/avif,image/webp"]
     ) do
  {:ok, %Req.Response{status: 200, body: body} = response} ->
    [content_type] = Req.Response.get_header(response, "content-type")
    {:ok, body, content_type}

  {:ok, %Req.Response{status: status}} ->
    {:error, {:http_status, status}}

  {:error, exception} ->
    {:error, exception}
end
```

Stream large results to a file instead of holding them in memory. The file
receives whatever body the service returns, so remove it when the status isn't
200:

```elixir
case Req.get(url,
       decode_body: false,
       receive_timeout: 60_000,
       into: File.stream!(path)
     ) do
  {:ok, %Req.Response{status: 200}} ->
    :ok

  {:ok, %Req.Response{status: status}} ->
    File.rm(path)
    {:error, {:http_status, status}}

  {:error, exception} ->
    File.rm(path)
    {:error, exception}
end
```

To pass chunks onward as they arrive, for example to a `Plug.Conn` already
switched to a chunked response, use `Req.stream/4`. Its function sees the
status before the first chunk, so it can stop without forwarding an error body:

```elixir
{:ok, response, conn} =
  Req.stream(url, conn, fn
    chunk, %Req.Response{status: 200}, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      {:cont, conn}

    _chunk, _response, conn ->
      {:halt, conn}
  end, decode_body: false)
```

Check `response.status` afterwards as in the examples above. Req versions
before 0.8 lack `Req.stream/4`; pass the same logic as an `into:` function.

## Direct execution

```elixir
{:ok, result} = ImagePipe.run(config, thumbnail, {:file, "photos/original.jpg"})
result.content_type # "image/webp"
result.width        # 400, when the source is large enough
result.data         # complete encoded bytes

{:ok, result} = ImagePipe.run(config, thumbnail, {:binary, uploaded_bytes})
{:ok, result} =
  ImagePipe.write(config, thumbnail, {:file, "photos/original.jpg"}, "thumb.webp")
```

`{:file, path}` reads an explicit local path, relative to the current working
directory or absolute. It follows symlinks and requires a regular file. Use
configured `Source.File` input when a path needs confinement to a root.
`{:binary, bytes}` takes encoded image bytes, such as an upload.
Both obey `max_body_bytes`, `max_input_pixels`, and `max_input_frames`.

`{:source, string}` routes through the configuration's
[source mounts](sources.md#mounts-and-routing), the same way HTTP requests do.
Supply the source string directly, without a `src` marker or outer URL
encoding:

```elixir
{:ok, result} = ImagePipe.run(config, thumbnail, {:source, "photos/original.jpg"})

{:ok, result} =
  ImagePipe.run(config, thumbnail, {:source, "https://assets.example.com/original.jpg"})
```

Prefix, custom-scheme, and S3 mounts work through this same input. Adapter-specific network, redirect, timeout, and content-type
policies remain in effect. Configured path responses keep their adapter's file
policy; stream responses have a bounded body read.

### Options and equivalence

Pass host overrides as the last argument to `run` or `write`; processing
options belong in the plan. Direct execution uses the same
[server settings](configuration.md) and output dimension clamps as HTTP.

`accept: "image/webp"` supplies optional format preferences when the plan
does not specify a format. It defaults to an empty Accept value, following
the source format and the usual fallback policy. `auto_avif`, `auto_webp`,
`format_order`, and `output_capabilities` apply as on a mount.
`clock` supplies Unix seconds for the plan's expiry check; a plan remains
valid at its exact expiry timestamp.

Matching source bytes, plans, host settings, detector behavior, and Accept
preferences produce the same processing result through direct execution and
HTTP. Use the same preset definitions on both entry points.

Configured `{:source, identifier}` inputs share HTTP caches and freshness
policies; either entry point can warm entries for the other. Raw `{:file, path}`
and `{:binary, bytes}` inputs bypass both caches.

`request_inputs` supplies the values named by `storage_inputs`:

```elixir
ImagePipe.run(config, thumbnail, {:source, "photos/original.jpg"},
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
| `:info` | Map with string keys: `"source"` (format, MIME type, displayed width/height, EXIF orientation, page count, and available source size) and `"result"` (width, height, effective DPR, and requested placeholders) | `content_type: "application/json"` |
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

## Builder API: composition and validation

`ImagePipe.URL.group/2` appends a complete group. All options in that call
follow the [fixed stage order](api_contract.md#processing-semantics), regardless
of keyword order. A second call starts a new group over the first group's
result, just like `-` in a URL. DPR, zoom, and other group settings start fresh.
An empty plan is valid; an explicitly appended group must contain an option.

```elixir
def thumbnail(plan) do
  ImagePipe.URL.group(plan,
    resize: [width: 400, height: 300, fit: :cover],
    anchor: :smart
  )
end

plan =
  ImagePipe.URL.new()
  |> thumbnail()
  |> ImagePipe.URL.group(padding: 12, background: "white")
  |> ImagePipe.URL.output(format: :webp)

lower_quality = ImagePipe.URL.output(plan, quality: 60)
```

Ordinary functions provide reusable plans. Every call returns a new value;
`plan` remains reusable after deriving `lower_quality`.

`ImagePipe.URL.output/2` merges explicitly supplied options. Repeating an option
replaces its entire value, including nested encoder keywords or per-format
quality settings. Omitted options keep their previous value. Host-dependent
output defaults remain unspecified until execution or URL interpretation
supplies configuration. Validation and execution expand request defaults and
named presets before checking the combined options.

Unknown options, duplicate keys, invalid types, and out-of-range values raise
`ArgumentError` during construction. With the mount's presets known (see
[validating URLs](urls.md#validating-urls-before-serving)),
`ImagePipe.URL.validate/1` checks dependencies and conflicts, returning `:ok` or
`{:error, issues}`. Each `ImagePipe.Plan.Spec.Issue` has a `reason`,
`detail`, and `locations`: `{:group, zero_based_index, option_name}` or
`{:request, option_name}`. Resize locations use the individual names such as
`:width` and `:fit`.

```elixir
{:error, issues} =
  ImagePipe.URL.new(ImagePipe.url_config(config))
  |> ImagePipe.URL.group(resize: [fit: :cover])
  |> ImagePipe.URL.validate()
# fit requires a concrete resize dimension
```

Validation checks the plan before canonical no-op normalization. It never fetches a source, opens an image, or accesses a cache. Source,
credentials, host configuration, and image-dependent geometry belong to the
terminal lifecycle.

## Request controls

`ImagePipe.URL.new/1` accepts these optional controls:

| Option | Value |
| --- | --- |
| `orient` | `:auto` (default) or `:none` |
| `page` | Non-negative integer: decode that page or frame, 0-based, instead of the source's default image |
| `filename`, `cachebuster` | Nonempty strings containing letters, digits, `.`, `_`, or `-` |
| `attachment`, `debug` | Boolean |
| `expires` | Positive Unix timestamp in seconds |

## Group options

Use the categorized processing reference for accepted values, defaults,
constraints, and equivalent URL syntax:

- [Resize and layout](processing/resize.md): dimensions, fit, DPR, zoom, canvas, padding, background.
- [Orientation and cropping](processing/crop.md): rotation, trim, regions, guides, and offsets.
- [Effects](processing/effects.md): filters, color adjustments, and overlays.

See [option values](requesting-images.md#option-values) for lengths,
colors, and named options.

## Output options

[Output and encoding](processing/output.md) covers formats, quality/search,
encoder fields, metadata, profiles, HDR, placeholders, and source information.

`ImagePipe.URL.output/2` takes typed keyword options, for example:

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(resize: [width: 400])
|> ImagePipe.URL.output(
  format: :jpeg,
  quality: 82,
  jpeg_options: [interlace: true],
  metadata: :copyright
)
```

Use `color_profile: :preserve_source` for `profile=preserve`, and
`hdr: :tone_map` for `hdr=tonemap`. The reference shows the remaining mappings.
Host defaults belong in [configuration](configuration.md); request options
override them.
