defmodule ImagePipe.Source.MountsWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  @sources Path.expand("test/support/image_pipe/test/sources")

  setup do
    mount = fn match, root_id ->
      [
        adapter: ImagePipe.Source.File,
        match: match,
        options: [root: @sources, root_id: root_id]
      ]
    end

    config =
      ImagePipe.Plug.init(
        sources: [
          media: mount.([prefix: "media"], "media"),
          assets: mount.([scheme: "asset"], "assets"),
          static: mount.(:path, "static")
        ]
      )

    %{config: config}
  end

  test "prefix, custom-scheme, and fallback mounts each serve their sources", %{config: config} do
    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 10])
      |> ImagePipe.URL.output(format: :png)

    for source <- ["media/alpha.png", "asset://alpha.png", "alpha.png"] do
      conn = conn(:get, ImagePipe.URL.url!(builder, source)) |> ImagePipe.Plug.call(config)

      assert conn.status == 200, source
      assert Image.width(Image.from_binary!(conn.resp_body)) == 10
    end
  end

  test "a bare prefix and dot segments are rejected", %{config: config} do
    for path <- ["/src/media", "/src/media/../alpha.png", "/src/asset:%2F%2F..%2Falpha.png"] do
      assert (conn(:get, path) |> ImagePipe.Plug.call(config)).status == 404, path
    end
  end
end
