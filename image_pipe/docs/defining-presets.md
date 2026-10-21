# Defining presets

Define named sets of URL options in the server's configuration, so URLs can
write `preset=card` instead of `w=400/h=300/fit=cover`. This assumes
ImagePipe running in your app or as `image_pipe_server`.
[Presets](presets.md) explains how presets combine with the options a URL
writes itself.

## Add presets

Map each name to a fragment of URL options, written as in a URL without the
source. A fragment can name other presets with `preset=`, and can hold
several groups separated by `-`:

<!-- tabs-open -->

### image_pipe_server

```toml
# config.toml
[processing.presets]
card = "w=400/h=300/fit=cover"
frame = "pad=20/bg=fff"
framed = "preset=card/-/preset=frame/format=webp"
```

See [`[processing]`](../../image_pipe_server/docs/server-configuration.md#processing).

### Plug

```elixir
# lib/my_app/application.ex
{ImagePipe,
 name: MyApp.Images,
 presets: %{
   "card" => "w=400/h=300/fit=cover",
   "frame" => "pad=20/bg=fff",
   "framed" => "preset=card/-/preset=frame/format=webp"
 },
 sources: [...]}
```

A preset can also be an `ImagePipe.URL` builder, which works exactly like
its URL spelling:

```elixir
"card" => ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
```

<!-- tabs-close -->

Names use letters, digits, `.`, `_`, and `-`. A fragment can't hold a source
or a signature. The configuration is checked at startup. Any of these stops
the server, or makes `ImagePipe.config/1` raise `ArgumentError`:

- An invalid name or option.
- A reference to an undefined preset.
- Presets that name each other in a cycle.
- Options in one group of a preset that can't be combined, such as `anchor`
  and `detect`.
- A [`wm`](processing/watermark.md#wm) name that isn't a configured
  watermark.
- [`wm-src64` or `wm-enc`](processing/watermark.md#wm-src64-and-wm-enc)
  while `request_watermarks` is off. See
  [`[processing]`](../../image_pipe_server/docs/server-configuration.md#processing)
  for the server, or `ImagePipe.config/1` for the Plug.
- A `wm-enc` token that the
  [source encryption keys](shared-url-settings.md#source-encryption-keys)
  can't decrypt, or a `wm-enc` token on a configuration without them.

The error names the problem, such as
`invalid ImagePipe configuration: unknown preset: crad`.

A preset may set options that do nothing on their own, such as `fit=cover`
without a size, since a URL can add what they need.

## Set request defaults

Request defaults apply one group of options to every request, under the
presets and options in the URL. Use them for settings every image shares,
such as a quality:

<!-- tabs-open -->

### image_pipe_server

```toml
[processing]
request_defaults = "q=80"
```

### Plug

```elixir
{ImagePipe, name: MyApp.Images, request_defaults: "q=80", presets: %{...}, sources: [...]}
```

<!-- tabs-close -->

Request defaults can't name presets. The checks in [Add presets](#add-presets)
apply to them too.

## Use a preset in a URL

<!-- tabs-open -->

### URL

```text
/images/preset=card/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(url_config)
|> ImagePipe.URL.group(presets: ["card"])
|> ImagePipe.URL.url!("photos/beach.jpg")
```

<!-- tabs-close -->

In an app that serves its own URLs, build `url_config` with
`ImagePipe.url_config(MyApp.Images)`. The builder then includes the presets
and request defaults, and `ImagePipe.URL.url/3` returns an error for a plan
the server would reject, such as an unknown preset name. A builder in
another application needs a copy of the presets for the same check,
described under [preset names](shared-url-settings.md#preset-names).

## Check the result

Request the preset with `output=info` to see the size it produces. This
example uses `image_pipe_server` on its default port and mount path. Add your
mount path, such as `/images`, for a Plug app:

```sh
curl http://localhost:8080/preset=card/output=info/src/photos/beach.jpg
```

```json
{"result":{"dpr":1.0,"height":300,"width":400},"source":{...}}
```

With signing keys configured, generate the URL with the builder instead of
writing it by hand. An unknown name answers `400`, and the body points at
the `preset=` option with `unknown preset: card`.

## Change or retire a preset

A changed definition applies once the server restarts with the new
configuration. Existing URLs stay valid and serve the new result.

To retire a preset, define it as an empty string rather than removing it.
Its URLs keep working, without the preset's options:

<!-- tabs-open -->

### image_pipe_server

```toml
[processing.presets]
old-card = ""
```

### Plug

```elixir
presets: %{"old-card" => "", ...}
```

<!-- tabs-close -->

Remove the name only once nothing requests its URLs anymore. A new preset
must reach the server before any application generates URLs with it.

## Next steps

- [Storing presets in a database](storing-presets-in-a-database.md): change
  presets without restarting, from an Elixir application.
- [Named presets](requesting-images.md#named-presets): how people requesting
  images use presets.
