# Caching processed images

Store processed images on disk, so a repeat request is served from the cache
instead of being processed again. This guide assumes ImagePipe is already
running in your app (see [Getting started with Phoenix](phoenix-getting-started.md)) or as
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
[Running](../../image_pipe_server/docs/server-deployment.md#running).

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
option to `keep` (see
[copy files from network storage](serving-local-files.md#copy-files-from-network-storage)).

## Bound the cache size

Both caches grow without limit by default. Set `max_size_bytes` to cap a
cache. The cache then evicts rarely requested images to stay under it. A
bounded cache also needs a `node_id` that names this server.

<!-- tabs-open -->

### Plug

Move the configuration from your `forward` into an instance, which starts the
processes a bounded cache needs. Add the instance to your application's
supervision tree, before the endpoint:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe,
   name: MyApp.Images,
   sources: [
     media: [
       adapter: ImagePipe.Source.File,
       match: :path,
       options: [root: "/srv/images", root_id: "media"]
     ]
   ],
   cache:
     {ImagePipe.Cache.FileSystem,
      root: "/var/cache/image_pipe/processed",
      max_size_bytes: 5_000_000_000,
      node_id: "node-0"}},
  MyAppWeb.Endpoint
]
```

Then mount the instance by name:

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug, instance: MyApp.Images
```

Mount options such as `http_cache` stay on the `forward` (see
[Mounting an instance](ImagePipe.Plug.html#module-mounting-an-instance)).

To bound an originals cache, add `max_size_bytes` and `node_id` to the
instance's `input_cache` options.

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

If replicas share a cache volume, give each one a different `node_id` and the
same `max_size_bytes`, which limits the shared `root`, not each replica's
share. If a replica's cache volume outlives the replica, keep its `node_id`
the same when it restarts. A cache volume that belongs to one pod and is lost with it, such
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

Read it into each bounded cache's options on the instance:

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

If the second request is still a `miss`, the origin may forbid storage (see
[storage permission](caching-and-freshness.md#storage-permission)).

Turn debug headers off again when you're done, since they
[disclose details](debug_headers.md#security-and-disclosure) about your
sources.

## Next steps

- [Serving images through a CDN](serving-through-a-cdn.md) adds CDN caching
  in front.
- `ImagePipe.Cache.FileSystem` lists every cache option, and
  [Cache storage](cache.md) what is stored and how bounded mode behaves.
- The
  [server configuration reference](../../image_pipe_server/docs/server-configuration.md#cache)
  lists every `[cache]` key.
