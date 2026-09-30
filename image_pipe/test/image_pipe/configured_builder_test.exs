defmodule ImagePipe.ConfiguredBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe, as: IP

  test "one validated configuration serves direct execution and a Plug mount" do
    config = IP.config(quality: 63, max_result_width: 12)
    client = IP.URL.new()
    thumbnail = client |> IP.URL.group(resize: [width: 30]) |> IP.URL.output(format: :png)
    bytes = Image.new!(60, 40) |> Image.write!(:memory, suffix: ".png")

    assert {:ok, result} = IP.run(config, thumbnail, {:binary, bytes})
    assert result.width == 12
    assert IP.URL.url!(client, "photo.png") == "/src/photo.png"
    assert IP.URL.url!(thumbnail, "photo.png") == "/w=30/format=png/src/photo.png"

    mount = IP.Plug.init(config: config, allow_debug_headers: true)
    assert mount[:quality] == 63
    assert mount[:max_result_width] == 12
    assert mount[:allow_debug_headers]
    assert IP.Plug.init(config)[:quality] == 63
  end

  test "configuration validates host options and keeps credentials out of inspection" do
    secret = "source-credential-value"

    config =
      IP.config(
        sources: [
          path: [adapter: ImagePipe.RunTest.OwnedSource, match: :path, options: [secret: secret]]
        ]
      )

    refute inspect(config) =~ secret
    assert_raise ArgumentError, fn -> IP.config(unknown: secret) end
    assert_raise ArgumentError, fn -> IP.config(allow_origin: "*") end
  end

  test "request-wide controls remain independent of shared configuration" do
    client = IP.URL.new(expires: 2_000_000_000)
    assert IP.URL.url!(client, "photo.png") == "/expires=2000000000/src/photo.png"
  end

  test "configured files share output entries across native and HTTP calls" do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-configured-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    config =
      IP.config(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [
              root: Path.expand("test/support/image_pipe/test/sources"),
              root_id: "test-images",
              stable: :trusted
            ]
          ]
        ],
        cache: {ImagePipe.Cache.FileSystem, root: root}
      )

    client = IP.URL.new() |> IP.URL.group(resize: [width: 3]) |> IP.URL.output(format: :png)
    assert {:ok, first} = IP.run(config, client, {:source, "small.png"})

    http =
      IP.Plug.call(
        Plug.Test.conn(:get, IP.URL.url!(client, "small.png")),
        IP.Plug.init(config: config, max_input_pixels: 1)
      )

    assert http.status == 200
    assert http.resp_body == first.data
    assert {:ok, again} = IP.run(config, client, {:source, "small.png"}, max_input_pixels: 1)
    assert again == first
    uncached = IP.URL.new() |> IP.URL.group(resize: [width: 4]) |> IP.URL.output(format: :png)

    assert {:error, {:input_limit, _}} =
             IP.run(config, uncached, {:source, "small.png"}, max_input_pixels: 1)
  end
end
