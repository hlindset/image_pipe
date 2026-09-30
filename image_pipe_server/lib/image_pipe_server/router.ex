defmodule ImagePipeServer.Router do
  @moduledoc """
  Routes requests to `GET /health` or to the ImagePipe mount.

  `/health` stays at the root whatever the mount path. Requests outside the
  mount path answer 404. `:image_pipe` takes options already initialized with
  `ImagePipe.Plug.init/1`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      mount: Plug.Router.Utils.split(Keyword.fetch!(opts, :mount_path)),
      image_pipe: Keyword.fetch!(opts, :image_pipe)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: method, path_info: ["health"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def call(conn, %{mount: mount, image_pipe: image_pipe}) do
    case strip_prefix(conn.path_info, mount) do
      {:ok, rest} -> Plug.forward(conn, rest, ImagePipe.Plug, image_pipe)
      :error -> send_resp(conn, 404, "")
    end
  end

  defp strip_prefix(path, []), do: {:ok, path}
  defp strip_prefix([segment | path], [segment | mount]), do: strip_prefix(path, mount)
  defp strip_prefix(_path, _mount), do: :error
end
