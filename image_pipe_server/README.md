# image_pipe_server

ImagePipe as a standalone image server, configured with a TOML file and
environment variables instead of Elixir code. Apps that only build URLs, with
`image_pipe_url`, can point at it instead of embedding `image_pipe`.

- [Getting started](docs/server-getting-started.md): run the server in Docker
  and resize and convert a first image. Start here.
- [Deployment](docs/server-deployment.md): run the server in production, with
  Docker and Kubernetes, health checks, shutdown, caches, and capacity.
- [Configuration](docs/server-configuration.md): the file, environment variables,
  and a reference of every setting.
- [Changelog](CHANGELOG.md): server release notes.

Follow [Building URLs for the server](../image_pipe/docs/building-server-urls.md)
for a complete application-and-server walkthrough.

The server loads no host Elixir code. Custom source adapters, detectors, and
function-valued options need a release built on `image_pipe`.
