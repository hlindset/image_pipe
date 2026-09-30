defmodule ImagePipe.PresetsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.Plug.Request, as: ParsedRequest
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  test "shared defaults and nested presets execute identically through Plug and builder" do
    image = Image.new!(60, 40, color: [80, 120, 160])
    body = Image.write!(image, :memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    url_config =
      IP.URL.config(
        presets: %{
          "default" => "gray/format=png",
          "base" => "w=30",
          "poster" => "preset=base/brightness=10"
        },
        keys: [Base.encode16(:binary.copy(<<71>>, 32))]
      )

    config =
      IP.config(
        url: url_config,
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    for builder <- [
          IP.URL.new(url_config),
          IP.URL.new(url_config, presets: ["poster"]) |> IP.URL.group(gray: false)
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

    builder = IP.URL.new(url_config, presets: ["poster"]) |> IP.URL.group(gray: false)
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
    url = fn presets ->
      IP.URL.new(IP.URL.config(presets: presets), presets: ["poster"])
      |> IP.URL.url!("photos/a b.jpg")
    end

    assert url.(%{}) == "/preset=poster/src/photos%2Fa%20b.jpg"
    assert url.(%{"poster" => "w=30"}) == url.(%{"poster" => "w=40"})
  end

  test "unknown names and pipeline conflicts fail before execution side effects" do
    url_config = IP.URL.config(presets: %{"pipeline" => "w=30/-/gray"})
    config = IP.config(url: url_config, cache: {CacheProbe, []})

    for builder <- [
          IP.URL.new(url_config, presets: ["missing"]),
          IP.URL.new(url_config, presets: ["pipeline"]) |> IP.URL.group(blur: 1)
        ] do
      assert {:error, [_ | _]} = IP.URL.validate(builder)

      assert {:error, {:invalid_request, [_ | _]}} =
               IP.run(config, builder, {:file, "/missing.png"})

      refute_received :cache_lookup
    end
  end

  test "a pipeline preset accepts request overrides and supplies dependent option consumers" do
    url_config = IP.URL.config(presets: %{"pipeline" => "w=30/-/gray", "box" => "w=30/h=20"})

    assert :ok =
             IP.URL.validate(
               IP.URL.new(url_config, presets: ["pipeline"])
               |> IP.URL.output(format: :png)
             )

    builder = IP.URL.new(url_config, presets: ["box"]) |> IP.URL.group(resize: [fit: :cover])
    assert :ok = IP.URL.validate(builder)
    assert IP.URL.url!(builder, "photo.jpg") =~ "fit=cover"
  end

  test "preset names are validated at builder construction" do
    for names <- ["poster", ["bad/name"], [""], [:poster]] do
      assert_raise ArgumentError, fn -> IP.URL.new(presets: names) end
    end
  end

  test "URL generation rejects empty collection overrides that the URL grammar cannot express" do
    url_config =
      IP.URL.config(presets: %{"default" => "jpeg-options=progressive/format-q=jpeg:70"})

    for options <- [[jpeg_options: []], [format_qualities: []]] do
      builder = IP.URL.new(url_config) |> IP.URL.output(options)
      assert :ok = IP.URL.validate(builder)
      assert IP.URL.url(builder, "photo.jpg") == {:error, :unrepresentable_preset_override}

      assert IP.URL.url(IP.URL.new() |> IP.URL.output(options), "photo.jpg") ==
               {:ok, "/src/photo.jpg"}
    end
  end

  test "encrypted preset URLs preserve references and round trip sources" do
    url_config =
      IP.URL.config(
        presets: %{"poster" => "w=30"},
        keys: [Base.encode16(:binary.copy(<<71>>, 32))],
        source_encryption_keys: [:binary.copy(<<72>>, 32)],
        encrypt_source: true
      )

    config = IP.config(url: url_config)

    builder = IP.URL.new(url_config, presets: ["poster"])
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

    url_config = IP.URL.config(presets: %{"poster" => "w=30/-/pad=2/format=png"})

    config =
      IP.config(
        url: url_config,
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

    builder = IP.URL.new(url_config, presets: ["poster"])
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
      url_config = IP.URL.config(presets: %{"default" => "w=10", "a" => "w=20", "b" => "h=30"})
      config = IP.config(url: url_config)

      builder =
        IP.URL.new(url_config, presets: ["a", "b"])
        |> IP.URL.group(resize: [width: width, height: height])

      url = IP.URL.url!(builder, "photo.jpg")
      assert {:ok, request} = ImagePipe.Plan.to_spec(builder.plan, config.options[:presets])

      assert {{:ok, ^request, "photo.jpg"}, _} =
               ParsedRequest.parse(Plug.Test.conn(:get, url), IP.Plug.init(config))
    end
  end
end
