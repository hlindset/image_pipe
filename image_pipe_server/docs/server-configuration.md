# Configuring image_pipe_server

The server reads its configuration once at boot, from a TOML file and from
environment variables. The [guides](../../image_pipe/docs/index.md) describe what the settings
do, with a tab for the server wherever its syntax differs.

An application that builds URLs for the server must match some of them, as
listed in [shared URL settings](../../image_pipe/docs/shared-url-settings.md).

## Sources and precedence

1. The library's defaults.
2. Standard `AWS_` variables, for the S3 credential options that
   `container_credentials` and `web_identity` leave out (see S3 `credentials`
   under [`[sources.<name>]`](#sources-name)).
3. The TOML file named by `IPS_CONFIG`, or `/etc/image_pipe/config.toml`, or
   the file's contents in `IPS_CONFIG_TOML` on a platform that can't mount
   files. The default file is optional, so a deployment can use only
   environment variables. A missing file named by `IPS_CONFIG`, or setting
   both `IPS_CONFIG` and `IPS_CONFIG_TOML`, stops the server.
4. `IPS_` environment variables, which override single settings in the TOML
   configuration.

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
  `address_policy`, or `vary_on`, belong in the file.

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

Errors from the library's own checks start with
`invalid ImagePipe configuration:` or `invalid ImagePipe instance:` and name
the setting without its table, such as `:max_result_width` for
`processing.max_result_width`:

```text
invalid ImagePipe configuration: invalid value for :max_result_width option: expected positive integer, got: 0
```

A file that isn't valid TOML is reported with its position and key, with the
values on the quoted line redacted. An error in `IPS_CONFIG_TOML` names the
variable in place of the path:

```text
invalid TOML: unexpected newline in single-quoted string in /etc/image_pipe/config.toml on line 2, column 14:

    keys = <redacted value>
           ^
```

A valid configuration can still fail to start when the server can't listen
on `port` or `health_port` in [`[server]`](#server), for example because
another process already uses the port. After the listener's own log line,
the server prints the port setting and the address it tried, and exits with
status 1:

```text
[error] Running ImagePipeServer.Router with Bandit 1.13.1 at http failed, port 8080 already in use
cannot start: can't listen on server.port 8080 at 0.0.0.0: address already in use
```

A `root` in [`[cache.output]`](#cache) that the server can't create or
write doesn't stop it. The server logs an error naming the directory,
serves images without storing them, and counts each one in `write_errors`
in the [cache stats](server-deployment.md#cache-stats):

```text
[error] cache: can't use cache root /var/cache/image_pipe/output: permission denied. Images are served without being stored until the root can be written.
```

## Reference

Every key the server accepts, generated from the loader's schemas. Types are
TOML types, and defaults are the library's. A table that is present must set
its keys marked required.

<!-- reference:start (generated by mix image_pipe_server.gen.reference) -->

### `[server]`

The HTTP listener. `mount_path` is the path that image URLs start with, such as `/images`. It starts with `/` and holds only letters, digits, and `-._~` between its slashes. The server refuses to start with any other character. Times are in milliseconds. `read_timeout` closes connections that send nothing for that long, idle keep-alive connections included. With `auth_token`, requests other than the health checks, `/stats`, and `/metrics` must send `Authorization: Bearer <token>`. The token needs at least 32 characters. On shutdown, `/health/ready` answers `503` while the server keeps serving for `shutdown_delay`. Then in-flight requests get `shutdown_timeout` to finish. `health_port` serves the health checks on a separate listener, outside `max_connections`, at the address in `health_bind`, or else `bind`. See [health and shutdown](server-deployment.md#health-and-shutdown).

| Key | Type | Default |
| --- | --- | --- |
| `port` | integer 0–65535 | `8080` |
| `bind` | string | `"0.0.0.0"` |
| `mount_path` | string | `"/"` |
| `shutdown_delay` | integer ≥ 0 | `5000` |
| `shutdown_timeout` | integer ≥ 0 | `15000` |
| `read_timeout` | integer > 0 | `10000` |
| `max_connections` | integer > 0 | `2048` |
| `auth_token` | string |  |
| `health_port` | integer 0–65535 |  |
| `health_bind` | string |  |

### `[url]`

How the server checks request URLs: the signing keys and the keys that decrypt `enc/` image paths. See [signing URLs and rotating keys](../../image_pipe/docs/signing-urls.md). Without `keys`, the server doesn't start unless `allow_unsigned = true`. That setting lets the server answer URLs without a signature, and the server logs a warning at startup. Set it only for a server that nothing outside a private network can reach.

| Key | Type | Default |
| --- | --- | --- |
| `keys` | array of hex strings, each at least 64 digits | `[]` |
| `source_encryption_keys` | array of hex strings, each a 32-byte key | `[]` |
| `allow_unsigned` | boolean | `false` |

### `[sources.<name>]`

One table per source. The table name is the source's name. Besides
`adapter` and `match`, a source takes its adapter's options.

| Key | Type | Default |
| --- | --- | --- |
| `adapter` | `"file"` or `"http"` or `"s3"` | required |
| `match` | `"path"` or table | required |
| `match.prefix` | array of string or string |  |
| `match.scheme` | array of string or string |  |

#### `adapter = "file"`

| Key | Type | Default |
| --- | --- | --- |
| `root` | string | required |
| `root_id` | string | required |
| `verify` | `"stat"` or `"hash"` | `"stat"` |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"enabled"` or `"disabled"` | `"enabled"` |
| `http_cache` | `"inherit"` or `"validators"` or `"auto"` or `"public"` or `"private"` | `"inherit"` |
| `cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |

#### `adapter = "http"`

| Key | Type | Default |
| --- | --- | --- |
| `allowed_hosts` | array of string |  |
| `base_url` | string |  |
| `receive_timeout` | integer ≥ 0 | `5000` |
| `fetch_timeout` | integer > 0 | `30000` |
| `connect_timeout` | integer ≥ 0 | `5000` |
| `pool_timeout` | integer ≥ 0 | `5000` |
| `pool_size` | integer > 0 | `50` |
| `max_redirects` | integer ≥ 0 | `0` |
| `dns_cache` | boolean | `true` |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"enabled"` or `"disabled"` | `"enabled"` |
| `http_cache` | `"inherit"` or `"validators"` or `"auto"` or `"public"` or `"private"` | `"inherit"` |
| `cache_policy.storage` | `"origin"` or `"allow"` or `"deny"` |  |
| `cache_policy.freshness` | `"origin"` or `{ fallback = … }` or `{ force = … }` (integer ≥ 0) |  |
| `cache_policy.stale_while_revalidate` | `"origin"` or `"disabled"` or `{ force = … }` (integer ≥ 0) |  |
| `path_pattern` | string (regular expression) |  |
| `address_policy.allow` | array of string |  |
| `address_policy.allow_loopback` | boolean | `false` |
| `address_policy.allow_unspecified` | boolean | `false` |
| `address_policy.allow_link_local` | boolean | `false` |
| `address_policy.allow_private` | boolean | `false` |
| `address_policy.allow_unique_local` | boolean | `false` |
| `address_policy.allow_multicast` | boolean | `false` |
| `address_policy.allow_broadcast` | boolean | `false` |
| `address_policy.allow_cgnat` | boolean | `false` |
| `address_policy.allow_reserved` | boolean | `false` |
| `request_headers` | table of string |  |
| `bearer_token` | string |  |

Elixir only: `req_options`, `address_resolver`.

#### `adapter = "s3"`

| Key | Type | Default |
| --- | --- | --- |
| `region` | string | required |
| `endpoint` | string | required |
| `receive_timeout` | integer ≥ 0 | `5000` |
| `fetch_timeout` | integer > 0 | `30000` |
| `connect_timeout` | integer ≥ 0 | `5000` |
| `pool_timeout` | integer ≥ 0 | `5000` |
| `pool_size` | integer > 0 | `50` |
| `stable` | `"auto"` or `"immutable"` | `"auto"` |
| `internal_cache` | `"enabled"` or `"disabled"` | `"enabled"` |
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
| `static.access_key_id` | string | required |
| `static.secret_access_key` | string | required |
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
| `role_arn` | string | required |
| `region` | string | required |
| `external_id` | string |  |
| `role_session_name` | string | `"image-pipe"` |
| `receive_timeout` | integer ≥ 0 | `5000` |
| `connect_timeout` | integer ≥ 0 | `5000` |

`provider = "container_credentials"`:

| Key | Type | Default |
| --- | --- | --- |
| `base_url` | string | `"http://169.254.170.2"` |
| `full_uri` | string |  |
| `relative_uri` | string |  |
| `auth_token` | string |  |
| `auth_token_file` | string |  |
| `receive_timeout` | integer ≥ 0 | `2000` |
| `connect_timeout` | integer ≥ 0 | `2000` |

`provider = "instance_role"`:

| Key | Type | Default |
| --- | --- | --- |
| `base_url` | string | `"http://169.254.169.254"` |
| `ttl_seconds` | integer > 0 | `21600` |
| `receive_timeout` | integer ≥ 0 | `2000` |
| `connect_timeout` | integer ≥ 0 | `2000` |

`provider = "web_identity"`:

| Key | Type | Default |
| --- | --- | --- |
| `token_file` | string |  |
| `role_arn` | string |  |
| `region` | string |  |
| `role_session_name` | string | `"image-pipe"` |
| `receive_timeout` | integer ≥ 0 | `5000` |
| `connect_timeout` | integer ≥ 0 | `5000` |

### `[cache]`

`output` caches processed images on the local filesystem. It needs `root` and `max_size_bytes`. `vary_on` names request headers and cookies whose values select separate processed copies (see [Vary](../../image_pipe/docs/cdn-http-cache.md#vary)). See [caching processed images](../../image_pipe/docs/caching-processed-images.md). `max_remembered_originals` is how many originals the server remembers in memory, with or without a cache: about 1 KB for each local file and 1.4 KB for each image from an origin. It defaults to one for each 50 KB of `output.max_size_bytes`, at least 10,000 and at most 200,000. See [originals and processed images](../../image_pipe/docs/caching-and-freshness.md#originals-and-processed-images) for what happens when an original is forgotten. `output.max_remembered_entries` is how many recently served entries the cache keeps in memory, about 1.1 KB each. It defaults to one for each 50 KB of `output.max_size_bytes`, at least 1,000 and at most 50,000.

| Key | Type | Default |
| --- | --- | --- |
| `output.max_size_bytes` | integer > 0 | required |
| `output.max_remembered_entries` | integer > 0 |  |
| `output.root` | string (absolute path) | required |
| `output.max_body_bytes` | integer ≥ 0 |  |
| `vary_on` | array of `{ header = … }` or `{ cookie = … }` (string) |  |
| `max_remembered_originals` | integer > 0 |  |

### `[processing]`

Defaults and limits for every image the server processes. The limits on originals, intermediate images, and results are described in [limiting work per request](../../image_pipe/docs/deployment.md).

| Key | Type | Default |
| --- | --- | --- |
| `max_body_bytes` | integer > 0 | `10000000` |
| `max_input_pixels` | integer > 0 | `40000000` |
| `max_input_frames` | integer > 0 | `1000` |
| `svg.font_dirs` | array of string | `[]` |
| `svg.fallback_family` | string |  |
| `svg.max_bytes` | integer > 0 | `10000000` |
| `svg.max_render_work` | integer > 0 | `100000000` |
| `svg.max_render_pixels` | integer > 0 | four times `max_input_pixels` |
| `max_result_width` | integer > 0 | `8192` |
| `max_intermediate_pixels` | integer > 0 | `100000000` |
| `max_blur_work` | integer > 0 or `"infinity"` | `4000000000000` |
| `max_search_pixels` | integer > 0 or `"infinity"` | `100000000` |
| `max_result_height` | integer > 0 | `8192` |
| `max_result_pixels` | integer > 0 | `40000000` |
| `auto_avif` | boolean | `true` |
| `auto_webp` | boolean | `true` |
| `quality` | integer 1–100 | `80` |
| `format_quality` | table of integer > 0 | `{ avif = 56, webp = 79 }` |
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
| `format_order` | array of `"avif"` or `"webp"` | `["avif", "webp"]` |
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
| `webp_options.effort` | integer 0–6 | `4` |
| `avif_options.subsample_mode` | `"auto"` or `"on"` or `"off"` | `"off"` |
| `avif_options.effort` | integer 0–9 | `3` |
| `watermarks.<name>.source` | string | required |
| `watermarks.<name>.opacity` | number | `1.0` |
| `presets` | table of string |  |
| `request_defaults` | string |  |
| `detector_warmup` | `"all"` or `false` or array of string | `"all"` |

Elixir only: `preset_lookup`, `telemetry_prefix`, `clock`.

### `[pool]`

How many images are processed at once, and how long requests wait for a turn. Times are in milliseconds. See [limiting concurrent processing](../../image_pipe/docs/processing-controls.md).

| Key | Type | Default |
| --- | --- | --- |
| `max_concurrency` | integer > 0 | the number of CPU cores the server can use |
| `low_priority_max_concurrency` | integer > 0 | half of `max_concurrency`, rounded down, at least 1 |
| `max_queue` | integer ≥ 0 | `1024` |
| `queue_timeout` | integer > 0 | `10000` |
| `processing_timeout` | integer > 0 | `30000` |

### `[http]`

Response settings: the CORS origin and the HTTP cache headers. See [serving images through a CDN](../../image_pipe/docs/serving-through-a-cdn.md).

| Key | Type | Default |
| --- | --- | --- |
| `allow_origin` | string |  |
| `http_cache` | `"validators"` or `"auto"` or `"public"` or `"private"` | `"validators"` |

### `[telemetry]`

`log_level` is the lowest level the server logs. `log_requests` logs one line per image request at `info`, or at `warning` for a `4xx`, a result that didn't come out as requested, or a failed cache read, and `error` for a `5xx` or a response that failed partway through sending. A low-priority request that a full processing pool turned away logs its `503` at `info`. `log_requests` also logs a `warning` line for each failed or dropped cache write, a `warning` line for each request without a valid `auth_token`, and an `info` line for each request outside `mount_path`. With `log_requests` on, `log_stages` also logs a line for each stage of each request, for debugging. `log_format` is `text`, or one JSON object per line: `json`, or `gcp`, `datadog`, or `elastic` for those log collectors' field names. `log_colors` colors `text` lines by level. With `trust_traceparent`, a request with a W3C `traceparent` header joins the caller's trace when [tracing](server-deployment.md#tracing) is on. Any client can send that header. With `trust_request_id`, an incoming `x-request-id` of 1 to 200 letters, digits, and `-_.:+/=` tags the request's log lines instead of a generated ID.

| Key | Type | Default |
| --- | --- | --- |
| `log_level` | `"error"` or `"info"` or `"debug"` or `"emergency"` or `"alert"` or `"critical"` or `"warning"` or `"notice"` | `"info"` |
| `log_requests` | boolean | `true` |
| `log_stages` | boolean | `false` |
| `log_format` | `"text"` or `"json"` or `"gcp"` or `"datadog"` or `"elastic"` | `"text"` |
| `log_colors` | boolean | `false` |
| `trust_traceparent` | boolean | `false` |
| `trust_request_id` | boolean | `false` |

### `[stats]`

`enabled` turns on `GET /stats`, which answers with JSON, and `GET /metrics`, which answers with Prometheus text. They report each cache's size, its hits and misses since the server started, and the free space on the disk that holds it. Every request must send `Authorization: Bearer <token>` with `token`, which is required when `enabled` is true and needs at least 32 characters. The `[server]` `auth_token` doesn't give access to them. With `health_port`, that listener serves them too. See [cache stats](server-deployment.md#cache-stats).

| Key | Type | Default |
| --- | --- | --- |
| `enabled` | boolean | `false` |
| `token` | string |  |

<!-- reference:end -->
