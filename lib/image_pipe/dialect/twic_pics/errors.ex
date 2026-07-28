defmodule ImagePipe.Dialect.TwicPics.Errors do
  @moduledoc false

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  alias ImagePipe.Response.ErrorStatus

  @doc false
  @spec send_parse(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send_parse(%Plug.Conn{} = conn, reason, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  @doc false
  @spec send(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, {:session, reason}, config) do
    exception = RuntimeError.exception("delivery session failed: #{inspect(reason)}")
    send_core(conn, {:encode, exception, []}, config)
  end

  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config) do
    send_core(conn, {:decode, reason}, config)
  end

  def send(%Plug.Conn{} = conn, {:transform, reason}, config) do
    send_core(conn, {:transform_error, reason}, config)
  end

  def send(%Plug.Conn{} = conn, reason, config) do
    send_core(conn, reason, config)
  end

  defp send_core(%Plug.Conn{} = conn, reason, config) do
    {status, body} = ErrorStatus.resolve_status(reason, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
