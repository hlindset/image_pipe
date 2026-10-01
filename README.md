# ImagePipe

ImagePipe serves and processes images inside Elixir applications, through a
Plug endpoint, an Elixir API, or both. It also runs as a standalone image
server, configured with a TOML file and environment variables.

This repository holds sibling Mix projects:

| Directory | Contents |
| --- | --- |
| [`image_pipe/`](image_pipe/README.md) | The library and Plug: code, tests, benchmarks, and [documentation](image_pipe/docs/index.md) |
| [`image_pipe_url/`](image_pipe_url/README.md) | The URL builder, grammar, and plan model, usable without the processing runtime |
| [`image_pipe_server/`](image_pipe_server/README.md) | The standalone server: a release and Docker image configured without Elixir code |
| [`fiddle/`](image_pipe/docs/fiddle.md) | A Phoenix demo app for trying options visually |

Run `mix` commands from inside a project directory. From the repository root,
`mise run setup` installs dependencies for every project, and
`mise run precommit` / `mise run precommit:server` / `mise run precommit:fiddle`
run the checks. `mise run server:image` builds the server's Docker image and
smoke-tests it.

[Contributor notes](docs/index.md) cover design plans and benchmarks.
[RELEASING.md](RELEASING.md) describes publishing the packages.

Licensed under the [Apache License 2.0](LICENSE.md).
