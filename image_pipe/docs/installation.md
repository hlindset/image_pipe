# Installation

ImagePipe requires Elixir 1.18 or newer. Add it to your application's
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:image_pipe, "~> 0.1.0"}
  ]
end
```

Run `mix deps.get` in your application.
ImagePipe uses Image and Vix for libvips processing. Available input and output
codecs depend on the native build; see [output formats](processing/output.md#formats).

## Native format support

Supported inputs are JPEG (including UltraHDR), PNG, WebP, TIFF, HEIF/AVIF,
JPEG XL, JPEG 2000, and GIF. Each needs its loader in the deployed libvips build;
a missing loader fails the request with `415`.

ImagePipe checks image signatures and accepts only matching loaders. Other
formats, including SVG, BMP, camera RAW, and AVIF image sequences, are rejected
with `415`, even if the installed libvips has a loader for them.

## Choose an entry point

| Entry point | Setup | Result |
| --- | --- | --- |
| [Plug](plug-usage.md) | Mount `ImagePipe.Plug` and configure source adapters | HTTP image, placeholder, or JSON response |
| [Builder + external server](external-server.md) | Use `image_pipe_url` in the application and run `image_pipe_server` separately | Signed URLs served by the image server |
| [Elixir](elixir-api.md) | Build a plan with `ImagePipe.URL.new/0` | Buffered `ImagePipe.Result` or a written file |
| [Combined](combined-usage.md) | Share `ImagePipe.URL.config/1` and `ImagePipe.config/1` between both | Matching processing, URL generation, and shared caches |

An application that only generates URLs for a separate image service can depend
on the URL builder alone. It needs no libvips or NIFs:

```elixir
{:image_pipe_url, "~> 0.1.0"}
```

It provides `ImagePipe.URL` with the same URL grammar, presets, signing, and
source encryption; see [URL builder with an external server](external-server.md).

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
