# Caching processed images

Store processed images on disk, so a repeat request is served from the cache
instead of being processed again. This guide assumes ImagePipe is already
running in your app (see [Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server`. How long cached images stay valid is covered in
[Caching and freshness](caching-and-freshness.md).

## Add a processed-image cache

Point the cache at a directory that ImagePipe can write to, and cap its size
with `max_size_bytes`, below the free space on that disk. ImagePipe creates
the directory if it is missing, and evicts the images least worth keeping
to stay under the cap (see [size limit](cache.md#size-limit)).

<!-- tabs-open -->

### Plug

A cache needs an instance, which starts the processes that track the cache's
size. Move the configuration from your `forward` into an instance, and add it
to your application's supervision tree, before the endpoint:

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
   cache: [root: "/var/cache/image_pipe/processed", max_size_bytes: 5_000_000_000]},
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

### image_pipe_server

```toml
[cache.output]
root = "/var/cache/image_pipe/processed"
max_size_bytes = 5_000_000_000
```

In the Docker image, put cache directories under `/var/cache/image_pipe` and
mount a volume there, as shown in
[Running](../../image_pipe_server/docs/server-deployment.md#running).

<!-- tabs-close -->

## Add an originals cache

Add an originals cache when you serve several sizes or formats of the same
image from a remote source: new sizes are then made from the stored original
instead of downloading it again. It needs its own directory and its own
`max_size_bytes`.

<!-- tabs-open -->

### Plug

Add `input_cache` to the instance's options:

```elixir
cache: [root: "/var/cache/image_pipe/processed", max_size_bytes: 5_000_000_000],
input_cache: [root: "/var/cache/image_pipe/originals", max_size_bytes: 20_000_000_000]
```

### image_pipe_server

```toml
[cache.input]
root = "/var/cache/image_pipe/originals"
max_size_bytes = 20_000_000_000
```

<!-- tabs-close -->

Local files are read where they are. To keep copies of them in the originals
cache, for example on a network filesystem, set the file source's `copy`
option to `keep` (see
[copy files from network storage](serving-local-files.md#copy-files-from-network-storage)).

## Run several replicas

Give each replica its own cache directories, such as its own volume. A
replica that finds another replica using its `root` logs an error and runs
without that cache until the other replica stops (see
[cache root owner file](cache.md#cache-root-owner-file)).

## Fill the cache ahead of time

To have an image ready before its first visitor asks for it, request it with
`HEAD`. ImagePipe processes and stores the image for a `HEAD` request just as
for a `GET`. Unless the URL sets `format`, the cache keeps a separate copy for
each output format that the `Accept` header selects, so send one request for
each kind of `Accept` header your visitors send, such as one that accepts AVIF
and one that accepts only WebP:

<!-- tabs-open -->

### Plug

```console
$ curl -s -I -H 'Accept: image/avif,image/webp,*/*' http://localhost:4000/images/w=400/src/photos/beach.jpg
```

To fill the cache from a job instead, call `ImagePipe.run/4` with the
instance's name, a `{:source, path}` input, and `accept:` in place of the
header (see [Processing in a job](combined-usage.md#processing-in-a-job)).

### image_pipe_server

```console
$ curl -s -I -H 'Accept: image/avif,image/webp,*/*' http://localhost:8080/w=400/src/photos/beach.jpg
```

If `[server]` sets `auth_token`, add `-H "Authorization: Bearer <token>"`.

<!-- tabs-close -->

If `storage_inputs` keeps separate copies per request header or cookie, send
those values too (see [cache key inputs](cache.md#cache-key-inputs)).

## Confirm caching works

Allow debug headers for now:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug, instance: MyApp.Images, allow_debug_headers: true
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
  [Cache storage](cache.md) what is stored and how the size limit works.
- The
  [server configuration reference](../../image_pipe_server/docs/server-configuration.md#cache)
  lists every `[cache]` key.
