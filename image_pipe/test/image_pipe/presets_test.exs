defmodule ImagePipe.PresetsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.Plug.Request, as: ParsedRequest
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  test "request defaults and nested presets execute identically through Plug and builder" do
    image = Image.new!(60, 40, color: [80, 120, 160])
    body = Image.write!(image, :memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    config =
      IP.config(
        url: IP.URL.config(keys: [Base.encode16(:binary.copy(<<71>>, 32))]),
        request_defaults: "gray/format=png",
        presets: %{"base" => "w=30", "poster" => "preset=base/brightness=10"},
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    url_config = IP.url_config(config)

    for builder <- [
          IP.URL.new(url_config),
          IP.URL.new(url_config) |> IP.URL.group(presets: ["poster"], gray: false)
        ] do
      assert :ok = IP.URL.validate(builder)
      url = IP.URL.url!(builder, "photo.jpg")
      refute_received :source_fetch
      assert {:ok, result} = IP.run(config, builder, {:binary, body})
      response = Plug.Test.conn(:get, url) |> IP.Plug.call(IP.Plug.init(config))
      assert response.status == 200
      assert response.resp_body == result.data
      assert_received :source_fetch
    end

    builder = IP.URL.new(url_config) |> IP.URL.group(presets: ["poster"], gray: false)
    url = IP.URL.url!(builder, "photo.jpg")
    assert url =~ "/preset=poster/"
    assert url =~ "/gray=false/"
    refute url =~ "/w=30/"
    assert {:ok, result} = IP.run(config, builder, {:binary, body})
    assert {result.width, result.height} == {30, 20}

    explicit =
      IP.URL.new()
      |> IP.URL.group(resize: [width: 30], brightness: 10)
      |> IP.URL.output(format: :png)

    assert {:ok, expected} = IP.run(IP.config(), explicit, {:binary, body})
    assert result.data == expected.data

    assert {:ok, default} = IP.run(config, IP.URL.new(url_config), {:binary, body})

    assert {:ok, plain} =
             IP.run(IP.config(), IP.URL.new() |> IP.URL.output(format: :png), {:binary, body})

    refute VipsImage.write_to_binary(Image.from_binary!(default.data)) ==
             VipsImage.write_to_binary(Image.from_binary!(plain.data))
  end

  test "URL references stay stable across preset definition changes and remote-only names" do
    remote = IP.URL.new() |> IP.URL.group(presets: ["poster"]) |> IP.URL.url!("photos/a b.jpg")
    assert remote == "/preset=poster/src/photos%2Fa%20b.jpg"

    for presets <- [%{"poster" => "w=30"}, %{"poster" => "w=40"}] do
      url_config = IP.url_config(IP.config(presets: presets))

      assert IP.URL.new(url_config)
             |> IP.URL.group(presets: ["poster"])
             |> IP.URL.url!("photos/a b.jpg") ==
               remote
    end
  end

  test "unknown names and pipeline conflicts fail before execution side effects" do
    config = IP.config(presets: %{"pipeline" => "w=30/-/gray"}, cache: {CacheProbe, []})
    url_config = IP.url_config(config)

    for builder <- [
          IP.URL.new(url_config) |> IP.URL.group(presets: ["missing"]),
          IP.URL.new(url_config) |> IP.URL.group(presets: ["pipeline"], blur: 1)
        ] do
      assert {:error, [_ | _]} = IP.URL.validate(builder)

      assert {:error, {:invalid_request, [_ | _]}} =
               IP.run(config, builder, {:file, "/missing.png"})

      refute_received :cache_lookup
    end
  end

  test "a pipeline preset accepts request overrides and supplies dependent option consumers" do
    url_config =
      IP.url_config(IP.config(presets: %{"pipeline" => "w=30/-/gray", "box" => "w=30/h=20"}))

    assert :ok =
             IP.URL.validate(
               IP.URL.new(url_config)
               |> IP.URL.group(presets: ["pipeline"])
               |> IP.URL.output(format: :png)
             )

    builder = IP.URL.new(url_config) |> IP.URL.group(presets: ["box"], resize: [fit: :cover])
    assert :ok = IP.URL.validate(builder)
    assert IP.URL.url!(builder, "photo.jpg") =~ "fit=cover"
  end

  test "preset names are validated at builder construction" do
    for names <- ["poster", ["bad/name"], [""], [:poster]] do
      assert_raise ArgumentError, fn -> IP.URL.new(presets: names) end
    end
  end

  test "URL generation clears request defaults with unset" do
    url_config =
      IP.url_config(IP.config(request_defaults: "jpeg-options=progressive/format-q=jpeg:70"))

    builder =
      IP.URL.new(url_config) |> IP.URL.output(jpeg_options: :unset, format_qualities: :unset)

    assert :ok = IP.URL.validate(builder)

    assert IP.URL.url(builder, "photo.jpg") ==
             {:ok, "/format-q=unset/jpeg-options=unset/src/photo.jpg"}
  end

  test "unset restores negotiation and drops a defaulted transform at the wire" do
    body = Image.new!(60, 40, color: [200, 40, 40]) |> Image.write!(:memory, suffix: ".png")

    origin = fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    sources = [
      path: [
        adapter: RootHTTPAdapter,
        match: :path,
        options: [root_url: "http://origin.test", req_options: [plug: origin]]
      ]
    ]

    get = fn config, path ->
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_req_header("accept", "image/webp")
      |> IP.Plug.call(IP.Plug.init(config))
    end

    defaulted = IP.config(request_defaults: "gray/format=png", sources: sources)
    plain = IP.config(sources: sources)

    response = get.(defaulted, "/w=30/gray=unset/format=unset/src/photo.png")
    expected = get.(plain, "/w=30/src/photo.png")

    assert response.status == 200
    assert Plug.Conn.get_resp_header(response, "content-type") == ["image/webp"]
    assert Plug.Conn.get_resp_header(response, "vary") == ["Accept"]
    assert response.resp_body == expected.resp_body
  end

  test "encrypted preset URLs preserve references and round trip sources" do
    url_config =
      IP.URL.config(
        keys: [Base.encode16(:binary.copy(<<71>>, 32))],
        source_encryption_keys: [String.duplicate("48", 32)],
        encrypt_source: true
      )

    config = IP.config(url: url_config, presets: %{"poster" => "w=30"})

    builder = IP.URL.new(IP.url_config(config)) |> IP.URL.group(presets: ["poster"])
    source = "https://origin.test/a b.jpg?token=secret"
    url = IP.URL.url!(builder, source)
    assert url =~ "/preset=poster/enc/"
    refute url =~ "secret"
    assert {:ok, request} = ImagePipe.Plan.to_spec(builder.plan, config.options[:presets])

    assert {{:ok, ^request, ^source}, _} =
             ParsedRequest.parse(Plug.Test.conn(:get, url), IP.Plug.init(config))
  end

  test "a builder pipeline preset warms the cache for equivalent Plug requests" do
    table = :ets.new(:shared_preset_cache, [:set, :public])

    config =
      IP.config(
        presets: %{"poster" => "w=30/-/pad=2/format=png"},
        cache: {ImagePipe.Test.PlugFixture.CacheProbe, store: table},
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              byte_identity: :strong,
              req_options: [
                plug: {ImagePipe.Test.PlugFixture.CountingOriginImage, test_pid: self()}
              ]
            ]
          ]
        ]
      )

    builder = IP.URL.new(IP.url_config(config)) |> IP.URL.group(presets: ["poster"])
    assert {:ok, native} = IP.run(config, builder, {:source, "photo.jpg"})
    assert_received :origin_fetch

    for url <- [IP.URL.url!(builder, "photo.jpg"), "/w=30/-/pad=2/format=png/src/photo.jpg"] do
      response = Plug.Test.conn(:get, url) |> IP.Plug.call(IP.Plug.init(config))
      assert response.status == 200
      assert response.resp_body == native.data
      refute_received :origin_fetch
    end
  end

  property "explicit dimensions override ordered presets in both request frontends" do
    check all width <- integer(1..100), height <- integer(1..100) do
      config = IP.config(request_defaults: "w=10", presets: %{"a" => "w=20", "b" => "h=30"})

      builder =
        IP.URL.new(IP.url_config(config))
        |> IP.URL.group(presets: ["a", "b"], resize: [width: width, height: height])

      url = IP.URL.url!(builder, "photo.jpg")

      assert {:ok, request} =
               ImagePipe.Plan.to_spec(
                 builder.plan,
                 config.options[:presets],
                 config.options[:request_defaults]
               )

      assert {{:ok, ^request, "photo.jpg"}, _} =
               ParsedRequest.parse(Plug.Test.conn(:get, url), IP.Plug.init(config))
    end
  end
end
