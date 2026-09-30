defmodule ImagePipeServer.Router do
  @moduledoc """
  Routes requests to `GET /health` or to the ImagePipe mount.

  `/health` stays at the root whatever the mount path. Requests outside the
  mount path answer 404. `:image_pipe` takes options already initialized with
  `ImagePipe.Plug.init/1`.

  With `:auth_token_hash` (the SHA-256 of the auth token), requests other than
  `/health` must send `Authorization: Bearer <token>`, or get a 401.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      mount: Plug.Router.Utils.split(Keyword.fetch!(opts, :mount_path)),
      image_pipe: Keyword.fetch!(opts, :image_pipe),
      auth_token_hash: Keyword.get(opts, :auth_token_hash)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: method, path_info: ["health"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def call(conn, %{auth_token_hash: hash} = opts) when is_binary(hash) do
    if authorized?(conn, hash) do
      route(conn, opts)
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, "")
    end
  end

  def call(conn, opts), do: route(conn, opts)

  defp route(conn, %{mount: mount, image_pipe: image_pipe}) do
    case strip_prefix(conn.path_info, mount) do
      {:ok, rest} -> Plug.forward(conn, rest, ImagePipe.Plug, image_pipe)
      :error -> send_resp(conn, 404, "")
    end
  end

  # Comparing digests keeps the comparison constant-time for any token length.
  defp authorized?(conn, hash) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), hash)
      _other -> false
    end
  end

  defp strip_prefix(path, []), do: {:ok, path}
  defp strip_prefix([segment | path], [segment | mount]), do: strip_prefix(path, mount)
  defp strip_prefix(_path, _mount), do: :error
end
