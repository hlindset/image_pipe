# Caching processed images

Store processed images on disk, so a repeat request is served from the cache
instead of being processed again. This guide assumes ImagePipe is already
running in your app (see [Plug usage](plug-usage.md)) or as
`image_pipe_server`. How long cached images stay valid is covered in
[Caching and freshness](caching-and-freshness.md).

## Add a processed-image cache

Point the cache at a directory that ImagePipe can write to. ImagePipe creates
the directory if it is missing.

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ],
  cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/processed"}
```

### image_pipe_server

```toml
[cache.output]
root = "/var/cache/image_pipe/processed"
```

In the Docker image, put cache directories under `/var/cache/image_pipe` and
mount a volume there, as shown in
[Running](https://github.com/hlindset/image_pipe/blob/main/image_pipe_server/docs/deployment.md#running).

<!-- tabs-close -->

## Add an originals cache

Add an originals cache when you serve several sizes or formats of the same
image from a remote source: new sizes are then made from the stored original
instead of downloading it again. It needs its own directory.

<!-- tabs-open -->

### Plug

```elixir
cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/processed"},
input_cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/originals"}
```

### image_pipe_server

```toml
[cache.input]
root = "/var/cache/image_pipe/originals"
```

<!-- tabs-close -->

Local files are read where they are. To keep copies of them in the originals
cache, for example on a network filesystem, set the file source's `copy`
option to `keep` (see [local files](sources.md#local-files)).

## Bound the cache size

Both caches grow without limit by default. Set `max_size_bytes` to cap a
cache. The cache then evicts rarely requested images to stay under it. A
bounded cache also needs a `node_id` that names this server.

<!-- tabs-open -->

### Plug

A bounded cache runs its own processes, which your application starts. The
mount and those processes need the same options, so build them once in your
application's `start/2`. Store the mount where a small plug can reach it, and
start the cache before the endpoint:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  cache = [
    root: "/var/cache/image_pipe/processed",
    max_size_bytes: 5_000_000_000,
    node_id: "node-0"
  ]

  mount =
    ImagePipe.Plug.init(
      sources: [
        media: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: "/srv/images", root_id: "media"]
        ]
      ],
      cache: {ImagePipe.Cache.FileSystem, cache}
    )

  :persistent_term.put({MyAppWeb.ImagePlug, :mount}, mount)

  children = [
    ImagePipe.Cache.FileSystem.child_spec(cache),
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

```elixir
# lib/my_app_web/image_plug.ex
defmodule MyAppWeb.ImagePlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(conn, :persistent_term.get({__MODULE__, :mount}))
  end
end
```

```elixir
# lib/my_app_web/router.ex
forward "/images", MyAppWeb.ImagePlug
```

To bound an originals cache, build its options the same way with
`pool: :input` added, pass them as
`input_cache: {ImagePipe.Cache.FileSystem, options}`, and start their own
`child_spec/1`.

### image_pipe_server

```toml
[cache.output]
root = "/var/cache/image_pipe/processed"
max_size_bytes = 5_000_000_000
node_id = "node-0"
```

The server starts the cache's processes itself. Bound `[cache.input]` the same
way.

<!-- tabs-close -->

## Run several replicas

If replicas share a cache volume, give each one a different `node_id`. If a
replica's cache volume outlives the replica, keep its `node_id` the same when
it restarts. A cache volume that belongs to one pod and is lost with it, such
as an `emptyDir`, works with a fixed `node_id`.

On Kubernetes, run a StatefulSet and use the pod name, such as
`image-pipe-0`, which covers both cases. Deployment pod names change on
restart.

<!-- tabs-open -->

### Plug

Expose the pod name to the container:

```yaml
env:
  - name: POD_NAME
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
```

In `start/2`, read it into the cache options:

```elixir
node_id: System.fetch_env!("POD_NAME")
```

### image_pipe_server

Set `node_id` from the pod name:

```yaml
env:
  - name: IPS_CACHE__OUTPUT__NODE_ID
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
  - name: IPS_CACHE__INPUT__NODE_ID
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
```

<!-- tabs-close -->

## Confirm caching works

Allow debug headers for now:

<!-- tabs-open -->

### Plug

```elixir
allow_debug_headers: true
```

### image_pipe_server

```toml
[http]
allow_debug_headers = true
```

<!-- tabs-close -->

Request the same image twice with `debug` added to its options. If your URLs
are signed, sign the URL with `debug` included.

<!-- tabs-open -->

### Plug

```console
$ curl -s -o /dev/null -D - http://localhost:4000/images/w=400/debug/src/photos/beach.jpg | grep 'x-imagepipe-cache:'
x-imagepipe-cache: miss
$ curl -s -o /dev/null -D - http://localhost:4000/images/w=400/debug/src/photos/beach.jpg | grep 'x-imagepipe-cache:'
x-imagepipe-cache: hit
```

### image_pipe_server

Use one of your own image paths. The server listens on port 8080 and serves
from `/` unless `[server]` sets another `port` or `mount_path`.

```console
$ curl -s -o /dev/null -D - http://localhost:8080/w=400/debug/src/photos/beach.jpg | grep 'x-imagepipe-cache:'
x-imagepipe-cache: miss
$ curl -s -o /dev/null -D - http://localhost:8080/w=400/debug/src/photos/beach.jpg | grep 'x-imagepipe-cache:'
x-imagepipe-cache: hit
```

If `[server]` sets `auth_token`, add `-H "Authorization: Bearer <token>"`.

<!-- tabs-close -->

If the second request is still a `miss`:

- The origin may forbid storage (see
  [storage permission](caching-and-freshness.md#storage-permission)).
- In a Plug app, a bounded cache whose `child_spec/1` isn't started never
  writes. The log shows
  `Admission process unavailable in bounded mode; skipping write`.

Turn debug headers off again when you're done, since they
[disclose details](debug_headers.md#security-and-disclosure) about your
sources.

## Next steps

- [HTTP and CDN caching](cdn-http-cache.md) adds browser and CDN caching in
  front.
- [Cache](cache.md) lists every cache option.
- The
  [server configuration reference](https://github.com/hlindset/image_pipe/blob/main/image_pipe_server/docs/configuration.md#cache)
  lists every `[cache]` key.
