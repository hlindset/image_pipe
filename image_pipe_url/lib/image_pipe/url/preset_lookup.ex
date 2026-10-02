defmodule ImagePipe.URL.PresetLookup do
  @moduledoc """
  Resolves presets that the static `:presets` map does not define.

  Configure an implementation with `ImagePipe.URL.config/1`:

      ImagePipe.URL.config(
        presets: %{"default" => "q=80"},
        preset_lookup: {MyApp.Presets, repo: MyApp.Repo}
      )

  Static presets shadow the lookup: a name the map defines is never fetched.
  Looked-up presets may reference static and looked-up names; static presets
  may reference only static names.

  The mount calls `c:fetch/2` while parsing a request, after signature
  verification and before any source or cache access. Each call receives the
  unresolved names for one nesting level, so most requests need one call. The
  URL builder never calls it.

  `c:fetch/2` runs on the request path. Hosts cache results themselves (ETS,
  `:persistent_term`, Cachex) and bound backend timeouts in their own client
  configuration. Changing a preset's definition changes the cache key and ETag
  of requests that use it.
  """

  @doc """
  Validates the lookup's options once, when the URL configuration is built.
  """
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  Returns the option fragment for each requested name the backend defines.

  Omit names the backend does not define. Fragments use the same grammar as
  the static `:presets` map values. Return `{:error, reason}` when the backend
  is unavailable; the request then fails with `503`.
  """
  @callback fetch(names :: [String.t()], options :: keyword()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
end
