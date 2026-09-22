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
    path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}
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
        path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}
      ]
    ]
end
```

Run that router with your application's Plug-compatible HTTP server.

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
config = ImagePipe.config(base_url: "/images")

thumbnail =
  ImagePipe.new(config)
  |> ImagePipe.group(resize: [width: 400, height: 300, fit: :cover])

url = ImagePipe.url!(thumbnail, "photos/beach.jpg")
```

[Combined usage](combined-usage.md) shows how to share the actual source,
signing, cache, and processing settings with the mount.

## Configure delivery

Add settings to the mount's options, or supply a reusable `config:`. Invalid
configuration raises at initialization. Malformed requests fail before source
fetch or cache access.

- Configure [sources](sources.md) to enable HTTP(S), S3, or application identifiers.
- Configure [signing keys](urls.md#signing-and-expiry) to require authenticated URLs.
- Enable [HTTP cache policy](cdn-http-cache.md) and configure [storage caches](cache.md) independently.
- Use [configuration](configuration.md) for defaults, limits, CORS, and presets.
- Browse [processing options](processing.md) for all transforms and outputs.

GET and HEAD use the same representation headers; the HTTP adapter suppresses
the HEAD body. OPTIONS is supported. Direct Elixir execution returns data
without HTTP headers or conditional responses.
