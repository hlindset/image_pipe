defmodule ImagePipe.Response.CORS do
  @moduledoc false

  import Plug.Conn, only: [put_resp_header: 3, register_before_send: 2, send_resp: 3]

  @allow "GET, HEAD"
  @allow_methods "GET, HEAD, OPTIONS"

  @doc """
  Register a before-send hook that stamps `Access-Control-Allow-Origin` on every
  response when `allow_origin` is configured, else a no-op. One registration
  covers image, info, redirect, error, 304, OPTIONS, and 405 outcomes.
  """
  @spec maybe_register(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def maybe_register(%Plug.Conn{} = conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil ->
        conn

      origin when is_binary(origin) ->
        register_before_send(conn, fn conn ->
          put_resp_header(conn, "access-control-allow-origin", origin)
        end)
    end
  end

  @doc """
  Answer an `OPTIONS` request: always `204 No Content` + `Allow: GET, HEAD`, plus
  `Access-Control-Allow-Methods` when CORS is configured. The
  `Access-Control-Allow-Origin` header is added by the `maybe_register/2`
  before-send hook, so there is one source for it.
  """
  @spec send_options(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def send_options(%Plug.Conn{} = conn, opts) do
    conn
    |> put_resp_header("allow", @allow)
    |> put_allow_methods(opts)
    |> send_resp(204, "")
  end

  defp put_allow_methods(conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil -> conn
      _origin -> put_resp_header(conn, "access-control-allow-methods", @allow_methods)
    end
  end
end
