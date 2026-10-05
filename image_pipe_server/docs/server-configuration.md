# Configuring image_pipe_server

The server reads its configuration once at boot, from a TOML file and from
environment variables. The [guides](../../image_pipe/docs/index.md) describe what the settings
do, with a tab for the server wherever its syntax differs.

An application that builds URLs for the server must match some of them, as
listed in [shared URL settings](../../image_pipe/docs/shared-url-settings.md).

## Sources and precedence

1. The library's defaults.
2. Standard `AWS_` variables, for the S3 credential options that
   `container_credentials` and `web_identity` leave out (see
   [S3 `credentials`](#s3-credentials)).
3. The TOML file named by `IPS_CONFIG`, or `/etc/image_pipe/config.toml`. The
   default file is optional, so a deployment can use only environment
   variables. A missing file named by `IPS_CONFIG` stops the server.
4. `IPS_` environment variables, which override single settings in the file.

A small file:

```toml
[url]
keys = ["0123abcd…"]

[sources.static]
adapter = "file"
match = "path"
root = "/data/images"
root_id = "static"

[sources.tmdb]
adapter = "http"
match = { prefix = "tmdb" }
base_url = "https://image.tmdb.org/t/p/original"
path_pattern = '[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)'
stable = "immutable"
cache_policy = { storage = "allow" }

[cache.output]
root = "/var/cache/image_pipe/output"
max_size_bytes = 10_000_000_000
node_id = "node-0"

[processing]
quality = 82

[pool]
max_concurrency = 8
max_queue = 16
```

## Environment variables

A variable names a setting by its path in the file: `IPS_`, then the levels
joined with `__` and written in upper case. Single underscores stay part of a
name.

```sh
IPS_URL__KEYS=0123abcd…
IPS_SOURCES__TMDB__ADAPTER=http
IPS_SOURCES__TMDB__MATCH__PREFIX=tmdb
IPS_SOURCES__TMDB__BASE_URL=https://image.tmdb.org/t/p/original
IPS_PROCESSING__QUALITY=82
```

- Levels are lowercased, so a source written as `[sources.TMDB]` in the file
  can't be overridden from the environment. Use lowercase source names.
- Lists are comma-separated, such as `IPS_URL__KEYS=0123abcd…,4567ef01…`, or
  have one entry per line.
- A variable ending in `_FILE` reads the value from that file, without
  trailing whitespace, for Docker and Kubernetes secrets:
  `IPS_URL__KEYS_FILE=/run/secrets/signing_keys`. A secret file can hold one
  list entry per line.
- Setting the same value twice is an error, such as `IPS_URL__KEYS` together
  with `IPS_URL__KEYS_FILE`, or with `IPS_url__keys`, since levels are
  lowercased.
- A list variable with no entries, or a `_FILE` variable whose file has none,
  is an error, so an empty signing-keys secret stops the server instead of
  turning off signature checks.
- Settings whose own name ends in `_file`, such as the `web_identity`
  provider's `token_file`, take the variable's value as the path instead:
  `IPS_SOURCES__MEDIA__CREDENTIALS__TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`.
- Variables that Kubernetes sets for a Service named `ips` or `ips-…`, such
  as `IPS_SERVICE_HOST` and `IPS_PORT`, are ignored. Every setting has a
  `__` in its name, and these never do.
- Settings that are awkward as variables, such as S3 `buckets`,
  `address_policy`, or `storage_inputs`, belong in the file.

## Values

TOML strings, numbers, booleans, arrays, and tables map onto the library's
options:

- Named values are strings: `stable = "immutable"`, `http_cache = "auto"`.
- Tagged values are tables with one entry: `freshness = { fallback = 60 }`.
- Tables with library-defined keys, such as `format_quality = { webp = 80 }`,
  accept only keys the library knows.
- `adapter` names a built-in source adapter: `"file"`, `"http"`, or `"s3"`.
- `match` is `"path"` or a table of `prefix` and `scheme` rules, each a string
  or an array.
- `path_pattern` is a regular expression, anchored by the adapter.
- HTTP sources take `request_headers` (a table of header names to values) and
  `bearer_token` for origins behind an API key or a static token. Both can
  come from `_FILE` variables. A shell can't export a variable named after a
  header with a `-`, such as
  `IPS_SOURCES__TMDB__REQUEST_HEADERS__X-API-KEY_FILE`. Docker, Compose, and
  Kubernetes accept the name, so set it there. Otherwise, set the header under
  `request_headers` in the TOML file.
- S3 `credentials` are `{ static = { access_key_id = "…", secret_access_key = "…" } }`
  or a provider: `{ provider = "instance_role" }`, `"container_credentials"`,
  `"web_identity"`, or `"assume_role"`, with the provider's options in the same
  table.

Some settings exist only in Elixir: functions (`address_resolver`, the
function form of `address_policy`, `clock`), `req_options`, custom source
adapters, detectors, and credential providers. The reference marks
them. Hosts that need them build their own release on top of `image_pipe`.

## Errors

Invalid configuration stops the server at boot. The server prints the error,
which names the setting or variable, and exits with status 1. Errors about
the file's shape and types never quote a value. The library's own checks
may quote a non-secret value, such as an out-of-range `quality`, but never
a key, credential, token, or the contents of a `_FILE`:

```text
invalid configuration: url.source_encryption_keys[0]: expected a hex-encoded 32-byte key
invalid configuration: processing.qualty: unknown setting
```

A file that isn't valid TOML is reported with its position and key, with the
values on the quoted line redacted:

```text
invalid TOML: unexpected newline in single-quoted string in /etc/image_pipe/config.toml on line 2, column 14:

    keys = <redacted value>
           ^
```

## Reference

Every key the server accepts, generated from the loader's schemas. Types are
TOML types; defaults are the library's.

<!-- reference:start (generated by mix image_pipe_server.gen.reference) -->

### `[server]`

The HTTP listener. Times are in milliseconds. `read_timeout` closes connections that send nothing for that long, idle keep-alive connections included. `max_connections` rounds up to a multiple of 100 above 100 connections. With `auth_token`, requests other than `/health` must send `Authorization: Bearer <token>`.

| Key | Type | Default |
| --- | --- | --- |
| `port` | integer 0–65535 | `8080` |
| `bind` | string | `"0.0.0.0"` |
| `mount_path` | string | `"/"` |
| `shutdown_timeout` | integer ≥ 0 | `15000` |
| `read_timeout` | integer > 0 | `10000` |
| `max_connections` | integer > 0 | `2048` |
| `auth_token` | string |  |

### `[url]`

How the server checks request URLs: the signing keys and the keys that decrypt `enc/` image paths. See [signing URLs and rotating keys](../../image_pipe/docs/signing-urls.md).

| Key | Type | Default |
| --- | --- | --- |
| `keys` | array of hex strings | `[]` |
| `source_encryption_keys` | array of hex strings, each a 32-byte key | `[]` |

### `[sources.<name>]`

One table per source. The table name is the source's name. Besides
`adapter` and `match`, a source takes its adapter's options.

| Key | Type | Default |
| --- | --- | --- |
| `adapter` | `"file"` or `"http"` or `"s3"` |  |
| `match` | `"path"` or table |  |
| `match.prefix` | array of string or string |  |
| `match.scheme` | array of string or string |  |

#### `adapter = "file"`

| Key | Type | Default |
| --- | --- | --- |
| `root` | string |  |
| `root_id` | string |  |
| `verify` | `"stat"` or `"hash"` | `"stat"` |
| `copy` | `"none"` or `"keep"` | `"none"` |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"auto"` or `"enabled"` or `"disabled"` | `"auto"` |
| `http_cache` | `"inherit"` or `"validators"` or `"auto"` or `"public"` or `"private"` | `"inherit"` |
| `cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |

#### `adapter = "http"`

| Key | Type | Default |
| --- | --- | --- |
| `allowed_hosts` | array of string |  |
| `base_url` | string |  |
| `receive_timeout` | integer ≥ 0 |  |
| `fetch_timeout` | integer > 0 |  |
| `connect_timeout` | integer ≥ 0 |  |
| `pool_timeout` | integer ≥ 0 |  |
| `max_redirects` | integer ≥ 0 | `0` |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"auto"` or `"enabled"` or `"disabled"` | `"auto"` |
| `http_cache` | `"inherit"` or `"validators"` or `"auto"` or `"public"` or `"private"` | `"inherit"` |
| `cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |
| `path_pattern` | string (regular expression) |  |
| `address_policy.allow` | array of string |  |
| `address_policy.allow_loopback` | boolean |  |
| `address_policy.allow_unspecified` | boolean |  |
| `address_policy.allow_link_local` | boolean |  |
| `address_policy.allow_private` | boolean |  |
| `address_policy.allow_unique_local` | boolean |  |
| `address_policy.allow_multicast` | boolean |  |
| `address_policy.allow_broadcast` | boolean |  |
| `address_policy.allow_cgnat` | boolean |  |
| `address_policy.allow_reserved` | boolean |  |
| `request_headers` | table of string |  |
| `bearer_token` | string |  |

Elixir only: `req_options`, `address_resolver`.

#### `adapter = "s3"`

| Key | Type | Default |
| --- | --- | --- |
| `region` | string |  |
| `endpoint` | string |  |
| `receive_timeout` | integer ≥ 0 |  |
| `fetch_timeout` | integer > 0 |  |
| `connect_timeout` | integer ≥ 0 |  |
| `pool_timeout` | integer ≥ 0 |  |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"auto"` or `"enabled"` or `"disabled"` | `"auto"` |
| `http_cache` | `"inherit"` or `"validators"` or `"auto"` or `"public"` or `"private"` | `"inherit"` |
| `cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |
| `credentials` | `{ static = {...} }` or `{ provider = "...", ... }` |  |
| `buckets` | table of the S3 settings above |  |

Elixir only: `req_options`.

#### S3 `credentials`

Static credentials:

| Key | Type | Default |
| --- | --- | --- |
| `static.access_key_id` | string |  |
| `static.secret_access_key` | string |  |
| `static.token` | string |  |

Or a credential `provider` and its options. `assume_role` takes `base`
credentials in the same forms. `container_credentials` without
`relative_uri`, `full_uri`, `auth_token`, or `auth_token_file` takes each
one whose variable is set from `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`,
`AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN`,
and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`. `web_identity` fills each of
`token_file`, `role_arn`, `region`, and `role_session_name` that the
table leaves out, from `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`,
`AWS_REGION`, and `AWS_ROLE_SESSION_NAME` respectively.

`provider = "assume_role"`:

| Key | Type | Default |
| --- | --- | --- |
| `base` | `{ static = {...} }` or `{ provider = "...", ... }` |  |
| `role_arn` | string |  |
| `region` | string |  |
| `external_id` | string |  |
| `role_session_name` | string |  |
| `receive_timeout` | integer ≥ 0 |  |
| `connect_timeout` | integer ≥ 0 |  |

`provider = "container_credentials"`:

| Key | Type | Default |
| --- | --- | --- |
| `base_url` | string |  |
| `full_uri` | string |  |
| `relative_uri` | string |  |
| `auth_token` | string |  |
| `auth_token_file` | string |  |
| `receive_timeout` | integer ≥ 0 |  |
| `connect_timeout` | integer ≥ 0 |  |

`provider = "instance_role"`:

| Key | Type | Default |
| --- | --- | --- |
| `base_url` | string |  |
| `ttl_seconds` | integer > 0 |  |
| `receive_timeout` | integer ≥ 0 |  |
| `connect_timeout` | integer ≥ 0 |  |

`provider = "web_identity"`:

| Key | Type | Default |
| --- | --- | --- |
| `token_file` | string |  |
| `role_arn` | string |  |
| `region` | string |  |
| `role_session_name` | string |  |
| `receive_timeout` | integer ≥ 0 |  |
| `connect_timeout` | integer ≥ 0 |  |

### `[cache]`

Caches on the local filesystem: `output` for processed images, `input` for originals. Their `root` directories must be separate, neither inside the other. Setting `max_size_bytes` bounds a cache and requires `node_id`. See [caching processed images](../../image_pipe/docs/caching-processed-images.md).

| Key | Type | Default |
| --- | --- | --- |
| `output.path_prefix` | string | `""` |
| `output.max_size_bytes` | integer > 0 |  |
| `output.node_id` | string |  |
| `output.state_dir` | string |  |
| `output.sketch_depth` | integer > 0 |  |
| `output.sketch_width` | integer > 0 |  |
| `output.aging_sample_size` | integer > 0 |  |
| `output.doorkeeper_cardinality` | integer > 0 |  |
| `output.eviction_victim_limit` | integer > 0 |  |
| `output.flush_interval` | integer > 0 |  |
| `output.cleanup_interval` | integer > 0 |  |
| `output.reconcile_interval` | integer > 0 |  |
| `output.state_ttl` | integer > 0 |  |
| `output.root` | string (absolute path) |  |
| `output.window_ratio` | number |  |
| `output.doorkeeper_fpr` | number |  |
| `output.max_body_bytes` | integer ≥ 0 |  |
| `input.path_prefix` | string | `""` |
| `input.max_size_bytes` | integer > 0 |  |
| `input.node_id` | string |  |
| `input.state_dir` | string |  |
| `input.sketch_depth` | integer > 0 |  |
| `input.sketch_width` | integer > 0 |  |
| `input.aging_sample_size` | integer > 0 |  |
| `input.doorkeeper_cardinality` | integer > 0 |  |
| `input.eviction_victim_limit` | integer > 0 |  |
| `input.flush_interval` | integer > 0 |  |
| `input.cleanup_interval` | integer > 0 |  |
| `input.reconcile_interval` | integer > 0 |  |
| `input.state_ttl` | integer > 0 |  |
| `input.root` | string (absolute path) |  |
| `input.window_ratio` | number |  |
| `input.doorkeeper_fpr` | number |  |
| `storage_inputs` | array of `{ header = … }` or `{ cookie = … }` (string) |  |

### `[processing]`

Defaults and limits for every image the server processes. The limits on originals and results are described in [limiting work per request](../../image_pipe/docs/deployment.md).

| Key | Type | Default |
| --- | --- | --- |
| `max_body_bytes` | integer > 0 | `10000000` |
| `max_input_pixels` | integer > 0 | `40000000` |
| `max_input_frames` | integer > 0 | `1000` |
| `max_result_width` | integer > 0 | `8192` |
| `max_result_height` | integer > 0 | `8192` |
| `max_result_pixels` | integer > 0 | `40000000` |
| `auto_avif` | boolean | `true` |
| `auto_webp` | boolean | `true` |
| `quality` | integer > 0 | `80` |
| `format_quality` | table of integer > 0 | `{ avif = 63, webp = 79 }` |
| `strip_metadata` | boolean | `true` |
| `keep_copyright` | boolean | `true` |
| `stripped_dpi` | integer 1–65535 | `72` |
| `strip_color_profile` | boolean | `true` |
| `preserve_hdr` | boolean | `false` |
| `skip_processing_formats` | array of `"avif"` or `"webp"` or `"jpeg"` or `"png"` or `"jpeg_xl"` or `"heif"` or `"tiff"` or `"jpeg2000"` or `"gif"` | `[]` |
| `autoquality` | boolean | `false` |
| `autoquality_target` | integer or number | `75` |
| `detector` | `"default"` | `"default"` |
| `detector_required` | boolean | `false` |
| `source_cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `source_cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `source_cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |
| `format_order` | array of `"avif"` or `"webp"` |  |
| `jpeg_options.interlace` | boolean |  |
| `jpeg_options.subsample_mode` | `"auto"` or `"on"` or `"off"` |  |
| `jpeg_options.trellis_quant` | boolean |  |
| `jpeg_options.overshoot_deringing` | boolean |  |
| `jpeg_options.optimize_scans` | boolean |  |
| `jpeg_options.quant_table` | integer 0–8 |  |
| `png_options.interlace` | boolean |  |
| `png_options.palette` | boolean |  |
| `png_options.bitdepth` | `1` or `2` or `4` or `8` or `16` |  |
| `png_options.filter` | `"none"` or `"sub"` or `"up"` or `"avg"` or `"paeth"` or `"all"` |  |
| `webp_options.lossless` | boolean |  |
| `webp_options.near_lossless` | boolean |  |
| `webp_options.smart_subsample` | boolean |  |
| `webp_options.preset` | `"default"` or `"photo"` or `"picture"` or `"drawing"` or `"icon"` or `"text"` |  |
| `webp_options.effort` | integer 0–6 |  |
| `avif_options.subsample_mode` | `"auto"` or `"on"` or `"off"` |  |
| `avif_options.effort` | integer 0–9 |  |
| `watermarks.<name>.source` | string |  |
| `watermarks.<name>.opacity` | number | `1.0` |
| `request_watermarks` | boolean | `false` |
| `presets` | table of string |  |
| `request_defaults` | string |  |
| `detector_warmup` | `"all"` or `false` or array of string | `"all"` |

Elixir only: `max_preset_lookups`, `preset_lookup`, `telemetry_prefix`, `clock`.

### `[pool]`

How many images are processed at once, and how long requests wait for a turn. Times are in milliseconds. `max_concurrency` defaults to the number of CPU cores the server can use. See [limiting concurrent processing](../../image_pipe/docs/processing-controls.md).

| Key | Type | Default |
| --- | --- | --- |
| `max_concurrency` | integer > 0 |  |
| `max_queue` | integer ≥ 0 | `64` |
| `queue_timeout` | integer > 0 | `10000` |
| `processing_timeout` | integer > 0 | `30000` |

### `[http]`

Response settings: the CORS origin, whether requests may ask for debug headers, and the HTTP cache headers. See [serving images through a CDN](../../image_pipe/docs/serving-through-a-cdn.md).

| Key | Type | Default |
| --- | --- | --- |
| `allow_origin` | string |  |
| `allow_debug_headers` | boolean | `false` |
| `http_cache` | `"validators"` or `"auto"` or `"public"` or `"private"` | `"validators"` |

### `[telemetry]`

`log_level` is the lowest level the server logs. `log_requests` logs each request and its stages at `info`, and failures at `warning`. With `trust_traceparent`, a request with a W3C `traceparent` header joins the caller's trace when [tracing](server-deployment.md#tracing) is on. Any client can send that header.

| Key | Type | Default |
| --- | --- | --- |
| `log_level` | `"error"` or `"info"` or `"debug"` or `"emergency"` or `"alert"` or `"critical"` or `"warning"` or `"notice"` | `"info"` |
| `log_requests` | boolean | `false` |
| `trust_traceparent` | boolean | `false` |

<!-- reference:end -->
