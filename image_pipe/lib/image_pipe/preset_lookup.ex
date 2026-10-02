defmodule ImagePipe.PresetLookup do
  @moduledoc """
  Resolves presets that the static `:presets` map does not define.

  Configure an implementation with `ImagePipe.config/1`:

      ImagePipe.config(
        url: url_config,
        presets: %{"card" => "w=400/h=300/fit=cover"},
        preset_lookup: {MyApp.Presets, repo: MyApp.Repo},
        sources: [...]
      )

  Static presets shadow the lookup: a name the map defines is never fetched.
  Looked-up presets may reference static and looked-up names; static presets
  may reference only static names. `:request_defaults` never involves the
  lookup.

  The mount calls `c:fetch/2` while parsing a request, after signature
  verification and before any source or cache access, and `ImagePipe.run/4`
  calls it before reading the input. Each call receives the unresolved names
  for one nesting level, so most requests need one call. The URL builder never
  calls it.

  `c:fetch/2` runs on the request path. Cache results in the implementation
  (ETS, `:persistent_term`, Cachex) and bound backend timeouts in the client
  configuration. Changing a preset's definition changes the cache key and ETag
  of requests that use it.
  """

  @doc """
  Validates the lookup's options once, when the configuration is built.
  """
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  Returns the option fragment for each requested name the backend defines.

  Omit names the backend does not define; a request selecting one fails with
  `400`. Return `""` for a retired name to keep its URLs working without
  options. Fragments use the same grammar as static `:presets` strings. Return
  `{:error, reason}` when the backend is unavailable; the request then fails
  with `503`.
  """
  @callback fetch(names :: [String.t()], options :: keyword()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
end
