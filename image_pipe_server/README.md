# image_pipe_server

ImagePipe as a standalone image server, configured with a TOML file and
environment variables instead of Elixir code. Apps that only build URLs, with
`image_pipe_url`, can point at it instead of embedding `image_pipe`.

Follow [URL builder with an external server](../image_pipe/docs/external-server.md)
for a complete application-and-server walkthrough.

```bash
docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
```

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro image_pipe_server
```

With a `config.toml` that serves files from `/data/images`:

```toml
[sources.static]
adapter = "file"
match = "path"
root = "/data/images"
root_id = "static"
```

`http://localhost:8080/w=400/format=webp/src/photo.jpg` then serves a resized
`/data/images/photo.jpg`, and `GET /health` reports readiness.

- [Configuration](docs/configuration.md): the file, environment variables,
  and a reference of every setting.
- [Deployment](docs/deployment.md): images, Docker and Kubernetes, health
  checks, shutdown, caches, and capacity.
- [Changelog](CHANGELOG.md): server release notes.

The server loads no host Elixir code. Custom source adapters, caches,
detectors, and function-valued options need a release built on `image_pipe`.

## Development

Run `mix` from this directory. `mise run precommit:server` runs the library
gate plus the server's checks, and `mise run server:image` builds the Docker
image and runs the container smoke test.
