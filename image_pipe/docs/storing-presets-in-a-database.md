# Storing presets in a database

Load preset definitions from a database or another service while ImagePipe
serves a request, so editors can add or change presets without a restart.
This assumes `ImagePipe.Plug` or `ImagePipe.run/4` in your Elixir
application. `image_pipe_server` reads presets only from its configuration
file. [Presets](presets.md#stored-presets) explains how stored presets
combine with the ones in the configuration.

## Implement the lookup

Write a module that implements `ImagePipe.PresetLookup`. `fetch/2` receives
the names a request needs and returns the definition of each name it has:

```elixir
# lib/my_app/presets.ex
defmodule MyApp.Presets do
  @behaviour ImagePipe.PresetLookup

  import Ecto.Query

  @impl true
  def validate_options(options) do
    case Keyword.fetch(options, :repo) do
      {:ok, _repo} -> {:ok, options}
      :error -> {:error, :missing_repo}
    end
  end

  @impl true
  def fetch(names, options) do
    repo = Keyword.fetch!(options, :repo)
    query = from p in "presets", where: p.name in ^names, select: {p.name, p.fragment}
    {:ok, Map.new(repo.all(query))}
  end
end
```

Each definition is a fragment of URL options, the same as a preset in the
configuration, such as `"w=400/h=300/fit=cover"`. Leave out names the
database doesn't have, and the request answers `400` with
`unknown preset`. When the database is unreachable, the request answers
`503`, whether `fetch/2` returns `{:error, reason}` or, as `repo.all/1` does
here, raises.

## Cache the definitions

ImagePipe calls `fetch/2` on every request that names a preset missing from
the configuration, and doesn't keep the results. Cache them in your module,
for example in ETS, `:persistent_term`, or Cachex, and set a short timeout on
the database or HTTP client it uses, since the request waits for the call.

## Configure the lookup

Pass the module and its options as `:preset_lookup`, next to any presets in
the configuration:

```elixir
# lib/my_app/application.ex
{ImagePipe,
 name: MyApp.Images,
 presets: %{"card" => "w=400/h=300/fit=cover"},
 preset_lookup: {MyApp.Presets, repo: MyApp.Repo},
 sources: [...]}
```

ImagePipe calls `validate_options/1` once, when it builds the configuration,
and raises `ArgumentError` when it returns `{:error, reason}`.

A name in `:presets` always wins, and requests that use only those names
never call the lookup. Stored presets may name presets from `:presets` or
other stored presets, and ImagePipe fetches the names they reference in
further calls. `:max_preset_lookups` (default `32`) caps how many distinct
names one request may look up. A request that needs more answers `500`.

## Build URLs for stored presets

The URL configuration from `ImagePipe.url_config/1` records that the
configuration has a lookup, so the builder accepts names missing from `:presets` and leaves them to the server.
`ImagePipe.validate/2` runs the lookup, for a full check before you hand out
a URL:

```elixir
config = ImagePipe.config!(MyApp.Images)
builder = ImagePipe.URL.new(ImagePipe.url_config(config)) |> ImagePipe.URL.group(presets: ["spring-sale"])

:ok = ImagePipe.validate(config, builder)
```

A builder in another application passes `preset_lookup: true` in its
[`:mount_presets`](shared-url-settings.md#preset-names).

## Retire a stored preset

Return `""` for a retired name instead of deleting its row. Its URLs keep
working, without the preset's options. A preset that added a watermark, a
crop that hides part of the image, or a size cap should usually stay
instead, since its URLs would quietly lose it.

## Check the lookup

Request a stored preset. Each request that calls the lookup emits the
`[:image_pipe, :preset, :lookup]` span, whose stop metadata counts the
definitions fetched and the calls to `fetch/2` (see
[telemetry events](telemetry-events.md)). The default Logger logs failed
lookups as warnings. `ImagePipe.PresetLookup` lists the status each
lookup result gives.
