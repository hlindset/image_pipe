# Serving and processing in one app

When your app both serves images over HTTP and processes them in code, such
as in background jobs, run one ImagePipe instance for both. Requests and
jobs then share its sources, cache, and presets, and a job can prepare
images the next browser request gets from the cache.

This guide assumes ImagePipe is running in your app (see
[Getting started with Phoenix](phoenix-getting-started.md)).

## Starting one instance

Configure sources and a cache on the instance in
`lib/my_app/application.ex`, before the endpoint:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe,
   name: MyApp.Images,
   base_url: "/images",
   sources: [
     media: [
       adapter: ImagePipe.Source.File,
       match: :path,
       options: [root: "/srv/images", root_id: "media"]
     ]
   ],
   cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/processed"}},
  MyAppWeb.Endpoint
]
```

`base_url` is the path where the router mounts the instance, so URLs built
from this configuration point at it.

Mount it in the router:

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug, instance: MyApp.Images
```

## Building URLs for pages

`ImagePipe.url_config/2` returns the instance's URL settings. Build URLs
from them, so they carry the right base URL and signature:

```elixir
def thumbnail_url(path) do
  MyApp.Images
  |> ImagePipe.url_config()
  |> ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
  |> ImagePipe.URL.url!(path)
end
```

```heex
<img src={thumbnail_url(@photo.path)} alt={@photo.description} />
```

`thumbnail_url("photos/beach.jpg")` returns
`"/images/w=400/h=300/fit=cover/src/photos/beach.jpg"`. When the instance
sets `keys:`, the URL also carries a signature. A builder that uses
`presets:` is checked against the instance's presets when you build it.

## Processing in a job

Pass the instance's name to `ImagePipe.run/4`, and read the original
through the instance's sources with `{:source, path}`:

```elixir
builder =
  ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])

{:ok, result} =
  ImagePipe.run(MyApp.Images, builder, {:source, "photos/beach.jpg"},
    accept: "image/avif,image/webp"
  )
```

`run` stores the result in the instance's cache: new files appear under
the cache's `root`. A browser that requests
`/images/w=400/h=300/fit=cover/src/photos/beach.jpg` and accepts AVIF gets the
same bytes from the cache, without processing the image again. The reverse
works too: a job gets an image a browser already requested from the cache.

To share a cached image, the job and the request must produce the same
output:

- Without `format` in the builder, the format depends on `Accept`. Pass the
  browser's `Accept` value as `accept:`, or set `format` in the builder.
- If the instance's `storage_inputs` keeps separate copies per header or
  cookie, pass the matching values as `request_inputs:` (see
  `ImagePipe.run/4`).

Originals given as `{:file, path}` or `{:binary, bytes}` don't go through a
source, so their results aren't cached.

## Limiting the work

Jobs and requests share the CPU. A
[processing pool](processing-controls.md) on the instance limits how many
images are processed at once, across both. `run` returns the complete image
in memory, so allow memory for the full output of each job running at once.

## Next steps

- [Limiting concurrent processing](processing-controls.md): a processing pool
  for requests and jobs.
- `ImagePipe.run/4`: every input and option, and the errors it returns.
