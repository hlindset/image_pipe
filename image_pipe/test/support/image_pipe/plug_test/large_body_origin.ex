defmodule ImagePipe.PlugTest.LargeBodyOrigin do
  @moduledoc false
  def call(conn, _opts) do
    body = :binary.copy("a", 10_000_001)

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
