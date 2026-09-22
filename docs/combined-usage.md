# Combined Plug and Elixir usage

Share one configuration when your application both serves images over HTTP
and generates images in jobs or scripts. The same plan can generate a URL,
warm a cache, or write a file.

## Configure once

Construct configuration at application startup and make it available to the
mount and callers. Here is a complete example that can also be run in IEx:

```elixir
alias ImagePipe, as: IP

config = IP.config(
  base_url: "/images",
  sources: [
    path: {ImagePipe.Source.File,
           root: "/srv/images", root_id: "media", stable: :trusted}
  ],
  cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image-pipe/output"},
  quality: 82
)

mount = IP.Plug.init(config: config, http_cache: [mode: :enabled])

thumbnail =
  IP.new(config)
  |> IP.group(resize: [width: 400, height: 300, fit: :cover])
  |> IP.output(format: :webp)

url = IP.url!(thumbnail, "photos/beach-v1.jpg")
{:ok, result} = IP.run(thumbnail, {:source, "photos/beach-v1.jpg"})
{:ok, _result} = IP.write(thumbnail, {:source, "photos/beach-v1.jpg"}, "thumbnail.webp")
```

`stable: :trusted` promises immutable source identifiers. Give changed files a
new path, such as `beach-v2.jpg`. Use the default `stable: :auto` for mutable
files, and read the [source cache policy](cache.md) before enabling caching for them.

## Connect the mount

Use `config: config` in the mount options from the [Plug guide](plug-usage.md).
For an application that supplies configuration at runtime, initialize with
`ImagePipe.Plug.init(config: config)` once and call
`ImagePipe.Plug.call(conn, mount)` from your forwarding plug. The forwarded
connection's `path_info` must contain only the mount-relative path.

For example, this simulates the forwarded HTTP request for the generated URL:

```elixir
path = String.replace_prefix(url, "/images", "")
conn = Plug.Test.conn(:get, path)
conn = IP.Plug.call(conn, mount)
200 = conn.status
true = conn.resp_body == result.data
```

Keep configuration server-side. In a template, expose the generated URL:

```heex
<img src={ImagePipe.url!(@thumbnail, @photo.source)} alt={@photo.description} />
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
IP.run(thumbnail, {:source, "photos/beach-v1.jpg"},
  accept: "image/webp",
  request_inputs: [headers: [{"x-tenant", "one"}]]
)
```

Those header values partition storage only when named in `storage_inputs`;
they are not forwarded to the source. See [Elixir request inputs](elixir-api.md#options-and-equivalence).

## Know which settings are shared

| Shared configuration | Plug-only behavior |
| --- | --- |
| Sources, caches, generation limits, output defaults, detector, signing/encryption keys, URL prefix | URL presets, CORS, debug-header permission, HTTP cache policy, conditional responses |

Plans contain explicit processing choices. URL presets—including a `default`
preset—are expanded only by the Plug parser. For a reusable recipe shared by
both entry points, use an ordinary function that builds a plan.

Use a shared [processing pool](processing-controls.md) to bound generation
across HTTP requests, jobs, and cache refreshes. Direct results are fully
buffered; allow memory for the complete output of each concurrent call.

Continue with [configuration](configuration.md), [URL protection](urls.md),
or the full [Elixir API guide](elixir-api.md).
