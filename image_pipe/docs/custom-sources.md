# Writing a custom source

Serve originals from a store the built-in sources don't cover, such as a
database, an internal API, or blobs your app manages. This guide assumes
ImagePipe is running in your app (see [Getting started with Phoenix](phoenix-getting-started.md)).
`image_pipe_server` runs only the built-in sources.

## Implement the behaviour

A source adapter is a module that implements `ImagePipe.Source`. This one
serves blobs by ID from `MyApp.Blobs.get/2`, which stands in for your own
code and returns `{:ok, bytes}` or `:error`:

```elixir
# lib/my_app/blob_source.ex
defmodule MyApp.BlobSource do
  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Source.CacheSettings
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @schema NimbleOptions.new!([bucket: [type: :string, required: true]] ++ CacheSettings.schema())

  @impl true
  def identifiers(_options), do: [Path]

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} -> CacheSettings.validate(opts)
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @impl true
  def resolve(%Path{segments: [id]}, opts, _runtime_opts) do
    identity = [kind: :blob, bucket: Keyword.fetch!(opts, :bucket), id: id]

    cache =
      CacheSettings.fields(opts,
        stable?: CacheSettings.immutable?(opts),
        seed: identity,
        copy?: true
      )

    {:ok, struct!(Resolved, [identity: identity, fetch: id] ++ cache)}
  end

  def resolve(%Path{}, _opts, _runtime_opts), do: {:error, {:source, :not_found}}

  @impl true
  def fetch(%Resolved{fetch: id}, opts, _runtime_opts) do
    case MyApp.Blobs.get(Keyword.fetch!(opts, :bucket), id) do
      {:ok, bytes} -> {:ok, %Response{stream: [bytes]}}
      :error -> {:error, {:source, :not_found}}
    end
  end
end
```

`resolve/3` describes the original without reading it, and `fetch/3` reads
it when no cached copy can be used. Three things matter most, and the
[behaviour reference](`ImagePipe.Source`) lists the rest:

- `identity` must name everything that selects different bytes, here the
  bucket and the ID. Two originals with the same identity share cache
  entries. Keep secrets out of it. ImagePipe adds a hash of the source's
  options, apart from the cache settings, so two sources with different
  options never share entries. A function in the options is hashed by its
  module, its place in that module, and the values it captures, so a
  redeploy keeps the hash unless the function or the code around it changes.
  A pid or a reference, or a function that captures one, can hash differently
  after a restart or redeploy, and the source's cache entries are then not
  reused.
- `CacheSettings.fields/2` fills in the cache fields from the standard
  `stable`, `cache_policy`, `internal_cache`, and `http_cache` options, which
  `CacheSettings.schema/0` adds to your schema. `copy?: true` keeps a copy of
  each original in the [originals cache](cache.md#originals-cache). Pass
  `false` when reading the store again is cheap.
- Errors are `{:error, {:source, reason}}`. `:not_found` answers `404`.
  The [`ImagePipe.Source` errors](ImagePipe.Source.html#module-errors) list
  the other reasons and how to choose a status.

## Add the source

Add a source that uses the adapter, like a built-in one. A path adapter can
take a prefix, a custom scheme, or both:

```elixir
sources: [
  blobs: [
    adapter: MyApp.BlobSource,
    match: [prefix: "blobs", scheme: "blob"],
    options: [bucket: "images", stable: :immutable]
  ]
]
```

Both `/w=400/src/blobs/42` and `/w=400/src/blob://42` then serve blob `42`.
Invalid options raise `ArgumentError` when the configuration is built.

If a blob never changes once stored, set `stable: :immutable` as above.
Cached images are then served without calling `fetch/3`. Otherwise each
original is identified by a hash of its bytes, and is fetched again
whenever it needs checking (see
[Caching and freshness](caching-and-freshness.md)).

## Confirm it works

Request a blob that exists, and one that doesn't:

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:4000/images/w=400/src/blobs/42
200 image/jpeg
$ curl -s -w '\n%{http_code}\n' http://localhost:4000/images/w=400/src/blobs/43
source not found
404
```

## Next steps

- [Routing image paths to sources](sources.md#routing-image-paths-to-sources) lists the match rules.
- `ImagePipe.Source.CacheSettings` describes the cache options your adapter
  accepts.
