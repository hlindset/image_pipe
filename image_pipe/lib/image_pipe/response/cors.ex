defmodule ImagePipe.Response.CORS do
  @moduledoc false

  import Plug.Conn, only: [put_resp_header: 3, register_before_send: 2, send_resp: 3]

  @allow "GET, HEAD"
  @allow_methods "GET, HEAD, OPTIONS"

  @doc """
  Register a before-send hook that stamps `Access-Control-Allow-Origin` and
  `Access-Control-Expose-Headers: *` on every response when `allow_origin` is
  configured, else a no-op. One registration covers image, info, redirect,
  error, 304, OPTIONS, and 405 outcomes. CORS here never allows credentials, so
  the `*` wildcard is valid.
  """
  @spec maybe_register(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def maybe_register(%Plug.Conn{} = conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil ->
        conn

      origin when is_binary(origin) ->
        register_before_send(conn, fn conn ->
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("access-control-expose-headers", "*")
        end)
    end
  end

  @doc """
  Answer an `OPTIONS` request: always `204 No Content` + `Allow: GET, HEAD`, plus
  `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers: *` when CORS
  is configured, so a preflight for conditional headers such as `If-None-Match`
  passes. The
  `Access-Control-Allow-Origin` header is added by the `maybe_register/2`
  before-send hook, so there is one source for it.
  """
  @spec send_options(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def send_options(%Plug.Conn{} = conn, opts) do
    conn
    |> put_resp_header("allow", @allow)
    |> put_preflight_headers(opts)
    |> send_resp(204, "")
  end

  defp put_preflight_headers(conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil ->
        conn

      _origin ->
        conn
        |> put_resp_header("access-control-allow-methods", @allow_methods)
        |> put_resp_header("access-control-allow-headers", "*")
    end
  end
end
