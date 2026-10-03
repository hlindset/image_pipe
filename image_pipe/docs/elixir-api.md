# Elixir API

ImagePipe has two entry points in an Elixir application. `ImagePipe.Plug`
serves images over HTTP from your Phoenix or Plug app. `ImagePipe.run/4` and
`ImagePipe.write/5` process images directly in your code, such as uploads in
a background job, and return the result or write it to a file. Both use
plans, written with `ImagePipe.URL` or as URLs, and take their sources,
caches, and limits from one configuration, so an application can use both.

## Elixir guides

- [Installation](installation.md): the Hex dependency and supported image
  formats.
- [Processing images in Elixir](processing-in-elixir.md): a first plan, run
  on a local file from `iex`.
- [Plug usage](plug-usage.md): mount `ImagePipe.Plug` in a router.
- [Combined Plug and Elixir usage](combined-usage.md): share one
  configuration between a mount and direct calls.
- [Caching processed images](caching-processed-images.md): store processed
  images on disk, with a size limit.
- [Fetching images from the server](fetching-from-the-server.md): use
  results from an ImagePipe server running elsewhere.

## Elixir API reference

- `ImagePipe`: configuration, supervised instances, `run/4`, and `write/5`.
- `ImagePipe.Result`: the fields of a successful result.
- `ImagePipe.URL`: building plans, signing, and source encryption.
- `ImagePipe.Plug`: mount options.
- [Configuration](configuration.md): where settings belong, defaults, and
  limits.
- [Image sources](sources.md): local files, HTTP(S), and S3.
- [Signing URLs and rotating keys](signing-urls.md): signing keys and expiry.
- [Defining presets](defining-presets.md): named sets of options and request defaults.
- [Requesting images](requesting-images.md) and the
  [processing options](processing.md): what each option does, with the
  builder spelling of each.
