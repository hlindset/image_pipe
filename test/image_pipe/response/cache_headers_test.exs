defmodule ImagePipe.Response.CacheHeadersTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Key
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders

  describe "from_representation/1" do
    test "keeps a strong ETag and supplied Vary name order" do
      representation = representation(etag: ~s("strong-etag"), vary: ["Save-Data", "Accept"])

      assert CacheHeaders.from_representation(representation) == %CacheHeaders{
               etag: ~s("strong-etag"),
               representation_headers: [{"vary", "Save-Data, Accept"}],
               headers: [{"etag", ~s("strong-etag")}]
             }
    end

    test "uses no-store without an ETag for an unstable representation" do
      representation = representation(etag: nil, no_store?: true)

      assert CacheHeaders.from_representation(representation) == %CacheHeaders{
               etag: nil,
               representation_headers: [],
               headers: [{"cache-control", "no-store"}]
             }
    end

    test "omits Vary when the representation has no Vary names" do
      representation = representation(vary: [])

      assert %CacheHeaders{representation_headers: []} =
               CacheHeaders.from_representation(representation)
    end
  end

  describe "host_cache_control?/1" do
    test "distinguishes host policy from Plug's default" do
      refute CacheHeaders.host_cache_control?([])
      refute CacheHeaders.host_cache_control?(["max-age=0, private, must-revalidate"])
      assert CacheHeaders.host_cache_control?(["public, max-age=3600"])
    end
  end

  defp representation(overrides) do
    defaults = %{
      cache_key: %Key{hash: "cache-key", data: []},
      etag: ~s("etag"),
      vary: [],
      no_store?: false
    }

    struct!(Representation, Map.merge(defaults, Map.new(overrides)))
  end
end
