defmodule OverlapDecodeOrigin do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn = Plug.Conn.put_resp_content_type(conn, "image/jpeg")
    body = Keyword.fetch!(opts, :body)

    case Keyword.fetch!(opts, :mode) do
      "auto" ->
        Plug.Conn.send_resp(conn, 200, body)

      "burst" ->
        conn = set_length(conn, body, "paced") |> Plug.Conn.send_chunked(200)
        <<head::binary-size(1_500_000), tail::binary>> = body
        {:ok, conn} = Plug.Conn.chunk(conn, head)
        Process.sleep(8)
        paced(conn, tail)

      mode ->
        conn = set_length(conn, body, mode) |> Plug.Conn.send_chunked(200)
        paced(conn, body)
    end
  end

  defp paced(conn, body) do
    body
    |> Stream.unfold(&chunk/1)
    |> Enum.reduce(conn, fn bytes, conn ->
      Process.sleep(1)
      {:ok, conn} = Plug.Conn.chunk(conn, bytes)
      conn
    end)
  end

  defp set_length(conn, body, "paced"),
    do: Plug.Conn.put_resp_header(conn, "content-length", Integer.to_string(byte_size(body)))

  defp set_length(conn, _body, "spool"), do: conn

  defp chunk(<<>>), do: nil

  defp chunk(body) do
    count = min(byte_size(body), 65_536)
    <<bytes::binary-size(^count), rest::binary>> = body
    {bytes, rest}
  end
end
