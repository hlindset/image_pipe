# Elixir configuration

An ImagePipe configuration holds the settings that apply to every image you
serve or process: sources, caches, limits, output defaults, presets, and URL
settings such as signing keys. You build it with `ImagePipe.config/1`,
which lists every option with its default.

```elixir
config =
  ImagePipe.config(
    base_url: "/images",
    keys: [signing_key],
    sources: [
      media: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: "/srv/images", root_id: "media"]
      ]
    ],
    presets: %{"card" => "w=400/h=300/fit=cover"},
    max_input_pixels: 40_000_000,
    quality: 82
  )
```

A mount, an instance, or a call to `ImagePipe.run/4` takes this
configuration. Invalid options raise `ArgumentError` when you build it.

## Where settings belong

| Setting | Examples | Set with |
| --- | --- | --- |
| Configuration | Sources, caches, limits, output defaults, presets, and URL settings (signing keys, source encryption keys, base URL) | `ImagePipe.config/1` |
| A source | Root directory, allowed hosts, timeouts, S3 credentials | The source's `options:`, listed in its adapter's docs, such as `ImagePipe.Source.HTTP` |
| A mount | CORS, HTTP cache headers, debug headers | `ImagePipe.Plug` options on the `forward` |
| An instance | Its name, URL settings for mounts with different keys (`mounts:`), and which detection models load at startup (`detector_warmup:`) | `ImagePipe.child_spec/1` |
| A request | Size, crop, effects, format, quality | URL options, or `ImagePipe.URL.group/2` and `ImagePipe.URL.output/2` |
| A direct call | The `Accept` value, header and cookie values for cached copies | `accept:` and `request_inputs:` on `ImagePipe.run/4` |

A mount checks request URLs against the configuration's URL settings, or
those of the named set it picks with `mount:`. To
build URLs in the same app, get those settings with `ImagePipe.url_config/1`.
A separate app needs the same keys (see
[shared URL settings](shared-url-settings.md)).

## Which setting wins

When the same setting is given in more than one place:

- Options passed to an inline mount next to `config:` replace that
  configuration's options. A mount of an instance accepts only mount options
  and `mount:`, which picks one of the named sets of URL settings in the
  instance's `mounts:`.
- Each entry in an instance's `mounts:` applies its URL settings on top of
  the instance's. A setting the entry leaves out keeps the instance's value,
  so a mount that sets only `source_encryption_keys` still checks the
  instance's signing keys. For a mount that doesn't check signatures, set
  `keys: []`, and `source_encryption_keys: []` if the instance has them.
- Options passed to an instance next to `config:` replace that
  configuration's options.
- Options passed to `ImagePipe.run/4` or `ImagePipe.write/5` replace the
  configuration's options for that call.
- A request's own options win over the configuration's defaults. A URL with
  `q=90` uses quality 90 whatever `quality` says.
- Presets apply in a fixed order: `request_defaults` first, then the named
  presets in the order the URL lists them, then the request's own options.
  See [presets](presets.md).

## Encoder defaults

`:jpeg_options`, `:png_options`, `:webp_options`, and `:avif_options` set
encoder defaults. They take the same keyword lists as the options of the same
name in `ImagePipe.URL.output/2`:

```elixir
config =
  ImagePipe.config(
    jpeg_options: [interlace: true],
    webp_options: [effort: 5]
  )

builder =
  ImagePipe.URL.new()
  |> ImagePipe.URL.output(format: :jpeg, jpeg_options: [interlace: false])
```

A request's settings replace the configuration's field by field, so this
builder encodes a baseline JPEG and keeps any other JPEG defaults. The
fields are listed in [encoder options](processing/output.md#encoder-options)
under their URL names. Hyphens become underscores, and `progressive` and
`subsample` have different builder names, listed in
[URL option names](`ImagePipe.URL#module-url-option-names`).

## Limits and cached images

The limits, such as `max_input_pixels` and `max_result_width`, set the largest
images ImagePipe processes. They don't apply to images already in the
cache. After you lower a limit, cached images that exceed it are still
served from the cache.
