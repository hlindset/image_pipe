defmodule ImagePipe.Source.CacheSettingsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.CacheSettings

  @schema NimbleOptions.new!(CacheSettings.schema())

  defp settings(opts \\ []), do: NimbleOptions.validate!(opts, @schema)

  test "defaults to mutable, inherited, and no policy" do
    opts = settings()

    refute CacheSettings.trusted?(opts)

    assert CacheSettings.fields(opts, stable?: false, seed: [id: 1], auto: :enabled) == [
             internal_cache: :enabled,
             http_cache: :inherit,
             cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false, policy: []}
           ]
  end

  test "a stable source gets a strong byte identity from its seed" do
    opts = settings(stable: :trusted, cache_policy: [storage: :allow])

    assert CacheSettings.trusted?(opts)

    fields = CacheSettings.fields(opts, stable?: true, seed: [id: 1], auto: :when_stable)

    assert fields[:cache_semantics] == %CacheSemantics{
             byte_identity: {:strong, [id: 1]},
             stable?: true,
             policy: [storage: :allow]
           }
  end

  test "internal_cache :auto follows the adapter's rule; explicit modes win" do
    auto = settings()

    for {stable?, rule, expected} <- [
          {false, :enabled, :enabled},
          {true, :enabled, :enabled},
          {false, :when_stable, :disabled},
          {true, :when_stable, :enabled}
        ] do
      assert CacheSettings.fields(auto, stable?: stable?, seed: [], auto: rule)[:internal_cache] ==
               expected
    end

    for mode <- [:enabled, :disabled], rule <- [:enabled, :when_stable] do
      opts = settings(internal_cache: mode)

      assert CacheSettings.fields(opts, stable?: false, seed: [], auto: rule)[:internal_cache] ==
               mode
    end
  end
end
