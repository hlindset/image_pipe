defmodule ImagePipe.PlugDialectRunnerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.RunnerFixtureDialect
  alias ImgproxyWireConformanceTest.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    base =
      ImagePipe.Plug.init(
        Keyword.merge([dialect: RunnerFixtureDialect, sources: @sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  test "serves an image with an ETag through the dialect mode" do
    conn = get("/fix/images/beach.jpg?format=webp", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/webp"
    assert [etag] = get_resp_header(conn, "etag")
    assert is_binary(etag)
  end

  test "parse errors render through the dialect's render_error" do
    conn = get("/fix/images/beach.jpg?boom=parse", opts())
    assert conn.status == 422
    assert conn.resp_body == "fixture parse reject"
  end

  test "OPTIONS answers 204 and non-GET/HEAD answers 405" do
    assert ImagePipe.Plug.call(conn(:options, "/fix/x.jpg"), opts()).status == 204
    assert ImagePipe.Plug.call(conn(:post, "/fix/x.jpg"), opts()).status == 405
  end
end
