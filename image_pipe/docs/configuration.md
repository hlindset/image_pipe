# Configuration

ImagePipe separates host policy from individual image requests. Build reusable
URL configuration with `ImagePipe.URL.config/1` and server configuration with
`ImagePipe.config/1`. The server configuration takes the URL configuration as
`:url`:

```elixir
url_config = ImagePipe.URL.config(base_url: "/images", presets: %{"card" => "w=400"})

config = ImagePipe.config(
  url: url_config,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ],
  max_body_bytes: 10_000_000,
  max_input_pixels: 40_000_000,
  quality: 82
)

plan = ImagePipe.URL.new(url_config)
mount = ImagePipe.Plug.init(config: config, allow_origin: "*")
```

Both are validated on construction without source/cache I/O. Unknown options
and invalid values raise `ArgumentError`, including URL options passed directly
to `ImagePipe.config/1`. Inspection hides their values, including credentials.
Store secrets in server-side configuration.

## Where settings belong

| Layer | Examples | How to supply it |
| --- | --- | --- |
| URL configuration | Signing and encryption keys, presets, URL prefix | `ImagePipe.URL.config/1`, passed to the server as `url:` |
| Server configuration | Sources, limits, output defaults, caches | `ImagePipe.config/1` |
| Source mount | Routing rule, root directory, allowed hosts, network timeouts, S3 credentials | A named mount under `sources`: `:match` plus the adapter's `:options` |
| Plug mount | CORS, HTTP cache policy, debug permission | `ImagePipe.Plug.init(options)` or router mount options |
| Processing request | Width, crop, effects, format, quality | URL options or `ImagePipe.URL.group/2` and `ImagePipe.URL.output/2` |
| Direct call context | Accept header, storage partition values | `accept:` and `request_inputs:` on `run`/`write` |

