defmodule ImagePipeFiddleWeb.NativePathController do
  use ImagePipeFiddleWeb, :controller

  alias ImagePipeFiddle.NativePath

  def create(conn, %{"tail" => tail, "protection" => protection}) do
    config = :persistent_term.get({ImagePipeFiddle.Application, :native_signed_opts})

    case NativePath.protect(tail, protection, config) do
      {:ok, path} -> json(conn, %{path: path})
      {:error, :invalid_request} -> invalid_request(conn)
    end
  end

  def create(conn, _params), do: invalid_request(conn)

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid request"})
  end
end
