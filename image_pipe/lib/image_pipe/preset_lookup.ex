defmodule ImagePipe.PresetLookup do
  @moduledoc """
  Resolves presets that the static `:presets` map does not define, while a
  request is served.

  Configure an implementation with `ImagePipe.config/1` or the
  `{ImagePipe, ...}` child spec:

      ImagePipe.config(
        presets: %{"card" => "w=400/h=300/fit=cover"},
        preset_lookup: {MyApp.Presets, repo: MyApp.Repo},
        sources: [...]
      )

  [Storing presets in a database](storing-presets-in-a-database.md) walks
  through an implementation, and [Presets](presets.md) explains how presets
  combine.

  ## When the lookup is called

  Static presets shadow the lookup: a name the map defines is never fetched,
  and a request that names only static presets never calls it. Looked-up
  presets may reference static and looked-up names. Static presets may
  reference only static names. `:request_defaults` never involves the
  lookup.

  `ImagePipe.Plug` calls `c:fetch/2` while parsing a request, after signature
  verification, and `ImagePipe.run/4` and `ImagePipe.validate/2` call it too,
  always before any source or cache access. Each call receives the unresolved
  names for one nesting level, so a request without nested looked-up
  references makes one call. `:max_preset_lookups` (default `32`) caps the
  distinct names one request may look up. The URL builder never calls the
  lookup.

  ## Results and statuses

  | Lookup result | Plug status | `ImagePipe.run/4` error |
  | --- | --- | --- |
  | A requested name is missing from the map | `400` | `{:invalid_request, issues}` |
  | `{:error, reason}`, a raise, an exit, a value other than `{:ok, map}`, or a non-string fragment | `503` | `{:preset, :lookup_unavailable}` |
  | A fragment that doesn't parse, references an unknown preset, or forms a cycle | `500` | `{:preset, :invalid_definition}` |
  | More than `:max_preset_lookups` distinct names | `500` | `{:preset, :invalid_definition}` |

  Names in the returned map that were not requested are ignored. Each call
  emits the `[:image_pipe, :preset, :lookup]` telemetry span.

  ## Caching

  ImagePipe does not cache lookup results. `c:fetch/2` runs on the request
  path, so cache results in the implementation (ETS, `:persistent_term`,
  Cachex) and bound backend timeouts in the client configuration. Changing a
  preset's definition changes the cache key and ETag of requests that use
  it.
  """

  @doc """
  Validates the lookup's options once, when the configuration is built.

  Return `{:ok, options}` with the options `c:fetch/2` receives.
  `{:error, reason}` makes `ImagePipe.config/1` raise `ArgumentError`.
  """
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  Returns the option fragment for each requested name the backend defines.

  Fragments use the same grammar as static `:presets` strings, such as
  `"w=400/h=300/fit=cover"`. Omit names the backend does not define, and a
  request selecting one fails with `400`. Return `""` for a retired name to
  keep its URLs working without options. Return `{:error, reason}` when the
  backend is unavailable, and the request fails with `503`.
  """
  @callback fetch(names :: [String.t()], options :: keyword()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
end
