defmodule ImagePipe.API.CacheFailOpenWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.RaisingOpenCache

  @moduletag capture_log: true

  for {output, content_type} <- [
        {"w=12/format=png", "image/png"},
        {"output=info", "application/json; charset=utf-8"}
      ] do
    test "#{output} is delivered when the cache adapter raises while opening" do
      body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".jpg")
      origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

      opts = [
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             internal_cache: :enabled,
             req_options: [plug: origin]}
        ]
      ]

      path = "/#{unquote(output)}/src/source.jpg"
      baseline = ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(opts))

      config =
        ImagePipe.Plug.init(Keyword.put(opts, :cache, {RaisingOpenCache, test_pid: self()}))

      response = ImagePipe.Plug.call(conn(:get, path), config)

      assert_received :cache_open_attempted
      assert baseline.status == 200
      assert response.status == 200
      assert get_resp_header(response, "content-type") == [unquote(content_type)]
      assert response.resp_body == baseline.resp_body
      refute_received :cache_write_attempted
      refute_received :cache_commit_attempted
    end
  end
end
