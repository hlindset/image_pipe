defmodule ImagePipe.PlugTest.LargeBodyOrigin do
  @moduledoc false
  # One byte over the default body limit, with a JPEG signature so detection
  # admits it to the (stubbed) loader.
  def call(conn, _opts) do
    body = <<0xFF, 0xD8, 0xFF>> <> :binary.copy("a", 10_000_001 - 3)

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
