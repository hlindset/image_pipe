defmodule ImagePipeServer.Router do
  @moduledoc """
  Routes requests to the health checks or to the ImagePipe mount.

  The health checks (see `ImagePipeServer.Health`) stay at the root whatever
  the mount path. Requests outside the mount path answer 404. `:image_pipe`
  takes options already initialized with `ImagePipe.Plug.init/1`. While the
  `:drain` flag is set, every response carries `connection: close`, so
  keep-alive clients reconnect to another replica.

  With `:auth_token_hash` (the SHA-256 of the auth token), requests other than
  the health checks must send `Authorization: Bearer <token>`, or get a 401.

  Every response carries an `x-request-id`, which is also the `:request_id`
  Logger metadata for the request. With `:trust_request_id`, an incoming ID
  of 1 to 200 letters, digits, and `-_.:+/=` is kept. Otherwise the router
  generates one, so a client can't add fields to log lines.
  """

  @behaviour Plug

  import Plug.Conn

  alias ImagePipeServer.Health

  @request_id ~r"\A[A-Za-z0-9\-_.:+/=]{1,200}\z"

  @impl Plug
  def init(opts) do
    %{
      trust_request_id: Keyword.get(opts, :trust_request_id, false),
      drain: Keyword.get_lazy(opts, :drain, &Health.new/0),
      mount: Plug.Router.Utils.split(Keyword.fetch!(opts, :mount_path)),
      image_pipe: Keyword.fetch!(opts, :image_pipe),
      auth_token_hash: Keyword.get(opts, :auth_token_hash)
    }
  end

  @impl Plug
  def call(conn, opts) do
    request_id = request_id(conn, opts.trust_request_id)
    Logger.metadata(request_id: request_id)

    conn
    |> put_resp_header("x-request-id", request_id)
    |> close_while_draining(opts.drain)
    |> dispatch(opts)
  end

  # HTTP/2 forbids connection headers; only HTTP/1 connections close this way.
  defp close_while_draining(conn, drain) do
    if Health.draining?(drain) and get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"],
      do: put_resp_header(conn, "connection", "close"),
      else: conn
  end

  defp request_id(conn, true) do
    case get_req_header(conn, "x-request-id") do
      [id | _rest] -> if Regex.match?(@request_id, id), do: id, else: Plug.RequestId.generate()
      [] -> Plug.RequestId.generate()
    end
  end

  defp request_id(_conn, false), do: Plug.RequestId.generate()

  defp dispatch(conn, opts) do
    cond do
      Health.check?(conn) -> Health.respond(conn, opts.drain)
      is_binary(opts.auth_token_hash) -> authorize(conn, opts)
      true -> route(conn, opts)
    end
  end

  defp authorize(conn, %{auth_token_hash: hash} = opts) do
    if authorized?(conn, hash) do
      route(conn, opts)
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, "")
    end
  end

  defp route(conn, %{mount: mount, image_pipe: image_pipe}) do
    case strip_prefix(conn.path_info, mount) do
      {:ok, rest} -> Plug.forward(conn, rest, ImagePipe.Plug, image_pipe)
      :error -> send_resp(conn, 404, "")
    end
  end

  # Comparing digests keeps the comparison constant-time for any token length.
  # The scheme is case-insensitive (RFC 9110 §11.1).
  defp authorized?(conn, hash) do
    with [<<scheme::binary-size(7), token::binary>>] <- get_req_header(conn, "authorization"),
         "bearer " <- String.downcase(scheme) do
      Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), hash)
    else
      _other -> false
    end
  end

  defp strip_prefix(path, []), do: {:ok, path}
  defp strip_prefix([segment | path], [segment | mount]), do: strip_prefix(path, mount)
  defp strip_prefix(_path, _mount), do: :error
end
