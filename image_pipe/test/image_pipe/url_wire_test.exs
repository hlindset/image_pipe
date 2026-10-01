defmodule ImagePipe.URLWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  @key Base.encode16(:binary.copy(<<71>>, 32))
  @encryption_key :binary.copy(<<72>>, 32)

  test "file sources with a leading slash work through builder and raw Plug paths" do
    root =
      Path.join(
        System.tmp_dir!(),
        "image-pipe-leading-slash-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    body = Image.new!(60, 40, color: [80, 120, 160]) |> Image.write!(:memory, suffix: ".png")
    File.write!(Path.join(root, "photo.png"), body)

    config =
      IP.config(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: root, root_id: "photos"]
          ]
        ]
      )

    builder = IP.URL.new() |> IP.URL.group(resize: [width: 30]) |> IP.URL.output(format: :png)
    assert {:ok, expected} = IP.run(config, builder, {:source, "photo.png"})
    assert {:ok, ^expected} = IP.run(config, builder, {:source, "/photo.png"})

    for url <- [IP.URL.url!(builder, "/photo.png"), "/w=30/format=png/src/%2Fphoto.png"] do
      response = conn(:get, url) |> IP.Plug.call(IP.Plug.init(config))
      assert response.status == 200
      assert response.resp_body == expected.data
    end

    for source <- ["//photo.png", "/../photo.png", "/nested//photo.png"] do
      assert {:error, {:source, :denied_path}} = IP.run(config, builder, {:source, source})
    end
  end

  setup do
    image = Image.new!(60, 40, color: [80, 120, 160])
    body = Image.write!(image, :memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end

    sources = [
      path: [
        adapter: RootHTTPAdapter,
        match: :path,
        options: [root_url: "http://origin.test", req_options: [plug: origin]]
      ]
    ]

    %{body: body, sources: sources}
  end

  test "raw signed paths execute under a mount and reject tampering before fetching", %{
    sources: sources
  } do
    url_config = IP.URL.config(keys: [@key])
    config = IP.config(url: url_config, sources: sources)
    mount = IP.Plug.init(config)
    signed = IP.URL.sign_path("/w=30/format=png/src/photo%2ejpg", url_config)
    refute_received :source_fetch
    refute_received :cache_lookup

    response =
      conn(:get, "/artwork" <> signed)
      |> Map.put(:script_name, ["artwork"])
      |> IP.Plug.call(mount)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
    output = Image.from_binary!(response.resp_body)
    assert {Image.width(output), Image.height(output)} == {30, 20}
    assert_received :source_fetch

    tampered = String.replace(signed, "%2e", ".")
    mount = IP.Plug.init(config: config, cache: {CacheProbe, []})
    assert conn(:get, tampered) |> IP.Plug.call(mount) |> Map.fetch!(:status) == 403
    refute_received :source_fetch
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "URLs built with ImagePipe.URL round trip through the Plug with signing, encryption, and presets",
       %{
         sources: sources
       } do
    url_config =
      IP.URL.config(
        base_url: "https://cdn.test/images",
        keys: [@key],
        source_encryption_keys: [@encryption_key],
        encrypt_source: true,
        iv_mode: :deterministic,
        presets: %{"thumb" => "w=30/format=png"}
      )

    config = IP.config(url: url_config, sources: sources, quality: 71)
    client = IP.URL.new(url_config, presets: ["thumb"])

    url = IP.URL.url!(client, "photo.jpg")
    assert url == IP.URL.url!(client, "photo.jpg")
    assert String.starts_with?(url, "https://cdn.test/images/sig=")
    assert url =~ "/preset=thumb/enc/"
    refute url =~ "photo.jpg"
    refute_received :source_fetch

    response =
      conn(:get, url)
      |> Map.put(:script_name, ["images"])
      |> IP.Plug.call(IP.Plug.init(config: config, allow_debug_headers: true))

    assert response.status == 200
    assert Image.width(Image.from_binary!(response.resp_body)) == 30
    assert_receive :source_fetch
    assert {:ok, native} = IP.run(config, client, {:source, "photo.jpg"})
    assert native.data == response.resp_body
    assert_receive :source_fetch
    random = IP.URL.url!(client, "photo.jpg", iv: :random)
    refute random == url
    assert IP.URL.url!(client, "photo.jpg") == url

    response =
      conn(:get, random)
      |> Map.put(:script_name, ["images"])
      |> IP.Plug.call(IP.Plug.init(config))

    assert response.status == 200
  end

  test "generated signed URLs execute the same plan as direct Elixir", %{
    body: body,
    sources: sources
  } do
    for {encrypt?, options} <- [
          {false, []},
          {true, []},
          {true, [iv: :random]},
          {true, [iv: <<7::128>>]}
        ] do
      url_config =
        IP.URL.config(
          base_url: "https://cdn.test/images",
          keys: [@key],
          source_encryption_keys: [@encryption_key],
          encrypt_source: encrypt?
        )

      config = IP.config(url: url_config, sources: sources)

      plan =
        IP.URL.new(url_config, expires: 2_000_000_000)
        |> IP.URL.group(resize: [width: 30, height: 20], brightness: 10)
        |> IP.URL.group(padding: 2, background: "white")
        |> IP.URL.output(format: :png)

      assert {:ok, result} = IP.run(config, plan, {:binary, body})
      mount = IP.Plug.init(config)
      url = IP.URL.url!(plan, "photo.jpg", options)
      refute_received :source_fetch
      response = conn(:get, url) |> Map.put(:script_name, ["images"]) |> IP.Plug.call(mount)
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["image/png"]
      assert_received :source_fetch
      output = Image.from_binary!(response.resp_body)
      assert {Image.width(output), Image.height(output)} == {34, 24}

      assert VipsImage.write_to_binary(output) ==
               VipsImage.write_to_binary(Image.from_binary!(result.data))
    end
  end

  test "tampering and expiry fail before source or cache access", %{sources: sources} do
    url_config =
      IP.URL.config(keys: [@key], source_encryption_keys: [@encryption_key], encrypt_source: true)

    config =
      IP.config(url: url_config, sources: sources, cache: {CacheProbe, []}, clock: fn -> 100 end)

    mount = IP.Plug.init(config)
    expired = IP.URL.url!(IP.URL.new(url_config, expires: 99), "photo.jpg")

    tampered =
      IP.URL.url!(IP.URL.new(url_config) |> IP.URL.group(gray: true), "photo.jpg")
      |> String.replace("/gray/", "/bitonal/")

    for {path, status} <- [{expired, 410}, {tampered, 403}] do
      response = conn(:get, path) |> IP.Plug.call(mount)
      assert response.status == status
      refute_received :source_fetch
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end
end
