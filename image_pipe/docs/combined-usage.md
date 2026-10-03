# Combined Plug and Elixir usage

Share one configuration when your application both serves images over HTTP
and generates images in jobs or scripts. The same plan can generate a URL,
warm a cache, or write a file.

## Configure once

Construct configuration at startup and share it with the mount and callers:

```elixir
url_config = ImagePipe.URL.config(base_url: "/images")

config = ImagePipe.config(
  url: url_config,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media", stable: :immutable]
    ]
  ],
  cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/output"},
  quality: 82
)

mount = ImagePipe.Plug.init(config: config, http_cache: :auto)

thumbnail =
  ImagePipe.URL.new(url_config)
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
  |> ImagePipe.URL.output(format: :webp)

url = ImagePipe.URL.url!(thumbnail, "photos/beach-v1.jpg")
{:ok, result} = ImagePipe.run(config, thumbnail, {:source, "photos/beach-v1.jpg"})
{:ok, _result} =
  ImagePipe.write(config, thumbnail, {:source, "photos/beach-v1.jpg"}, "thumbnail.webp")
```

`stable: :immutable` promises immutable source identifiers. Give changed files a
new path, such as `beach-v2.jpg`. Use the default `stable: :auto` for files
that can change: ImagePipe identifies them by their contents and reuses cached
results while they're unchanged. See [local files](sources.md#local-files).

## Connect the mount

To share it with a router mount, run the configuration as an instance and
mount it with `instance:` (see [Mount an instance](plug-usage.md#mount-an-instance)).
Router options are evaluated when the router compiles, so they can't take a
`config` built at startup, and an instance is also needed when the
configuration reads runtime values, such as keys from environment variables,
or uses a bounded cache. Direct calls get the instance's configuration from
`ImagePipe.config!/1`.

`ImagePipe.Plug.call(conn, mount)` serves a request with a mount from
`ImagePipe.Plug.init/1`. The connection's `path_info` must contain only the
mount-relative path.

For example, this simulates the forwarded HTTP request for the generated URL:

```elixir
path = String.replace_prefix(url, "/images", "")
conn = Plug.Test.conn(:get, path)
conn = ImagePipe.Plug.call(conn, mount)
200 = conn.status
true = conn.resp_body == result.data
```

Keep configuration server-side. In a template, expose the generated URL:

```heex
<img src={ImagePipe.URL.url!(@thumbnail, @photo.source)} alt={@photo.description} />
```

## Share cache entries

Configured `{:source, identifier}` inputs use the same adapters, source identity,
freshness rules, and cache entries as HTTP requests. A background `run` can warm
the output for the next browser request, and HTTP can warm it for an Elixir job.
Raw `{:file, path}` and `{:binary, bytes}` inputs bypass both caches.

Equivalent output requires the same source bytes, plan, host settings, and
detector behavior. If the format is negotiated, pass the same `accept:` value
to direct execution. If `storage_inputs` partitions storage, pass the matching
`request_inputs:` too:

```elixir
ImagePipe.run(config, thumbnail, {:source, "photos/beach-v1.jpg"},
  accept: "image/webp",
  request_inputs: [headers: [{"x-tenant", "one"}]]
)
```

Those header values partition storage only when named in `storage_inputs`.
They are not forwarded to the source. See the `:request_inputs` option of `ImagePipe.run/4`.

## Know which settings are shared

| URL configuration | Server configuration | Plug-only behavior |
| --- | --- | --- |
| Signing/encryption keys, URL prefix | Sources, caches, generation limits, output defaults, detector, presets, request defaults | CORS, debug-header permission, HTTP cache policy, conditional responses |

Build URLs from `ImagePipe.url_config(config)` and select presets with
`ImagePipe.URL.new(ImagePipe.url_config(config)) |> ImagePipe.URL.group(presets: ["poster-320"])`;
the builder then checks plans against the configuration's presets. Plug and direct
execution expand request defaults, named presets in order, and explicit
options using the same rules. Generated URLs retain the preset names for the
serving mount to resolve. If URLs are built in a different application from the
one that serves them, see [URL builder with an external server](external-server.md).

Use a shared [processing pool](processing-controls.md) to bound generation
across HTTP requests, jobs, and cache refreshes. Direct results are fully
buffered; allow memory for the complete output of each concurrent call.
