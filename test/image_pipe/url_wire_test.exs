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

  setup do
    image = Image.new!(60, 40, color: [80, 120, 160])
    body = Image.write!(image, :memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end

    sources = [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
    ]

    %{body: body, sources: sources}
  end

  test "one shared config supplies encryption, signing, URL defaults, and processing", %{
    sources: sources
  } do
    config =
      IP.config(
        sources: sources,
        base_url: "https://cdn.test/images",
        keys: [@key],
        source_encryption_keys: [@encryption_key],
        encrypt_source: true,
        iv_mode: :deterministic,
        quality: 71
      )

    client = IP.new(config) |> IP.group(resize: [width: 30]) |> IP.output(format: :png)
    url = IP.url!(client, "photo.jpg")
    assert url == IP.url!(client, "photo.jpg")
    assert String.starts_with?(url, "https://cdn.test/images/sig=")
    assert url =~ "/enc/"
    refute url =~ "photo.jpg"
    refute_received :source_fetch

    response =
      conn(:get, url)
      |> Map.put(:script_name, ["images"])
      |> IP.Plug.call(IP.Plug.init(config: config, allow_debug_headers: true))

    assert response.status == 200
    assert_receive :source_fetch
    assert {:ok, native} = IP.run(client, {:source, "photo.jpg"})
    assert native.data == response.resp_body
    assert_receive :source_fetch
    random = IP.url!(client, "photo.jpg", iv: :random)
    refute random == url
    assert IP.url!(client, "photo.jpg") == url

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
      config =
        IP.config(
          sources: sources,
          base_url: "https://cdn.test/images",
          keys: [@key],
          source_encryption_keys: [@encryption_key],
          encrypt_source: encrypt?
        )

      plan =
        IP.new(config, expires: 2_000_000_000)
        |> IP.group(resize: [width: 30, height: 20], brightness: 10)
        |> IP.group(padding: 2, background: "white")
        |> IP.output(format: :png)

      assert {:ok, result} = IP.run(plan, {:binary, body})
      mount = IP.Plug.init(config)
      url = IP.url!(plan, "photo.jpg", options)
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
    config =
      IP.config(
        sources: sources,
        keys: [@key],
        source_encryption_keys: [@encryption_key],
        encrypt_source: true,
        cache: {CacheProbe, []},
        clock: fn -> 100 end
      )

    mount = IP.Plug.init(config)
    expired = IP.url!(IP.new(config, expires: 99), "photo.jpg")

    tampered =
      IP.url!(IP.new(config) |> IP.group(gray: true), "photo.jpg")
      |> String.replace("/gray/", "/bitonal/")

    for {path, status} <- [{expired, 404}, {tampered, 403}] do
      response = conn(:get, path) |> IP.Plug.call(mount)
      assert response.status == status
      refute_received :source_fetch
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end
end
