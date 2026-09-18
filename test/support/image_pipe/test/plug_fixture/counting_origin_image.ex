defmodule ImagePipe.Test.PlugFixture.CountingOriginImage do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts

  def call(conn, opts) do
    opts
    |> Keyword.fetch!(:test_pid)
    |> send(:origin_fetch)

    body = File.read!("priv/static/images/beach.jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
