# Development

The repository pins its tools in `mise.toml`. In a fresh checkout, trust that
file, then install the tools and every project's dependencies from the
repository root:

```sh
mise trust
mise install
mise run setup
```

Run `mix` from inside a project directory, through `mise exec --`, for
example `cd image_pipe && mise exec -- iex -S mix`.

## Checks

- `mise run precommit` runs the format, compile, Credo, Dialyzer, and test
  checks for `image_pipe_url` and `image_pipe`, plus a duplication check and
  a check that both projects share a version.
- `mise run precommit:server` adds the `image_pipe_server` checks.
- `mise run server:image` builds the server's Docker image and runs the
  container smoke test.
- `mise run precommit:fiddle` adds the Fiddle's Elixir and JavaScript checks.

## Demo app

[Running the Fiddle](fiddle.md) covers the interactive demo, tracing to a
local Jaeger, and the S3 sidecar.
