# image_pipe_server

ImagePipe as a standalone image server, configured with a TOML file and
environment variables instead of Elixir code. Apps that only build URLs, with
`image_pipe_url`, can point at it instead of embedding `image_pipe`.

- [Deployment](docs/server-deployment.md): build the image and serve a first
  request, then Docker and Kubernetes, health checks, shutdown, caches, and
  capacity. Start here.
- [Configuration](docs/server-configuration.md): the file, environment variables,
  and a reference of every setting.
- [Changelog](CHANGELOG.md): server release notes.

Follow [URL builder with an external server](../image_pipe/docs/external-server.md)
for a complete application-and-server walkthrough.

The server loads no host Elixir code. Custom source adapters, caches,
detectors, and function-valued options need a release built on `image_pipe`.
