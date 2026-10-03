# URL builder with an external server

Use `image_pipe_url` in your Elixir application to generate signed image URLs.
Run `image_pipe_server` separately to fetch originals, process them, and serve
the results. The application needs no libvips or NIFs.

This walkthrough uses Docker and a local source image. See
[installation](installation.md) for Elixir requirements.

## Start the server

From the repository root, copy the sample image and generate a signing key:

```sh
mkdir -p images/photos
cp image_pipe/priv/static/images/beach.jpg images/photos/beach.jpg
export IMAGE_PIPE_SIGNING_KEY="$(openssl rand -hex 32)"
```

Create `config.toml` in the repository root:

```toml
[server]
mount_path = "/images"

[processing.presets]
card = "w=400/h=300/fit=cover"

[sources.static]
adapter = "file"
match = "path"
root = "/data/images"
root_id = "static"
```

Build and start the container from the same shell. `IPS_URL__KEYS` supplies the
server with the signing key the application will use:

```sh
docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
docker run --rm -d --name image-pipe-example \
  --read-only --tmpfs /tmp -p 127.0.0.1:8080:8080 \
  -e IPS_URL__KEYS="$IMAGE_PIPE_SIGNING_KEY" \
  --mount "type=bind,src=$PWD/config.toml,dst=/etc/image_pipe/config.toml,readonly" \
  --mount "type=bind,src=$PWD/images,dst=/data/images,readonly" \
  image_pipe_server
curl --fail --retry 30 --retry-connrefused --retry-delay 1 http://localhost:8080/health
```

The health response is `ok`. It stays at `/health`, while image requests use
the `/images` mount. The original is now available to the server as
`/data/images/photos/beach.jpg`.

## Configure the builder application

Add the URL package to your application's dependencies in `mix.exs`:

```elixir
def deps do
  [{:image_pipe_url, "~> 0.1.0"}]
end
```

Run `mix deps.get`, then `iex -S mix` in that application from the same shell,
so it inherits `IMAGE_PIPE_SIGNING_KEY`. Generate a URL:

```elixir
url_config =
  ImagePipe.URL.config(
    base_url: "http://localhost:8080/images",
    keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
  )

url =
  ImagePipe.URL.new(url_config)
  |> ImagePipe.URL.group(presets: ["card"])
  |> ImagePipe.URL.output(format: :webp)
  |> ImagePipe.URL.url!("photos/beach.jpg")
```

Open the returned URL in a browser. It serves a 400 × 300 WebP image. You can
use the same URL as an image's `src` in your application. Signing keys stay in
the application and the server; the browser receives the signed URL.

`base_url` belongs to the builder. It includes the address clients can reach
and the server's `mount_path`; for production, use your public HTTPS address
or CDN address, such as `https://images.example.com/images`.

## Share settings and originals

Keep signing keys synchronized between the application and server. A URL
carries a preset's name; the server applies its current definition, so the
application needs no preset definitions to build URLs. To have the builder
check plans against the server's presets, pass them as
[`mount_presets`](urls.md#validating-urls-before-serving) from the same shared
configuration source. If you enable
[source encryption](urls.md#conceal-the-source), share those keys too.

Deploy the server before a newer builder or a new preset. The server must
understand the URLs the builder emits. Stop generating a preset's URLs before
removing its server definition; existing URLs need it for as long as they are
in use.

The server must be able to read each original. In this example, `photos/beach.jpg`
is relative to the server's configured file root. In production, configure
[HTTP or S3 sources](sources.md) or mount shared storage into the container.
Files that exist only on the application's disk need to be placed in a source
the server can access. The server has no upload endpoint.

## Next steps

- [URLs and presets](urls.md): processing options, signing, expiry, and source concealment.
- [Fetching results from the service](elixir-api.md#fetching-results-from-the-service): consume responses in the application with an HTTP client.
- [Server configuration](../../image_pipe_server/docs/server-configuration.md): TOML settings, environment variables, and mounted secrets.
- [Server deployment](../../image_pipe_server/docs/server-deployment.md): TLS, caches, capacity, and health checks.

Stop the example container with `docker stop image-pipe-example`.
