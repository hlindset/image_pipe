defmodule ImagePipe.Dialect.DeclarativeTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.DeclarativeFixtureDialect

  defmodule OriginImage do
    @moduledoc false

    # A 200×300 opaque PNG: large enough that the fixture's width-only fit
    # resize downscales rather than enlarges.
    def init(opts), do: opts

    def call(conn, _opts) do
      body = Image.new!(200, 300, color: [100, 150, 200]) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
    ]
  end

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(
      Keyword.merge([dialect: DeclarativeFixtureDialect, sources: sources()], extra)
    )
  end

  defp get(path, config), do: ImagePipe.Plug.call(conn(:get, path), config)

  test "a minimal host dialect mounts and serves an image" do
    conn = get("/images/beach.jpg?w=64", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    {:ok, image} = Image.open(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "the host's parse rejection reaches its own render_error as a parse Failure" do
    conn = get("/images/beach.jpg?w=nope", opts())

    assert conn.status == 400
    assert conn.resp_body =~ "invalid_width"
  end

  test "http_cache: [mode: :enabled] generates CDN headers and round-trips a 304" do
    config = opts(http_cache: [mode: :enabled])
    conn = get("/images/beach.jpg?w=64", config)

    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert [etag] = get_resp_header(conn, "etag")

    revalidated =
      :get
      |> conn("/images/beach.jpg?w=64")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(config)

    assert revalidated.status == 304
  end

  test "without http_cache: [mode: :enabled] the declarative tier emits no ETag" do
    conn = get("/images/beach.jpg?w=64", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "etag") == []
  end
end
