defmodule ImagePipeServer.Router do
  @moduledoc """
  Routes requests to `GET /health` or to the ImagePipe mount.

  `/health` stays at the root whatever the mount path. Requests outside the
  mount path answer 404. `:image_pipe` takes options already initialized with
  `ImagePipe.Plug.init/1`.

  With `:auth_token_hash` (the SHA-256 of the auth token), requests other than
  `/health` must send `Authorization: Bearer <token>`, or get a 401.

  Every response carries an `x-request-id`, kept from the request when valid,
  which is also the `:request_id` Logger metadata for the request.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      request_id: Plug.RequestId.init([]),
      mount: Plug.Router.Utils.split(Keyword.fetch!(opts, :mount_path)),
      image_pipe: Keyword.fetch!(opts, :image_pipe),
      auth_token_hash: Keyword.get(opts, :auth_token_hash)
    }
  end

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.RequestId.call(opts.request_id)
    |> dispatch(opts)
  end

  defp dispatch(%Plug.Conn{method: method, path_info: ["health"]} = conn, _opts)
       when method in ["GET", "HEAD"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  defp dispatch(conn, %{auth_token_hash: hash} = opts) when is_binary(hash) do
    if authorized?(conn, hash) do
      route(conn, opts)
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, "")
    end
  end

  defp dispatch(conn, opts), do: route(conn, opts)

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
