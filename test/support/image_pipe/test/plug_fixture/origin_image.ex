defmodule ImagePipe.Test.PlugFixture.OriginImage do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def call(conn, _opts) do
    body = File.read!("priv/static/images/beach.jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
