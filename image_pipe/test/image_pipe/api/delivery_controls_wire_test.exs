defmodule ImagePipe.API.DeliveryControlsWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe

  @image File.read!("priv/static/images/beach.jpg")

  test "image delivery uses the current filename and disposition across a warm cache" do
    config = mount()

    attached = request(:get, "w=64/format=jpeg/filename=first/attachment", config)
    assert attached.status == 200
    assert get_resp_header(attached, "content-disposition") == [attachment("first.jpg")]
    assert [etag] = get_resp_header(attached, "etag")
    assert_receive :origin_fetch
    assert [first_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert_receive {:cache_put, stored_key, _body}
    assert stored_key.hash == first_key.hash

    inline = request(:get, "w=64/format=jpeg/filename=second", config)
    assert inline.status == 200
    assert inline.resp_body == attached.resp_body
    assert get_resp_header(inline, "content-disposition") == [inline("second.jpg")]
    assert get_resp_header(inline, "etag") == [etag]
    assert [second_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert second_key.hash == first_key.hash
    refute_receive :origin_fetch
    refute_receive {:cache_put, _key, _body}

    unnamed = request(:get, "w=64/format=jpeg", config)
    assert get_resp_header(unnamed, "content-disposition") == ["inline"]
    refute hd(get_resp_header(unnamed, "content-disposition")) =~ "beach"
  end

  test "complete-body terminals use current delivery controls on cache hits" do
    for {terminal, content_type, extension} <- [
          {"output=blurhash", "text/plain; charset=utf-8", "txt"},
          {"output=info", "application/json; charset=utf-8", "json"}
        ] do
      config = mount()

      attached = request(:get, "#{terminal}/filename=first/attachment", config)
      assert attached.status == 200, terminal
      assert get_resp_header(attached, "content-type") == [content_type]

      assert get_resp_header(attached, "content-disposition") == [
               attachment("first.#{extension}")
             ]

      assert [etag] = get_resp_header(attached, "etag")
      assert_receive :origin_fetch
      assert [first_key] = Enum.uniq(CacheProbe.lookup_keys())
      assert_receive {:cache_put, stored_key, _body}
      assert stored_key.hash == first_key.hash

      inline = request(:get, "#{terminal}/filename=second", config)
      assert inline.status == 200, terminal
      assert inline.resp_body == attached.resp_body
      assert get_resp_header(inline, "content-type") == [content_type]
      assert get_resp_header(inline, "content-disposition") == [inline("second.#{extension}")]
      assert get_resp_header(inline, "etag") == [etag]
      assert [second_key] = Enum.uniq(CacheProbe.lookup_keys())
      assert second_key.hash == first_key.hash
      refute_receive :origin_fetch
      refute_receive {:cache_put, _key, _body}
    end
  end

  test "cachebuster partitions storage without changing bytes or ETag" do
    config = mount()

    first = request(:get, "w=64/format=jpeg/cb=deploy-a", config)
    assert first.status == 200
    assert [etag] = get_resp_header(first, "etag")
    assert_receive :origin_fetch
    assert [first_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert_receive {:cache_put, _, _body}

    second = request(:get, "w=64/format=jpeg/cb=deploy-b", config)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "etag") == [etag]
    assert_receive :origin_fetch
    assert [second_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert_receive {:cache_put, _, _body}
    refute second_key.hash == first_key.hash
  end

  test "HEAD matches a warm GET and conditional responses omit content disposition" do
    config = mount()
    options = "w=64/format=jpeg/filename=download/attachment"

    assert request(:get, options, config).status == 200
    assert_receive :origin_fetch
    assert [key] = Enum.uniq(CacheProbe.lookup_keys())
    assert_receive {:cache_put, _, _body}

    get = request(:get, options, config)
    assert get.status == 200
    assert [get_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert get_key.hash == key.hash

    head = request(:head, options, config)
    assert head.status == 200
    assert head.resp_body == ""
    assert [head_key] = Enum.uniq(CacheProbe.lookup_keys())
    assert head_key.hash == key.hash

    for header <- [
          "cache-control",
          "content-disposition",
          "content-length",
          "content-type",
          "etag"
        ] do
      assert get_resp_header(head, header) == get_resp_header(get, header), header
    end

    [etag] = get_resp_header(get, "etag")
    conditional = request(:head, options, config, [{"if-none-match", etag}])
    assert conditional.status == 304
    assert get_resp_header(conditional, "content-disposition") == []
    refute_receive {:cache_lookup, _key}
    refute_receive :origin_fetch
  end

  defp request(method, options, config, headers \\ []) do
    conn = conn(method, "/#{options}/src/images/beach.jpg")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    ImagePipe.Plug.call(conn, config)
  end

  defp mount do
    test_pid = self()
    store = :ets.new(:api_delivery_controls_cache, [:set, :public])

    origin = fn conn ->
      send(test_pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, @image)
    end

    ImagePipe.Plug.init(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      cache: {CacheProbe, store: store},
      http_cache: [mode: :enabled],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    )
  end

  defp attachment(filename), do: ~s(attachment; filename="#{filename}")
  defp inline(filename), do: ~s(inline; filename="#{filename}")
end
