# Configuration

ImagePipe separates host policy from individual image requests. Build reusable
host configuration with `ImagePipe.config/1`, then use it in both entry points:

```elixir
config = ImagePipe.config(
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}],
  max_body_bytes: 10_000_000,
  max_input_pixels: 40_000_000,
  quality: 82,
  base_url: "/images"
)

plan = ImagePipe.new(config)
mount = ImagePipe.Plug.init(config: config, allow_origin: "*")
```

Configuration is validated on construction without source/cache I/O. Unknown
options and invalid values raise `ArgumentError`. Configuration inspection hides
its values, including credentials. Store secrets in server-side configuration.

## Where settings belong

| Layer | Examples | How to supply it |
| --- | --- | --- |
| Shared host configuration | Sources, limits, output defaults, caches, keys | `ImagePipe.config/1` |
| Source adapter | Root directory, allowed hosts, network timeouts, S3 credentials | Options inside the `sources` adapter tuple |
| Plug mount | Presets, CORS, HTTP cache policy, debug permission | `ImagePipe.Plug.init(options)` or router mount options |
| Processing request | Width, crop, effects, format, quality | URL options or `ImagePipe.group/2` and `ImagePipe.output/2` |
| Direct call context | Accept header, storage partition values | `accept:` and `request_inputs:` on `run`/`write` |

Mount options can override shared configuration. Direct `run`/`write` host
options override the builder's configuration. Explicit request output choices
override host defaults. URL preset precedence is `default`, named presets in
listed order, then explicit URL options. See [presets](urls.md#presets) for
related-option replacement rules.

## Sources, caches, and URL protection

| Option | Default | Purpose |
| --- | --- | --- |
| `sources` | No configured adapters | Keyword list of source name to `{module, options}`; see [sources](sources.md) |
| `source_schemes` | `%{}` | Custom scheme names to `{translator, options}` |
| `cache` | Disabled | Output cache adapter; see [caching](cache.md) |
| `input_cache` | Disabled | Independent source-body cache adapter |
| `source_cache_policy` | Built-in policy | Freshness/revalidation policy; see [caching](cache.md) |
| `storage_inputs` | `[]` | Header/cookie names that partition cache storage, e.g. `[{:header, "x-tenant"}]` |
| `base_url` | `""` | URL-generation prefix, e.g. `"/images"` or `"https://cdn.example.com/images"` |
| `keys` | `[]` | Ordered hex signing keys; first signs, all verify |
| `source_encryption_keys` | `[]` | Ordered raw 32-byte encryption keys, separate from signing keys |
| `encrypt_source` | `false` | Generate concealed sources in URLs; requires both key sets |
| `iv_mode` | `:deterministic` | Source-encryption IV generation; also accepts `:random` |
| `clock` | Current Unix seconds | Zero-argument function used for request expiry |

Signing, encryption, and source encoding are covered in [URLs and presets](urls.md).
`storage_inputs` changes storage identity without changing a byte-identical
representation's ETag; it does not forward those inputs to the source.

## Resource limits

| Option | Default | Meaning |
| --- | --- | --- |
| `max_body_bytes` | `10_000_000` | Maximum encoded source body size |
| `max_input_pixels` | `40_000_000` | Maximum decoded input pixel count |
| `max_result_width` | `8_192` | Maximum output width |
| `max_result_height` | `8_192` | Maximum output height |
| `max_result_pixels` | `40_000_000` | Maximum output pixel count |
| `processing_pool` | Omitted | Registered name or PID of a supervised `ImagePipe.ProcessingPool` |

Size limits are positive integers. Output limits clamp generation along with
encoder limits. These are generation limits, not cache identity: successful
cached responses may still be served after a limit changes.

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
| `strip_color_profile` | `true` | Convert into working space and omit source ICC; `false` preserves source profile |
| `preserve_hdr` | `false` | Preserve high bit depth when supported by the output |

Explicit request `quality`/`q` wins over the selected format's quality.
Request `metadata`/`meta` replaces both metadata switches. Named output color
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
  ImagePipe.new(config)
  |> ImagePipe.output(format: :jpeg, jpeg_options: [interlace: false])
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
| `presets` | `%{}` | Map from name to processing option string; [preset guide](urls.md#presets) |
| `allow_origin` | Omitted | Nonempty CORS origin string, e.g. `"https://app.example.com"` or `"*"` |
| `allow_debug_headers` | `false` | Allow request `debug` to expose diagnostic headers |
| `http_cache` | Disabled | `[mode: :enabled, visibility: :auto]`; visibility also accepts `:private` or `:public` |

Enabling HTTP cache headers and configuring internal storage are separate
decisions. See [HTTP caching](cdn-http-cache.md) and [debug headers](debug_headers.md)
for behavior and disclosure details.
