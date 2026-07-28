defmodule ImagePipe.PlugRedirectTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  defmodule RedirectDialect do
    use ImagePipe.Dialect.Declarative

    @impl ImagePipe.Dialect
    def validate_config!(opts), do: opts

    @impl ImagePipe.Dialect.Declarative
    def parse_plan(_conn, _config), do: {:redirect, 303, "/iiif/abc/info.json"}

    @impl ImagePipe.Dialect
    def render_error(conn, _reason, _config), do: send_resp(conn, 400, "")
  end

  test "a {:redirect, …} parse result short-circuits to a 303 with Location" do
    conn =
      conn(:get, "/iiif/abc")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(dialect: RedirectDialect))

    assert conn.status == 303
    assert get_resp_header(conn, "location") == ["/iiif/abc/info.json"]
  end
end
