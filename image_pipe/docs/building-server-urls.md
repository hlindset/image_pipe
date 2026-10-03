# Building URLs for the server

In this guide we'll run `image_pipe_server` so that it serves only signed
URLs, then create an Elixir app that builds signed URLs for it with
`image_pipe_url`.

You need Docker, port 8080 free, Elixir 1.18 or newer, and a JPEG photo.
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)
covers the server's basics in more detail.

## Starting the server

Create a working directory with an `images` folder, and copy your photo into
it as `photo.jpg`:

```bash
mkdir -p image-server/images
cd image-server
cp /path/to/your/photo.jpg images/photo.jpg
```

The examples below use a 4000×2667 photo. With your photo, the widths match
and the heights follow its proportions.

The server and the app share a secret signing key. Generate one into an
environment variable, and keep this terminal open, since the app needs the
same key later:

```bash
export IMAGE_PIPE_SIGNING_KEY="$(openssl rand -hex 32)"
```

Create `config.toml` in the `image-server` directory:

```toml
# config.toml
[sources.photos]
adapter = "file"
match = "path"
root = "/data/images"
root_id = "photos"

[processing.presets]
card = "w=400/h=300/fit=cover"
```

The `photos` source reads originals from the folder we mount at
`/data/images`. `card` is a preset, a named set of options that URLs can
refer to as `preset=card`.

Start the server with the key in `IPS_URL__KEYS`:

```bash
docker run -d --name image-server -p 8080:8080 \
  -e IPS_URL__KEYS="$IMAGE_PIPE_SIGNING_KEY" \
  -v "$PWD/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$PWD/images:/data/images:ro" \
  ghcr.io/hlindset/image_pipe_server:0.1.0
```

Open <http://localhost:8080/health>. Within a second or two it shows `ok`.

With a signing key set, the server refuses URLs without a valid signature.
Open <http://localhost:8080/w=400/src/photo.jpg>:

```text
GET /w=400/src/photo.jpg
403 Forbidden, body: invalid signature
```

## Creating the app

In the same terminal, create an app next to `image-server`:

```bash
cd ..
mix new storefront
cd storefront
```

Add the URL builder to the dependencies in `mix.exs`:

```elixir
# mix.exs
defp deps do
  [
    {:image_pipe_url, "~> 0.1.0"}
  ]
end
```

Fetch it:

```bash
mix deps.get
```

`image_pipe_url` only builds URLs. It processes no images, so the app needs
no image libraries.

## Building a signed URL

Start `iex` from the same terminal, so it can read `IMAGE_PIPE_SIGNING_KEY`:

```bash
iex -S mix
```

The URL configuration holds the server's address and the signing key:

```elixir
iex> url_config =
...>   ImagePipe.URL.config(
...>     base_url: "http://localhost:8080",
...>     keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
...>   )
```

Let's build a URL that uses the `card` preset:

```elixir
iex> card = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(presets: ["card"])
iex> ImagePipe.URL.url!(card, "photo.jpg")
"http://localhost:8080/sig=1D5In_g8YgQxxxZDqgkAoZM2uKmZllppEO6bExfkft4/preset=card/src/photo.jpg"
```

Your signature differs, since your key does. Open the URL in a browser:

```text
GET /sig=.../preset=card/src/photo.jpg (in Chrome)
200 OK, content-type: image/avif, 400×300
```

Notice that:

- The `sig=` segment signs everything after it. The server checks it with
  the same key and serves the image.
- `preset=card` names the preset, and the server applies its definition,
  `w=400/h=300/fit=cover`. The app needs only the name.
- The app can put this URL in an `<img>` tag. The browser gets the URL, never
  the key.

## Changing the options

Edit the URL in the browser and add `w=800/` after `preset=card/`. The
server answers `403` with the body `invalid signature`, because the
signature no longer matches the options. Every change needs a URL built
with the key:

```elixir
iex> wide = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 800])
iex> ImagePipe.URL.url!(wide, "photo.jpg")
"http://localhost:8080/sig=2J7_YYeGtqkBDb7-9SBMWXHF3613bvJTgA91QG81oL4/w=800/src/photo.jpg"
```

Open it:

```text
GET /sig=.../w=800/src/photo.jpg
200 OK, content-type: image/avif, 800×533
```

`resize: [width: 800]` becomes `w=800` in the URL.

The builder signs any preset name, but only the server has the preset
definitions. A URL with `presets: ["cards"]` is signed correctly, and the server
answers `400`:

```text
invalid transformation options

/sig=*******************************************/preset=cards/src/photo.jpg
                                                 ^^^^^^^^^^^^
                                                 |
                                                 unknown preset: cards
```

When you're done, stop and remove the container:

```bash
docker rm -f image-server
```

## Next steps

We ran a server that accepts only signed URLs and built signed URLs for it
from an Elixir app. From here:

- [Shared URL settings](shared-url-settings.md): every setting the app and
  the server must agree on, such as keys, presets, and the base URL.
- [Signing URLs and rotating keys](signing-urls.md): URLs that expire, and
  replacing a key without breaking URLs in use.
- `ImagePipe.URL`: every builder function, and how builder options map to
  URL options.
- [Fetching images from the server](fetching-from-the-server.md): use
  processed images, placeholders, or image information inside the app.

The server reads originals only from its own sources. Files the app stores
need to be somewhere the server can read them, such as
[S3](serving-from-s3.md) or [an HTTP origin](serving-from-http.md).
[Deploying image_pipe_server](../../image_pipe_server/docs/server-deployment.md)
covers running the server in production.