Mount options can override server configuration. Direct `run`/`write` host
options override the server configuration passed to them. Explicit request
output choices override host defaults. Preset precedence is `default`, named
presets in listed order, then explicit options, for both Plug and direct
execution. Configure `presets: %{"poster" => "w=320"}` in
`ImagePipe.URL.config/1` and select names with
`ImagePipe.URL.new(url_config, presets: ["poster"])`. The mount and `run`
expand presets from the server configuration's `url:` value. See
[presets](urls.md#presets) for related-option replacement rules.

## Sources, caches, and URL protection

| Option | Default | Purpose |
| --- | --- | --- |
| `sources` | No mounts | Named mounts: `name: [adapter: module, match: rule, options: [...]]`; see [sources](sources.md#mounts-and-routing) |
| `cache` | Disabled | Output cache adapter; see [caching](cache.md) |
| `input_cache` | Disabled | Independent source-body cache adapter |
| `source_cache_policy` | Built-in policy | Freshness/revalidation policy; see [caching](cache.md) |
| `storage_inputs` | `[]` | Header/cookie names that partition cache storage, e.g. `[{:header, "x-tenant"}]` |
| `url` | Unsigned, no presets | An `ImagePipe.URL.Config` from `ImagePipe.URL.config/1` |
| `clock` | Current Unix seconds | Zero-argument function used for request expiry |

`ImagePipe.URL.config/1` accepts:

| Option | Default | Purpose |
| --- | --- | --- |
| `base_url` | `""` | URL-generation prefix, e.g. `"/images"` or `"https://cdn.example.com/images"` |
| `keys` | `[]` | Ordered hex signing keys; first signs, all verify |
| `source_encryption_keys` | `[]` | Ordered raw 32-byte encryption keys, separate from signing keys |
| `encrypt_source` | `false` | Generate concealed sources in URLs; requires both key sets |
| `iv_mode` | `:deterministic` | Source-encryption IV generation; also accepts `:random` |
| `presets` | `%{}` | Preset name to URL option fragment; see [presets](urls.md#presets) |

Signing, encryption, and source encoding are covered in [URLs and presets](urls.md).
`storage_inputs` changes storage identity without changing a byte-identical
representation's ETag; it does not forward those inputs to the source.

## Resource limits

| Option | Default | Meaning |
| --- | --- | --- |
| `max_body_bytes` | `10_000_000` | Maximum encoded source body size |
| `max_input_pixels` | `40_000_000` | Maximum decoded input pixel count, per frame |
| `max_input_frames` | `1_000` | Maximum frames or pages a source may declare |
| `max_result_width` | `8_192` | Maximum output width |
| `max_result_height` | `8_192` | Maximum output height |
| `max_result_pixels` | `40_000_000` | Maximum output pixel count |
| `processing_pool` | Omitted | Registered name or PID of a supervised `ImagePipe.ProcessingPool` |

Size limits are positive integers. Output limits clamp generation along with
encoder limits. These are generation limits, not cache identity: successful
cached responses may still be served after a limit changes.

Multi-frame and multi-page sources (animated WebP, JPEG XL, and GIF, multi-page
TIFF, HEIF/AVIF image collections) decode one image: their default image (the
first frame or page, or a HEIF collection's primary image) unless the request
selects another with `page=N`. `max_input_pixels` applies to that one image, or
to `N + 1` frames when a request selects frame N of an animation. `max_input_frames` rejects a source
that declares more frames than the limit with `413`, even though only one is
decoded: the loader visits every frame while reading the header, and for
animated WebP that cost grows quadratically. APNG sources decode their default
image and their frames aren't counted.

Pool capacity, queue length, and deadlines belong on the pool's child spec;
see [processing controls](processing-controls.md). Source network timeouts and
redirect limits belong on the source adapter.

## Format and quality defaults

| Option | Default | Accepted values / purpose |
| --- | --- | --- |
| `auto_avif`, `auto_webp` | `true` | Enable each modern format during Accept negotiation |
| `format_order` | `[:avif, :webp]` | Nonempty, distinct list of modern format atoms; unlisted formats follow in default order |
| `output_capabilities` | Detected encoders | Map of format atom to boolean capability override |
| `quality` | `80` | Global quality, `1..100` |
| `format_quality` | `%{webp: 79, avif: 63}` | Per-format qualities, merged with defaults |
| `strip_metadata` | `true` | Strip optional source metadata |
| `keep_copyright` | `true` | Retain copyright and artist attribution when stripping |
| `stripped_dpi` | `72` | Density written when stripping metadata without a request `dpi`, `1..65535` |
| `strip_color_profile` | `true` | Convert into working space and omit source ICC; `false` preserves source profile |
| `preserve_hdr` | `false` | Preserve high bit depth when supported by the output |

Explicit request `quality`/`q` wins over the selected format's quality.
Request `metadata`/`meta` replaces both metadata switches; request `dpi`
replaces `stripped_dpi`. Named output color
profiles require tone-mapped output. See [output and encoding](processing/output.md).

## Automatic quality search

| Option | Default |
| --- | --- |
| `autoquality_method` | `:none`; also `:size`, `:ssimulacra2`, `:butteraugli` |
| `autoquality_target` | `%{ssimulacra2: 78, butteraugli: 1.0}`; provide a positive `:size` byte target for size search |
| `autoquality_allowed_error` | `%{ssimulacra2: 1.0, butteraugli: 0.1}` |
| `autoquality_min_quality`, `autoquality_max_quality` | `70`, `80` |
| `autoquality_format_min_quality` | `%{avif: 60}` |
| `autoquality_format_max_quality` | `%{avif: 65}` |
| `autoquality_max_resolution` | `0` (no resolution cutoff) |
| `autoquality_max_iterations` | `6` |

Quality bounds are `1..100`. Request bounds override per-format host bounds,
which override global host bounds. SSIMULACRA2 targets are `0..100`;
Butteraugli targets are `0..25`. Perceptual error tolerances are nonnegative.
Search may encode several candidates, so account for its cost when setting
[processing capacity](processing-controls.md).

## Encoder defaults

Host configuration accepts typed option structs. The Elixir **request builder**
accepts keyword lists for the same settings:

```elixir
config = ImagePipe.config(
  jpeg_options: %ImagePipe.Plan.Output.JpegOptions{interlace: true},
  webp_options: %ImagePipe.Plan.Output.WebpOptions{effort: 5}
)

plan =
  ImagePipe.URL.new()
  |> ImagePipe.URL.output(format: :jpeg, jpeg_options: [interlace: false])
```

| Host key | Struct |
| --- | --- |
| `jpeg_options` | `ImagePipe.Plan.Output.JpegOptions` |
| `png_options` | `ImagePipe.Plan.Output.PngOptions` |
| `webp_options` | `ImagePipe.Plan.Output.WebpOptions` |
| `avif_options` | `ImagePipe.Plan.Output.AvifOptions` |

Unspecified fields use encoder defaults. Sparse request fields override host
fields. See the [encoder field reference](processing/output.md#encoder-options).

## Detection and observability

| Option | Default | Purpose |
| --- | --- | --- |
| `detector` | `:default` | Default optional detector, `nil`, or a custom module |
| `detector_required` | `false` | Reject unavailable explicitly requested detection classes before source/cache access |
| `telemetry_prefix` | `[:image_pipe]` | Nonempty list of atoms for emitted event names |

See [content-aware cropping](content-aware-gravity.md) for dependencies and
warmup. Logger and tracing handlers are opt-in; [telemetry](telemetry.md) explains
how to attach them.

## Plug-only options

Pass these alongside `config: config`, rather than to `ImagePipe.config/1`:

| Option | Default | Purpose |
| --- | --- | --- |
| `allow_origin` | Omitted | Nonempty CORS origin string, e.g. `"https://app.example.com"` or `"*"` |
| `allow_debug_headers` | `false` | Allow request `debug` to expose diagnostic headers |
| `http_cache` | Disabled | `[mode: :enabled, visibility: :auto]`; visibility also accepts `:private` or `:public` |

Enabling HTTP cache headers and configuring internal storage are separate
decisions. See [HTTP caching](cdn-http-cache.md) and [debug headers](debug_headers.md)
for behavior and disclosure details.
