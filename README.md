# ImagePipe

ImagePipe serves and processes images inside Elixir applications, through a
Plug endpoint, an Elixir API, or both.

This repository holds sibling Mix projects:

| Directory | Contents |
| --- | --- |
| [`image_pipe/`](image_pipe/README.md) | The library and Plug: code, tests, benchmarks, and [documentation](image_pipe/docs/index.md) |
| [`fiddle/`](image_pipe/docs/fiddle.md) | A Phoenix demo app for trying options visually |

Run `mix` commands from inside a project directory. From the repository root,
`mise run setup` installs dependencies for both projects, and
`mise run precommit` / `mise run precommit:fiddle` run the checks.

Licensed under the [Apache License 2.0](LICENSE.md).
