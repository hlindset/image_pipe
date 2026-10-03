defmodule ImagePipe.Source.CacheSettingsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.CacheSettings

  @schema NimbleOptions.new!(CacheSettings.schema())

  defp settings(opts \\ []), do: NimbleOptions.validate!(opts, @schema)

  test "defaults to mutable, inherited, and no policy" do
    opts = settings()

    refute CacheSettings.immutable?(opts)

    assert CacheSettings.fields(opts, stable?: false, seed: [id: 1], copy?: true) == [
             internal_cache: :enabled,
             http_cache: :inherit,
             cache_semantics: %CacheSemantics{
               byte_identity: :content,
               stable?: false,
               policy: [],
               copy?: true
             }
           ]
  end

  test "a stable source gets a strong byte identity from its seed" do
    opts = settings(stable: :immutable, cache_policy: [storage: :allow])

    assert CacheSettings.immutable?(opts)

    fields = CacheSettings.fields(opts, stable?: true, seed: [id: 1], copy?: false)

    assert fields[:cache_semantics] == %CacheSemantics{
             byte_identity: {:strong, [id: 1]},
             stable?: true,
             policy: [storage: :allow]
           }
  end

  test "internal_cache :auto enables internal caching; explicit modes win" do
    for stable? <- [false, true] do
      assert CacheSettings.fields(settings(), stable?: stable?, seed: [], copy?: false)[
               :internal_cache
             ] ==
               :enabled
    end

    for mode <- [:enabled, :disabled] do
      opts = settings(internal_cache: mode)

      assert CacheSettings.fields(opts, stable?: false, seed: [], copy?: false)[:internal_cache] ==
               mode
    end
  end
end
