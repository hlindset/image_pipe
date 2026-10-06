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

> #### ImagePipe needs `req` 0.8.0-rc.0 {: .warning}
>
> ImagePipe depends on `req` `~> 0.8.0-rc.0`. If your app locks an older
> version, as a new Phoenix app does, `mix deps.get` stops with a version
> conflict over `req`. Unlock it and fetch again:
>
> ```bash
> mix deps.unlock req
> mix deps.get
> ```

ImagePipe uses Image and Vix for libvips processing. Available input and output
codecs depend on the native build. See [output formats](processing/output.md#formats).

Serving images with `ImagePipe.Plug` uses your application's HTTP server, such
as an existing Phoenix endpoint. Processing images in Elixir code needs no web
server. The [documentation overview](index.md) lists the guide to start with
for each use.

## Native format support

Supported inputs are JPEG (including UltraHDR), PNG, WebP, TIFF, HEIF/AVIF,
JPEG XL, JPEG 2000, and GIF. Each needs its loader in the deployed libvips build.
A missing loader fails the request with `415`.

ImagePipe checks image signatures and accepts only matching loaders. Other
formats, including SVG, BMP, camera RAW, and AVIF image sequences, are rejected
with `415`, even if the installed libvips has a loader for them.

## Installing only the URL builder

An application that only generates URLs for a separate image service can depend
on the pure Elixir URL builder alone:

```elixir
{:image_pipe_url, "~> 0.1.0"}
```

It provides `ImagePipe.URL` with the same URL grammar, preset references,
signing, and source encryption. See [Building URLs for the server](building-server-urls.md).
