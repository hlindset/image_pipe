defmodule ImagePipe.Test.BodyOrigin do
  @moduledoc false
  # Origin plug that serves the configured `{body, content_type}` for every
  # request.

  use Boundary, top_level?: true, deps: []

  def init({body, content_type}), do: {body, content_type}

  def call(conn, {body, content_type}) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(200, body)
  end
end
