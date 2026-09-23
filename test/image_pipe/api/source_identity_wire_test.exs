defmodule ImagePipe.API.SourceIdentityWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.IdentitySource
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage

  test "distinct map and list byte seeds do not reuse cached pixels or return false 304" do
    store = :ets.new(:identity_cache, [:set, :public])
    first_config = config(%{revision: 1}, :red, store)
    second_config = config([revision: 1], :blue, store)

    first = request(first_config)
    assert first.status == 200
    assert_receive :identity_source_fetch
    assert [first_key] = Enum.uniq(CacheProbe.lookup_keys())

    second = request(second_config)
    assert second.status == 200
    assert_receive :identity_source_fetch
    assert [second_key] = Enum.uniq(CacheProbe.lookup_keys())
    refute first_key.hash == second_key.hash
    refute pixels(first) == pixels(second)
    refute get_resp_header(first, "etag") == get_resp_header(second, "etag")

    [old_etag] = get_resp_header(first, "etag")
    conditional = request(second_config, old_etag)
    assert conditional.status == 200
    assert conditional.resp_body == second.resp_body
    refute_received :identity_source_fetch

    [current_etag] = get_resp_header(second, "etag")
    _ = CacheProbe.lookup_keys()
    assert request(second_config, current_etag).status == 304
    assert CacheProbe.lookup_keys() == []
    refute_received :identity_source_fetch
  end

  test "a structured byte seed supports conditional requests" do
    store = :ets.new(:identity_cache, [:set, :public])
    config = config(~D[2026-09-23], :red, store)
    first = request(config)
    assert first.status == 200
    assert_receive :identity_source_fetch
    [etag] = get_resp_header(first, "etag")
    assert request(config, etag).status == 304
    refute_received :identity_source_fetch
  end

  defp config(seed, color, store) do
    {:ok, image} = Image.new(8, 8, color: color)
    {:ok, bytes} = Image.write(image, :memory, suffix: ".png")

    ImagePipe.Plug.init(
      sources: [path: {IdentitySource, seed: seed, bytes: bytes, owner: self()}],
      cache: {CacheProbe, store: store}
    )
  end

  defp request(config, etag \\ nil) do
    conn = conn(:get, "/format=png/src/photo.png")
    conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
    ImagePipe.Plug.call(conn, config)
  end

  defp pixels(conn) do
    {:ok, image} = Image.from_binary(conn.resp_body)
    {:ok, pixels} = VipsImage.write_to_binary(image)
    pixels
  end
end
