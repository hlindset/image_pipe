# Plug usage

Use `ImagePipe.Plug` to serve transformed images on demand. First
[install ImagePipe](installation.md), then mount it with at least one source
adapter. The following examples read `/srv/images/photos/beach.jpg`.

## Mount in Phoenix

In your Phoenix router, add a forward outside pipelines that require HTML,
authentication redirects, or CSRF tokens for image requests:

```elixir
forward "/images", ImagePipe.Plug,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ]
```

The source adapter resolves paths relative to its configured root.

## Mount in Plug.Router

`Plug.Router` uses a different `forward` syntax:

```elixir
defmodule MyApp.ImageRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/images",
    to: ImagePipe.Plug,
    init_opts: [
      sources: [
        media: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: "/srv/images", root_id: "media"]
        ]
      ]
    ]
end
```

Run that router with your application's Plug-compatible HTTP server.

## Mount an instance

Router options are evaluated when the router compiles. When the
configuration reads runtime values, such as keys from environment variables,
or uses a bounded cache, run it as an instance in your application's
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
       options: [root: System.fetch_env!("IMAGE_ROOT"), root_id: "media"]
     ]
   ]},
  MyAppWeb.Endpoint
]
```

Then mount the instance by name:

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug, instance: MyApp.Images
```

The mount accepts `url:` and mount options such as `http_cache` next to
`instance:`. Other options raise `ArgumentError`. `ImagePipe.child_spec/1`
lists the instance's options, and `ImagePipe.Plug` the mount options.

## Request an image

With the application listening on port 4000:

```text
http://localhost:4000/images/w=400/src/photos/beach.jpg
http://localhost:4000/images/w=400/h=300/fit=cover/format=webp/src/photos/beach.jpg
```

The first URL preserves aspect ratio within a 400-pixel width. The second fills
a 400×300 box with a crop and selects WebP. Enlargement is off by default, so
small sources can produce smaller results. Add `enlarge` when upscaling is wanted.

The mount prefix `/images` is routing; `src/photos/beach.jpg` identifies the
source. The source's `.jpg` extension does not select the output format.
Without `format`, ImagePipe negotiates from the request's `Accept` header and
its output policy. See [output formats](processing/output.md#formats).

```html
<img src="/images/w=400/h=300/fit=cover/src/photos/beach.jpg" alt="Beach" />
```

## Generate URLs in Elixir

Use the builder to escape sources and serialize options, especially when
signing URLs or using remote sources:

```elixir
url_config = ImagePipe.URL.config(base_url: "/images")

thumbnail =
  ImagePipe.URL.new(url_config)
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])

url = ImagePipe.URL.url!(thumbnail, "photos/beach.jpg")
```

[Combined usage](combined-usage.md) shows how to share the actual source,
signing, cache, and processing settings with the mount.

## Configure delivery

Add settings to the mount's or the instance's options, or supply a reusable
`config:` to an inline mount. Invalid configuration raises `ArgumentError`
when the router compiles, or for an instance when its child specification is
built. An instance mount raises on a request if its instance isn't running or
doesn't define its `url:`. Malformed requests fail before source fetch or
cache access.

- Configure [sources](sources.md) to enable HTTP(S), S3, or application identifiers.
- Configure [signing keys](signing-urls.md) to require authenticated URLs.
- Enable [HTTP cache policy](cdn-http-cache.md) and configure [storage caches](cache.md) independently.
- Use [configuration](configuration.md) for defaults, limits, CORS, and presets.
- Browse [processing options](processing.md) for all transforms and outputs.

GET and HEAD use the same representation headers; the HTTP adapter suppresses
the HEAD body. OPTIONS is supported. Direct Elixir execution returns data
without HTTP headers or conditional responses.
