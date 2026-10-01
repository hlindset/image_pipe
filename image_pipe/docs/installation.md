# Installation

ImagePipe requires Elixir 1.18 or newer. It is unreleased and has no Hex package
yet; depend on a local checkout for evaluation. The repository holds the library
in its `image_pipe/` directory:

```elixir
def deps do
  [
    {:image_pipe, path: "../image_pipe/image_pipe"}
  ]
end
```

Adjust the path to your checkout, then run `mix deps.get` in your application.
ImagePipe uses Image and Vix for libvips processing. Available input and output
codecs depend on the native build; see [output formats](processing/output.md#formats).

## Choose an entry point

| Entry point | Setup | Result |
| --- | --- | --- |
| [Plug](plug-usage.md) | Mount `ImagePipe.Plug` and configure source adapters | HTTP image, placeholder, or JSON response |
| [Elixir](elixir-api.md) | Build a plan with `ImagePipe.URL.new/0` | Buffered `ImagePipe.Result` or a written file |
| [Combined](combined-usage.md) | Share `ImagePipe.URL.config/1` and `ImagePipe.config/1` between both | Matching processing, URL generation, and shared caches |

An application that only generates URLs for a separate image service can depend
on the URL builder alone. It needs no libvips or NIFs:

```elixir
{:image_pipe_url, path: "../image_pipe/image_pipe_url"}
```

It provides `ImagePipe.URL` with the same URL grammar, presets, signing, and
source encryption; see [split deployments](elixir-api.md#split-deployments).

Your application supplies the HTTP server when using Plug. An existing Phoenix
endpoint is sufficient. Direct Elixir calls need no web server.

## Work on this repository

The repository pins its tools in `mise.toml`. Install them and the project
dependencies with:

```sh
mise install
mise run setup
```

Use `mise exec --` for repository commands, run from the project directory, for
example `cd image_pipe && mise exec -- iex -S mix`.
See [Run the Fiddle](fiddle.md) for the interactive demo and sidecars.
