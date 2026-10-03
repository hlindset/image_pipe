defmodule ImagePipe.Response.CacheHeadersTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Response.CacheHeaders

  describe "host_cache_control?/1" do
    test "distinguishes host policy from Plug's default" do
      refute CacheHeaders.host_cache_control?([])
      refute CacheHeaders.host_cache_control?(["max-age=0, private, must-revalidate"])
      assert CacheHeaders.host_cache_control?(["public, max-age=3600"])
    end
  end
end
