# Serving images from local files

Serve originals from a directory that ImagePipe can read, such as a local
disk or a mounted network filesystem. This guide assumes ImagePipe is
running in your app (see [Plug usage](plug-usage.md)) or as
`image_pipe_server` (see
[getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Add a file source

Name the directory and give it a `root_id`, a short name that stays the
same if the directory moves:

<!-- tabs-open -->

### Plug

```elixir
sources: [
  media: [
    adapter: ImagePipe.Source.File,
    match: :path,
    options: [root: "/srv/images", root_id: "media"]
  ]
]
```

### image_pipe_server

```toml
[sources.media]
adapter = "file"
match = "path"
root = "/srv/images"
root_id = "media"
```

<!-- tabs-close -->

`match` set to `path` serves every image path that no other source matches.
To serve only paths under `media/`, match a prefix instead (see
[routing image paths to sources](sources.md#routing-image-paths-to-sources)).

## Mark write-once files

If files in the directory are never replaced in place, mark the source as
write-once. Cached images from it are then served without checking the
file:

<!-- tabs-open -->

### Plug

```elixir
options: [root: "/srv/images", root_id: "media", stable: :immutable]
```

### image_pipe_server

```toml
stable = "immutable"
```

<!-- tabs-close -->

A changed image then needs a new path, such as `cat-v2.jpg`. Leave `stable`
out if files can change. ImagePipe then checks each file's size,
timestamps, inode, and device, and hashes it again when they change. Where file timestamps
can't be trusted, set `verify` to `hash` to hash the file on every check
instead. How each choice affects caching is explained in
[local file sources](caching-and-freshness.md#local-file-sources).

## Copy files from network storage

On a network filesystem such as EFS or NFS, set `copy` to `keep`. Each
original is then copied into the
[originals cache](caching-processed-images.md#add-an-originals-cache) once,
so other sizes and formats don't read it over the network again:

<!-- tabs-open -->

### Plug

```elixir
input_cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/originals"},
sources: [
  media: [
    adapter: ImagePipe.Source.File,
    match: :path,
    options: [root: "/mnt/efs/images", root_id: "media", copy: :keep]
  ]
]
```

### image_pipe_server

```toml
[cache.input]
root = "/var/cache/image_pipe/originals"

[sources.media]
adapter = "file"
match = "path"
root = "/mnt/efs/images"
root_id = "media"
copy = "keep"
```

<!-- tabs-close -->

## Confirm it works

Request an image in the directory, such as `/srv/images/photos/beach.jpg`.
If your URLs are signed, sign this one too.

<!-- tabs-open -->

### Plug

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:4000/images/w=400/src/photos/beach.jpg
200 image/jpeg
```

### image_pipe_server

The server listens on port 8080 and serves from `/` unless `[server]` sets
another `port` or `mount_path`.

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:8080/w=400/src/photos/beach.jpg
200 image/jpeg
```

<!-- tabs-close -->

A path with no file behind it answers `404` with the body
`source not found`.

## Next steps

- [Caching processed images](caching-processed-images.md) stores resized
  copies so they aren't made again.
- `ImagePipe.Source.File` and the server's
  [`adapter = "file"` reference](../../image_pipe_server/docs/server-configuration.md#sources-name)
  list every option.
