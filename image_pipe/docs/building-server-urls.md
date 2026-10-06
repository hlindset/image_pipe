# Building URLs for the server

In this guide we'll configure `image_pipe_server` to serve only signed URLs,
then create an Elixir app that builds signed URLs for it with
`image_pipe_url`.

Work through
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)
first. You also need Elixir 1.18 or newer.

## Adding a signing key

The server and the app share a secret signing key. In the `image-server`
directory from the server guide, generate one into an environment variable.
Keep this terminal open, since the app needs the same key later:

```bash
export IMAGE_PIPE_SIGNING_KEY="$(openssl rand -hex 32)"
```

Start the server as before, now with the key in `IPS_URL__KEYS`:

```bash
docker run -d --name image-server -p 8080:8080 \
  -e IPS_URL__KEYS="$IMAGE_PIPE_SIGNING_KEY" \
  -v "$PWD/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$PWD/images:/data/images:ro" \
  ghcr.io/hlindset/image_pipe_server:0.1
```

With a signing key set, the server refuses URLs without a valid signature.
<http://localhost:8080/w=400/src/photo.jpg>, which worked before, now
answers `403` with the body `invalid signature`.

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

Let's build a signed URL for a 400×300 crop of the photo:

```elixir
iex> thumbnail =
...>   ImagePipe.URL.new(url_config)
...>   |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
iex> ImagePipe.URL.url!(thumbnail, "photo.jpg")
"http://localhost:8080/sig=4awb0-qKf4y4nPx6pMtsC7tzfn2MAY3gYzpUJ1ZeUGQ/w=400/h=300/fit=cover/src/photo.jpg"
```

The `sig=` value is computed from your key, so yours is different. Open
your URL in a browser:

```text
GET /sig=.../w=400/h=300/fit=cover/src/photo.jpg (in Chrome)
200 OK, content-type: image/avif, 400×300
```

Notice that the `sig=` segment signs everything after it, and the server
checks it with the same key before serving the image.

## Changing the options

Edit the URL in the browser and change `w=400` to `w=800`. The server
answers `403` with the body `invalid signature`, because the signature no
longer matches the options. Every change needs a URL built with the key:

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
