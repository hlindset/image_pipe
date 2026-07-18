defmodule ImagePipe.Dialect.TwicPics.Errors do
  @moduledoc false

  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  alias ImagePipe.Response.ErrorStatus

  @type header :: {String.t(), String.t()}

  @doc false
  @spec send_parse(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send_parse(%Plug.Conn{} = conn, reason, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  @doc false
  @spec send(Plug.Conn.t(), term(), keyword(), [header()]) :: Plug.Conn.t()
  def send(conn, reason, config, headers \\ [])

  def send(%Plug.Conn{} = conn, {:session, reason}, config, headers) do
    exception = RuntimeError.exception("delivery session failed: #{inspect(reason)}")
    send_core(conn, {:encode, exception, []}, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config, headers) do
    send_core(conn, {:decode, reason}, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:transform, reason}, config, headers) do
    send_core(conn, {:transform_error, reason}, config, headers)
  end

  def send(%Plug.Conn{} = conn, reason, config, headers) do
    send_core(conn, reason, config, headers)
  end

  defp send_core(%Plug.Conn{} = conn, reason, config, headers) do
    {status, body} = ErrorStatus.resolve_status(reason, config)

    conn
    |> put_headers(headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp put_headers(%Plug.Conn{} = conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end
end
